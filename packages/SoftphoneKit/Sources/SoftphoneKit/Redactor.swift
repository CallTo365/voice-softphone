import Foundation

/// Removes credentials from text before it reaches a log (S6). Pure, unit-tested.
///
/// Covers what liblinphone and our own code can emit: SIP `Authorization`/`Proxy-Authorization`
/// headers, `password=`/`ha1=` pairs in URIs and config lines, bearer tokens, APNs push tokens in
/// `pn-prid=`, and the response hash of a digest.
public enum Redactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            (#"(?im)^((?:Proxy-)?Authorization:\s*)(.*)$"#, "$1<redacted>"),
            (#"(?i)(password|passwd|ha1|secret|token)(\s*[=:]\s*)([^\s;,&"']+)"#, "$1$2<redacted>"),
            (#"(?i)(pn-prid=)([^;\s>"]+)"#, "$1<redacted>"),
            (#"(?i)(response=")([0-9a-f]+)(")"#, "$1<redacted>$3"),
            (#"(?i)(Bearer\s+)([A-Za-z0-9._\-]+)"#, "$1<redacted>"),
        ]
        return raw.compactMap { pattern, template in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (re, template)
        }
    }()

    public static func redact(_ text: String) -> String {
        patterns.reduce(text) { acc, entry in
            let (re, template) = entry
            let range = NSRange(acc.startIndex..., in: acc)
            return re.stringByReplacingMatches(in: acc, range: range, withTemplate: template)
        }
    }
}
