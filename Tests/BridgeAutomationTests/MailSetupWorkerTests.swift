import XCTest
import BridgeCore
@testable import BridgeAutomation

@MainActor final class MailSetupWorkerTests:XCTestCase {
    func testWorkerDiscoversFoldersWithoutCreatingGrant() async throws {
        let store=fixture(),box=NativeMailbox(accountID:"one",path:["Inbox"])
        let request=try store.transaction { try MailSetupCoordinator.enqueue(accountID:"one",state:&$0) }
        let worker=MailSetupWorker(store:store,readerFactory:{ _ in SetupFixtureReader(boxes:[box]) })
        await worker.processNext()
        XCTAssertEqual(try store.read().setupOperations.first?.result?.mailboxes,[box])
        XCTAssertTrue(try store.read().grants.isEmpty)
        XCTAssertEqual(try store.read().setupOperations.first?.id,request.id)
    }
    func testDeletedAccountDoesNotReturnFolders() async throws {
        let store=fixture()
        _ = try store.transaction { try MailSetupCoordinator.enqueue(accountID:"deleted",state:&$0) }
        let worker=MailSetupWorker(store:store,readerFactory:{ _ in SetupFixtureReader(boxes:[]) })
        await worker.processNext()
        XCTAssertNotNil(try store.read().setupOperations.first?.error)
        XCTAssertNil(try store.read().setupOperations.first?.result)
    }
    func testCanceledRequestCannotPublishLateDiscovery() async throws {
        let store=fixture()
        let request=try store.transaction { try MailSetupCoordinator.enqueue(accountID:nil,state:&$0) }
        let worker=MailSetupWorker(store:store,readerFactory:{ _ in
            SetupFixtureReader(boxes:[],beforeReturn:{ try store.transaction { MailSetupCoordinator.cancel(request.id,state:&$0) } })
        })
        await worker.processNext()
        XCTAssertTrue(try store.read().setupOperations.isEmpty)
    }
    private func fixture()->NativeMailStore {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return NativeMailStore(bridgeDirectory:directory)
    }
}

private struct SetupFixtureReader:MailSetupReading {
    let boxes:[NativeMailbox]
    var beforeReturn:(@Sendable () throws -> Void)?
    func accounts() async throws -> [NativeMailAccount] {
        try beforeReturn?()
        return [NativeMailAccount(id:"one",name:"One",addresses:["owner@example.com"],server:"")]
    }
    func mailboxes(accountID:String) async throws -> [NativeMailbox] { boxes }
}
