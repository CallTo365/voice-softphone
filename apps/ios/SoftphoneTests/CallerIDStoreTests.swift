import Foundation
import Testing
@testable import SoftphoneKit

/// Stubs every request of a URLSession; counts calls so the tests can prove nothing is fetched twice within the TTL.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.responder?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedAPI(bearer: String = "dvt_test") -> PlatformAPI {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    return PlatformAPI(baseURL: URL(string: "https://api.test")!, bearer: bearer, session: URLSession(configuration: cfg))
}

private let callerIDsJSON = """
{"items":[{"number":"+31856662750","label":"shared company number","source":"tenant","department_id":null},
          {"number":"+32473981616","label":"Hugo Mobiel","source":"identity","department_id":null},
          {"number":"anonymous","label":"Anonymous (withheld)","source":"anonymous","department_id":null}],
 "next_cursor":null,"total":3,"active_caller_id":null,"active_caller_id_until":null,
 "default":{"number":"+31856662751","layer":"tenant","anonymous":false}}
"""

@MainActor
struct CallerIDStoreTests {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "CallerIDStoreTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: d.description)
        return d
    }

    @Test func fetchesOnEveryOpenExceptImmediateReopens() async {
        StubProtocol.requests = []
        StubProtocol.responder = { _ in (200, Data(callerIDsJSON.utf8)) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = CallerIDStore(api: stubbedAPI(), tenantID: "t", userID: "u", defaults: freshDefaults(), ttl: 10, now: { clock })

        #expect(store.isStale)
        #expect(store.summary == "Default caller ID")   // nothing fetched by construction
        #expect(StubProtocol.requests.isEmpty)

        await store.load()
        #expect(StubProtocol.requests.count == 1)
        #expect(StubProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer dvt_test")
        #expect(StubProtocol.requests[0].url?.path == "/v1/tenants/t/users/u/caller-ids")
        #expect(store.items.count == 3)
        #expect(store.summary == "+31856662751 (default)")
        #expect(!store.isStale)

        clock = clock.addingTimeInterval(3)
        await store.load()
        #expect(StubProtocol.requests.count == 1)        // re-opened within seconds: coalesced

        clock = clock.addingTimeInterval(30)
        await store.load()
        #expect(StubProtocol.requests.count == 2)        // next open: refreshed (a number added meanwhile shows up)
        #expect(!store.items.isEmpty)

        await store.load(force: true)
        #expect(StubProtocol.requests.count == 3)
    }

    @Test func selectionPersistsAndBuildsTheHeader() async {
        StubProtocol.responder = { _ in (200, Data(callerIDsJSON.utf8)) }
        let defaults = freshDefaults()
        let store = CallerIDStore(api: stubbedAPI(), tenantID: "t", userID: "u", defaults: defaults)
        await store.load()
        store.select("+32473981616")
        #expect(store.summary == "Hugo Mobiel")           // identity numbers show their label
        #expect(store.preferredIdentity(domain: "acme.sip.local") == "<sip:+32473981616@acme.sip.local>")

        // a second store for the same user picks the choice up from UserDefaults without any network
        StubProtocol.requests = []
        let again = CallerIDStore(api: stubbedAPI(), tenantID: "t", userID: "u", defaults: defaults)
        #expect(again.selected == "+32473981616")
        #expect(StubProtocol.requests.isEmpty)

        store.select("anonymous")
        #expect(store.preferredIdentity(domain: "acme.sip.local") == "<sip:anonymous@anonymous.invalid>")
        store.select(nil)
        #expect(store.preferredIdentity(domain: "acme.sip.local") == nil)
    }

    @Test func revokedSelectionIsClearedOnReload() async {
        StubProtocol.responder = { _ in (200, Data(callerIDsJSON.utf8)) }
        let defaults = freshDefaults()
        defaults.set("+31999999999", forKey: "callerId.u")   // stored earlier, no longer presentable
        let store = CallerIDStore(api: stubbedAPI(), tenantID: "t", userID: "u", defaults: defaults)
        #expect(store.selected == "+31999999999")
        await store.load()
        #expect(store.selected == nil)
        #expect(store.lastError?.code == "caller_id_gone")
        #expect(defaults.string(forKey: "callerId.u") == nil)
    }

    @Test func apiErrorsSurfaceAsFailures() async {
        StubProtocol.responder = { _ in (401, Data(#"{"error":{"code":"unauthorized","message":"invalid or revoked device token"}}"#.utf8)) }
        let store = CallerIDStore(api: stubbedAPI(), tenantID: "t", userID: "u", defaults: freshDefaults())
        await store.load()
        #expect(store.lastError == PlatformAPI.Failure(status: 401, code: "unauthorized", message: "invalid or revoked device token"))
        #expect(store.items.isEmpty)
        #expect(store.isStale)   // a failed load leaves the cache stale so the next open retries
    }
}

struct EnrollLinkTests {
    @Test func parsesTheAdminUILink() {
        let l = EnrollLink(url: URL(string: "callto://enroll?code=2WDH3G9G&api=https://91-99-163-145.sslip.io")!)
        #expect(l?.code == "2WDH3G9G")
        #expect(l?.apiBase.absoluteString == "https://91-99-163-145.sslip.io")
    }

    @Test func rejectsOtherLinks() {
        #expect(EnrollLink(url: URL(string: "callto://call?number=1002")!) == nil)
        #expect(EnrollLink(url: URL(string: "https://example.com/enroll?code=X&api=https://a")!) == nil)
        #expect(EnrollLink(url: URL(string: "callto://enroll?api=https://a")!) == nil)
        #expect(EnrollLink(url: URL(string: "callto://enroll?code=X&api=ftp://a")!) == nil)
    }
}
