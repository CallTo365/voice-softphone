import Foundation
import Observation

/// Ties enrollment (who we are on the platform), the SIP engine and the caller-ID choice together.
/// The app talks to this; `CallEngine` stays SIP-only. Everything persistent lives in the Keychain via
/// `AccountStore`; `CallerIDStore` keeps only the user's choice in `UserDefaults`.
@MainActor
@Observable
public final class AppSession {
    public let engine: CallEngine
    /// CallKit on real devices (phase 1, docs/07); nil on the simulator, where the engine is driven directly.
    public let callKit: CallKitBridge?
    public private(set) var enrollment: DeviceEnrollment?
    public private(set) var callerIDs: CallerIDStore?
    public private(set) var isEnrolling = false
    public private(set) var enrollError: PlatformAPI.Failure?

    @ObservationIgnored private let store: AccountStore
    @ObservationIgnored private var api: PlatformAPI?

    public init(store: AccountStore = AccountStore(), engine: CallEngine? = nil, callKit: Bool = CallKitBridge.isSupported) {
        self.store = store
        let engine = engine ?? CallEngine(store: store)
        self.engine = engine
        let bridge = callKit ? CallKitBridge(engine: engine) : nil
        self.callKit = bridge
        engine.callKit = bridge          // before start(): the Core is created CallKit-aware
        bridge?.holdHandler = { [weak self] onHold in
            guard let self else { return false }
            return await self.holdForCallKit(onHold)
        }
    }

    /// Starts the engine (which restores the SIP account) and restores the enrollment.
    public func start() {
        engine.start()
        do {
            if let e = try store.loadEnrollment() { adopt(e) }
        } catch {
            Diagnostics.api.warning("stored enrollment unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Redeems an enrollment code (docs/05 §5, contract §7.2): stores the device identity and the SIP account,
    /// registers. Returns false with `enrollError` set when the platform refused.
    @discardableResult
    public func enroll(code: String, apiBase: URL, deviceName: String, appID: String) async -> Bool {
        guard !isEnrolling else { return false }
        isEnrolling = true
        enrollError = nil
        defer { isEnrolling = false }
        let client = PlatformAPI(baseURL: apiBase)
        let instance = (try? store.instanceID()) ?? engine.instanceID
        do {
            let res = try await client.enroll(.init(enrollment_code: code, platform: "ios", app_id: appID,
                                                    device_name: deviceName, sip_instance: instance))
            let (enrollment, account) = DeviceEnrollment.from(res, apiBase: apiBase)
            try store.save(enrollment)
            engine.configure(account: account)   // persists the SIP account (Keychain) and registers
            adopt(enrollment)
            Diagnostics.api.notice("enrolled device \(enrollment.deviceID, privacy: .public) as \(enrollment.userExtension, privacy: .public)@\(enrollment.tenantSlug, privacy: .public)")
            return true
        } catch let f as PlatformAPI.Failure {
            enrollError = f
        } catch {
            enrollError = PlatformAPI.Failure(status: 0, code: "network", message: error.localizedDescription)
        }
        return false
    }

    /// Forgets the enrollment and the SIP account on this device (the platform's device row stays until an
    /// admin revokes it; a re-enrollment with the same instance re-uses it).
    public func signOut() {
        engine.removeAccount()
        try? store.clearEnrollment()
        callerIDs?.clearSelection()
        enrollment = nil
        callerIDs = nil
        api = nil
    }

    /// Last call-control problem worth showing (hold/record); cleared on the next success.
    public private(set) var controlError: PlatformAPI.Failure?
    public private(set) var controlBusy = false

    /// Platform-side hold of the current call (the far end hears music, switchboards see `call.held`).
    public func toggleHold() async {
        guard let call = engine.call, let id = call.platformCallID, let api else {
            controlError = PlatformAPI.Failure(status: 0, code: "no_call_id", message: "The platform has not identified this call yet.")
            return
        }
        await control {
            if call.heldByMe { try await api.unhold(callID: id) } else { try await api.hold(callID: id) }
            engine.setHeldByMe(!call.heldByMe)
        }
    }

    /// On-demand recording of the current call.
    public func toggleRecording() async {
        guard let call = engine.call, let id = call.platformCallID, let api else {
            controlError = PlatformAPI.Failure(status: 0, code: "no_call_id", message: "The platform has not identified this call yet.")
            return
        }
        await control {
            try await api.record(callID: id, action: call.recording ? "stop" : "start")
            engine.setRecording(!call.recording)
        }
    }

    public func clearControlError() { controlError = nil }

    private func control(_ op: () async throws -> Void) async {
        guard !controlBusy else { return }
        controlBusy = true
        defer { controlBusy = false }
        do {
            try await op()
            controlError = nil
        } catch let f as PlatformAPI.Failure {
            controlError = f
        } catch {
            controlError = PlatformAPI.Failure(status: 0, code: "network", message: error.localizedDescription)
        }
    }

    // MARK: Call intents (through CallKit on devices, straight to the engine on the simulator; docs/07)

    /// Dials with the caller-ID choice attached (docs/05 §3).
    public func placeCall(to number: String) {
        let ppi = engine.account.flatMap { callerIDs?.preferredIdentity(domain: $0.domain) }
        guard engine.call == nil else { engine.noteBusy(); return }
        if let callKit {
            callKit.startCall(to: number, displayName: nil, preferredIdentity: ppi)
        } else {
            engine.placeCall(to: number, preferredIdentity: ppi)
        }
    }

    public func answer() {
        guard let call = engine.call else { return }
        if let callKit { callKit.answer(call.uuid) } else { engine.accept() }
    }

    /// Declines a ringing call or hangs up a live one.
    public func endCall() {
        guard let call = engine.call else { return }
        if let callKit {
            callKit.end(call.uuid)
        } else if call.direction == .incoming, call.phase == .incoming || call.phase == .incomingPush {
            engine.decline()
        } else {
            engine.hangUp()
        }
    }

    public func toggleMute() {
        guard let call = engine.call else { return }
        if let callKit { callKit.setMuted(call.uuid, !call.muted) } else { engine.toggleMute() }
    }

    /// CallKit asked for a hold (a cellular call answered on top of ours, docs/07 D1): the platform hold, so the
    /// far end hears music and the switchboard sees it; a plain SDK pause would leave the platform blind (S2).
    private func holdForCallKit(_ onHold: Bool) async -> Bool {
        guard let call = engine.call, call.heldByMe != onHold else { return true }
        await toggleHold()
        return controlError == nil
    }

    private func adopt(_ e: DeviceEnrollment) {
        enrollment = e
        let client = PlatformAPI(baseURL: e.apiBase, bearer: e.apiToken)
        api = client
        callerIDs = CallerIDStore(api: client, tenantID: e.tenantID, userID: e.userID)
    }
}
