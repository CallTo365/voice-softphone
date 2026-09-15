import Foundation
import Observation

/// The caller IDs this user may present (docs/05). Nothing is fetched until `load()` is called — the dialer
/// calls it when the sheet opens, not when the screen appears — and the result is kept for `ttl`; a later open
/// shows the cached list at once and refreshes in the background when it is stale.
///
/// The choice is per device and per user (`UserDefaults`, not a secret) and is sent on every call as
/// `P-Preferred-Identity`; the platform validates it (platform ADR-0043). `nil` = let the platform decide.
@MainActor
@Observable
public final class CallerIDStore {
    public typealias Option = PlatformAPI.CallerIDOption

    public private(set) var items: [Option] = []
    public private(set) var platformDefault: PlatformAPI.CallerIDSet.Default?
    public private(set) var fetchedAt: Date?
    public private(set) var isLoading = false
    public private(set) var lastError: PlatformAPI.Failure?
    /// The chosen number ("anonymous" allowed) or nil for the platform default.
    public private(set) var selected: String?

    @ObservationIgnored private let api: PlatformAPI
    @ObservationIgnored private let tenantID: String
    @ObservationIgnored private let userID: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ttl: TimeInterval
    @ObservationIgnored private let now: () -> Date

    public init(api: PlatformAPI, tenantID: String, userID: String, defaults: UserDefaults = .standard,
                ttl: TimeInterval = 300, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.tenantID = tenantID
        self.userID = userID
        self.defaults = defaults
        self.ttl = ttl
        self.now = now
        self.selected = defaults.string(forKey: Self.key(userID))
    }

    public var isStale: Bool {
        guard let fetchedAt else { return true }
        return now().timeIntervalSince(fetchedAt) > ttl
    }

    /// The option matching the selection, when the list is loaded and still contains it.
    public var selectedOption: Option? {
        guard let selected else { return nil }
        return items.first { $0.number == selected }
    }

    /// Short text for the dialer control: the chosen number/label, or "Default caller ID".
    public var summary: String {
        if let selected {
            if selected == "anonymous" { return "Anonymous" }
            if let o = selectedOption, !o.label.isEmpty, o.source == "identity" { return o.label }
            return selected
        }
        if let d = platformDefault, let n = d.number { return d.anonymous == true ? "Anonymous (default)" : "\(n) (default)" }
        return "Default caller ID"
    }

    /// Fetches when nothing is cached or the cache is older than the TTL (or `force`). Concurrent calls coalesce.
    public func load(force: Bool = false) async {
        guard force || isStale, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let set = try await api.callerIDs(tenantID: tenantID, userID: userID)
            items = set.items
            platformDefault = set.default
            fetchedAt = now()
            lastError = nil
            if let selected, !set.items.contains(where: { $0.number == selected }) {
                // revoked or no longer presentable: fall back to the platform default and say so once
                Diagnostics.api.notice("stored caller id \(selected, privacy: .public) is no longer presentable; cleared")
                clearSelection()
                lastError = PlatformAPI.Failure(status: 0, code: "caller_id_gone", message: "Your previous caller ID is no longer available; the default is used.")
            }
        } catch let f as PlatformAPI.Failure {
            lastError = f
        } catch {
            lastError = PlatformAPI.Failure(status: 0, code: "network", message: error.localizedDescription)
        }
    }

    public func select(_ number: String?) {
        selected = number
        if let number { defaults.set(number, forKey: Self.key(userID)) } else { defaults.removeObject(forKey: Self.key(userID)) }
    }

    public func clearSelection() { select(nil) }

    /// The header value for the INVITE (docs/05 §3), or nil when the platform decides.
    public func preferredIdentity(domain: String) -> String? {
        guard let selected else { return nil }
        if selected == "anonymous" { return "<sip:anonymous@anonymous.invalid>" }
        return "<sip:\(selected)@\(domain)>"
    }

    private static func key(_ userID: String) -> String { "callerId.\(userID)" }
}
