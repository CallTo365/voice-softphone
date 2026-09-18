import Foundation
import os

/// Recent log lines kept in memory for the Diagnostics screen (the phone has no Xcode). Thread-safe: the SDK
/// logs from its own threads. Every line went through the redactor before it got here (S6).
public final class LogBuffer: @unchecked Sendable {
    public static let shared = LogBuffer(capacity: 500)
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity: Int
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(capacity: Int) { self.capacity = capacity }

    func append(_ category: String, _ level: String, _ text: String) {
        let line = "\(Self.stamp.string(from: Date())) \(level) [\(category)] \(text)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
    }

    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    public func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
    }
}

/// One logger per category (see `.ai/instructions.md`); every message passes the redactor (S6).
public enum Diagnostics {
    public static let subsystem = "com.callto365.softphone"

    /// App-level event worth keeping for the Diagnostics screen as well as os_log.
    public static func record(_ category: String, _ text: String, level: OSLogType = .info) {
        let safe = Redactor.redact(text)
        LogBuffer.shared.append(category, level == .error ? "E" : (level == .default ? "N" : "I"), safe)
        let logger: Logger
        switch category {
        case "sip": logger = sip
        case "callkit": logger = callkit
        case "push": logger = push
        case "api": logger = api
        default: logger = ui
        }
        logger.log(level: level, "\(safe, privacy: .public)")
    }

    public static let sip = Logger(subsystem: subsystem, category: "sip")
    public static let callkit = Logger(subsystem: subsystem, category: "callkit")
    public static let push = Logger(subsystem: subsystem, category: "push")
    public static let api = Logger(subsystem: subsystem, category: "api")
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    /// liblinphone's own log line, already redacted. Level maps: Error/Fatal -> error,
    /// Warning -> warning, Message -> info, Trace/Debug -> debug.
    static func sdkLine(_ level: SDKLogLevel, _ message: String) {
        let text = Redactor.redact(message)
        // the buffer keeps warnings and errors from the SDK plus the lines that explain connectivity
        let keep = level == .error || level == .warning || text.contains("reachab") || text.contains("Channel [")
            || text.contains("registration") || text.contains("resolv") || text.contains("REGISTER")
        if keep {
            LogBuffer.shared.append("sdk", level == .error ? "E" : (level == .warning ? "W" : "I"), text)
        }
        switch level {
        case .error: sip.error("\(text, privacy: .public)")
        case .warning: sip.warning("\(text, privacy: .public)")
        case .info: sip.info("\(text, privacy: .public)")
        case .debug: sip.debug("\(text, privacy: .public)")
        }
    }

    enum SDKLogLevel { case error, warning, info, debug }
}
