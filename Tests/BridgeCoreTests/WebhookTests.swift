import XCTest
@testable import BridgeCore

final class WebhookTests: XCTestCase {
    let secret = "whsec_" + Data("01234567890123456789012345678901".utf8).base64EncodedString()

    func testSignatureMatchesIndependentOpenSSLVector() throws {
        XCTAssertEqual(try WebhookSecurity.signature(id: "evt_test", timestamp: 1_700_000_000, body: Data("{}".utf8), secret: secret),
                       "v1,disXL8gf6Ho+VkVgiDUJ4e6yYrxymPKOPczqxI2Y1/g=")
    }
    func testShortOrUnprefixedSecretsAreRefused() {
        for invalid in ["abc", "whsec_YWJj"] {
            XCTAssertThrowsError(try WebhookSecurity.signature(id:"evt", timestamp:0, body:Data(), secret:invalid))
        }
    }
    func testCallbackRejectsLocalHTTPUserInfoAndImpostorHosts() {
        for invalid in ["http://api.openai.com/callback", "https://127.0.0.1/callback", "https://localhost/callback", "https://user@api.openai.com/callback", "https://openai.com.evil.example/callback", "https://api.openai.com:8080/callback"] {
            XCTAssertThrowsError(try WebhookSecurity.callbackURL(invalid), invalid)
        }
    }
    func testCallbackAllowsOnlyOfficialHTTPSHosts() throws {
        XCTAssertEqual(try WebhookSecurity.callbackURL("https://api.openai.com/callback/opaque").host, "api.openai.com")
        XCTAssertEqual(try WebhookSecurity.callbackURL("https://chatgpt.com/callback/opaque").host, "chatgpt.com")
    }
    func testCallbackRefusesTheDomainThatServesUserSuppliedContent() {
        // ChatGPT was observed calling back on openai.com. A domain that hosts content uploaded by anyone
        // has no business receiving Mail Dot's events.
        XCTAssertThrowsError(try WebhookSecurity.callbackURL("https://files.oaiusercontent.com/callback/opaque"))
        XCTAssertThrowsError(try WebhookSecurity.callbackURL("https://oaiusercontent.com/callback"))
        XCTAssertEqual(WebhookSecurity.allowedCallbackDomains,["openai.com","chatgpt.com"])
    }
    func testChallengeComparisonIncludesLength() {
        XCTAssertTrue(WebhookSecurity.sameChallenge("abcdef", "abcdef"))
        XCTAssertFalse(WebhookSecurity.sameChallenge("abcdef", "abcdeg"))
        XCTAssertFalse(WebhookSecurity.sameChallenge("abcdef", "abc"))
    }

    func testPinnedTransportRejectsNonpublicAddresses() {
        for address in ["127.0.0.1","10.0.0.1","169.254.1.2","100.64.0.1","192.0.2.1","198.18.0.1","198.51.100.1","203.0.113.1","240.0.0.1","::1","::ffff:127.0.0.1","fc00::1","fe80::1","2001:db8::1","2002:7f00:1::1"] {
            XCTAssertFalse(PinnedWebhookTransport.isPublicAddress(address),address)
        }
        for address in ["1.1.1.1","8.8.8.8","2606:4700::1111"] {
            XCTAssertTrue(PinnedWebhookTransport.isPublicAddress(address),address)
        }
    }
}
