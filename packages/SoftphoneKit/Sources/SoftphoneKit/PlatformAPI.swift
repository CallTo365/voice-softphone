import Foundation

/// Typed client for the control plane (`../voice-platform/docs/02-contracts.md` §7.2, §15). Thin on purpose:
/// one method per endpoint the app uses, Codable bodies, errors as the platform's `{error:{code,message}}`.
/// The bearer is the device token from enrollment (ADR-0004 / platform ADR-0042); it never appears in logs.
public struct PlatformAPI: Sendable {
    public struct Failure: Error, Equatable, Sendable {
        public var status: Int
        public var code: String
        public var message: String

        public var userMessage: String {
            switch code {
            case "invalid_enrollment_code": "That code is unknown, expired or already used."
            case "rate_limited": "Too many attempts. Wait a minute and try again."
            case "enrollment_refused": "This user or company is not active."
            case "unauthorized": "This device is no longer enrolled."
            case "feature_not_licensed", "payment_required": "Recording is not included in your seat."
            case "not_found": "The platform does not know this call (yet)."
            case "network": "Cannot reach the platform: \(message)"
            default: "\(message) (\(code))"
            }
        }
    }

    public let baseURL: URL
    public var bearer: String?
    private let session: URLSession

    public init(baseURL: URL, bearer: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearer = bearer
        self.session = session
    }

    // MARK: Enrollment (unauthenticated)

    public struct EnrollmentRequest: Codable, Sendable {
        public var enrollment_code: String
        public var platform: String
        public var app_id: String
        public var device_name: String?
        public var sip_instance: String?
    }

    public struct Enrollment: Codable, Equatable, Sendable {
        public struct Tenant: Codable, Equatable, Sendable { public var id, slug, name: String }
        public struct User: Codable, Equatable, Sendable { public var id: String; public var `extension`: String; public var display_name: String }
        public struct SIP: Codable, Equatable, Sendable {
            public var domain, username, ha1, realm, server, transport: String
            public var port: Int
        }
        public var device_id: String
        public var api_token: String
        public var tenant: Tenant
        public var user: User
        public var sip: SIP
    }

    public func enroll(_ req: EnrollmentRequest) async throws -> Enrollment {
        try await send("POST", "/v1/auth/device", body: req, authenticated: false)
    }

    // MARK: Me

    public struct Me: Codable, Equatable, Sendable {
        public var kind: String
        public var tenant_id: String?
        public var user_id: String?
        public var device_id: String?
        public var roles: [String]
    }

    public func me() async throws -> Me { try await send("GET", "/v1/me") }

    // MARK: Caller IDs (contract §15)

    public struct CallerIDOption: Codable, Equatable, Hashable, Sendable {
        public var number: String       // E.164 or "anonymous"
        public var label: String
        public var source: String       // department | inherited | tenant | own | identity | anonymous
        public var department_id: String?
    }

    public struct CallerIDSet: Codable, Equatable, Sendable {
        public struct Default: Codable, Equatable, Sendable {
            public var number: String?
            public var layer: String
            public var anonymous: Bool?
        }
        public var items: [CallerIDOption]
        public var active_caller_id: String?
        public var `default`: Default
    }

    public func callerIDs(tenantID: String, userID: String) async throws -> CallerIDSet {
        try await send("GET", "/v1/tenants/\(tenantID)/users/\(userID)/caller-ids")
    }

    // MARK: Call control (contract §10.6, §12.8) — the user on the call

    private struct StatusReply: Codable { var status: String }
    private struct RecordBody: Codable { var action: String }

    public func hold(callID: String) async throws {
        let _: StatusReply = try await send("POST", "/v1/calls/\(callID)/hold", body: Empty())
    }

    public func unhold(callID: String) async throws {
        let _: StatusReply = try await send("POST", "/v1/calls/\(callID)/unhold", body: Empty())
    }

    /// `action` is "start" or "stop"; the seat needs the recording feature (402/403 otherwise).
    public func record(callID: String, action: String) async throws {
        let _: StatusReply = try await send("POST", "/v1/calls/\(callID)/record", body: RecordBody(action: action))
    }

    // MARK: Devices (contract §7.2)

    public struct DevicePatch: Codable, Sendable {
        public var device_name: String?
        public var push_provider: String?
        public var push_token: String?
        public init(device_name: String? = nil, push_provider: String? = nil, push_token: String? = nil) {
            self.device_name = device_name
            self.push_provider = push_provider
            self.push_token = push_token
        }
    }

    public struct Device: Codable, Equatable, Sendable {
        public var id: String
        public var platform: String
        public var device_name: String?
        public var has_push_token: Bool
        public var last_seen_at: String?
        public var current: Bool
    }

    private struct DeviceList: Codable { var items: [Device] }

    public func myDevices() async throws -> [Device] {
        let list: DeviceList = try await send("GET", "/v1/me/devices")
        return list.items
    }

    public func updateMyDevice(id: String, _ patch: DevicePatch) async throws -> Device {
        try await send("PATCH", "/v1/me/devices/\(id)", body: patch)
    }

    // MARK: Plumbing

    private struct Empty: Codable {}
    private struct ErrorEnvelope: Codable { struct Inner: Codable { var code: String; var message: String }; var error: Inner }

    private func send<T: Decodable>(_ method: String, _ path: String, authenticated: Bool = true) async throws -> T {
        try await send(method, path, body: Empty?.none, authenticated: authenticated)
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B?, authenticated: Bool = true) async throws -> T {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        if authenticated {
            guard let bearer, !bearer.isEmpty else { throw Failure(status: 401, code: "unauthorized", message: "not enrolled") }
            req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            Diagnostics.record("api", "\(method) \(path): \(error.localizedDescription)", level: .error)
            throw Failure(status: 0, code: "network", message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Diagnostics.record("api", "\(method) \(path) -> \(status)")
        guard (200..<300).contains(status) else {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw Failure(status: status, code: env.error.code, message: env.error.message)
            }
            throw Failure(status: status, code: "http_\(status)", message: String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        if T.self == Empty.self, data.isEmpty { return Empty() as! T }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure(status: status, code: "decode", message: "unexpected response: \(error)")
        }
    }
}

/// `callto://enroll?code=ABCD2345&api=https://host` — what the admin UI shows as text and QR.
public struct EnrollLink: Equatable, Sendable {
    public var code: String
    public var apiBase: URL

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "callto", url.host()?.lowercased() == "enroll",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let api = items.first(where: { $0.name == "api" })?.value, let base = URL(string: api),
              base.scheme == "https" || base.scheme == "http" else { return nil }
        self.code = code
        self.apiBase = base
    }
}
