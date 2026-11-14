import XCTest
import BridgeCore
@testable import BridgeAutomation

final class NativeReplyProbeTests:XCTestCase {
    func testScriptedReplyOmittingVisibleQuoteStaysReadOnly() throws {
        let native=MailDraft(id:1,subject:"Re: Synthetic",sender:"owner@example.invalid",to:["owner@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0)
        var visible=native; visible.id = -1; visible.attachmentCount = -1; visible.body="Visible quoted fixture"
        let result=try ReplyCapturePolicy.reconcile(native:native,visible:visible)
        XCTAssertEqual(result.id,-1)
        XCTAssertEqual(result.attachmentCount,-1)
        XCTAssertEqual(result.body,"Visible quoted fixture")
        visible.body=""
        XCTAssertEqual(try ReplyCapturePolicy.reconcile(native:native,visible:visible).id,1)
        visible.to=["other@example.invalid"]
        XCTAssertThrowsError(try ReplyCapturePolicy.reconcile(native:native,visible:visible))
    }
    func testIncompleteFixturePageCannotSelectSource() throws {
        let row:JSONValue=["subject":"Mail Dot native read test - UNSENT"]
        XCTAssertThrowsError(try NativeReplyProbe.uniqueFixture(in:["messages":[row],"collection_complete":false,"next_offset":50]))
        XCTAssertNoThrow(try NativeReplyProbe.uniqueFixture(in:["messages":[row],"collection_complete":true,"next_offset":nil]))
        XCTAssertThrowsError(try NativeReplyProbe.uniqueFixture(in:["messages":[row,row],"collection_complete":true,"next_offset":nil]))
    }
    func testOnlyExactSyntheticDraftCanBecomeProbeReply() throws {
        let account=NativeMailAccount(id:"fixture-account",name:"Fixture",addresses:["owner@example.invalid"],server:"fixture")
        let box=NativeMailbox(accountID:account.id,path:["Drafts"])
        let message=NativeMailMessage(id:1,mailboxID:box.id,headerID:"fixture",subject:"Mail Dot native read test - UNSENT",sender:"Owner <owner@example.invalid>",receivedAt:Date(),isRead:true,size:512,to:[],cc:[],bcc:[],attachmentCount:0)
        let text="Fixture identifier: native-mail-read-20261109.\nMeeting: Thursday at 14:00.\nState: synthetic unsent test; no delivery intended."
        func body(_ record:NativeMailMessage,_ value:String?=nil)throws->NativeMailBody {
            try NativeMailBody(message:record,text:value ?? text,expectedFingerprint:record.fingerprint)
        }
        XCTAssertNoThrow(try NativeReplyProbe.validate(body:body(message),account:account,mailbox:box))
        XCTAssertThrowsError(try NativeReplyProbe.validate(body:body(message,"Different content"),account:account,mailbox:box))
        var other=message; other.subject="Real correspondence"
        XCTAssertThrowsError(try NativeReplyProbe.validate(body:body(other),account:account,mailbox:box))
        other=message; other.to=["someone@example.invalid"]
        XCTAssertThrowsError(try NativeReplyProbe.validate(body:body(other),account:account,mailbox:box))
        other=message; other.attachmentCount=1
        XCTAssertThrowsError(try NativeReplyProbe.validate(body:body(other),account:account,mailbox:box))
        other=message; other.sender="stranger@example.invalid"
        XCTAssertThrowsError(try NativeReplyProbe.validate(body:body(other),account:account,mailbox:box))
        XCTAssertThrowsError(try NativeReplyProbe.validate(body:body(message),account:account,mailbox:NativeMailbox(accountID:"other",path:["Drafts"])))
        XCTAssertThrowsError(try NativeReplyProbe.validate(body:body(message),account:account,mailbox:NativeMailbox(accountID:account.id,path:["INBOX"])))
    }
}
