import XCTest
import BridgeCore
@testable import BridgeAutomation

final class NativeMailReaderTests:XCTestCase {
    func testScriptAssignmentsCannotReplaceNamedHandlers() throws {
        // AppleScript identifiers are case-insensitive. Assigning selectedBox
        // can replace a handler named selectedbox and break its second call.
        let source=NativeMailReader.source as NSString
        func names(_ pattern:String)throws->Set<String> {
            let expression=try NSRegularExpression(pattern:pattern,options:[.anchorsMatchLines])
            return Set(expression.matches(in:source as String,range:NSRange(location:0,length:source.length)).map {
                source.substring(with:$0.range(at:1)).lowercased()
            })
        }
        let handlers=try names(#"^\s*on ([A-Za-z][A-Za-z0-9]*)\("#)
        let assignments=try names(#"^\s*set (?:my )?([A-Za-z][A-Za-z0-9]*) to "#)
        XCTAssertTrue(handlers.intersection(assignments).isEmpty,"A script assignment shadows a named handler.")
    }
    func testExpiryDuringResolutionPreventsFollowingBodyRead() throws {
        // Fake resolution consumes the remaining budget. The production script's
        // checkpoint must stop the next event, represented here by a counter.
        let probe=NativeMailReader.source + """

        on run
            set my readDeadline to (current date) + 10
            set fakeReads to {"resolve"}
            set my readDeadline to (current date) - 1
            try
                my checkdeadline()
                set end of fakeReads to "body"
                return {count of fakeReads, 0}
            on error number errorNumber
                return {count of fakeReads, errorNumber}
            end try
        end run
        """
        let script=try XCTUnwrap(NSAppleScript(source:probe))
        var error:NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error))
        let result=script.executeAndReturnError(&error)
        XCTAssertNil(error)
        XCTAssertEqual(result.atIndex(1)?.int32Value,1)
        XCTAssertEqual(result.atIndex(2)?.int32Value,-1712)
    }
    func testNativeReaderScriptCompilesWithoutReadingMail() throws {
        XCTAssertNoThrow(try NativeMailReader.validateScript())
    }
    func testMessageFingerprintBindsMailboxAndLiteralHeaders() throws {
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        let message=NativeMailMessage(id:1,mailboxID:inbox.id,headerID:"fixture",subject:"Résumé",sender:"sender@example.invalid",receivedAt:Date(timeIntervalSince1970:1000),isRead:false,size:100,to:["owner@example.invalid"],cc:[],bcc:[],attachmentCount:0)
        var changed=message; changed.subject="Resume"
        XCTAssertNotEqual(changed.fingerprint,message.fingerprint)
        changed=message; changed.mailboxID=NativeMailbox(accountID:"other",path:["Inbox"]).id
        XCTAssertNotEqual(changed.fingerprint,message.fingerprint)
        changed=message; changed.isRead=true
        XCTAssertNotEqual(changed.fingerprint,message.fingerprint)
    }
    func testNativeBodyLimitAndExpectedIdentityAreChecked() throws {
        let message=NativeMailMessage(id:1,mailboxID:"box",headerID:"fixture",subject:"Synthetic",sender:"sender@example.invalid",receivedAt:Date(),isRead:false,size:100,to:[],cc:[],bcc:[],attachmentCount:0)
        XCTAssertThrowsError(try NativeMailBody(message:message,text:String(repeating:"x",count:65_537),expectedFingerprint:message.fingerprint))
        XCTAssertThrowsError(try NativeMailBody(message:message,text:"Synthetic",expectedFingerprint:"stale"))
        XCTAssertNoThrow(try NativeMailBody(message:message,text:"Synthetic",expectedFingerprint:message.fingerprint))
    }
}
