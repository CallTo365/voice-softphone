import Foundation

/// What enrollment leaves on the device (Keychain, S6): who we are on the platform and how to talk to it.
/// The SIP side of the same response becomes the `SIPAccount`.
public struct DeviceEnrollment: Codable, Equatable, Sendable {
    public var deviceID: String
    public var apiToken: String
    public var apiBase: URL
    public var tenantID: String
    public var tenantSlug: String
    public var tenantName: String
    public var userID: String
    public var userExtension: String
    public var userDisplayName: String
    public var enrolledAt: Date

    public init(deviceID: String, apiToken: String, apiBase: URL, tenantID: String, tenantSlug: String, tenantName: String,
                userID: String, userExtension: String, userDisplayName: String, enrolledAt: Date = Date()) {
        self.deviceID = deviceID
        self.apiToken = apiToken
        self.apiBase = apiBase
        self.tenantID = tenantID
        self.tenantSlug = tenantSlug
        self.tenantName = tenantName
        self.userID = userID
        self.userExtension = userExtension
        self.userDisplayName = userDisplayName
        self.enrolledAt = enrolledAt
    }

    /// Splits the platform's enrollment response into the API identity and the SIP account.
    public static func from(_ e: PlatformAPI.Enrollment, apiBase: URL) -> (DeviceEnrollment, SIPAccount) {
        let enrollment = DeviceEnrollment(
            deviceID: e.device_id, apiToken: e.api_token, apiBase: apiBase,
            tenantID: e.tenant.id, tenantSlug: e.tenant.slug, tenantName: e.tenant.name,
            userID: e.user.id, userExtension: e.user.`extension`, userDisplayName: e.user.display_name
        )
        let account = SIPAccount(
            username: e.sip.username, domain: e.sip.domain, serverHost: e.sip.server, serverPort: e.sip.port,
            transport: SIPAccount.Transport(rawValue: e.sip.transport) ?? .tls,
            ha1: e.sip.ha1, realm: e.sip.realm
        )
        return (enrollment, account)
    }
}
