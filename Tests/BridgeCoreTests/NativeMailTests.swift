import XCTest
@testable import BridgeCore

final class NativeMailTests:XCTestCase {
    func testConsumingAReadRechecksScopeAndRemovesItsStoredContent() throws {
        var state=NativeMailState()
        let box=NativeMailbox(accountID:"one",path:["Inbox"])
        try NativeMailCoordinator.authorize(accountID:"one",mailboxes:[box],state:&state)
        let request=try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:box.id,kind:.listMessages,query:NativeMailQuery(),state:&state)
        _ = try NativeMailCoordinator.claim(request.id,state:&state)
        try NativeMailCoordinator.complete(request.id,result:["messages":[]],state:&state)
        let value=try NativeMailCoordinator.consume(request.id,state:&state)
        XCTAssertEqual(value?["messages"].array?.count,0)
        XCTAssertTrue(state.operations.isEmpty)
        XCTAssertThrowsError(try NativeMailCoordinator.consume(request.id,state:&state))
    }
    func testPrivateNativeStateSurvivesLegacyWritesAndRejectsOversizeAtomically() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=NativeMailStore(bridgeDirectory:directory)
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        let operation=try store.transaction { value in
            try NativeMailCoordinator.authorize(accountID:"one",mailboxes:[inbox],state:&value)
            let request=try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:inbox.id,kind:.listMessages,query:NativeMailQuery(),state:&value)
            _ = try NativeMailCoordinator.claim(request.id,state:&value)
            return request
        }
        try BridgeStore(directory:directory).transaction { $0.audit.append("old message writer") }
        XCTAssertEqual(try store.read().grants.first?.accountID,"one")
        XCTAssertThrowsError(try store.transaction { try NativeMailCoordinator.complete(operation.id,result:["body":.string(String(repeating:"x",count:131_073))],state:&$0) })
        XCTAssertNil(try store.read().operations.first?.result)
        let mode=try FileManager.default.attributesOfItem(atPath:store.directory.appendingPathComponent("access.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode,0o600)
    }
    func testConcurrentReadDoesNotDiscardAnUnconsumedResult() throws {
        var state=NativeMailState()
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        try NativeMailCoordinator.authorize(accountID:"one",mailboxes:[inbox],state:&state)
        let first=try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:inbox.id,kind:.listMessages,query:NativeMailQuery(),state:&state)
        _ = try NativeMailCoordinator.claim(first.id,state:&state)
        try NativeMailCoordinator.complete(first.id,result:["messages":[]],state:&state)
        _ = try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:inbox.id,kind:.listMessages,query:NativeMailQuery(),state:&state)
        XCTAssertNotNil(state.operations.first(where:{$0.id == first.id})?.result)
    }
    func testMailboxIdentityIncludesAccountAndFullPath() throws {
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        XCTAssertNotEqual(inbox.id,NativeMailbox(accountID:"two",path:["Inbox"]).id)
        XCTAssertNotEqual(inbox.id,NativeMailbox(accountID:"one",path:["Archive","Inbox"]).id)
        XCTAssertEqual(try JSONValue.encode(inbox)["id"].string,inbox.id)
        XCTAssertNotEqual(NativeMailbox(accountID:"one",path:["é"]),NativeMailbox(accountID:"one",path:["e\u{301}"]))
    }
    func testNoReadWithoutExplicitNativeFolderGrant() throws {
        var state=NativeMailState()
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        XCTAssertThrowsError(try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:inbox.id,kind:.listMessages,query:NativeMailQuery(),state:&state))
        XCTAssertTrue(state.operations.isEmpty)
    }
    func testGrantDoesNotAuthorizeAnotherAccountOrFolder() throws {
        var state=NativeMailState()
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        try NativeMailCoordinator.authorize(accountID:"one",mailboxes:[inbox],state:&state)
        XCTAssertThrowsError(try NativeMailCoordinator.enqueue(accountID:"two",mailboxID:inbox.id,kind:.listMessages,query:NativeMailQuery(),state:&state))
        let archive=NativeMailbox(accountID:"one",path:["Archive"])
        XCTAssertThrowsError(try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:archive.id,kind:.listMessages,query:NativeMailQuery(),state:&state))
        XCTAssertThrowsError(try NativeMailCoordinator.authorize(accountID:"two",mailboxes:[inbox],state:&state))
    }
    func testRevocationDiscardsInFlightDataAndRegrantDoesNotReviveIt() throws {
        var state=NativeMailState()
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        try NativeMailCoordinator.authorize(accountID:"one",mailboxes:[inbox],state:&state)
        let request=try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:inbox.id,kind:.listMessages,query:NativeMailQuery(),state:&state)
        _ = try NativeMailCoordinator.claim(request.id,state:&state)
        NativeMailCoordinator.revoke(accountID:"one",state:&state)
        try NativeMailCoordinator.authorize(accountID:"one",mailboxes:[inbox],state:&state)
        XCTAssertThrowsError(try NativeMailCoordinator.complete(request.id,result:["body":"must not escape"],state:&state))
        XCTAssertNil(state.operations.first?.result)
    }
    func testExpiredReadIsNeverClaimed() throws {
        var state=NativeMailState()
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        try NativeMailCoordinator.authorize(accountID:"one",mailboxes:[inbox],state:&state)
        let request=try NativeMailCoordinator.enqueue(accountID:"one",mailboxID:inbox.id,kind:.listMessages,query:NativeMailQuery(),state:&state)
        state.operations[0].deadline = .distantPast
        XCTAssertThrowsError(try NativeMailCoordinator.claim(request.id,state:&state))
        XCTAssertNil(state.operations[0].claimedAt)
    }
}
