import Foundation

/// What the app needs to register one SIP identity through the edge.
///
/// Phase 0 (dev-only account screen) fills this by hand; from phase 3 on it comes from
/// `POST /v1/auth/device` (ADR-0004) and the user never sees it. Either `password` or `ha1` is set,
/// never both; `ha1` is what enrollment returns because the platform stores no plaintext.
public struct SIPAccount: Codable, Equatable, Sendable {
    public enum Transport: String, Codable, Sendable, CaseIterable {
        case tls, tcp, udp
    }

    /// SIP user part, e.g. "1001".
    public var username: String
    /// SIP domain of the tenant, e.g. "acme.sip.local". Stays in From/To; also the auth realm.
    public var domain: String
    /// Host the app connects to (the certificate name), e.g. "91-99-163-145.sslip.io".
    public var serverHost: String
    public var serverPort: Int
    public var transport: Transport
    public var password: String?
    public var ha1: String?
    /// Auth realm when it differs from `domain`. Kamailio uses the domain (`auth_check("$fd", ...)`).
    public var realm: String?
    /// Development only (S5): accept any server certificate. Ignored in release builds.
    public var trustAnyCertificate: Bool

    public init(
        username: String,
        domain: String,
        serverHost: String,
        serverPort: Int = 5061,
        transport: Transport = .tls,
        password: String? = nil,
        ha1: String? = nil,
        realm: String? = nil,
        trustAnyCertificate: Bool = false
    ) {
        self.username = username
        self.domain = domain
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.transport = transport
        self.password = password
        self.ha1 = ha1
        self.realm = realm
        self.trustAnyCertificate = trustAnyCertificate
    }

    /// `sip:1001@acme.sip.local`
    public var identity: String { "sip:\(username)@\(domain)" }

    /// `sip:host:port;transport=tls` — the proxy every request is routed through.
    public var serverURI: String {
        "sip:\(serverHost):\(serverPort);transport=\(transport.rawValue)"
    }

    public var hasCredential: Bool {
        (password?.isEmpty == false) || (ha1?.isEmpty == false)
    }
}
