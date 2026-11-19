import XCTest
@testable import BridgeCore

/// The place in Dot's queue the pane and the banner show while a message is being checked (owner request, 19 November 2026).
final class DotQueuePlaceTests: XCTestCase {
    private func entry(_ id: String, received: Date) -> MailTriageEntry {
        MailTriageEntry(messageID: "\(id)@example.invalid", sender: "\(id)@example.invalid", senderName: nil, subject: id, receivedAt: received,
                        verdict: MailTriage.Verdict(essential: true, reason: "r"), automatic: true)
    }
    private func request(_ at: Date, chained: Bool) throws -> MailWorkflowRequest {
        var request = try MailWorkflowRequest(action: .draftCheck, accountIDs: ["gmail:profile"], triageID: UUID().uuidString, createdAt: at)
        if chained { request.chained = true }
        return request
    }

    /// A batch of three handed to Dot, two more waiting in Mail Dot's queue: the first is being read, the others count
    /// the requests before them, and those not yet handed over start behind the whole batch.
    func testEachMessageCountsTheRequestsBeforeIt() throws {
        let now = Date()
        var triage = MailTriageState(), workflow = MailWorkflowState()
        let batch = (0..<3).map { entry("b\($0)", received: now.addingTimeInterval(Double(-$0))) }
        let later = (0..<2).map { entry("w\($0)", received: now.addingTimeInterval(Double(-100 - $0))) }
        (batch + later).forEach { triage.record($0) }
        for (index, one) in batch.enumerated() {
            let made = try request(now.addingTimeInterval(Double(index)), chained: index > 0)
            workflow.requests.append(made)
            triage.markAsked(one.id, requestID: made.id, now: now)
        }
        workflow.markRead(workflow.requests[0].id, now: now.addingTimeInterval(5))
        let at = now.addingTimeInterval(10)
        func place(_ one: MailTriageEntry) -> DotQueuePlace? {
            DotQueuePlace.of(triage.entries.first { $0.id == one.id }!, triage: triage, workflow: workflow, now: at)
        }
        XCTAssertEqual(place(batch[0]), .reading)
        XCTAssertEqual(place(batch[1]), .inBatch(ahead: 1))
        XCTAssertEqual(place(batch[2]), .inBatch(ahead: 2))
        XCTAssertEqual(place(later[0]), .waiting(ahead: 3), "behind the whole batch")
        XCTAssertEqual(place(later[1]), .waiting(ahead: 4))
        XCTAssertNil(place(batch[0])?.ahead, "a message being read shows no count")
        XCTAssertNil(DotQueuePlace.waiting(ahead: 0).ahead, "nor one with nothing before it")
    }

    /// A message Dot has finished is no longer waiting, and the ones behind it move up.
    func testTheQueueMovesUpWhenAMessageIsDone() throws {
        let now = Date()
        var triage = MailTriageState(), workflow = MailWorkflowState()
        let a = entry("a", received: now), b = entry("b", received: now.addingTimeInterval(-1))
        triage.record(a); triage.record(b)
        let first = try request(now, chained: false), second = try request(now.addingTimeInterval(1), chained: true)
        workflow.requests = [first, second]
        triage.markAsked(a.id, requestID: first.id, now: now); triage.markAsked(b.id, requestID: second.id, now: now)
        XCTAssertEqual(DotQueuePlace.of(triage.entries.first { $0.id == b.id }!, triage: triage, workflow: workflow, now: now), .inBatch(ahead: 1))
        workflow.requests.removeAll { $0.id == first.id }
        triage.accept(requestID: first.id, stage: .ready, summary: "No reply needed.")
        XCTAssertEqual(DotQueuePlace.of(triage.entries.first { $0.id == b.id }!, triage: triage, workflow: workflow, now: now), .inBatch(ahead: 0))
        XCTAssertNil(DotQueuePlace.of(triage.entries.first { $0.id == a.id }!, triage: triage, workflow: workflow, now: now), "a finished message has no place")
    }
}
