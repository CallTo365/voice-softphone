import AVFAudio
import CallKit
import Foundation

/// Phase 1 (docs/01 §4, docs/02 §2–3, docs/07): the app's `CXProvider`. Maps CallKit actions to engine
/// intents and engine events to CallKit reports. The audio session is touched only through the SDK's
/// `configureAudioSession()` / `activateAudioSession()` and only from the provider callbacks (S4).
///
/// Ownership: `AppSession` creates it (real devices only, `isSupported`) and hands it to the engine before
/// `start()`, so the Core runs with `callkitEnabled`. Every user intent while CallKit is active goes
/// through a `CXTransaction` (start, answer, end, mute); the engine acts only when CallKit performs the
/// action, so the native screen, the lock screen and the app stay in step.
@MainActor
public final class CallKitBridge: NSObject {
    /// The SDK disables CallKit on the simulator (ADR-0001, S14); the app keeps the phase-0 direct path there.
    public static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// What CallKit did with a request, for the diagnostics screen.
    public private(set) var lastRequestError: String?

    /// Platform hold on CallKit's request (a cellular call answered on top of ours, docs/07 D1): set by
    /// `AppSession`, returns success. nil = the action fails and CallKit ends the call.
    public var holdHandler: (@MainActor (Bool) async -> Bool)?

    private let provider: CXProvider
    /// Default queue = main, so request completions arrive on the main thread.
    private let controller = CXCallController()
    private unowned let engine: CallEngine
    /// The caller-ID choice per CallKit uuid between the request and the `CXStartCallAction` (the CXHandle
    /// only carries the number).
    private var pendingIdentity: [UUID: String] = [:]
    /// Calls ended through a `CXEndCallAction`: fulfilling the action ends them for CallKit, so their
    /// `Released` must not be reported a second time.
    private var endedByAction: Set<UUID> = []
    private var reportedConnected: Set<UUID> = []

    public init(engine: CallEngine) {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1          // one call at a time in the MVP
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.includesCallsInRecents = true         // the Phone app's Recents can call back (INStartCallIntent)
        provider = CXProvider(configuration: config)
        self.engine = engine
        super.init()
        provider.setDelegate(self, queue: nil)       // nil = main queue (R12)
        CallKitBridge.current = self
    }

    // MARK: Requests (UI -> CallKit -> provider(perform:) -> engine)

    /// Starts an outgoing call through CallKit. `preferredIdentity` is the P-Preferred-Identity value (docs/05).
    public func startCall(to number: String, displayName: String?, preferredIdentity: String?) {
        let uuid = UUID()
        if let preferredIdentity { pendingIdentity[uuid] = preferredIdentity }
        let action = CXStartCallAction(call: uuid, handle: Self.handle(for: number))
        action.contactIdentifier = displayName
        action.isVideo = false
        request(action, "start")
    }

    public func answer(_ uuid: UUID) { request(CXAnswerCallAction(call: uuid), "answer") }

    public func end(_ uuid: UUID) { request(CXEndCallAction(call: uuid), "end") }

    public func setMuted(_ uuid: UUID, _ muted: Bool) { request(CXSetMutedCallAction(call: uuid, muted: muted), "mute") }

    private func request(_ action: CXAction, _ what: String) {
        controller.request(CXTransaction(action: action)) { @Sendable error in
            let text = error.map { String(describing: $0) }
            Task { @MainActor in CallKitBridge.requestCompleted(what, text) }
        }
    }

    /// One provider per process; completion closures re-enter through this static instead of capturing `self`
    /// (same pattern as `CallEngine.current`).
    private nonisolated(unsafe) static var current: CallKitBridge?
    private static func requestCompleted(_ what: String, _ error: String?) {
        guard let bridge = current else { return }
        if let error {
            bridge.lastRequestError = "\(what): \(error)"
            Diagnostics.record("callkit", "request \(what) refused: \(error)", level: .error)
        } else {
            Diagnostics.record("callkit", "request \(what) accepted")
        }
    }

    // MARK: Reports (engine -> CallKit)

    /// Reports an INVITE to CallKit before anything else happens with it (S1 applies to pushes in phase 2 in
    /// the same way). On refusal (Focus / Do Not Disturb, an unsupported handle) the engine declines busy.
    public func reportIncoming(_ uuid: UUID, number: String, name: String?) {
        let update = CXCallUpdate()
        update.remoteHandle = Self.handle(for: number)
        update.localizedCallerName = name?.isEmpty == false ? name : nil
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsDTMF = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        Diagnostics.record("callkit", "report incoming \(uuid) from \(Redactor.redact(number))")
        provider.reportNewIncomingCall(with: uuid, update: update) { @Sendable error in
            let text = error.map { String(describing: $0) }
            Task { @MainActor in CallKitBridge.incomingReported(uuid, text) }
        }
    }

