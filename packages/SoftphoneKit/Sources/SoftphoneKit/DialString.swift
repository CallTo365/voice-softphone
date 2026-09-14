import Foundation

/// Turns what the user typed into a SIP address on the tenant domain. Pure, unit-tested.
///
/// The platform decides what the digits mean (extension, DID, E.164); the app only cleans up
/// what humans type: spaces, dots, dashes, parentheses, and a leading "+" or "00".
public enum DialString {
    public enum Failure: Error, Equatable {
        case empty
        case invalidCharacters
    }

    /// "+31 (0)6 12-34.56 78" -> "+31612345678"; "1001" -> "1001"; "00 32 473" -> "+32473".
    public static func normalize(_ raw: String) -> Result<String, Failure> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .failure(.empty) }
        let separators = CharacterSet(charactersIn: " .-()/")
        s = String(s.unicodeScalars.filter { !separators.contains($0) })
        if s.hasPrefix("00") { s = "+" + s.dropFirst(2) }
        let body = s.hasPrefix("+") ? String(s.dropFirst()) : s
        guard !body.isEmpty, body.allSatisfy({ $0.isNumber || $0 == "*" || $0 == "#" }) else {
            return .failure(.invalidCharacters)
        }
        // "(0)" national prefix inside an international number: "+31(0)6..." became "+3106..."; drop the 0.
        var out = s
        if out.hasPrefix("+"), raw.contains("(0)") {
            let country = String(raw.split(separator: "(")[0]).filter(\.isNumber)
            let rest = body.dropFirst(country.count)
            if rest.hasPrefix("0") { out = "+" + country + rest.dropFirst() }
        }
        return .success(out)
    }

    /// `sip:<normalized>@<domain>`; the domain is the account's SIP domain, never the server host.
    public static func sipURI(_ raw: String, domain: String) -> Result<String, Failure> {
        normalize(raw).map { "sip:\($0)@\(domain)" }
    }
}
