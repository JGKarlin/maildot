import XCTest
@testable import BridgeCore

/// A request the owner made themselves goes before automatic ones (owner report, 17 November 2026).
final class OwnerFirstTests: XCTestCase {
    func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maildot-owner-first-"+UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
    func linked(_ root:URL) throws -> [MailWorkflowAccount] {
        try MailSettingsStore(bridgeDirectory:root).transaction {
            var profile = MailConnection(id:"profile", email:"owner@example.invalid", connectionID:"link")
            profile.observedAt = Date(); $0.connections = [profile]
        }
        return try MailWorkflowAccount.available(settings:MailSettingsStore(bridgeDirectory:root).read(), native:NativeMailState())
    }

    func testOnlyAnUnstartedRecentOwnerRequestCounts() throws {
        var state = MailWorkflowState()
        let ids:Set<String> = ["gmail:profile"]
        let automatic = try MailWorkflowRequest(action:.draftCheck, accountIDs:["gmail:profile"], triageID:UUID().uuidString)
        try state.enqueue(automatic, allowedAccountIDs:ids)
        XCTAssertTrue(state.ownerRequestsWaiting().isEmpty, "an automatic draft check is not the owner's")
        let owner = try MailWorkflowRequest(action:.status, accountIDs:["gmail:profile"])
        try state.enqueue(owner, allowedAccountIDs:ids)
        XCTAssertEqual(state.ownerRequestsWaiting().map(\.id), [owner.id])
        XCTAssertTrue(state.ownerRequestsWaiting(now:Date().addingTimeInterval(MailWorkflowRequest.ownerPriorityWindow + 1)).isEmpty,
                      "a request nobody started holds automatic ones back for fifteen minutes at most")
        XCTAssertTrue(state.take(owner.id, worker:"dot"))
        XCTAssertTrue(state.ownerRequestsWaiting().isEmpty, "once Dot has started it, automatic requests may follow")
    }

    func testABackgroundRequestDotOpensNamesTheOwnersWaitingRequest() throws {
        let root = root(), available = try linked(root)
        let ids = Set(available.map(\.id))
        let automatic = try MailWorkflowRequest(action:.draftCheck, accountIDs:Array(ids), triageID:UUID().uuidString)
        let owner = try MailWorkflowRequest(action:.status, accountIDs:Array(ids))
        try MailWorkflowStore(bridgeDirectory:root).transaction { try $0.enqueue(automatic, allowedAccountIDs:ids); try $0.enqueue(owner, allowedAccountIDs:ids) }
        let background = try MailWorkflowTools.call("get_mail_workflow", arguments:["request_id":.string(automatic.id)], bridgeDirectory:root)
        XCTAssertEqual(background["owner_requests_waiting"].array?.compactMap(\.string), [owner.id])
        XCTAssertNotNil(background["owner_first_instruction"].string)
        let own = try MailWorkflowTools.call("get_mail_workflow", arguments:["request_id":.string(owner.id)], bridgeDirectory:root)
        XCTAssertEqual(own["owner_requests_waiting"], .null, "the owner's own request is not told to wait for itself")
    }

    /// The panel shows how many requests are ahead of the owner's while ChatGPT starts Dot.
    func testTheReplyPanelCountsTheUnfinishedRequestsMadeBeforeTheOwnersReply() throws {
        var state = MailWorkflowState()
        let ids:Set<String> = ["gmail:profile"]
        let start = Date()
        let working = try MailWorkflowRequest(action:.draftCheck, accountIDs:["gmail:profile"], triageID:UUID().uuidString, createdAt:start.addingTimeInterval(-120))
        let queued = try MailWorkflowRequest(action:.draftCheck, accountIDs:["gmail:profile"], triageID:UUID().uuidString, createdAt:start.addingTimeInterval(-60))
        let stale = try MailWorkflowRequest(action:.draftCheck, accountIDs:["gmail:profile"], triageID:UUID().uuidString, createdAt:start.addingTimeInterval(-3600))
        for request in [stale,working,queued] { try state.enqueue(request, allowedAccountIDs:ids) }
        XCTAssertTrue(state.take(working.id, worker:"dot", now:start))
        let context = UUID().uuidString
        _ = try state.requestReply(accountIDs:["gmail:profile"], allowedAccountIDs:ids, contextID:context, now:start)
        XCTAssertEqual(state.replyProgress(contextID:context, now:start)?.ahead, 2, "the one Dot is on and the one queued, not the stale one")
        let later = try MailWorkflowRequest(action:.draftCheck, accountIDs:["gmail:profile"], triageID:UUID().uuidString, createdAt:start.addingTimeInterval(30))
        try state.enqueue(later, allowedAccountIDs:ids)
        XCTAssertEqual(state.replyProgress(contextID:context, now:start)?.ahead, 2, "a request made after the reply is not ahead of it")
    }
}
