import Foundation
import Observation
@preconcurrency import linphonesw

/// The single owner of the liblinphone `Core` (docs/01 section 4). Main-actor only: the Core runs
/// with auto-iterate on the main thread, so every delegate callback arrives here as well.
///
/// Phase 0 scope: register over TLS, place and receive audio calls in the foreground, mute,
/// speaker, DTMF, hang up. CallKit (phase 1) and push (phase 2) plug in through `CallKitBridge`
/// hooks that are deliberately not here yet; see docs/02.
@MainActor
@Observable
public final class CallEngine {
    // MARK: Observable state

    public private(set) var registration: RegistrationStatus = .unconfigured
    public private(set) var call: ActiveCall?
    public private(set) var account: SIPAccount?
    public private(set) var sdkVersion: String = ""
    public private(set) var instanceID: String = ""
    /// Last engine-level problem worth showing (registration is reported through `registration`).
    public private(set) var lastError: SoftphoneError?

    // MARK: Private

    @ObservationIgnored private let store: AccountStore
    @ObservationIgnored private var core: Core?
    @ObservationIgnored private var coreDelegate: CoreDelegateStub?
    @ObservationIgnored private var logDelegate: LoggingServiceDelegateStub?
    @ObservationIgnored private var sdkAccount: Account?
    @ObservationIgnored private var sdkCall: Call?
    @ObservationIgnored private var speakerDevice: AudioDevice?
    @ObservationIgnored private var earpieceDevice: AudioDevice?

    public init(store: AccountStore = AccountStore()) {
        self.store = store
    }

    // MARK: Lifecycle

