import Foundation
import Security

/// Keychain-backed storage for everything secret (S6): the SIP account and the per-installation
/// instance id that becomes `+sip.instance` (S3).
///
/// Items use `kSecAttrAccessibleAfterFirstUnlock` so the app can register after a reboot before the
/// user unlocks (needed once push wake-up exists), and are not synchronised to iCloud.
public struct AccountStore: Sendable {
    public enum Failure: Error, Equatable {
        case keychain(OSStatus)
        case encoding
    }

    private let service: String

    public init(service: String = "com.callto365.softphone") {
        self.service = service
    }

    // MARK: SIP account

    public func loadAccount() throws -> SIPAccount? {
        guard let data = try read(key: "sip-account") else { return nil }
        guard let account = try? JSONDecoder().decode(SIPAccount.self, from: data) else {
            throw Failure.encoding
        }
        return account
    }

    public func save(_ account: SIPAccount) throws {
        guard let data = try? JSONEncoder().encode(account) else { throw Failure.encoding }
        try write(key: "sip-account", data: data)
    }

    public func clearAccount() throws {
        try delete(key: "sip-account")
    }

    // MARK: Instance id

    /// Lowercase UUID, created once per installation. liblinphone renders it as
    /// `+sip.instance="<urn:uuid:...>"` (config key `misc/uuid`, checked in linphonecore.c 2026-09-14).
    public func instanceID() throws -> String {
        if let data = try read(key: "sip-instance"), let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        let fresh = UUID().uuidString.lowercased()
        try write(key: "sip-instance", data: Data(fresh.utf8))
        return fresh
    }

    // MARK: Keychain plumbing

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private func read(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw Failure.keychain(status)
        }
    }

    private func write(key: String, data: Data) throws {
        let query = baseQuery(key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
