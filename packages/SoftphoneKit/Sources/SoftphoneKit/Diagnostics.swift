import Foundation
import os

/// One logger per category (see `.ai/instructions.md`); every message passes the redactor (S6).
public enum Diagnostics {
    public static let subsystem = "com.callto365.softphone"

    public static let sip = Logger(subsystem: subsystem, category: "sip")
    public static let callkit = Logger(subsystem: subsystem, category: "callkit")
    public static let push = Logger(subsystem: subsystem, category: "push")
    public static let api = Logger(subsystem: subsystem, category: "api")
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    /// liblinphone's own log line, already redacted. Level maps: Error/Fatal -> error,
    /// Warning -> warning, Message -> info, Trace/Debug -> debug.
    static func sdkLine(_ level: SDKLogLevel, _ message: String) {
        let text = Redactor.redact(message)
        switch level {
        case .error: sip.error("\(text, privacy: .public)")
        case .warning: sip.warning("\(text, privacy: .public)")
        case .info: sip.info("\(text, privacy: .public)")
        case .debug: sip.debug("\(text, privacy: .public)")
        }
    }

    enum SDKLogLevel { case error, warning, info, debug }
}
