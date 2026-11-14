import XCTest
import BridgeCore
@testable import BridgeAutomation

private actor CreationCounter {
    var value=0
    func increment() {value += 1}
}
final class NativeCompositionWorkerTests:XCTestCase {
    private func fixture(_ root:URL) throws -> (NativeCompositionPlan,[NativeMailAccount],MailDraft) {
        let p=MailWorkflowComposition(accountID:"gmail:profile",sender:"owner@example.com",to:["recipient@example.com"],cc:[],bcc:[],subject:"Synthetic",body:"Not sent.",delivery:.save)
        var request=try MailWorkflowRequest(action:.compose,accountIDs:[p.accountID])
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal",items:[])
        report.composition=p; try request.accept(report)
        var connection=MailConnection(id:"profile",email:p.sender,connectionID:"connection"); connection.observedAt=Date()
        let settings=MailSettingsStore(bridgeDirectory:root)
        try settings.transaction {$0.connections=[connection]}
        let accounts=try MailWorkflowAccount.available(settings:settings.read(),native:NativeMailState())
        let native=[NativeMailAccount(id:"owner",name:"Owner",addresses:[p.sender],server:"imap.example.com")]
        let plan=try NativeCompositionPlan(request:request,displayedRevision:1,displayed:p,accounts:accounts,nativeAccounts:native)
        try MailWorkflowStore(bridgeDirectory:root).transaction{try $0.enqueue(request,allowedAccountIDs:[p.accountID])}
        try NativeCompositionStore(bridgeDirectory:root).transaction{try $0.enqueue(plan)}
        return (plan,native,MailDraft(id:42,subject:p.subject,sender:p.sender,to:p.to,cc:[],bcc:[],body:p.body,attachmentCount:0))
    }
    func testWorkerPersistsOneResultAndDoesNotReplay() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (_,native,draft)=try fixture(root)
        let count=CreationCounter()
        let worker=NativeCompositionWorker(bridgeDirectory:root) {_,_,consume in
            try consume(native); await count.increment(); return draft
        }
        await worker.processNext(); await worker.processNext()
        let calls=await count.value
        XCTAssertEqual(calls,1)
        let op=try NativeCompositionStore(bridgeDirectory:root).read().operations[0]
        XCTAssertEqual(op.draft,draft); XCTAssertNotNil(op.consumedAt); XCTAssertNil(op.error)
    }
    func testRevocationIsRecheckedAtConsumption() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (_,native,draft)=try fixture(root)
        let count=CreationCounter()
        let worker=NativeCompositionWorker(bridgeDirectory:root) {_,_,consume in
            try MailSettingsStore(bridgeDirectory:root).transaction{$0.connections=[]}
            try consume(native); await count.increment(); return draft
        }
        await worker.processNext(); await worker.processNext()
        let calls=await count.value
        XCTAssertEqual(calls,0)
        let op=try NativeCompositionStore(bridgeDirectory:root).read().operations[0]
        XCTAssertNil(op.consumedAt); XCTAssertNotNil(op.error); XCTAssertNil(op.draft)
    }
    func testTwoWorkersCannotCreateTheSameQueuedProposal() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (_,native,draft)=try fixture(root)
        let count=CreationCounter()
        let create:NativeCompositionWorker.Create={_,_,consume in
            try consume(native); await count.increment(); return draft
        }
        let first=NativeCompositionWorker(bridgeDirectory:root,create:create)
        let second=NativeCompositionWorker(bridgeDirectory:root,create:create)
        async let one:Void=first.processNext()
        async let two:Void=second.processNext()
        _=await (one,two)
        let calls=await count.value
        XCTAssertEqual(calls,1)
        XCTAssertEqual(try NativeCompositionStore(bridgeDirectory:root).read().operations[0].draft,draft)
    }
    func testUncertainNativeResultIsRetainedAndNeverReplayed() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (_,native,_)=try fixture(root)
        let count=CreationCounter()
        let worker=NativeCompositionWorker(bridgeDirectory:root) {_,_,consume in
            try consume(native); await count.increment(); throw BridgeFailure("Native outcome uncertain")
        }
        await worker.processNext(); await worker.processNext()
        let calls=await count.value
        XCTAssertEqual(calls,1)
        let op=try NativeCompositionStore(bridgeDirectory:root).read().operations[0]
        XCTAssertNotNil(op.consumedAt); XCTAssertNotNil(op.error); XCTAssertNil(op.draft)
    }
    func testResultWriteFailureRemainsReadableAsUnconfirmed() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=NativeCompositionStore(bridgeDirectory:root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:store.directory.path)
            try? FileManager.default.removeItem(at:root)
        }
        let (_,native,draft)=try fixture(root)
        let worker=NativeCompositionWorker(bridgeDirectory:root) {_,_,consume in
            try consume(native)
            try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:store.directory.path)
            return draft
        }
        await worker.processNext()
        let operation=try store.read().operations[0]
        XCTAssertNotNil(operation.consumedAt)
        XCTAssertNil(operation.draft); XCTAssertNil(operation.error)
        XCTAssertEqual(operation.outcome,.unconfirmed)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:store.directory.path)
        XCTAssertNil(try store.transaction{$0.claimNext()})
    }
}