    /// Creates and starts the Core once. Safe to call again (no-op). Loads the stored account.
    public func start() {
        guard core == nil else { return }
        do {
            installSDKLogging()
            let factory = Factory.Instance
            // No config file (S6): with a path, liblinphone persists accounts, auth info (password/ha1)
            // and flags such as verify_server_certs in plain text and restores them on the next launch
            // (seen 2026-09-14). The Keychain is the only store; everything is re-applied at start.
            let core = try factory.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil)
            Self.removeLegacyConfigFile(factory)
            self.core = core
            sdkVersion = Core.getVersion

            // +sip.instance (S3): fixed per installation, set before start (misc/uuid is read in start).
            instanceID = (try? store.instanceID()) ?? UUID().uuidString.lowercased()
            core.config?.setString(section: "misc", key: "uuid", value: instanceID)

            core.autoIterateEnabled = true
            // Phase 0 has no CallKit and no push yet; both flip to true in phases 1 and 2.
            core.callkitEnabled = false
            core.pushNotificationEnabled = false
            core.setUserAgent(name: "CallTo", version: Self.appVersion)
            // Media: SRTP offered, plain accepted (the edge decides per leg); opus first, PCMA fallback (D9).
            try core.setMediaencryption(newValue: .SRTP)
            core.mediaEncryptionMandatory = false
            configureCodecs(core)
            core.useRfc2833ForDtmf = true
            core.useInfoForDtmf = false
            core.echoCancellationEnabled = true
            core.nativeRingingEnabled = false   // becomes CallKit's job in phase 1

            installCoreDelegate(core)
            try core.start()
            refreshAudioDevices(core)
            Diagnostics.sip.info("core started, liblinphone \(self.sdkVersion, privacy: .public), instance \(self.instanceID, privacy: .public)")
        } catch {
            Diagnostics.sip.error("core start failed: \(String(describing: error), privacy: .public)")
            lastError = .sdk(String(describing: error))
            return
        }
        // The Keychain is separate from the Core: an unreadable item (e.g. an unsigned test host,
        // errSecMissingEntitlement -34018) must not look like an SDK failure.
        do {
            if let stored = try store.loadAccount() {
                configure(account: stored, persist: false)
            }
        } catch {
            Diagnostics.sip.warning("stored account unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces the account: removes the previous one, registers the new one. `persist` writes it
    /// to the Keychain (phase 0 dev screen; from phase 3 enrollment does the persisting).
    public func configure(account: SIPAccount, persist: Bool = true) {
        guard let core else { lastError = .sdk("core not started"); return }
        do {
            if persist { try store.save(account) }
            self.account = account
            lastError = nil

            core.clearAccounts()
            core.clearAllAuthInfo()

            let realm = account.realm?.isEmpty == false ? account.realm : account.domain
            let auth = try Factory.Instance.createAuthInfo(
                username: account.username,
                userid: nil,
                passwd: account.password?.isEmpty == false ? account.password : nil,
                ha1: account.ha1?.isEmpty == false ? account.ha1 : nil,
                realm: realm,
                domain: account.domain
            )
            core.addAuthInfo(info: auth)

            let params = try core.createAccountParams()
            let identity = try Factory.Instance.createAddress(addr: account.identity)
            try params.setIdentityaddress(newValue: identity)
            let server = try Factory.Instance.createAddress(addr: account.serverURI)
            try server.setTransport(newValue: Self.sdkTransport(account.transport))
            try params.setServeraddress(newValue: server)
            params.outboundProxyEnabled = true      // everything goes through the edge, the domain does not resolve
            params.registerEnabled = true
            params.expires = 600                    // matches the platform's default_expires
            params.pushNotificationAllowed = false  // phase 2

            #if DEBUG
            // S5: development toggle only; release builds never reach this line.
            core.verifyServerCertificates(yesno: !account.trustAnyCertificate)
            core.verifyServerCn(yesno: !account.trustAnyCertificate)
            #endif

            let sdkAccount = try core.createAccount(params: params)
            try core.addAccount(account: sdkAccount)
            core.defaultAccount = sdkAccount
            self.sdkAccount = sdkAccount
            registration = .registering
            Diagnostics.sip.info("account configured: \(account.identity, privacy: .public) via \(account.serverURI, privacy: .public)")
        } catch {
            Diagnostics.sip.error("account configure failed: \(String(describing: error), privacy: .public)")
            registration = .failed(String(describing: error))
        }
    }

    /// Unregisters and forgets the account (dev screen "Sign out").
    public func removeAccount() {
        guard let core else { return }
        core.clearAccounts()
        core.clearAllAuthInfo()
        try? store.clearAccount()
        sdkAccount = nil
        account = nil
        registration = .unconfigured
    }

    public func enterBackground() { core?.enterBackground() }
    public func enterForeground() { core?.enterForeground() }

    // MARK: Call intents

    public func placeCall(to raw: String) {
        guard let core, let account else { lastError = .notConfigured; return }
        guard registration.isRegistered else { lastError = .notRegistered; return }
        guard call == nil else { lastError = .busy; return }
        guard case .success(let uri) = DialString.sipURI(raw, domain: account.domain) else {
            lastError = .invalidNumber
            return
        }
        do {
            let address = try Factory.Instance.createAddress(addr: uri)
            guard let sdkCall = core.inviteAddress(addr: address) else {
                lastError = .sdk("invite returned nil")
                return
            }
            self.sdkCall = sdkCall
            lastError = nil
            Diagnostics.sip.info("invite \(uri, privacy: .public) call-id \(sdkCall.callLog?.callId ?? "?", privacy: .public)")
        } catch {
            lastError = .sdk(String(describing: error))
        }
    }

    public func accept() {
        guard let sdkCall else { return }
        do { try sdkCall.accept() } catch { lastError = .sdk(String(describing: error)) }
    }

    public func decline() {
        guard let sdkCall else { return }
        do { try sdkCall.decline(reason: .Declined) } catch { lastError = .sdk(String(describing: error)) }
    }

    public func hangUp() {
        guard let sdkCall else { return }
        do { try sdkCall.terminate() } catch { lastError = .sdk(String(describing: error)) }
    }

    public func toggleMute() {
        guard let core, call != nil else { return }
        core.micEnabled.toggle()
        call?.muted = !core.micEnabled
    }

    public func toggleSpeaker() {
        guard let core, call != nil else { return }
        refreshAudioDevices(core)
        let wantSpeaker = !(call?.speakerOn ?? false)
        if let device = wantSpeaker ? speakerDevice : earpieceDevice {
            core.outputAudioDevice = device
            sdkCall?.outputAudioDevice = device
            call?.speakerOn = wantSpeaker
        }
    }

    public func sendDTMF(_ digit: Character) {
        guard let sdkCall, let ascii = digit.asciiValue else { return }
        do { try sdkCall.sendDtmf(dtmf: CChar(ascii)) } catch { lastError = .sdk(String(describing: error)) }
    }

    public func clearError() { lastError = nil }

    // MARK: Delegates

    private func installCoreDelegate(_ core: Core) {
        let delegate = CoreDelegateStub(
            onCallStateChanged: { _, call, state, message in
                MainActor.assumeIsolated { CallEngine.current?.callStateChanged(call, state, message) }
            },
            onAudioDevicesListUpdated: { core in
                MainActor.assumeIsolated { CallEngine.current?.refreshAudioDevices(core) }
            },
            onAccountRegistrationStateChanged: { _, _, state, message in
                MainActor.assumeIsolated { CallEngine.current?.registrationChanged(state, message) }
            }
        )
        core.addDelegate(delegate: delegate)
        coreDelegate = delegate
        CallEngine.current = self
    }

    /// The Core is a singleton per process; delegate closures are not actor-isolated, so they
    /// re-enter through this static instead of capturing `self` (keeps Swift 6 strict concurrency honest).
    private nonisolated(unsafe) static var current: CallEngine?

    private func registrationChanged(_ state: RegistrationState, _ message: String) {
        switch state {
        case .Ok: registration = .registered
        case .Progress, .Refreshing: registration = .registering
        case .Cleared: registration = .cleared
        case .Failed:
            registration = .failed(Self.registrationFailureText(sdkAccount?.errorInfo, message))
            stopRetryingAfterAuthFailure()
        case .None: registration = account == nil ? .unconfigured : .cleared
        }
        Diagnostics.sip.info("registration \(String(describing: state), privacy: .public): \(message, privacy: .public)")
    }

    /// A wrong credential must not be retried: liblinphone re-sends the same digest until the edge
    /// bans the source IP (Kamailio: 10 failed authentications -> 5 minutes of silent drops, which the
    /// client then sees as 408 timeouts; happened 2026-09-14). Registration stays off until the user
    /// re-enters the account (`configure`), which creates a fresh Account with register enabled.
    private func stopRetryingAfterAuthFailure() {
        guard let sdkAccount, let reason = sdkAccount.errorInfo?.reason,
              reason == .Unauthorized || reason == .Forbidden,
              let params = sdkAccount.params?.clone() else { return }
        params.registerEnabled = false
        sdkAccount.params = params
        Diagnostics.sip.warning("registration disabled after an authentication failure; fix the account and register again")
    }

    /// liblinphone reports transport problems as "io error"; say what a user can act on.
    private static func registrationFailureText(_ info: ErrorInfo?, _ message: String) -> String {
        guard let info else { return message }
        switch info.reason {
        case .IOError: return "cannot reach the edge (network, port or certificate)"
        case .Unauthorized, .Forbidden: return "wrong extension or password (registration stopped)"
        case .NotFound: return "unknown extension or domain"
        default:
            if info.protocolCode > 0, let phrase = info.phrase { return "\(info.protocolCode) \(phrase)" }
            return message
        }
    }

    private func callStateChanged(_ sdk: Call, _ state: Call.State, _ message: String) {
        let callID = sdk.callLog?.callId ?? "?"
        Diagnostics.sip.info("call \(callID, privacy: .public) -> \(String(describing: state), privacy: .public) \(message, privacy: .public)")

        switch state {
        case .IncomingReceived, .PushIncomingReceived:
            if let existing = sdkCall, existing !== sdk {
                // MVP: one call at a time; a second incoming call is busy-declined (call waiting later).
                try? sdk.decline(reason: .Busy)
                return
            }
            sdkCall = sdk
            call = ActiveCall(
                callID: callID,
                direction: .incoming,
                remoteNumber: sdk.remoteAddress?.username ?? "unknown",
                remoteName: sdk.remoteAddress?.displayName,
                phase: state == .PushIncomingReceived ? .incomingPush : .incoming,
                sdkState: String(describing: state),
                startedAt: Date()
            )
        case .OutgoingInit, .OutgoingProgress:
            upsertOutgoing(sdk, phase: .dialing, state: state)
        case .OutgoingRinging, .OutgoingEarlyMedia:
            upsertOutgoing(sdk, phase: .ringing, state: state)
        case .Connected, .StreamsRunning:
            if call?.connectedAt == nil { call?.connectedAt = Date() }
            call?.phase = .active
            call?.sdkState = String(describing: state)
        case .Paused, .PausedByRemote, .Pausing:
            call?.phase = .held
            call?.sdkState = String(describing: state)
        case .Resuming:
            call?.phase = .active
        case .End, .Error:
            call?.phase = .ended(reason: Self.endReason(sdk, message))
            call?.sdkState = String(describing: state)
        case .Released:
            let reason = Self.endReason(sdk, message)
            call?.phase = .ended(reason: reason)
            sdkCall = nil
            // Keep the ended card briefly for the UI, then clear.
            let ended = call
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if let self, self.call == ended { self.call = nil }
            }
            core?.micEnabled = true
        default:
            call?.sdkState = String(describing: state)
        }
    }

    private func upsertOutgoing(_ sdk: Call, phase: CallPhase, state: Call.State) {
        if call == nil {
            call = ActiveCall(
                callID: sdk.callLog?.callId ?? "?",
                direction: .outgoing,
                remoteNumber: sdk.remoteAddress?.username ?? "unknown",
                remoteName: sdk.remoteAddress?.displayName,
                phase: phase,
                sdkState: String(describing: state),
                startedAt: Date()
            )
        } else {
            call?.phase = phase
            call?.sdkState = String(describing: state)
        }
    }

    private static func endReason(_ sdk: Call, _ message: String) -> String {
        if let info = sdk.errorInfo, info.protocolCode >= 300 {
            return "\(info.protocolCode) \(info.phrase ?? message)"
        }
        switch sdk.reason {
        case .None: return "ended"
        case .Declined: return "declined"
        case .NotAnswered: return "no answer"
        case .Busy: return "busy"
        case .NotFound: return "not found"
        default: return String(describing: sdk.reason)
        }
    }

    // MARK: Audio and codecs

    private func refreshAudioDevices(_ core: Core) {
        let devices = core.audioDevices.filter { $0.hasCapability(capability: .CapabilityPlay) }
        speakerDevice = devices.first { $0.type == .Speaker }
        earpieceDevice = devices.first { $0.type == .Earpiece } ?? devices.first { $0.type != .Speaker }
    }

    private func configureCodecs(_ core: Core) {
        let wanted = ["opus", "PCMA", "PCMU"]
        for pt in core.audioPayloadTypes {
            _ = pt.enable(enabled: wanted.contains(pt.mimeType))
        }
    }

    private func installSDKLogging() {
        let service = LoggingService.Instance
        // logLevel is a threshold: Message lets fatal/error/warning/message through, drops trace/debug.
        #if DEBUG
        service.logLevel = .Message
        #else
        service.logLevel = .Warning
        #endif
        let delegate = LoggingServiceDelegateStub(onLogMessageWritten: { _, _, level, message in
            let mapped: Diagnostics.SDKLogLevel
            if level.contains(.Error) || level.contains(.Fatal) { mapped = .error }
            else if level.contains(.Warning) { mapped = .warning }
            else if level.contains(.Message) { mapped = .info }
            else { mapped = .debug }
            Diagnostics.sdkLine(mapped, message)
        })
        service.addDelegate(delegate: delegate)
        logDelegate = delegate
    }

    /// Builds before 2026-09-14 wrote `<configDir>/linphonerc` with credentials inside; delete it once.
    private static func removeLegacyConfigFile(_ factory: Factory) {
        let path = factory.getConfigDir(context: nil) + "/linphonerc"
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
            Diagnostics.sip.notice("removed legacy linphonerc")
        }
    }

    private static func sdkTransport(_ t: SIPAccount.Transport) -> TransportType {
        switch t {
        case .tls: .Tls
        case .tcp: .Tcp
        case .udp: .Udp
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short).\(build)"
    }
}
