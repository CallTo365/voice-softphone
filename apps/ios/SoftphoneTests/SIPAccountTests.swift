import Foundation
import Testing
@testable import SoftphoneKit

struct SIPAccountTests {
    @Test func identityAndServerURI() {
        let a = SIPAccount(username: "1001", domain: "acme.sip.local", serverHost: "91-99-163-145.sslip.io", password: "x")
        #expect(a.identity == "sip:1001@acme.sip.local")
        #expect(a.serverURI == "sip:91-99-163-145.sslip.io:5061;transport=tls")
        #expect(a.hasCredential)
    }

    @Test func ha1CountsAsCredential() {
        let a = SIPAccount(username: "1001", domain: "acme.sip.local", serverHost: "h", ha1: "abcd")
        #expect(a.hasCredential)
        #expect(!SIPAccount(username: "1001", domain: "d", serverHost: "h").hasCredential)
    }

    @Test func roundTripsThroughJSON() throws {
        let a = SIPAccount(username: "1001", domain: "acme.sip.local", serverHost: "h", serverPort: 5062, transport: .tcp, ha1: "abcd", realm: "r", trustAnyCertificate: true)
        let data = try JSONEncoder().encode(a)
        let b = try JSONDecoder().decode(SIPAccount.self, from: data)
        #expect(a == b)
    }
}
