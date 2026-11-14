import XCTest
@testable import BridgeCore

final class MailSetupTests:XCTestCase {
    func testLegacyNativeStateDecodesWithoutSetupQueue() throws {
        let state=try JSONDecoder().decode(NativeMailState.self,from:Data(#"{"schemaVersion":1,"grants":[],"operations":[]}"#.utf8))
        XCTAssertTrue(state.setupOperations.isEmpty)
    }
    func testDiscoveryDoesNotGrantMessageAccessAndResultIsConsumedOnce() throws {
        var state=NativeMailState()
        let request=try MailSetupCoordinator.enqueue(accountID:"one",state:&state)
        _ = try MailSetupCoordinator.claim(request.id,state:&state)
        let inbox=NativeMailbox(accountID:"one",path:["Inbox"])
        try MailSetupCoordinator.complete(request.id,result:MailSetupResult(mailboxes:[inbox]),state:&state)
        XCTAssertEqual(try MailSetupCoordinator.consume(request.id,state:&state)?.mailboxes,[inbox])
        XCTAssertThrowsError(try MailSetupCoordinator.consume(request.id,state:&state))
        XCTAssertTrue(state.grants.isEmpty)
        XCTAssertTrue(state.operations.isEmpty)
        XCTAssertThrowsError(try NativeMailCoordinator.grant(accountID:"one",mailboxID:inbox.id,state:state))
    }
    func testWrongAccountOrMixedMetadataCannotBePublished() throws {
        var state=NativeMailState()
        let request=try MailSetupCoordinator.enqueue(accountID:"one",state:&state)
        _ = try MailSetupCoordinator.claim(request.id,state:&state)
        XCTAssertThrowsError(try MailSetupCoordinator.complete(request.id,result:MailSetupResult(mailboxes:[NativeMailbox(accountID:"two",path:["Inbox"])]),state:&state))
        XCTAssertThrowsError(try MailSetupCoordinator.complete(request.id,result:MailSetupResult(accounts:[NativeMailAccount(id:"one",name:"One",addresses:[],server:"")]),state:&state))
        XCTAssertNil(state.setupOperations.first?.result)
    }
    func testExpiredCanceledOrUnclaimedDiscoveryCannotPublish() throws {
        var state=NativeMailState()
        let request=try MailSetupCoordinator.enqueue(accountID:nil,state:&state)
        XCTAssertThrowsError(try MailSetupCoordinator.complete(request.id,result:MailSetupResult(),state:&state))
        _ = try MailSetupCoordinator.claim(request.id,state:&state)
        state.setupOperations[0].deadline = .distantPast
        XCTAssertThrowsError(try MailSetupCoordinator.complete(request.id,result:MailSetupResult(),state:&state))
        XCTAssertThrowsError(try MailSetupCoordinator.consume(request.id,state:&state))
        MailSetupCoordinator.cancel(request.id,state:&state)
        XCTAssertTrue(state.setupOperations.isEmpty)
        XCTAssertThrowsError(try MailSetupCoordinator.complete(request.id,result:MailSetupResult(),state:&state))
    }
    func testDiscoveryQueueAndMetadataBounds() throws {
        var state=NativeMailState()
        for _ in 0..<20 { _ = try MailSetupCoordinator.enqueue(accountID:nil,state:&state) }
        XCTAssertThrowsError(try MailSetupCoordinator.enqueue(accountID:nil,state:&state))
        XCTAssertThrowsError(try MailSetupCoordinator.enqueue(accountID:"",state:&state))
        let request=state.setupOperations[0]
        _ = try MailSetupCoordinator.claim(request.id,state:&state)
        let duplicate=NativeMailAccount(id:"one",name:"One",addresses:[],server:"")
        XCTAssertThrowsError(try MailSetupCoordinator.complete(request.id,result:MailSetupResult(accounts:[duplicate,duplicate]),state:&state))
        XCTAssertThrowsError(try MailSetupCoordinator.complete(request.id,result:MailSetupResult(accounts:(0...100).map { NativeMailAccount(id:String($0),name:"One",addresses:[],server:"") }),state:&state))
    }
}
