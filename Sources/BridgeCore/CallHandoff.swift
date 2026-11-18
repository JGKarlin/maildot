import Foundation

/// Gives Dot a moment to read the request a call is about before the call opens (owner's report, 18 November 2026).
///
/// Mail Dot leaves the reason for a call with Dot in writing and then opens the call. It used to wait a fixed three
/// seconds between the two, knowing nothing of whether Dot had read the request; for request B039210B Dot's written
/// side took 43 seconds, so the voice greeted the owner without it. ChatGPT offers no way to hand a call its context
/// when it is opened, and the voice gives no sign that it has loaded any. The one acknowledgment Mail Dot can see is
/// Dot's own call to get_mail_workflow naming the request, which Mail Dot records.
///
/// The owner chose not to be kept waiting for that read (18 November 2026): Dot usually needs longer, so Dot is to
/// say that it has the request and ask the owner to hold on while it looks into it (see DotCallPrompt). In the
/// owner's trial the voice did so only when the message was sent into the open call, so that is the order used.
/// The hold below serves the earlier order, message first, kept for a test on a Mac (`messageFirstKey`): it ends on
/// Dot's read or on its limit, never on a fixed delay, and what happened is logged with the request's identifier.
public enum CallHandoff {
    /// How long the call is held, at most, for Dot to read the request.
    public static let limit: TimeInterval = 10
    /// The hold on this Mac: `limit`, unless another number of seconds (0 to 60) was set for a test of the handoff.
    public static func limit(set seconds: Double?) -> TimeInterval {
        guard let seconds, seconds >= 0, seconds <= 60 else { return limit }
        return seconds
    }
    public static let limitKey = "CallHandoffSeconds"
    /// Set on a Mac to try the earlier order, the message first and then the call after the hold. The call opens
    /// first and the message goes into it otherwise (owner's trial, 18 November 2026).
    public static let messageFirstKey = "CallPromptBeforeLaunch"

    public enum Result: Equatable, Sendable {
        /// Dot read the request this many seconds after the wait began.
        case read(after: TimeInterval)
        /// The limit passed without Dot reading it.
        case unread
    }

    /// Whether Dot has read this exact request since it was made. A read of another request, a read from before the
    /// request existed, and a refused read do not count.
    public static func acknowledged(_ request: MailWorkflowRequest, records: [ToolCallRecord]) -> Bool {
        records.contains { $0.tool == "get_mail_workflow" && $0.outcome == .ok && $0.request == request.id && $0.at >= request.createdAt }
    }

    /// Waits until Dot has read every one of these requests, or the limit has passed. `records` gives Mail Dot's
    /// record of Dot's calls as it stands, `clock` the time, and `pause` waits a moment between looks. The wait ends
    /// on the condition, never on a fixed delay.
    public static func wait(for requests: [MailWorkflowRequest], limit: TimeInterval = limit, isolation: isolated (any Actor)? = #isolation,
                            clock: () -> Date = { Date() }, records: () -> [ToolCallRecord], pause: () async -> Void) async -> [String: Result] {
        var results: [String: Result] = [:]
        let began = clock()
        while true {
            let seen = records(), elapsed = clock().timeIntervalSince(began)
            for request in requests where results[request.id] == nil && acknowledged(request, records: seen) {
                results[request.id] = .read(after: max(0, elapsed))
            }
            if results.count == requests.count { return results }
            if elapsed >= limit {
                for request in requests where results[request.id] == nil { results[request.id] = .unread }
                return results
            }
            await pause()
        }
    }
}
