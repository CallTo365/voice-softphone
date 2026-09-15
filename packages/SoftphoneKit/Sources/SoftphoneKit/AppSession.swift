import Foundation
import Observation

/// Ties enrollment (who we are on the platform), the SIP engine and the caller-ID choice together.
/// The app talks to this; `CallEngine` stays SIP-only. Everything persistent lives in the Keychain via
/// `AccountStore`; `CallerIDStore` keeps only the user's choice in `UserDefaults`.
@MainActor
@Observable
public final class AppSession {
    public let engine: CallEngine
    public private(set) var enrollment: DeviceEnrollment?
    public private(set) var callerIDs: CallerIDStore?
    public private(set) var isEnrolling = false
    public private(set) var enrollError: PlatformAPI.Failure?

    @ObservationIgnored private let store: AccountStore
    @ObservationIgnored private var api: PlatformAPI?

    public init(store: AccountStore = AccountStore(), engine: CallEngine? = nil) {
        self.store = store
        self.engine = engine ?? CallEngine(store: store)
    }

    /// Starts the engine (which restores the SIP account) and restores the enrollment.
    public func start() {
        engine.start()
        do {
            if let e = try store.loadEnrollment() { adopt(e) }
        } catch {
            Diagnostics.api.warning("stored enrollment unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Redeems an enrollment code (docs/05 §5, contract §7.2): stores the device identity and the SIP account,
    /// registers. Returns false with `enrollError` set when the platform refused.
    @discardableResult
    public func enroll(code: String, apiBase: URL, deviceName: String, appID: String) async -> Bool {
        guard !isEnrolling else { return false }
        isEnrolling = true
        enrollError = nil
        defer { isEnrolling = false }
        let client = PlatformAPI(baseURL: apiBase)
        let instance = (try? store.instanceID()) ?? engine.instanceID
        do {
            let res = try await client.enroll(.init(enrollment_code: code, platform: "ios", app_id: appID,
                                                    device_name: deviceName, sip_instance: instance))
            let (enrollment, account) = DeviceEnrollment.from(res, apiBase: apiBase)
            try store.save(enrollment)
            engine.configure(account: account)   // persists the SIP account (Keychain) and registers
            adopt(enrollment)
            Diagnostics.api.notice("enrolled device \(enrollment.deviceID, privacy: .public) as \(enrollment.userExtension, privacy: .public)@\(enrollment.tenantSlug, privacy: .public)")
            return true
        } catch let f as PlatformAPI.Failure {
            enrollError = f
        } catch {
            enrollError = PlatformAPI.Failure(status: 0, code: "network", message: error.localizedDescription)
        }
        return false
    }

    /// Forgets the enrollment and the SIP account on this device (the platform's device row stays until an
    /// admin revokes it; a re-enrollment with the same instance re-uses it).
    public func signOut() {
        engine.removeAccount()
        try? store.clearEnrollment()
        callerIDs?.clearSelection()
        enrollment = nil
        callerIDs = nil
        api = nil
    }

    /// Dials with the caller-ID choice attached (docs/05 §3).
    public func placeCall(to number: String) {
        let ppi = engine.account.flatMap { callerIDs?.preferredIdentity(domain: $0.domain) }
        engine.placeCall(to: number, preferredIdentity: ppi)
    }

    private func adopt(_ e: DeviceEnrollment) {
        enrollment = e
        let client = PlatformAPI(baseURL: e.apiBase, bearer: e.apiToken)
        api = client
        callerIDs = CallerIDStore(api: client, tenantID: e.tenantID, userID: e.userID)
    }
}
