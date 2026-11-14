import XCTest
@testable import BridgeCore

final class NewMessageTests:XCTestCase {
    private func newMessage(to:[String]) -> ReplyContext {
        var context=ReplyContext(id:"new",envelope:MailDraft(id: -1,subject:"",sender:"owner@example.invalid",to:to,cc:[],bcc:[],body:"",attachmentCount:0))
        context.newMessage=true
        context.snapshot=context.envelope
        BridgeCoordinator.ownerOpensPanel(context:&context)
        return context
    }

    func testDotIsNotAskedUntilThereIsARecipientAndTheOwnerSaysWhatToWrite() throws {
        var context=newMessage(to:[])
        XCTAssertFalse(BridgeCoordinator.dotIsOwedWord(context),"no recipient, no words")
        context.envelope.to=["sam@example.invalid"]
        XCTAssertFalse(BridgeCoordinator.dotIsOwedWord(context),"a recipient, but nothing said yet")
        var state=BridgeState(); state.contexts["new"]=context
        try BridgeCoordinator.ownerDirects("Ask Sam whether Thursday works for the seminar.",contextID:"new",state:&state)
        XCTAssertTrue(BridgeCoordinator.dotIsOwedWord(try XCTUnwrap(state.contexts["new"])))
    }

    func testDotIsToldItIsANewMessageForThisRecipientAndToWriteASubject() throws {
        var state=BridgeState(); state.contexts["new"]=newMessage(to:["sam@example.invalid"])
        try BridgeCoordinator.ownerDirects("Ask Sam whether Thursday works.",contextID:"new",state:&state)
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:try XCTUnwrap(state.contexts["new"]),preferences:["en-US"]))
        XCTAssertTrue(told.contains("a new message they are writing in Mail; it is not a reply. It is addressed to sam@example.invalid."))
        XCTAssertTrue(told.contains("What the owner wants this message to say: Ask Sam whether Thursday works."))
        XCTAssertTrue(told.contains("pass it as subject if propose_reply offers a subject field"))
        XCTAssertTrue(told.contains("Settle what you can yourself before asking anything, and look only as far as the reply needs"))
        XCTAssertTrue(told.contains("1) Open every reply with a salutation"),"the owner's drafting rules apply too")
        XCTAssertTrue(told.contains("Write everything else the owner reads on the Mac"))
    }

    func testTheSubjectComesAsAFieldOrAsTheFirstLineAndOnlyForANewMessage() throws {
        var context=newMessage(to:["sam@example.invalid"])
        try BridgeCoordinator.propose("Subject: Seminar on Thursday\n\nHi Sam,\nDoes Thursday at 14:00 work?",expectedRevision:0,eventID:nil,context:&context)
        XCTAssertEqual(context.proposal?.subject,"Seminar on Thursday")
        XCTAssertEqual(context.proposal?.body,"Hi Sam,\nDoes Thursday at 14:00 work?")
        try BridgeCoordinator.propose("Hi Sam,\nRevised.",expectedRevision:0,expectedProposalRevision:1,eventID:nil,subject:"Seminar, revised",context:&context)
        XCTAssertEqual(context.proposal?.subject,"Seminar, revised")
        XCTAssertEqual(BridgeCoordinator.subjectLine(in:"件名：研究会の日程\n\n田中様、")?.subject,"研究会の日程")
        var reply=ReplyContext(id:"r",envelope:MailDraft(id: -1,subject:"Re: x",sender:"owner@example.invalid",to:["a@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0))
        reply.snapshot=reply.envelope
        try BridgeCoordinator.propose("Subject: not for replies\n\nHello",expectedRevision:0,eventID:nil,delivery:.save,subject:"ignored",context:&reply)
        XCTAssertNil(reply.proposal?.subject,"a reply keeps its own subject")
        XCTAssertTrue(reply.proposal?.body.hasPrefix("Subject:") == true,"and its text is left as Dot wrote it")
    }

    func testASubjectTheOwnerTypedIsKeptAndDotWritesToIt() throws {
        var context=newMessage(to:["sam@example.invalid"])
        context.envelope.subject="Seminar room booking"; context.snapshot?.subject="Seminar room booking"
        var state=BridgeState(); state.contexts["new"]=context
        try BridgeCoordinator.ownerDirects("Ask Sam to confirm the room.",contextID:"new",state:&state)
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:try XCTUnwrap(state.contexts["new"]),preferences:["en-US"]))
        XCTAssertTrue(told.contains("The owner has already given this message its subject line: Seminar room booking. Keep it exactly"))
        var drafted=try XCTUnwrap(state.contexts["new"])
        try BridgeCoordinator.propose("Subject: Something else\n\nHi Sam,\nCould you confirm the room?",expectedRevision:0,eventID:nil,subject:"Another",context:&drafted)
        XCTAssertNil(drafted.proposal?.subject,"the owner's subject stays; Mail Dot types none")
        XCTAssertEqual(drafted.proposal?.body,"Hi Sam,\nCould you confirm the room?","a subject line Dot put first is still taken out of the message")
    }
}
