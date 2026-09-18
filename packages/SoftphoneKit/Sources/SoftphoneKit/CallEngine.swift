import Foundation
import Network
import Observation
@preconcurrency import linphonesw

/// The single owner of the liblinphone `Core` (docs/01 section 4). Main-actor only: the Core runs
/// with auto-iterate on the main thread, so every delegate callback arrives here as well.
///
/// Register over TLS, place and receive audio calls, mute, speaker, DTMF, hang up. With a `callKit`
/// bridge attached (phase 1, real devices) the Core runs CallKit-aware: the audio session is configured
/// and activated only from the provider callbacks (S4) and every call is reported to CallKit (docs/07).
/// Push (phase 2) plugs in next to it; see docs/02.
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
    /// What the SDK believes about the network; iOS' own view is in `pathSatisfied`. They disagree on VPNs.
    public private(set) var sdkReachable = true
    public private(set) var pathSatisfied = true
    /// Set before `start()` on real devices (AppSession); nil = phase-0 direct path (simulator).
    @ObservationIgnored public var callKit: CallKitBridge?

    // MARK: Private

    @ObservationIgnored private let store: AccountStore
    @ObservationIgnored private var core: Core?
    @ObservationIgnored private var coreDelegate: CoreDelegateStub?
    @ObservationIgnored private var logDelegate: LoggingServiceDelegateStub?
    /// Must outlive every log callback: the wrapper stores an *unretained* pointer to this Swift object
    /// in the C logging service ("swiftRef") and re-derives it on every log line, from any thread.
    /// Letting it go out of scope crashed the app at call start (mediastreamer ticker thread, 2026-09-14).
    @ObservationIgnored private var sdkLogging: LoggingService?
    @ObservationIgnored private var sdkAccount: Account?
    @ObservationIgnored private var sdkCall: Call?
    @ObservationIgnored private var speakerDevice: AudioDevice?
    @ObservationIgnored private var earpieceDevice: AudioDevice?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var reachabilityTask: Task<Void, Never>?

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
            // CallKit-aware Core when the bridge exists: the SDK then waits for activateAudioSession() before it
            // starts audio and leaves ringing to CallKit. Push flips to true in phase 2.
            core.callkitEnabled = callKit != nil
            core.pushNotificationEnabled = false
            core.setUserAgent(name: "CallTo", version: Self.appVersion)
            // Media: SRTP offered, plain accepted (the edge decides per leg); opus first, PCMA fallback (D9).
            try core.setMediaencryption(newValue: .SRTP)
            core.mediaEncryptionMandatory = false
            configureCodecs(core)
            core.useRfc2833ForDtmf = true
            core.useInfoForDtmf = false
            core.echoCancellationEnabled = true
            core.nativeRingingEnabled = false   // ringing is CallKit's (device) or nobody's (simulator)

            installCoreDelegate(core)
            try core.start()
            refreshAudioDevices(core)
            startPathMonitor()
            Diagnostics.record("sip", "core started, liblinphone \(sdkVersion), instance \(instanceID), callkit \(core.callkitEnabled)")
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
            Diagnostics.record("sip", "account configured: \(account.identity) via \(account.serverURI) (sdk reachable: \(core.isNetworkReachable))")
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

    /// Places a call. `preferredIdentity` is the `P-Preferred-Identity` value for the caller-ID choice
    /// (docs/05 §3, e.g. `<sip:+31856662750@acme.sip.local>`); nil lets the platform decide. `callKitUUID` is
    /// the id CallKit gave the call (`CXStartCallAction`); with a bridge attached, only the bridge calls this.
    /// Returns false with `lastError` set when nothing was sent.
    @discardableResult
    public func placeCall(to raw: String, preferredIdentity: String? = nil, callKitUUID: UUID? = nil) -> Bool {
        guard let core, let account else { lastError = .notConfigured; return false }
        guard registration.isRegistered else { lastError = .notRegistered; return false }
        guard call == nil else { lastError = .busy; return false }
        guard case .success(let uri) = DialString.sipURI(raw, domain: account.domain) else {
            lastError = .invalidNumber
            return false
        }
        do {
            let address = try Factory.Instance.createAddress(addr: uri)
            let params = try core.createCallParams(call: nil)
            if let preferredIdentity {
                params.addCustomHeader(headerName: "P-Preferred-Identity", headerValue: preferredIdentity)
            }
            pendingOutgoingUUID = callKitUUID
            guard let sdkCall = core.inviteAddressWithParams(addr: address, params: params) else {
                pendingOutgoingUUID = nil
                lastError = .sdk("invite returned nil")
                return false
            }
            self.sdkCall = sdkCall
            lastError = nil
            Diagnostics.record("sip", "invite \(uri) call-id \(sdkCall.callLog?.callId ?? "?") ppi \(preferredIdentity ?? "-") callkit \(callKitUUID?.uuidString ?? "-")")
            return true
        } catch {
            pendingOutgoingUUID = nil
            lastError = .sdk(String(describing: error))
            return false
        }
    }
    /// The CallKit uuid of the call being placed, adopted by the first outgoing state (OutgoingInit).
    @ObservationIgnored private var pendingOutgoingUUID: UUID?

    public func accept() {
        guard let sdkCall else { return }
        do { try sdkCall.accept() } catch { lastError = .sdk(String(describing: error)) }
    }

    public func decline() {
        guard let sdkCall else { return }
        do { try sdkCall.decline(reason: .Declined) } catch { lastError = .sdk(String(describing: error)) }
    }

    /// CallKit refused to show the call (a Focus, an unsupported handle): the caller hears busy rather than ringing
    /// a phone that shows nothing; the platform's busy handling (forwarding, voicemail) takes over.
    public func declineBusy() {
        guard let sdkCall else { return }
        do { try sdkCall.decline(reason: .Busy) } catch { lastError = .sdk(String(describing: error)) }
    }

    // MARK: CallKit audio hand-over (S4: called from the provider callbacks only, via CallKitBridge)

    /// Before `accept()` / the invite of a CallKit-started call: the SDK sets up the AVAudioSession with its defaults.
    public func configureAudioSession() { core?.configureAudioSession() }

    /// `didActivate` / `didDeactivate` of the provider: the SDK starts or stops the audio streams accordingly.
    public func audioSessionActivated(_ active: Bool) { core?.activateAudioSession(activated: active) }

    public func hangUp() {
        guard let sdkCall else { return }
        hungUpLocally = true
        do { try sdkCall.terminate() } catch { lastError = .sdk(String(describing: error)) }
    }
    @ObservationIgnored private var hungUpLocally = false

    public func toggleMute() { setMuted(!(call?.muted ?? false)) }

    public func setMuted(_ muted: Bool) {
        guard let core, call != nil else { return }
        core.micEnabled = !muted
        call?.muted = muted
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
    /// A second call attempt while one is up (the MVP has no call waiting).
    public func noteBusy() { lastError = .busy }

    // MARK: Delegates

    private func installCoreDelegate(_ core: Core) {
        // Every closure the SDK calls is @Sendable on purpose: a plain closure written inside this @MainActor method
        // would be inferred main-actor-isolated and the Swift 6 runtime asserts that at entry — the SDK invokes
        // some callbacks from its own threads (DNS, media), which crashed the app on iOS 26 (2026-09-18, R12).
        // Core callbacks are delivered from iterate() on the main thread (auto-iterate), hence assumeIsolated;
        // the reachability callback may come from the SDK's monitor thread, so it hops instead.
        let delegate = CoreDelegateStub(
            onCallStateChanged: { @Sendable _, call, state, message in
                MainActor.assumeIsolated { CallEngine.current?.callStateChanged(call, state, message) }
            },
            onCallStatsUpdated: { @Sendable _, call, stats in
                MainActor.assumeIsolated { CallEngine.current?.statsUpdated(call, stats) }
            },
            onNetworkReachable: { @Sendable _, reachable in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { CallEngine.current?.sdkReachabilityChanged(reachable) }
                } else {
                    Task { @MainActor in CallEngine.current?.sdkReachabilityChanged(reachable) }
                }
            },
            onAudioDevicesListUpdated: { @Sendable core in
                MainActor.assumeIsolated { CallEngine.current?.refreshAudioDevices(core) }
            },
            onAccountRegistrationStateChanged: { @Sendable _, _, state, message in
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
        Diagnostics.record("sip", "registration \(String(describing: state)): \(message)")
    }

    // MARK: Reachability

    /// liblinphone runs its own reachability monitor; on VPNs (utun interfaces) it has been seen to report the SIP
    /// host as unreachable while iOS has a perfectly good route, and it then never sends the REGISTER. When iOS says
    /// the path is satisfied and the SDK still says no after a few seconds, the SDK is told otherwise (logged).
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { @Sendable path in   // called on the monitor's queue (R12)
            let ok = path.status == .satisfied
            let ifaces = path.availableInterfaces.map { "\($0.name)/\($0.type)" }.joined(separator: ",")
            Task { @MainActor in CallEngine.current?.pathChanged(ok, ifaces) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.callto365.softphone.path"))
    }

    private func pathChanged(_ satisfied: Bool, _ interfaces: String) {
        pathSatisfied = satisfied
        Diagnostics.record("sip", "ios path \(satisfied ? "satisfied" : "unsatisfied") [\(interfaces)], sdk reachable: \(core?.isNetworkReachable ?? false)")
        reconcileReachability()
    }

    private func sdkReachabilityChanged(_ reachable: Bool) {
        sdkReachable = reachable
        Diagnostics.record("sip", "sdk network reachable: \(reachable) (ios path satisfied: \(pathSatisfied))", level: reachable ? .info : .default)
        reconcileReachability()
    }

    private func reconcileReachability() {
        reachabilityTask?.cancel()
        guard pathSatisfied, let core, !core.isNetworkReachable else { return }
        reachabilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.pathSatisfied, let core = self.core, !core.isNetworkReachable else { return }
            Diagnostics.record("sip", "sdk still says unreachable while iOS has a route: forcing network reachable (VPN?)", level: .default)
            core.networkReachable = true
        }
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
        Diagnostics.record("sip", "call \(callID) -> \(String(describing: state)) \(message)")

        switch state {
        case .IncomingReceived, .PushIncomingReceived:
            if let existing = sdkCall, existing !== sdk {
                // MVP: one call at a time; a second incoming call is busy-declined (call waiting later).
                try? sdk.decline(reason: .Busy)
                return
            }
            sdkCall = sdk
            let incoming = ActiveCall(
                callID: callID,
                direction: .incoming,
                remoteNumber: sdk.remoteAddress?.username ?? "unknown",
                remoteName: sdk.remoteAddress?.displayName,
                phase: state == .PushIncomingReceived ? .incomingPush : .incoming,
                sdkState: String(describing: state),
                startedAt: Date()
            )
            call = incoming
            capturePlatformCallID(sdk)
            // docs/02 §3: CallKit shows it (lock screen, native answer); nothing else happens with the call first.
            callKit?.reportIncoming(incoming.uuid, number: incoming.remoteNumber, name: incoming.remoteName)
        case .OutgoingInit:
            upsertOutgoing(sdk, phase: .dialing, state: state)
        case .OutgoingProgress:
            upsertOutgoing(sdk, phase: .dialing, state: state)
            if let uuid = call?.uuid { callKit?.reportOutgoingStartedConnecting(uuid) }
        case .OutgoingRinging, .OutgoingEarlyMedia:
            upsertOutgoing(sdk, phase: .ringing, state: state)
            capturePlatformCallID(sdk)
        case .Connected, .StreamsRunning:
            if call?.connectedAt == nil { call?.connectedAt = Date() }
            call?.phase = .active
            call?.sdkState = String(describing: state)
            capturePlatformCallID(sdk)
            if let uuid = call?.uuid { callKit?.reportConnected(uuid) }
        case .Paused, .PausedByRemote, .Pausing:
            call?.phase = .held
            call?.sdkState = String(describing: state)
        case .Resuming:
            call?.phase = .active
        case .End, .Error:
            call?.phase = .ended(reason: hungUpLocally ? "ended" : Self.endReason(sdk, message))
            call?.sdkState = String(describing: state)
        case .Released:
            let reason = hungUpLocally ? "ended" : Self.endReason(sdk, message)
            if let uuid = call?.uuid { callKit?.reportEnded(uuid, cause: Self.endCause(sdk, hungUpLocally: hungUpLocally)) }
            hungUpLocally = false
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

    private func statsUpdated(_ sdk: Call, _ stats: CallStats) {
        guard stats.type == .Audio, let current = sdkCall, current === sdk, call != nil else { return }
        let params = sdk.currentParams
        let codec = params?.usedAudioPayloadType.map { "\($0.mimeType)/\($0.clockRate)" } ?? "?"
        let encryption: String
        switch params?.mediaEncryption {
        case .SRTP: encryption = "SRTP"
        case .ZRTP: encryption = "ZRTP"
        case .DTLS: encryption = "DTLS-SRTP"
        case .None: encryption = "no encryption"
        case nil: encryption = "?"
        }
        call?.media = MediaStats(
            codec: codec,
            encryption: encryption,
            downloadKbps: stats.downloadBandwidth,
            uploadKbps: stats.uploadBandwidth,
            receiverLossPercent: stats.receiverLossRate,
            senderLossPercent: stats.senderLossRate,
            jitterMs: stats.jitterBufferSizeMs,
            roundTripMs: stats.roundTripDelay * 1000
        )
    }

    /// X-Call-ID-Platform from the remote party's last message (the INVITE for inbound, the 18x/200 for outbound).
    private func capturePlatformCallID(_ sdk: Call) {
        guard call?.platformCallID == nil else { return }
        let v = sdk.remoteParams?.getCustomHeader(headerName: "X-Call-ID-Platform").trimmingCharacters(in: .whitespaces) ?? ""
        if !v.isEmpty {
            call?.platformCallID = v
            Diagnostics.record("sip", "platform call id \(v)")
        }
    }

    /// Marks platform-side state the app changed through the API (AppSession), so the UI reflects it.
    public func setHeldByMe(_ held: Bool) { call?.heldByMe = held }
    public func setRecording(_ on: Bool) { call?.recording = on }

    private func upsertOutgoing(_ sdk: Call, phase: CallPhase, state: Call.State) {
        if call == nil {
            call = ActiveCall(
                uuid: pendingOutgoingUUID ?? UUID(),
                callID: sdk.callLog?.callId ?? "?",
                direction: .outgoing,
                remoteNumber: sdk.remoteAddress?.username ?? "unknown",
                remoteName: sdk.remoteAddress?.displayName,
                phase: phase,
                sdkState: String(describing: state),
                startedAt: Date()
            )
            pendingOutgoingUUID = nil
        } else {
            call?.phase = phase
            call?.sdkState = String(describing: state)
        }
    }

    /// What CallKit is told at the end (docs/07): the SDK's call log knows about the other device of the user
    /// (parallel forking: "answered elsewhere" / "declined elsewhere"), a timed-out ring is "unanswered", an
    /// outgoing call refused by the network (4xx/5xx other than busy or decline) "failed".
    static func endCause(_ sdk: Call, hungUpLocally: Bool) -> CallEndCause {
        endCause(status: sdk.callLog?.status, direction: sdk.dir, protocolCode: sdk.errorInfo?.protocolCode ?? 0, hungUpLocally: hungUpLocally)
    }

    nonisolated static func endCause(status: Call.Status?, direction: Call.Dir, protocolCode: Int, hungUpLocally: Bool) -> CallEndCause {
        switch status {
        case .AcceptedElsewhere: return .answeredElsewhere
        case .DeclinedElsewhere: return .declinedElsewhere
        case .Missed: return .unanswered
        default: break
        }
        if hungUpLocally { return .remoteEnded }   // our own end action already told CallKit; this is the fallback
        if direction == .Outgoing, protocolCode >= 400, protocolCode != 486, protocolCode != 603 { return .failed }
        return .remoteEnded
    }

    private static func endReason(_ sdk: Call, _ message: String) -> String {
        if let info = sdk.errorInfo, info.protocolCode >= 300 {
            return "\(info.protocolCode) \(info.phrase ?? message)"
        }
        switch sdk.reason {
        case .None, .Unknown: return sdk.dir == .Incoming || sdk.duration > 0 ? "ended by the other side" : "ended"
        case .Declined: return "declined"
        case .NotAnswered: return "no answer"
        case .Busy: return "busy"
        case .NotFound: return "not found"
        case .IOError: return "network error"
        default: return String(describing: sdk.reason).lowercased()
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
        // Called from any SDK thread: @Sendable, nothing main-actor inside (R12).
        let delegate = LoggingServiceDelegateStub(onLogMessageWritten: { @Sendable _, _, level, message in
            let mapped: Diagnostics.SDKLogLevel
            if level.contains(.Error) || level.contains(.Fatal) { mapped = .error }
            else if level.contains(.Warning) { mapped = .warning }
            else if level.contains(.Message) { mapped = .info }
            else { mapped = .debug }
            Diagnostics.sdkLine(mapped, message)
        })
        service.addDelegate(delegate: delegate)
        logDelegate = delegate
        sdkLogging = service
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
