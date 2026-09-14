import Testing
@testable import SoftphoneKit

struct DialStringTests {
    @Test func extensionStaysAsIs() {
        #expect(DialString.normalize("1001") == .success("1001"))
    }

    @Test func separatorsAreStripped() {
        #expect(DialString.normalize("+31 6 12-34.56 78") == .success("+31612345678"))
        #expect(DialString.normalize("(0473) 98 16 16") == .success("0473981616"))
    }

    @Test func doubleZeroBecomesPlus() {
        #expect(DialString.normalize("0032 473 98 16 16") == .success("+32473981616"))
    }

    @Test func nationalPrefixInsideInternationalIsDropped() {
        #expect(DialString.normalize("+31 (0)6 12345678") == .success("+31612345678"))
    }

    @Test func starAndHashAreAllowed() {
        #expect(DialString.normalize("*98") == .success("*98"))
    }

    @Test func rejectsGarbage() {
        #expect(DialString.normalize("") == .failure(.empty))
        #expect(DialString.normalize("   ") == .failure(.empty))
        #expect(DialString.normalize("abc") == .failure(.invalidCharacters))
        #expect(DialString.normalize("+") == .failure(.invalidCharacters))
    }

    @Test func buildsSipURIOnTheDomainNotTheServer() {
        #expect(DialString.sipURI("1002", domain: "acme.sip.local") == .success("sip:1002@acme.sip.local"))
    }
}
