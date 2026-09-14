import Foundation

/// Registration as the UI shows it (docs/02 section 8).
public enum RegistrationStatus: Equatable, Sendable {
    case unconfigured
    case registering
    case registered
    case cleared
    case failed(String)

    public var isRegistered: Bool { self == .registered }

    public var label: String {
        switch self {
        case .unconfigured: "No account"
        case .registering: "Registering…"
        case .registered: "Registered"
        case .cleared: "Unregistered"
        case .failed(let why): "Registration failed: \(why)"
        }
    }
}

public enum CallDirection: Sendable { case incoming, outgoing }

/// Coarse call phase for the UI; the liblinphone state is kept in `ActiveCall.sdkState` for logs.
public enum CallPhase: Equatable, Sendable {
    case incomingPush     // CallKit already showed it, INVITE not here yet (phase 2)
    case incoming
    case dialing
    case ringing
    case active
    case held
    case ending
    case ended(reason: String)

    public var isLive: Bool {
        switch self {
        case .ending, .ended: false
        default: true
        }
    }
}

/// The one call the MVP handles at a time. Call waiting comes later.
public struct ActiveCall: Equatable, Sendable {
    /// SIP Call-ID: what support and Homer see.
    public var callID: String
    public var direction: CallDirection
    public var remoteNumber: String
    public var remoteName: String?
    public var phase: CallPhase
    public var sdkState: String
    public var startedAt: Date
    public var connectedAt: Date?
    public var muted: Bool = false
    public var speakerOn: Bool = false
    /// Live media facts, refreshed by the SDK about once per second while streams run.
    public var media: MediaStats?

    public var displayName: String {
        if let n = remoteName, !n.isEmpty { return n }
        return remoteNumber
    }
}

public enum SoftphoneError: Error, Equatable, Sendable {
    case notConfigured
    case notRegistered
    case invalidNumber
    case sdk(String)
    case busy

    public var userMessage: String {
        switch self {
        case .notConfigured: "Set up an account first."
        case .notRegistered: "Not registered with the platform."
        case .invalidNumber: "That is not a number we can dial."
        case .sdk(let m): "Call failed: \(m)"
        case .busy: "Another call is in progress."
        }
    }
}

/// What the call screen shows under the timer so a test does not depend on ears: codec, encryption,
/// bitrate in both directions and loss. Download > 0 with an echo service means audio came back.
public struct MediaStats: Equatable, Sendable {
    public var codec: String            // e.g. "opus/48000"
    public var encryption: String       // "SRTP", "none", ...
    public var downloadKbps: Float
    public var uploadKbps: Float
    public var receiverLossPercent: Float
    public var senderLossPercent: Float
    public var jitterMs: Float
    public var roundTripMs: Float

    public var summary: String {
        String(format: "%@ · %@ · ↓ %.0f ↑ %.0f kbit/s · loss %.0f%%/%.0f%% · jitter %.0f ms",
               codec, encryption, downloadKbps, uploadKbps, receiverLossPercent, senderLossPercent, jitterMs)
    }
}
