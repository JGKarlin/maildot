import XCTest
@testable import BridgeCore

/// The owner's requirement: only essential mail is offered to Dot; receipts, codes, spam and the like never are.
final class MailTriageTests:XCTestCase {
    private let owner:Set<String>=["owner@example.invalid","owner@work.example.invalid"]
    private func input(_ sender:String="tanaka@example.invalid",name:String?="田中 愛子",to:[String]=["owner@example.invalid"],cc:[String]=[],subject:String="研究会の日程について",headers:[String:[String]]=[:]) -> MailTriage.Input {
        MailTriage.Input(messageID:"<a@example.invalid>",senderAddress:sender,senderName:name,to:to,cc:cc,subject:subject,receivedAt:Date(),headers:headers)
    }
    private func essential(_ value:MailTriage.Input,correspondents:Set<String>=[],rules:[String:MailTriage.Rule]=[:]) -> Bool { MailTriage.assess(value,owner:owner,correspondents:correspondents,rules:rules).essential }

    func testASubjectWordSetsAsideOnlyMailFromStrangers() {
        let consult=input(subject:"(相談) Application receipt from an applicant")
        XCTAssertFalse(essential(consult),"a stranger's receipt stays out")
        XCTAssertTrue(essential(consult,correspondents:["tanaka@example.invalid"]),"someone the owner writes to is still offered to Dot")
    }
    func testTheBannerFollowsADraftAskedForInTheReplyPanel() {
        var state=MailTriageState()
        var entry=MailTriageEntry(messageID:"a@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"S",receivedAt:nil,verdict:MailTriage.assess(input(),owner:owner),automatic:true)
        entry.outcome = .noDraft
        state.record(entry)
        state.noteReplyPanelDrafting(messageID:"<a@example.invalid>")
        XCTAssertEqual(MailDotBanner(state.entries[0]),.drafting)
        state.recordReplyDraft(messageID:"<a@example.invalid>",sender:"tanaka@example.invalid",senderName:nil,subject:"S",draft:"Thank you.")
        XCTAssertEqual(MailDotBanner(state.entries[0]),.draftReady)
    }
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
        // A batch at a time (owner's choice, 18 November 2026): never more in flight than the batch, and no more
        // offered until Dot has answered some, up to the hourly limit.
        XCTAssertEqual(MailTriageState.inFlightLimit,6)
        for _ in 0..<(MailTriageState.hourlyLimit+10) {
            let due=state.dueForDot()
            guard !due.isEmpty else { break }
            XCTAssertLessThanOrEqual(due.count,MailTriageState.inFlightLimit,"never more than one batch in flight")
            for entry in due { state.markAsked(entry.id,requestID:UUID().uuidString) }
            XCTAssertTrue(state.dueForDot().isEmpty,"a full batch: the next waits for Dot's answers")
            // Dot answers one: exactly one more is offered, while the hour's limit allows.
            let first=state.entries.first{$0.id == due[0].id}!.requestID!
            state.accept(requestID:first,stage:.ready,summary:"No reply needed.")
            XCTAssertLessThanOrEqual(state.dueForDot().count,1)
            for entry in due.dropFirst() { state.accept(requestID:state.entries.first{$0.id == entry.id}!.requestID!,stage:.ready,summary:"No reply needed.") }
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
        XCTAssertThrowsError(try state.ask(entry.id,draft:true,guidance:String(repeating:"x",count:ReplyOwnerRequest.textLimit+1)))
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

    // MARK: The batch (owner's choice, 18 November 2026)

    private func chainStore() throws -> (MailWorkflowStore,URL,[MailWorkflowAccount]) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return (MailWorkflowStore(bridgeDirectory:root),root,[])
    }
    private func chained(_ at:Date,first:Bool) throws -> MailWorkflowRequest {
        var request=try MailWorkflowRequest(action:.draftCheck,accountIDs:["gmail:profile"],triageID:UUID().uuidString,createdAt:at)
        if !first { request.chained=true; request.event.nextAttemptAt=at.addingTimeInterval(MailWorkflowState.chainPlaceWait) }
        return request
    }

    /// ChatGPT is told of the first message alone; the others wait to be handed over, each a place later.
    func testOnlyTheFirstOfABatchIsAnnouncedAtOnce() throws {
        let now=Date()
        var state=MailWorkflowState()
        let first=try chained(now,first:true),second=try chained(now.addingTimeInterval(1),first:false),third=try chained(now.addingTimeInterval(2),first:false)
        state.requests=[first,second,third]
        XCTAssertEqual(state.chainWaiting(now:now).map(\.id),[second.id,third.id])
        XCTAssertEqual(state.chainNext(now:now)?.id,second.id,"the one handed over next")
        // Dot reports on the first and is handed the second: the notices of those still waiting are put off.
        let put=state.deferChain(first:MailWorkflowState.chainTakeWait,now:now.addingTimeInterval(30))
        XCTAssertEqual(put,[second.id,third.id])
        let due=state.requests.map{ $0.event.nextAttemptAt.timeIntervalSince(now) }
        XCTAssertEqual(due[1],30+MailWorkflowState.chainTakeWait,accuracy:1)
        XCTAssertEqual(due[2],30+MailWorkflowState.chainTakeWait+MailWorkflowState.chainPlaceWait,accuracy:1,"each a place later")
        XCTAssertEqual(due[0],0,accuracy:1,"the first was announced at once and is left alone")
    }

    /// A chain Dot does not follow costs nothing: a message Dot has taken, one already announced and one finished are
    /// no longer waiting to be handed over.
    func testAMessageTakenAnnouncedOrFinishedLeavesTheChain() throws {
        let now=Date()
        var state=MailWorkflowState()
        var taken=try chained(now,first:false),announced=try chained(now.addingTimeInterval(1),first:false)
        let waiting=try chained(now.addingTimeInterval(2),first:false)
        taken.take(worker:"w",now:now)
        announced.event.receiptAt=now; announced.event.attempts=1
        state.requests=[taken,announced,waiting]
        XCTAssertEqual(state.chainWaiting(now:now).map(\.id),[waiting.id])
        XCTAssertEqual(MailWorkflowState.chainPlaceWait,75,"the pace of one message at a time, as before")
        XCTAssertTrue(MailWorkflowTools.draftCheckInstructions.contains("next_request_id"))
        XCTAssertTrue(MailWorkflowTools.chainInstruction.contains("Do not end your turn"))
    }
}
