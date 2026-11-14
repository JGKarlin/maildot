import XCTest
@testable import BridgeCore

/// The owner's requirement: only essential mail is offered to Dot; receipts, codes, spam and the like never are.
final class MailTriageTests:XCTestCase {
    private let owner:Set<String>=["owner@example.invalid","owner@work.example.invalid"]
    private func input(_ sender:String="tanaka@example.invalid",name:String?="田中 愛子",to:[String]=["owner@example.invalid"],cc:[String]=[],subject:String="研究会の日程について",headers:[String:[String]]=[:]) -> MailTriage.Input {
        MailTriage.Input(messageID:"<a@example.invalid>",senderAddress:sender,senderName:name,to:to,cc:cc,subject:subject,receivedAt:Date(),headers:headers)
    }
    private func essential(_ value:MailTriage.Input,correspondents:Set<String>=[],rules:[String:MailTriage.Rule]=[:]) -> Bool { MailTriage.assess(value,owner:owner,correspondents:correspondents,rules:rules).essential }

    func testAPersonWritingToTheOwnerDirectlyIsOfferedToDot() {
        XCTAssertTrue(essential(input()))
        XCTAssertEqual(MailTriage.assess(input(),owner:owner).reason,"田中 愛子 wrote to you directly.")
        XCTAssertEqual(MailTriage.assess(input(),owner:owner,correspondents:["tanaka@example.invalid"]).reason,"田中 愛子 wrote to you directly, and you have written to them before.")
        XCTAssertTrue(essential(input(to:["OWNER@work.example.invalid"])),"any of the owner's addresses, in any case")
    }
    func testReceiptsCodesSpamBulkAndAutomatedMailAreNeverOffered() {
        let cases:[(MailTriage.Input,String)]=[
            (input(subject:"Your receipt from Example Store"),"receipt"),
            (input(subject:"ご注文の確認"),"Japanese order notice"),
            (input(subject:"Your verification code is 482913"),"code"),
            (input(subject:"認証コード: 551203"),"Japanese code"),
            (input(headers:["X-Spam-Flag":["YES"]]),"spam flag"),
            (input(headers:["x-spam-status":["Yes, score=7.1"]]),"spam status"),
            (input(headers:["X-MS-Exchange-Organization-SCL":["6"]]),"Exchange spam"),
            (input(headers:["List-Unsubscribe":["<mailto:u@example.invalid>"]]),"list"),
            (input(headers:["Precedence":["bulk"]]),"bulk"),
            (input(headers:["Auto-Submitted":["auto-generated"]]),"automatic"),
            (input("no-reply@example.invalid"),"no-reply"),
            (input("notifications@github.example.invalid"),"notifications"),
            (input("owner@example.invalid"),"from the owner"),
            (input(to:["someone@example.invalid"]),"not addressed to the owner"),
        ]
        for (value,label) in cases { XCTAssertFalse(essential(value),label) }
        // Copied mail goes to Dot too, after the same checks (owner request, 13 November 2026), and is marked as copied.
        let copied=MailTriage.assess(input(to:["team@example.invalid"],cc:["owner@example.invalid"]),owner:owner)
        XCTAssertTrue(copied.essential); XCTAssertTrue(copied.copied); XCTAssertTrue(copied.reason.contains("copied you"))
        XCTAssertFalse(essential(input(to:["team@example.invalid"],cc:["owner@example.invalid"],headers:["List-Id":["<team.example.invalid>"]])),"a copied list message is still a list message")
        XCTAssertFalse(essential(input("no-reply@example.invalid",to:["team@example.invalid"],cc:["owner@example.invalid"])),"a copied automated message is still automated")
        XCTAssertTrue(essential(input(headers:["Auto-Submitted":["no"]])),"Auto-Submitted: no is a person")
        XCTAssertTrue(essential(input(subject:"Room 3021 for Thursday")),"a number alone is not a code")
    }
    func testCopiedMailWaitsBehindMailSentToTheOwner() {
        var state=MailTriageState()
        func add(_ id:String,copied:Bool,minutesAgo:Double) {
            var entry=MailTriageEntry(messageID:"\(id)@example.invalid",sender:"a@example.invalid",senderName:nil,subject:id,receivedAt:Date().addingTimeInterval(-minutesAgo*60),
                                      verdict:MailTriage.Verdict(essential:true,reason:"x",copied:copied),automatic:true)
            entry.outcome = .pending
            state.record(entry)
        }
        add("cc-newest",copied:true,minutesAgo:1); add("direct-older",copied:false,minutesAgo:30); add("direct-newer",copied:false,minutesAgo:5)
        XCTAssertEqual(state.queueForDot().map(\.subject),["direct-newer","direct-older","cc-newest"])
    }
    func testTheOwnersRulesComeFirst() {
        XCTAssertFalse(essential(input(),rules:["tanaka@example.invalid":.never]))
        XCTAssertTrue(essential(input("no-reply@example.invalid"),rules:["no-reply@example.invalid":.always]))
    }
    func testEachMessageIsRecordedOnceAndOfferedWithinTheHourlyLimit() throws {
        var state=MailTriageState()
        let verdict=MailTriage.assess(input(),owner:owner)
        XCTAssertTrue(state.record(MailTriageEntry(messageID:"a@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"x",receivedAt:nil,verdict:verdict,automatic:true)))
        XCTAssertFalse(state.record(MailTriageEntry(messageID:"a@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"x",receivedAt:nil,verdict:verdict,automatic:true)),"Mail may hand a message over twice")
        let off=MailTriageEntry(messageID:"b@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"y",receivedAt:nil,verdict:verdict,automatic:false)
        XCTAssertEqual(off.outcome,.held,"with automatic drafting off nothing is offered")
        state.record(off)
        XCTAssertEqual(state.dueForDot().map(\.messageID),["a@example.invalid"])
        for index in 0..<(MailTriageState.hourlyLimit+10) { state.record(MailTriageEntry(messageID:"m\(index)@example.invalid",sender:"p\(index)@example.invalid",senderName:nil,subject:"z",receivedAt:nil,verdict:verdict,automatic:true)) }
        // One at a time; each answered before the next, up to the hourly limit.
        for _ in 0..<(MailTriageState.hourlyLimit+10) {
            guard let entry=state.dueForDot().first else { break }
            XCTAssertEqual(state.dueForDot().count,1,"never more than one request in flight")
            state.markAsked(entry.id,requestID:UUID().uuidString)
            XCTAssertTrue(state.dueForDot().isEmpty,"the next waits for Dot's answer")
            state.accept(requestID:state.entries.first{$0.id == entry.id}!.requestID!,stage:.ready,summary:"No reply needed.")
        }
        XCTAssertEqual(state.entries.filter{$0.outcome == .noDraft}.count,MailTriageState.hourlyLimit)
        XCTAssertTrue(state.dueForDot().isEmpty,"no more than the hourly limit is offered")
    }
    func testTheOwnersAskDotOffersASkippedMessage() throws {
        var state=MailTriageState()
        let skipped=MailTriageEntry(messageID:"r@example.invalid",sender:"no-reply@example.invalid",senderName:nil,subject:"Your receipt",receivedAt:nil,verdict:MailTriage.assess(input("no-reply@example.invalid"),owner:owner),automatic:true)
        state.record(skipped)
        XCTAssertTrue(state.dueForDot().isEmpty)
        try state.ask(skipped.id)
        XCTAssertEqual(state.dueForDot().first?.id,skipped.id)
        XCTAssertTrue(state.entries[0].askedByOwner)
    }
    func testDraftAReplyCarriesTheOwnersOptionalGuidance() throws {
        var state=MailTriageState()
        let entry=MailTriageEntry(messageID:"g@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"FYI",receivedAt:nil,verdict:MailTriage.assess(input(),owner:owner),automatic:true)
        state.record(entry); state.markAsked(entry.id,requestID:"req-1")
        state.accept(requestID:"req-1",stage:.ready,summary:"No reply needed: it only informs.")
        XCTAssertThrowsError(try state.ask(entry.id,draft:true,guidance:String(repeating:"x",count:2001)))
        try state.ask(entry.id,draft:true,guidance:"  Thank them and confirm Friday.  ")
        XCTAssertEqual(state.entries[0].outcome,.pending)
        XCTAssertEqual(state.entries[0].draftRequested,true)
        XCTAssertEqual(state.entries[0].draftGuidance,"Thank them and confirm Friday.")
        // Try Again after a failure keeps the owner's words.
        state.markAsked(entry.id,requestID:"req-2"); state.entries[0].outcome = .failed
        try state.ask(entry.id)
        XCTAssertEqual(state.entries[0].draftGuidance,"Thank them and confirm Friday.")
        // A blank Draft a Reply asks for a reply with no guidance.
        state.markAsked(entry.id,requestID:"req-3"); state.entries[0].outcome = .noDraft
        try state.ask(entry.id,draft:true,guidance:"   ")
        XCTAssertEqual(state.entries[0].draftRequested,true)
        XCTAssertNil(state.entries[0].draftGuidance)
        XCTAssertTrue(MailWorkflowTools.draftCheckInstructions.contains("owner_guidance"))
        XCTAssertTrue(MailWorkflowTools.draftCheckInstructions.contains("owner_wants_reply"))
    }
    func testDotsAnswerIsEitherADraftOrNoDraftNeeded() {
        var state=MailTriageState()
        let entry=MailTriageEntry(messageID:"d@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"x",receivedAt:nil,verdict:MailTriage.assess(input(),owner:owner),automatic:true)
        state.record(entry); state.markAsked(entry.id,requestID:"req-1")
        state.accept(requestID:"req-1",stage:.ready,summary:"Tanaka asks whether Thursday works.\nDraft reply:\n田中様\n\n木曜日の14時で問題ありません。")
        XCTAssertEqual(state.entries[0].outcome,.drafted)
        XCTAssertEqual(state.entries[0].draft,"田中様\n\n木曜日の14時で問題ありません。")
        XCTAssertEqual(state.draft(forMessageID:"<d@example.invalid>")?.id,entry.id)
        var other=MailTriageState(); other.record(entry); other.markAsked(entry.id,requestID:"req-2")
        other.accept(requestID:"req-2",stage:.ready,summary:"No reply needed: it is an announcement.")
        XCTAssertEqual(other.entries[0].outcome,.noDraft)
        XCTAssertNil(other.draft(forMessageID:"d@example.invalid"))
    }

    func testOnlyMessagesThatNeedTheOwnerCarryAFlagAndItIsKeptCurrent() throws {
        var state=MailTriageState()
        let essential=MailTriageEntry(messageID:"c@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"x",receivedAt:nil,verdict:MailTriage.assess(input(),owner:owner),automatic:true)
        let skipped=MailTriageEntry(messageID:"s@example.invalid",sender:"no-reply@example.invalid",senderName:nil,subject:"Receipt",receivedAt:nil,verdict:MailTriage.assess(input("no-reply@example.invalid"),owner:owner),automatic:true)
        state.record(essential); state.record(skipped)
        XCTAssertTrue(state.flagsDue().isEmpty,"nothing is flagged while Dot is checking, nor a skipped message")
        state.markAsked(essential.id,requestID:"r")
        state.accept(requestID:"r",stage:.awaitingInput,summary:"I need one thing.",question:"Thursday or Friday?")
        XCTAssertEqual(state.entries[0].listMark,.needsGuidance)
        XCTAssertEqual(state.flagsDue().map(\.id),[essential.id])
        XCTAssertEqual(state.flagIndex(for:.needsGuidance),4,"blue: the owner already uses red and orange")
        state.noteFlag(essential.id,applied:4,ownerFlagged:false,replied:false)
        XCTAssertTrue(state.flagsDue().isEmpty)
        try state.answer(essential.id,with:"Friday")
        XCTAssertEqual(state.flagsDue().map(\.id),[essential.id],"once answered, Mail Dot takes its flag off")
        state.noteFlag(essential.id,applied:-1,ownerFlagged:false,replied:false)
        state.markAsked(essential.id,requestID:"r2")
        state.accept(requestID:"r2",stage:.ready,summary:"Draft reply:\n金曜日でお願いします。")
        XCTAssertEqual(state.entries[0].listMark,.draftReady)
        state.flagColors=["draftReady":4]
        XCTAssertEqual(state.flagIndex(for:.draftReady),4,"the owner's choice of colour")
        state.noteFlag(essential.id,applied:4,ownerFlagged:false,replied:true)
        XCTAssertEqual(state.entries[0].outcome,.replied,"a reply the owner sent from Mail is seen")
        XCTAssertEqual(state.flagsDue().map(\.id),[essential.id],"and the flag comes off")
        state.noteFlag(essential.id,applied:nil,ownerFlagged:true,replied:false)
        XCTAssertTrue(state.flagsDue().isEmpty,"a flag the owner set is never touched")
    }
    func testAListSavedByBuild82StillLoads() throws {
        let saved=#"{"correspondents":["a@example.invalid"],"entries":[{"askedByOwner":false,"essential":true,"id":"E1","outcome":"asked","reason":"r","seenAt":"2026-11-11T15:00:00Z","sender":"a@example.invalid","subject":"s","appliedColor":"blue"}],"rules":{}}"#
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state=try decoder.decode(MailTriageState.self,from:Data(saved.utf8))
        XCTAssertEqual(state.entries.count,1)
        XCTAssertNil(state.flagColors)
        XCTAssertNil(state.entries[0].ownerFlagged)
    }
    func testDraftsDotWroteOnItsOwnAreThrownAwayWhenRepliedDiscardedOrOld() throws {
        var state=MailTriageState()
        for (index,age) in [TimeInterval(0),TimeInterval(15*86_400)].enumerated() {
            var entry=MailTriageEntry(messageID:"d\(index)@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"x",receivedAt:nil,verdict:MailTriage.assess(input(),owner:owner),automatic:true)
            entry.seenAt=Date().addingTimeInterval(-age); entry.outcome = .drafted; entry.draft="Reply \(index)"
            state.record(entry)
        }
        XCTAssertEqual(state.discardOldDrafts(),1,"only the draft older than 14 days")
        XCTAssertNil(state.entries[1].draft)
        XCTAssertEqual(state.entries[0].draft,"Reply 0")
        state.markReplied(messageID:"d0@example.invalid")
        XCTAssertNil(state.entries[0].draft,"a reply by any means throws the draft away")
        var other=MailTriageState()
        var entry=MailTriageEntry(messageID:"e@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"x",receivedAt:nil,verdict:MailTriage.assess(input(),owner:owner),automatic:true)
        entry.outcome = .drafted; entry.draft="Reply"
        other.record(entry)
        try other.discardDraft(entry.id)
        XCTAssertNil(other.draft(forMessageID:"e@example.invalid"))
    }
}
