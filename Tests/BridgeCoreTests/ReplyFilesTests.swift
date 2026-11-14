import XCTest
@testable import BridgeCore

final class ReplyFilesTests:XCTestCase {
    private func directory() -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }

    func testOnlyDocumentsWithPlainNamesWithinTheLimitsAreKept() throws {
        XCTAssertEqual(try ReplyFiles.safeName("../Forms/申請書 (更新).docx"),"申請書 (更新).docx")
        XCTAssertThrowsError(try ReplyFiles.safeName("run.command"),"nothing that runs")
        XCTAssertThrowsError(try ReplyFiles.safeName(".hidden"))
        let root=directory()
        let file=try ReplyFiles.save(Data("x".utf8),filename:"form.docx",mediaType:nil,owner:"reply",bridgeDirectory:root,existing:[])
        XCTAssertEqual(try Data(contentsOf:ReplyFiles.url(root,owner:"reply",file:file)),Data("x".utf8))
        XCTAssertThrowsError(try ReplyFiles.save(Data(count:ReplyFiles.maxBytes+1),filename:"big.pdf",mediaType:nil,owner:"reply",bridgeDirectory:root,existing:[]))
        let five=Array(repeating:file,count:ReplyFiles.perReply)
        XCTAssertThrowsError(try ReplyFiles.save(Data("y".utf8),filename:"six.pdf",mediaType:nil,owner:"reply",bridgeDirectory:root,existing:five))
    }

    func testAnAutomaticDraftsFilesAndDoneLinesReachTheReply() throws {
        let root=directory()
        var state=MailTriageState()
        var entry=MailTriageEntry(messageID:"<f@example.invalid>",sender:"m@example.invalid",senderName:nil,subject:"Forms",receivedAt:Date(),verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)
        entry.requestID="req"
        state.record(entry)
        state.accept(requestID:"req",stage:.ready,summary:"She asks for new names on two forms.\nDone: Updated the names on both forms\nDone: Added the deadline to your calendar\nDraft reply:\nHi Ai,\nBoth forms are attached.")
        let drafted=try XCTUnwrap(state.entries.first)
        XCTAssertEqual(drafted.outcome,.drafted)
        XCTAssertEqual(drafted.tasksDone,["Updated the names on both forms","Added the deadline to your calendar"])
        XCTAssertEqual(drafted.dotNote,"She asks for new names on two forms.")
        let file=try ReplyFiles.save(Data("x".utf8),filename:"form.docx",mediaType:nil,owner:"triage-"+drafted.id,bridgeDirectory:root,existing:[])
        ReplyFiles.move([file],from:"triage-"+drafted.id,to:"reply",bridgeDirectory:root)
        XCTAssertTrue(FileManager.default.fileExists(atPath:ReplyFiles.url(root,owner:"reply",file:file).path))
        var context=ReplyContext(id:"reply",envelope:MailDraft(id: -1,subject:"Re: Forms",sender:"owner@example.invalid",to:["m@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0))
        context.snapshot=context.envelope
        BridgeCoordinator.ownerOpensPanel(context:&context)
        XCTAssertTrue(BridgeCoordinator.usePreparedReply(try XCTUnwrap(drafted.draft),writtenAt:Date(),tasksDone:drafted.tasksDone,files:[file],context:&context))
        XCTAssertEqual(context.proposal?.tasksDone?.count,2)
        XCTAssertEqual(context.dotFiles?.first?.filename,"form.docx")
    }

    func testDotIsToldToFinishTasksButNeverToActForTheOwnerTowardOthers() throws {
        var context=ReplyContext(id:"reply",envelope:MailDraft(id: -1,subject:"Re: Forms",sender:"owner@example.invalid",to:["m@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0))
        context.snapshot=context.envelope
        BridgeCoordinator.ownerOpensPanel(context:&context)
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:context,preferences:["en-US"]))
        XCTAssertTrue(told.contains("add or change events in the owner's own calendar"))
        XCTAssertTrue(told.contains("never send, submit, sign, accept or decline an invitation, or notify anyone"))
        XCTAssertTrue(told.contains("attach_reply_file takes context_id"))
        XCTAssertTrue(MailWorkflowTools.instructions(for:.draftCheck).contains("beginning Done: before the line Draft reply:"))
        try BridgeCoordinator.propose("Hi,\nDone.",expectedRevision:context.snapshotRevision,eventID:nil,tasksDone:["Added the seminar to your calendar"],context:&context)
        XCTAssertEqual(context.proposal?.tasksDone,["Added the seminar to your calendar"])
    }
}
