import Testing
@testable import SoftphoneKit

struct RedactorTests {
    @Test func authorizationHeaderIsRedacted() {
        let line = "Authorization: Digest username=\"1001\", realm=\"acme.sip.local\", response=\"abc123\""
        let out = Redactor.redact(line)
        #expect(out == "Authorization: <redacted>")
    }

    @Test func proxyAuthorizationToo() {
        let out = Redactor.redact("Proxy-Authorization: Digest username=\"1001\"")
        #expect(out == "Proxy-Authorization: <redacted>")
    }

    @Test func passwordAndHa1Pairs() {
        #expect(Redactor.redact("passwd=hunter2;ha1=0123abcd") == "passwd=<redacted>;ha1=<redacted>")
        #expect(Redactor.redact("password: s3cret") == "password: <redacted>")
    }

    @Test func pushTokenInContact() {
        let contact = "<sip:1001@1.2.3.4;transport=tls;pn-provider=apns.dev;pn-prid=ABCDEF0123;pn-param=T.b.voip>"
        #expect(Redactor.redact(contact) == "<sip:1001@1.2.3.4;transport=tls;pn-provider=apns.dev;pn-prid=<redacted>;pn-param=T.b.voip>")
    }

    @Test func bearerToken() {
        #expect(Redactor.redact("Bearer eyJhbGciOi.abc-def_ghi") == "Bearer <redacted>")
    }

    @Test func digestResponseInsideOtherText() {
        #expect(Redactor.redact("x response=\"deadbeef\" y") == "x response=\"<redacted>\" y")
    }

    @Test func leavesOrdinaryTextAlone() {
        let s = "REGISTER sip:acme.sip.local SIP/2.0 expires=600"
        #expect(Redactor.redact(s) == s)
    }
}