    private static func incomingReported(_ uuid: UUID, _ error: String?) {
        guard let bridge = current else { return }
        guard let error else { return }
        // Refused (e.g. filtered by a Focus): the far end must not keep ringing a phone that shows nothing.
        Diagnostics.record("callkit", "incoming \(uuid) refused by CallKit: \(error); declining busy", level: .error)
        bridge.engine.declineBusy()
    }

    public func reportOutgoingStartedConnecting(_ uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
    }

    public func reportConnected(_ uuid: UUID) {
        guard !reportedConnected.contains(uuid) else { return }
        reportedConnected.insert(uuid)
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)   // no-op for incoming calls
    }

    /// The SDK released the call. Skipped when this bridge ended it through a `CXEndCallAction`.
    public func reportEnded(_ uuid: UUID, cause: CallEndCause) {
        pendingIdentity[uuid] = nil
        reportedConnected.remove(uuid)
        if endedByAction.remove(uuid) != nil {
            Diagnostics.record("callkit", "call \(uuid) ended by our action; no end report")
            return
        }
        let reason = Self.endedReason(cause)
        Diagnostics.record("callkit", "report ended \(uuid): \(cause) -> \(reason.rawValue)")
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
    }

    /// The remote party changed (a display name learned after the INVITE).
    public func updateRemote(_ uuid: UUID, number: String, name: String?) {
        let update = CXCallUpdate()
        update.remoteHandle = Self.handle(for: number)
        update.localizedCallerName = name?.isEmpty == false ? name : nil
        provider.reportCall(with: uuid, updated: update)
    }

    // MARK: Pure helpers (tested)

    /// Digits with an optional leading `+` are a phone number (CallKit formats and matches Contacts); everything
    /// else (an extension name, a SIP user) is a generic handle.
    nonisolated static func handle(for number: String) -> CXHandle {
        CXHandle(type: handleType(for: number), value: number)
    }

    public nonisolated static func handleType(for number: String) -> CXHandle.HandleType {
        let digits = number.hasPrefix("+") ? String(number.dropFirst()) : number
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return .generic }
        return .phoneNumber
    }

    public nonisolated static func endedReason(_ cause: CallEndCause) -> CXCallEndedReason {
        switch cause {
        case .remoteEnded: .remoteEnded
        case .unanswered: .unanswered
        case .answeredElsewhere: .answeredElsewhere
        case .declinedElsewhere: .declinedElsewhere
        case .failed: .failed
        }
    }
}

/// Why a call ended, as CallKit wants to know it (`CXCallEndedReason`); derived from the SDK's call log.
public enum CallEndCause: Equatable, Sendable {
    case remoteEnded
    case unanswered
    case answeredElsewhere
    case declinedElsewhere
    case failed
}

// MARK: - CXProviderDelegate

/// The provider calls these on the main queue (`setDelegate(_, queue: nil)`). The protocol's requirements are
/// nonisolated; the `@preconcurrency` conformance (SE-0423) lets main-actor methods satisfy them with a runtime
/// isolation check at entry, which the main queue delivery guarantees (R12).
extension CallKitBridge: @preconcurrency CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        Diagnostics.record("callkit", "provider reset: ending every call", level: .error)
        engine.hangUp()
    }

    public func providerDidBegin(_ provider: CXProvider) {
        Diagnostics.record("callkit", "provider began")
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let ppi = pendingIdentity.removeValue(forKey: action.callUUID)
        engine.configureAudioSession()                     // S4: inside the provider callback only
        if engine.placeCall(to: action.handle.value, preferredIdentity: ppi, callKitUUID: action.callUUID) {
            action.fulfill()                               // connecting/connected follow from the SDK states
        } else {
            Diagnostics.record("callkit", "start \(action.callUUID) failed: \(engine.lastError?.userMessage ?? "?")", level: .error)
            action.fail()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard engine.call?.uuid == action.callUUID else { action.fail(); return }
        engine.configureAudioSession()
        engine.accept()
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = engine.call, call.uuid == action.callUUID else {
            action.fulfill()                               // nothing to end on our side; keep CallKit consistent
            return
        }
        endedByAction.insert(action.callUUID)
        if call.direction == .incoming, call.phase == .incoming || call.phase == .incomingPush {
            engine.decline()
        } else {
            engine.hangUp()
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard engine.call?.uuid == action.callUUID, let holdHandler else { action.fail(); return }
        let onHold = action.isOnHold
        Task { @MainActor in
            if await holdHandler(onHold) { action.fulfill() } else { action.fail() }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard engine.call?.uuid == action.callUUID else { action.fail(); return }
        engine.setMuted(action.isMuted)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard engine.call?.uuid == action.callUUID else { action.fail(); return }
        for digit in action.digits { engine.sendDTMF(digit) }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        Diagnostics.record("callkit", "action timed out: \(type(of: action))", level: .error)
        action.fail()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Diagnostics.record("callkit", "audio session activated")
        engine.audioSessionActivated(true)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Diagnostics.record("callkit", "audio session deactivated")
        engine.audioSessionActivated(false)
    }
}
