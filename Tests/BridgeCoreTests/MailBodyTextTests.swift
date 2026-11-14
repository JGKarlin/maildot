import XCTest
@testable import BridgeCore

final class MailBodyTextTests:XCTestCase {
    let names=["Tanaka","田中","Hanako"]
    func raw(_ body:String,headers:String) -> Data { Data(("From: a@example.invalid\r\nCc: owner@example.invalid\r\n\(headers)\r\n\r\n"+body).utf8) }
    func testPlainUTF8() {
        XCTAssertTrue(MailBodyText.mentions(names,inRawMessage:raw("Dear Prof. Tanaka, could you confirm?",headers:"Content-Type: text/plain; charset=utf-8")))
        XCTAssertFalse(MailBodyText.mentions(names,inRawMessage:raw("Dear all,\n> Tanaka wrote earlier",headers:"Content-Type: text/plain")),"quoted earlier mail does not count")
    }
    func testBase64JapaneseInMultipart() {
        let text=Data("田中先生\nご確認をお願いします。".utf8).base64EncodedString()
        let body="--b1\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(text)\r\n--b1\r\nContent-Type: text/html\r\n\r\n<p>x</p>\r\n--b1--\r\n"
        XCTAssertTrue(MailBodyText.mentions(names,inRawMessage:raw(body,headers:"Content-Type: multipart/alternative; boundary=\"b1\"")))
    }
    func testISO2022JPQuotedPrintable() throws {
        let jis=try XCTUnwrap("田中先生".data(using:.iso2022JP))
        let qp=jis.map{ $0 == 0x1B || $0 >= 0x80 || $0 == 0x3D ? String(format:"=%02X",$0) : String(UnicodeScalar($0)) }.joined()
        XCTAssertTrue(MailBodyText.mentions(names,inRawMessage:raw(qp,headers:"Content-Type: text/plain; charset=ISO-2022-JP\r\nContent-Transfer-Encoding: quoted-printable")))
    }
    func testACcMessageNamingTheOwnerGoesToDot() {
        let owner:Set<String>=["owner@example.invalid"]
        var input=MailTriage.Input(messageID:"m@example.invalid",senderAddress:"a@example.invalid",senderName:"A",to:["b@example.invalid"],cc:["owner@example.invalid"],subject:"Question",receivedAt:Date(),headers:[:])
        XCTAssertTrue(MailTriage.assess(input,owner:owner).essential,"copied mail goes to Dot")
        input.mentionsOwner=true
        XCTAssertTrue(MailTriage.assess(input,owner:owner).reason.contains("mentions you"))
        var state=MailTriageState()
        state.record(MailTriageEntry(messageID:"m@example.invalid",sender:"a@example.invalid",senderName:"A",subject:"Question",receivedAt:Date(),
                                     verdict:MailTriage.Verdict(essential:false,reason:MailTriage.copiedOnlyReason),automatic:true))
        XCTAssertTrue(state.noteMention(messageID:"<m@example.invalid>",sender:"a@example.invalid"))
        XCTAssertEqual(state.entries[0].outcome,.pending)
    }
}

final class OwnerNamesTests:XCTestCase {
    func testNamesComeFromRegisteredFullNamesNotFromCode() {
        XCTAssertEqual(OwnerNames.derive(from:["Hanako Tanaka","田中 花子","Hanako Tanaka"]),["Hanako Tanaka","Hanako","Tanaka","田中 花子","田中","花子"])
        XCTAssertEqual(OwnerNames.derive(from:["Jo A. Li"]),["Jo A. Li"],"initials and two-letter Latin parts are not names to look for")
        var settings=MailSettings()
        XCTAssertTrue(settings.effectiveOwnerNames.isEmpty,"nothing built in")
        settings.macUserFullName="Hanako Tanaka"
        XCTAssertEqual(settings.effectiveOwnerNames,["Hanako Tanaka","Hanako","Tanaka"])
        settings.ownerNames=["Dr. T"]
        XCTAssertEqual(settings.effectiveOwnerNames,["Dr. T"],"names the owner sets win")
    }
}
