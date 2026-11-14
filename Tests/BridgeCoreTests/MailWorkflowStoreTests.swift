import Foundation
import XCTest
@testable import BridgeCore

final class MailWorkflowStoreTests:XCTestCase {
    func testReportSurvivesReopeningAndFailedTransactionPreservesIt() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MailWorkflowStore(bridgeDirectory:root)
        let request=try MailWorkflowRequest(action:.status,accountIDs:["a"])
        try store.transaction { try $0.enqueue(request,allowedAccountIDs:["a"]) }
        try store.transaction {
            try $0.requests[0].accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"No pending messages",items:[]))
        }
        XCTAssertThrowsError(try store.transaction { state in
            state.requests.removeAll()
            throw BridgeFailure("Canceled update")
        })
        let restored=try MailWorkflowStore(bridgeDirectory:root).read()
        XCTAssertEqual(restored.requests[0].report?.summary,"No pending messages")
        XCTAssertEqual(restored.requests[0].revision,1)
    }
    func testUnlinkedAccountsAndInventedTargetsCannotBeQueued() throws {
        var state=MailWorkflowState()
        XCTAssertThrowsError(try state.enqueue(MailWorkflowRequest(action:.status,accountIDs:["unlinked"]),allowedAccountIDs:["a"]))
        XCTAssertThrowsError(try state.enqueue(MailWorkflowRequest(action:.readFull,accountIDs:["a"],itemID:"invented",itemRevision:1,sourceID:"source"),allowedAccountIDs:["a"]))
        XCTAssertTrue(state.requests.isEmpty)
    }
    func testStateFileSymlinkIsRejected() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MailWorkflowStore(bridgeDirectory:root)
        try FileManager.default.createDirectory(at:store.directory,withIntermediateDirectories:true)
        let target=root.appendingPathComponent("other.json")
        try JSONEncoder().encode(MailWorkflowState()).write(to:target)
        try FileManager.default.createSymbolicLink(at:store.directory.appendingPathComponent("workflow.json"),withDestinationURL:target)
        XCTAssertThrowsError(try store.read())
    }
    func testOlderListedRevisionCannotBeSelectedAfterANewerReport() throws {
        var state=MailWorkflowState()
        for revision in [1,2] {
            var request=try MailWorkflowRequest(action:.drafts,accountIDs:["a"])
            let item=MailWorkflowItem(id:"draft",accountID:"a",sourceID:"source",revision:revision,kind:.draft,subject:"Test",summary:"Draft",checkedAt:Date())
            try request.accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Drafts",items:[item]))
            state.requests.append(request)
        }
        XCTAssertThrowsError(try state.enqueue(MailWorkflowRequest(action:.readFull,accountIDs:["a"],itemID:"draft",itemRevision:1,sourceID:"source"),allowedAccountIDs:["a"]))
        try state.dismiss(state.requests[1].id)
        XCTAssertThrowsError(try state.enqueue(MailWorkflowRequest(action:.readFull,accountIDs:["a"],itemID:"draft",itemRevision:1,sourceID:"source"),allowedAccountIDs:["a"]))
        XCTAssertNoThrow(try state.enqueue(MailWorkflowRequest(action:.readFull,accountIDs:["a"],itemID:"draft",itemRevision:2,sourceID:"source"),allowedAccountIDs:["a"]))
    }
    func testPendingRequestCanBeCanceledAndFreesCapacity() throws {
        var state=MailWorkflowState()
        for _ in 0..<20 { try state.enqueue(MailWorkflowRequest(action:.status,accountIDs:["a"]),allowedAccountIDs:["a"]) }
        try state.dismiss(state.requests[0].id)
        XCTAssertNoThrow(try state.enqueue(MailWorkflowRequest(action:.status,accountIDs:["a"]),allowedAccountIDs:["a"]))
        XCTAssertEqual(state.requests.count,20)
    }
    func testVisibleActionEligibilityTracksLatestKnownVersionAfterDismissal() throws {
        var state=MailWorkflowState()
        var versions:[MailWorkflowItem]=[]
        for revision in [1,2] {
            var request=try MailWorkflowRequest(action:.drafts,accountIDs:["a"])
            let item=MailWorkflowItem(id:"draft",accountID:"a",sourceID:"source",revision:revision,kind:.draft,subject:"Test",summary:"Draft",checkedAt:Date())
            try request.accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Drafts",items:[item]))
            state.requests.append(request); versions.append(item)
        }
        XCTAssertFalse(state.isLatestKnownVersion(versions[0]))
        XCTAssertTrue(state.isLatestKnownVersion(versions[1]))
        try state.dismiss(state.requests[1].id)
        XCTAssertFalse(state.isLatestKnownVersion(versions[0]))
        XCTAssertTrue(state.isLatestKnownVersion(versions[1]))
        var invented=versions[1]; invented.accountID="other-account"
        XCTAssertFalse(state.isLatestKnownVersion(invented))
        invented=versions[1]; invented.sourceID="other-source"
        XCTAssertFalse(state.isLatestKnownVersion(invented))
    }
    func testConflictingSourceIdentityDisablesBothVersions() throws {
        var state=MailWorkflowState()
        for source in ["first","conflicting"] {
            var request=try MailWorkflowRequest(action:.drafts,accountIDs:["a"])
            let item=MailWorkflowItem(id:"draft",accountID:"a",sourceID:source,revision:1,kind:.draft,subject:"Test",summary:"Draft",checkedAt:Date())
            try request.accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Drafts",items:[item]))
            state.requests.append(request)
        }
        for item in state.requests.flatMap(\.observedItems) { XCTAssertFalse(state.isLatestKnownVersion(item)) }
    }
}
