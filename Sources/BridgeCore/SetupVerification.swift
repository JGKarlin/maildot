import Foundation

/// How setup proves itself (owner's approval, 17 November 2026). Dot's report that it is done is a claim; setup ends
/// only when Mail Dot has seen, on this Mac, an answer from Dot's handler for each event. Both tests use requests
/// Mail Dot already knows: a check through mail.workflow_requested (Dot reports Ready and reads nothing), and the
/// Keep connected request through mail.settings_requested, which also has Dot create or correct its task.
public enum SetupVerification {
    /// Dot's handler for drafting requests answered since `since` (any time, when setup was never asked).
    public static func draftingAnswered(_ settings: MailSettings, since: Date?) -> Bool {
        guard let answered = settings.effectiveDotAccess.lastAnsweredAt else { return false }
        return answered >= (since ?? .distantPast)
    }
    /// Dot's handler for settings requests answered a Keep connected request made for this setup. A request made
    /// up to its answer limit before setup was asked counts too: on a fresh Mac it waited for the subscription.
    public static func settingsAnswered(_ settings: MailSettings, since: Date?) -> Bool {
        let from = (since ?? .distantPast).addingTimeInterval(-MailSettingsCoordinator.keepConnectedAnswerLimit)
        return settings.requests.contains { $0.kind == .keepConnected && $0.createdAt >= from && answeredByDot($0) }
    }
    /// Both tests are answered: setup has proved itself, and only then is the owner's press forgotten. Forgetting it
    /// earlier (when Dot reported done, or the first subscription arrived) turned the open setup window back to
    /// "Ask Dot to Connect" while the tests were still out (installer review, 18 November 2026).
    public static func verified(_ settings: MailSettings, since: Date?) -> Bool {
        draftingAnswered(settings, since: since) && settingsAnswered(settings, since: since)
    }
    /// Confirmed, or refused by Dot in its own report. A request closed because Dot never answered is not an answer.
    static func answeredByDot(_ request: MailSettingsRequest) -> Bool {
        request.status == .confirmed || (request.status == .failed && request.resultCode != nil && request.resultCode != "noAnswer")
    }
    /// Asks for whichever test is still owed, unless one is already waiting. Returns whether anything was asked.
    @discardableResult public static func requestTests(settings: inout MailSettings, since: Date?, now: Date = .now) throws -> Bool {
        var asked = false
        if !draftingAnswered(settings, since: since), settings.effectiveDotAccess.checkRequestedAt == nil {
            settings.requestDotCheck(now: now); asked = true
        }
        if !settingsAnswered(settings, since: since),
           !settings.requests.contains(where: { $0.kind == .keepConnected && ![.confirmed, .failed].contains($0.status) }) {
            try MailSettingsCoordinator.request(.keepConnected, instruction: MailSettingsCoordinator.keepConnectedInstruction, settings: &settings)
            asked = true
        }
        return asked
    }
}
