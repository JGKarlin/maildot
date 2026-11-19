import Foundation

/// Where a message Dot is checking stands in Dot's queue, for the pane and the banner (owner request, 19 November
/// 2026: the pane said only "Dot is checking this message…", with no place, although the reply panel has shown one
/// since 17 November). Display only: the order Dot gets messages in, the batch and the hourly limit are unchanged.
public enum DotQueuePlace: Equatable, Sendable {
    /// Still in Mail Dot's own queue, not yet handed to Dot; `ahead` counts every request that goes before it,
    /// those Dot already has included.
    case waiting(ahead: Int)
    /// Handed to Dot in a batch, waiting its turn behind `ahead` others.
    case inBatch(ahead: Int)
    /// Dot has taken it and is reading it.
    case reading

    /// The number of requests before this message, when it has to wait for any.
    public var ahead: Int? {
        switch self {
        case .waiting(let ahead), .inBatch(let ahead): ahead > 0 ? ahead : nil
        case .reading: nil
        }
    }

    /// The place of one entry, from Mail Dot's two records: the queue of arriving mail and the requests Dot has.
    /// Nil when the entry is not waiting on Dot, or its request is no longer known.
    public static func of(_ entry: MailTriageEntry, triage: MailTriageState, workflow: MailWorkflowState, now: Date = Date()) -> DotQueuePlace? {
        switch entry.outcome {
        case .pending where entry.requestID == nil:
            guard let index = triage.queueForDot().firstIndex(where: { $0.id == entry.id }) else { return nil }
            return .waiting(ahead: workflow.liveRequestCount(now: now) + index)
        case .pending, .asked:
            guard let id = entry.requestID, let request = workflow.requests.first(where: { $0.id == id }) else { return nil }
            if [.ready, .failed, .awaitingInput].contains(request.stage) { return nil }
            if request.stage == .working || request.hasActiveClaim(now: now) || request.event.reviewedAt != nil { return .reading }
            return .inBatch(ahead: workflow.requestsAhead(of: id, now: now))
        default:
            return nil
        }
    }
}
