import XCTest
@testable import BridgeCore

final class AbandonedRequestTests:XCTestCase {
    func testUnfinishedDraftRequestsNeverBlockNewOnes() throws {
        var state=MailWorkflowState()
        let old=Date().addingTimeInterval(-3600)
        // As saved by builds that never dropped them: 20 requests Dot never finished, an hour old.
        state.requests=try (0..<MailWorkflowState.limit).map { _ in try MailWorkflowRequest(action:.draftCheck,accountIDs:["mail:a"],triageID:UUID().uuidString,createdAt:old) }
        XCTAssertEqual(state.requests.count,MailWorkflowState.limit)
        let fresh=UUID().uuidString
        XCTAssertNoThrow(try state.enqueue(MailWorkflowRequest(action:.draftCheck,accountIDs:["mail:a"],triageID:fresh),allowedAccountIDs:["mail:a"]),
                         "requests Dot left unfinished for half an hour are dropped, so a new message is still offered")
        XCTAssertEqual(state.requests.map(\.triageID),[fresh])
    }
    func testRecentUnfinishedRequestsAreKept() throws {
        var state=MailWorkflowState()
        try state.enqueue(MailWorkflowRequest(action:.draftCheck,accountIDs:["mail:a"],triageID:UUID().uuidString),allowedAccountIDs:["mail:a"])
        try state.enqueue(MailWorkflowRequest(action:.draftCheck,accountIDs:["mail:a"],triageID:UUID().uuidString),allowedAccountIDs:["mail:a"])
        XCTAssertEqual(state.requests.count,2)
    }
}
