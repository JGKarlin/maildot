import XCTest
@testable import BridgeCore

@MainActor final class NativeMailRPCTests:XCTestCase {
    func testNativeToolsCannotAuthorizeOrReadAnUnselectedAccount() async throws {
        let bridge=fixture(),router=MCPRouter(store:bridge,statelessTunnel:true)
        let status=try await call(router,"native_mail_status",[:])
        XCTAssertEqual(status["result"]["structuredContent"]["accounts"].array?.count,0)
        let denied=try await call(router,"native_mail_list_mailboxes",["account_id":"unselected"])
        XCTAssertEqual(denied["result"]["isError"],true)
        XCTAssertTrue(try NativeMailStore(bridgeDirectory:bridge.directory).read().operations.isEmpty)
        let catalog=MCPRouter.tools.compactMap { $0["name"].string }
        XCTAssertFalse(catalog.contains("authorize_native_mail"))
    }
    func testNativeMailboxRPCConsumesOnlyTheScopedResult() async throws {
        let bridge=fixture(),store=NativeMailStore(bridgeDirectory:bridge.directory)
        let box=NativeMailbox(accountID:"selected",path:["Inbox"])
        try store.transaction { try NativeMailCoordinator.authorize(accountID:"selected",mailboxes:[box],state:&$0) }
        let router=MCPRouter(store:bridge,statelessTunnel:true,wakeCompanion:{
            try? store.transaction { state in
                guard let pending=state.operations.first else { return }
                _ = try NativeMailCoordinator.claim(pending.id,state:&state)
                try NativeMailCoordinator.complete(pending.id,result:["account_id":"selected","mailboxes":try .encode([box])],state:&state)
            }
        })
        let response=try await call(router,"native_mail_list_mailboxes",["account_id":"selected"])
        XCTAssertEqual(response["result"]["isError"],false)
        XCTAssertEqual(response["result"]["structuredContent"]["mailboxes"].array?.first?["id"].string,box.id)
        XCTAssertTrue(try store.read().operations.isEmpty)
    }
    private func fixture()->BridgeStore {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return BridgeStore(directory:directory)
    }
    private func call(_ router:MCPRouter,_ name:String,_ arguments:JSONValue) async throws -> JSONValue {
        let request:JSONValue=["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":.string(name),"arguments":arguments]]
        let serialized=try request.text()
        let reply=await router.response(serialized)
        return try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(reply).utf8))
    }
}
