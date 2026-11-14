import XCTest
import BridgeCore
@testable import BridgeAutomation

@MainActor final class NativeMailWorkerTests:XCTestCase {
    func testWorkerRemovesExpiredUnconsumedContent() async throws {
        let (store,inbox)=try fixture()
        try store.transaction { state in
            let request=try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:inbox.id,kind:.listMessages,query:NativeMailQuery(),state:&state)
            _ = try NativeMailCoordinator.claim(request.id,state:&state)
            try NativeMailCoordinator.complete(request.id,result:["messages":[]],state:&state)
            state.operations[0].deadline = .distantPast
        }
        let worker=NativeMailWorker(store:store,readerFactory:{ _ in FixtureMailReader(boxes:[inbox]) })
        await worker.processNext()
        XCTAssertTrue(try store.read().operations.isEmpty)
    }
    func testWorkerPublishesOnlyAuthorizedMailboxReferences() async throws {
        let (store,inbox)=try fixture()
        let request=try store.transaction { try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:nil,kind:.probeMailboxes,query:NativeMailQuery(),state:&$0) }
        let worker=NativeMailWorker(store:store,readerFactory:{ _ in FixtureMailReader(boxes:[inbox,NativeMailbox(accountID:"one",path:["Private other folder"])]) })
        await worker.processNext()
        let result=try XCTUnwrap(store.read().operations.first(where:{$0.id == request.id})?.result)
        XCTAssertEqual(result["mailboxes"].array?.count,1)
        XCTAssertFalse(try result.text().contains("Private other folder"))
        XCTAssertNotNil(try store.read().grants.first?.verifiedAt)
    }
    func testRevocationWhileReaderRunsCannotPublishData() async throws {
        let (store,inbox)=try fixture()
        let request=try store.transaction { try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:nil,kind:.probeMailboxes,query:NativeMailQuery(),state:&$0) }
        let worker=NativeMailWorker(store:store,readerFactory:{ _ in FixtureMailReader(boxes:[inbox],beforeReturn:{ try store.transaction { NativeMailCoordinator.revoke(accountID:"one",state:&$0) } }) })
        await worker.processNext()
        let operation=try XCTUnwrap(store.read().operations.first(where:{$0.id == request.id}))
        XCTAssertNil(operation.result)
        XCTAssertNotNil(operation.error)
        XCTAssertNil(try store.read().grants.first?.verifiedAt)
    }
    func testMailDotsOwnCheckConnectsTheAccountAndAMailClosedFailureDoesNotUndoIt() async throws {
        let (store,inbox)=try fixture()
        try store.transaction { _ = try NativeMailCoordinator.check(accountID:"one",state:&$0) }
        await NativeMailWorker(store:store,readerFactory:{ _ in FixtureMailReader(boxes:[inbox]) }).processNext()
        let verified=try XCTUnwrap(store.read().grants.first?.verifiedAt,"the owner's Allow is followed by Mail Dot's own check")
        XCTAssertNotNil(NativeMailCoordinator.latestCheck(accountID:"one",state:try store.read())?.result)
        // Later, Mail is closed when the account is checked again: that says nothing about the folders.
        try store.transaction { _ = try NativeMailCoordinator.check(accountID:"one",state:&$0) }
        await NativeMailWorker(store:store,readerFactory:{ _ in FixtureMailReader(boxes:[inbox],beforeReturn:{ throw BridgeFailure("Mail is not open. Open Mail, then try again.") }) }).processNext()
        XCTAssertEqual(try store.read().grants.first?.verifiedAt,verified)
        XCTAssertEqual(NativeMailCoordinator.latestCheck(accountID:"one",state:try store.read())?.error,"Mail is not open. Open Mail, then try again.")
    }
    func testACheckThatFindsAnAllowedFolderGoneUndoesTheVerification() async throws {
        let (store,inbox)=try fixture()
        try store.transaction { _ = try NativeMailCoordinator.check(accountID:"one",state:&$0) }
        await NativeMailWorker(store:store,readerFactory:{ _ in FixtureMailReader(boxes:[inbox]) }).processNext()
        XCTAssertNotNil(try store.read().grants.first?.verifiedAt)
        try store.transaction { _ = try NativeMailCoordinator.check(accountID:"one",state:&$0) }
        await NativeMailWorker(store:store,readerFactory:{ _ in FixtureMailReader(boxes:[NativeMailbox(accountID:"one",path:["Renamed"])]) }).processNext()
        XCTAssertNil(try store.read().grants.first?.verifiedAt)
    }
    private func fixture() throws -> (NativeMailStore,NativeMailbox) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        let store=NativeMailStore(bridgeDirectory:directory),inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        try store.transaction { try NativeMailCoordinator.authorize(accountID:"one",mailboxes:[inbox],state:&$0) }
        return (store,inbox)
    }
}

private struct FixtureMailReader:NativeMailReading {
    let boxes:[NativeMailbox]
    var beforeReturn:(@Sendable () throws -> Void)?
    func mailboxes(accountID:String) async throws -> [NativeMailbox] { try beforeReturn?(); return boxes }
    func listMessages(accountID:String,mailbox:NativeMailbox,query:NativeMailQuery) async throws -> JSONValue { throw BridgeFailure("Not part of this fixture") }
    func readMessage(accountID:String,mailbox:NativeMailbox,messageID:Int,expectedFingerprint:String) async throws -> NativeMailBody { throw BridgeFailure("Not part of this fixture") }
}
