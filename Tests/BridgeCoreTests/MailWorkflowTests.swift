import XCTest
@testable import BridgeCore

final class MailWorkflowTests:XCTestCase {
    func testCompositionAcceptsOnlyBoundedBareAddressSyntax() throws {
        for address in ["person(comment)@example.invalid","a:b@example.invalid","a..b@example.invalid",".a@example.invalid","a.@example.invalid","a@-example.invalid","a@example-.invalid","a@example..invalid"] {
            let proposal=MailWorkflowComposition(accountID:"a",sender:"owner@example.invalid",to:[address],cc:[],bcc:[],subject:"Fixture",body:"Text")
            XCTAssertThrowsError(try proposal.validate(),address)
        }
        let valid=MailWorkflowComposition(accountID:"a",sender:"owner@example.invalid",to:["first.last+tag@sub.example.invalid"],cc:[],bcc:[],subject:"Fixture",body:"Text")
        XCTAssertNoThrow(try valid.validate())
    }
    func testComposeRequiresExplicitScopedDraftFields() throws {
        var request=try MailWorkflowRequest(action:.compose,accountIDs:["account-a"])
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal ready",items:[])
        XCTAssertThrowsError(try request.accept(report))
        report.composition=MailWorkflowComposition(accountID:"account-a",sender:"owner@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],subject:"Meeting",body:"Hello\n\nThursday works.\nOwner")
        // The owner's rule applies to new messages too: Dot must have asked which mode applies.
        XCTAssertThrowsError(try request.accept(report)); XCTAssertNil(request.report)
        report.composition?.delivery = .save
        try request.accept(report)
        XCTAssertEqual(request.report?.composition?.delivery,.save)
        let restored=try JSONDecoder().decode(MailWorkflowRequest.self,from:JSONEncoder().encode(request))
        try restored.validate()
        XCTAssertEqual(restored.report?.composition?.to,["recipient@example.invalid"])
        XCTAssertEqual(restored.report?.composition?.body,"Hello\n\nThursday works.\nOwner")
    }
    func testComposeRejectsUnselectedAccountAmbiguousAddressesAndOversizedBody() throws {
        for change in 0..<5 {
            var request=try MailWorkflowRequest(action:.compose,accountIDs:["account-a"])
            var proposal=MailWorkflowComposition(accountID:"account-a",sender:"owner@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],subject:"Meeting",body:"Hello")
            switch change {
            case 0: proposal.accountID="account-b"
            case 1: proposal.to=[]
            case 2: proposal.to=["Unresolved Person"]
            case 3: proposal.subject="Meeting\nBcc: another@example.invalid"
            default: proposal.body=String(repeating:"x",count:65_537)
            }
            var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal",items:[])
            report.composition=proposal
            XCTAssertThrowsError(try request.accept(report)); XCTAssertNil(request.report)
        }
    }
    func testFullReadTextBoundaryAndActionStageRestrictions() throws {
        let cases:[(MailWorkflowAction,MailWorkflowStage,String,Bool)]=[
            (.readFull,.ready,String(repeating:"x",count:65_536),true),
            (.readFull,.ready,String(repeating:"x",count:65_537),false),
            (.readFull,.ready," \n\t",false),
            (.readFull,.working,"Complete text",false),
            (.summarize,.ready,"Complete text",false)
        ]
        for (action,stage,text,allowed) in cases {
            var request=try MailWorkflowRequest(action:action,accountIDs:["account-a"],itemID:"message-a",itemRevision:1,sourceID:"source-a")
            var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:stage,summary:"Result",items:[])
            report.readback=MailWorkflowReadback(itemID:"message-a",accountID:"account-a",sourceID:"source-a",itemRevision:1,text:text)
            if allowed { try request.accept(report); XCTAssertEqual(request.report?.readback?.text.utf8.count,65_536) }
            else { XCTAssertThrowsError(try request.accept(report)); XCTAssertNil(request.report) }
        }
    }
    func testLegacyCompletedFullReadWithoutTextRemainsReadable() throws {
        let id=UUID().uuidString
        let legacy:JSONValue=["id":.string(id),"action":"readFull","accountIDs":["account-a"],"itemID":"message-a","itemRevision":1,"sourceID":"source-a","createdAt":0,"revision":1,"stage":"ready","observedItems":[],"event":try .encode(BridgeEvent()),"report":["requestID":.string(id),"expectedRevision":0,"stage":"ready","summary":"Legacy summary","items":[]]]
        // Dates in the persisted state use JSONEncoder's reference-date numbers.
        var object=legacy.object!; object["event"]=try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(BridgeEvent()))
        let request=try JSONDecoder().decode(MailWorkflowRequest.self,from:Data(JSONValue.object(object).text().utf8))
        try request.validate()
        XCTAssertNil(request.report?.readback)
        XCTAssertEqual(request.report?.summary,"Legacy summary")
    }
    func testFullReadRequiresCompleteBoundTextRatherThanSummary() throws {
        var request=try MailWorkflowRequest(action:.readFull,accountIDs:["account-a"],itemID:"message-a",itemRevision:1,sourceID:"source-a")
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Readback ready",items:[])
        XCTAssertThrowsError(try request.accept(report))
        let complete="Hello,\n\n" + String(repeating:"Long message. ",count:800) + "\nSignature\nQuoted original"
        report.readback=MailWorkflowReadback(itemID:"message-a",accountID:"account-a",sourceID:"source-a",itemRevision:1,text:complete)
        try request.accept(report)
        let restored=try JSONDecoder().decode(MailWorkflowRequest.self,from:JSONEncoder().encode(request))
        try restored.validate()
        XCTAssertEqual(restored.report?.readback?.text,complete)
    }
    func testFullReadRejectsWrongIdentityVersionOrOversizedText() throws {
        for change in 0..<5 {
            var request=try MailWorkflowRequest(action:.readFull,accountIDs:["account-a"],itemID:"message-a",itemRevision:1,sourceID:"source-a")
            var readback=MailWorkflowReadback(itemID:"message-a",accountID:"account-a",sourceID:"source-a",itemRevision:1,text:"Complete body")
            switch change {
            case 0: readback.accountID="account-b"
            case 1: readback.itemID="message-b"
            case 2: readback.sourceID="source-b"
            case 3: readback.itemRevision=2
            default: readback.text=String(repeating:"あ",count:21846)
            }
            var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Readback",items:[])
            report.readback=readback
            XCTAssertThrowsError(try request.accept(report))
            XCTAssertNil(request.report); XCTAssertEqual(request.revision,0)
        }
    }
    func testCorrelatedReportAdvancesRequestWithoutGrantingSendAuthority() throws {
        var request=try MailWorkflowRequest(action:.status,accountIDs:["account-a"])
        let report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"One message needs your input",items:[item()])
        try request.accept(report)
        XCTAssertEqual(request.revision,1)
        XCTAssertEqual(request.stage,.ready)
        XCTAssertEqual(request.report?.items.count,1)
        XCTAssertThrowsError(try request.accept(report))
    }
    func testWrongRequestAccountAndDuplicateItemsAreRejected() throws {
        var request=try MailWorkflowRequest(action:.drafts,accountIDs:["account-a"])
        var report=MailWorkflowReport(requestID:UUID().uuidString,expectedRevision:0,stage:.ready,summary:"Drafts",items:[item()])
        XCTAssertThrowsError(try request.accept(report))
        report.requestID=request.id; report.items[0].accountID="unselected"
        XCTAssertThrowsError(try request.accept(report))
        report.items=[item(),item()]
        XCTAssertThrowsError(try request.accept(report))
        XCTAssertEqual(request.revision,0); XCTAssertNil(request.report)
    }
    func testItemActionsRequireAnExactTargetAndRevision() throws {
        XCTAssertThrowsError(try MailWorkflowRequest(action:.readFull,accountIDs:["account-a"]))
        XCTAssertThrowsError(try MailWorkflowRequest(action:.summarize,accountIDs:["account-a"],itemID:"item",itemRevision:-1))
        XCTAssertNoThrow(try MailWorkflowRequest(action:.readFull,accountIDs:["account-a"],itemID:"item",itemRevision:2,sourceID:"source"))
        XCTAssertThrowsError(try MailWorkflowRequest(action:.status,accountIDs:[]))
    }
    func testNeedsInputRequiresAQuestionAndTerminalReportsCannotBeReplaced() throws {
        var request=try MailWorkflowRequest(action:.needsInput,accountIDs:["account-a"])
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.awaitingInput,summary:"Need a decision",items:[])
        XCTAssertThrowsError(try request.accept(report))
        report.question="Which meeting time?"
        try request.accept(report)
        report.expectedRevision=1; report.stage = .ready; report.question=nil
        try request.accept(report)
        report.expectedRevision=2
        XCTAssertThrowsError(try request.accept(report))
    }
    func testListCategoryAndSelectedItemRevisionMustMatch() throws {
        var drafts=try MailWorkflowRequest(action:.drafts,accountIDs:["account-a"])
        XCTAssertThrowsError(try drafts.accept(MailWorkflowReport(requestID:drafts.id,expectedRevision:0,stage:.ready,summary:"Drafts",items:[item()])))
        var selected=try MailWorkflowRequest(action:.summarize,accountIDs:["account-a"],itemID:"message-a",itemRevision:2,sourceID:"source-a")
        XCTAssertThrowsError(try selected.accept(MailWorkflowReport(requestID:selected.id,expectedRevision:0,stage:.ready,summary:"Summary",items:[item()])))
    }
    func testRevisionResponseMayAdvanceOnlyTheSelectedItem() throws {
        var request=try MailWorkflowRequest(action:.revise,accountIDs:["account-a"],itemID:"message-a",itemRevision:1,sourceID:"source-a")
        var revised=item(); revised.revision=2
        XCTAssertNoThrow(try request.accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Revision prepared",items:[revised])))
    }
    func testSelectedSourceCannotBeSubstitutedInTheResponse() throws {
        var request=try MailWorkflowRequest(action:.readFull,accountIDs:["account-a"],itemID:"message-a",itemRevision:1,sourceID:"source-a")
        var replacement=item(); replacement.sourceID="different-email"
        XCTAssertThrowsError(try request.accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Readback",items:[replacement])))
        XCTAssertNil(request.report)
    }
    func testSuccessiveReportsCannotRegressAnObservedRevision() throws {
        var request=try MailWorkflowRequest(action:.revise,accountIDs:["account-a"],itemID:"message-a",itemRevision:1,sourceID:"source-a")
        var latest=item(); latest.revision=3
        try request.accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.working,summary:"Revising",items:[latest]))
        latest.revision=2
        XCTAssertThrowsError(try request.accept(MailWorkflowReport(requestID:request.id,expectedRevision:1,stage:.ready,summary:"Ready",items:[latest])))
        XCTAssertEqual(request.report?.items.first?.revision,3)
        try request.accept(MailWorkflowReport(requestID:request.id,expectedRevision:1,stage:.working,summary:"Still working",items:[]))
        XCTAssertEqual(request.observedItems.first?.revision,3)
        try request.validate()
    }
    private func item()->MailWorkflowItem {
        MailWorkflowItem(id:"message-a",accountID:"account-a",sourceID:"source-a",revision:1,kind:.needsInput,subject:"Meeting",summary:"Choose a time",question:"Thursday or Friday?",checkedAt:Date())
    }
}
