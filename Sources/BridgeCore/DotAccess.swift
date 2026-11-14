import Foundation

/// Whether Dot answers on this Mac (owner request, 14 November 2026). Mail Dot works only with a ChatGPT plan that
/// includes Dot, and OpenAI tells an app nothing about a person's plan, so the test is whether Dot actually
/// answers. Until it has, Mail Dot sends Dot nothing on its own, its banners say so plainly, and Settings offers
/// Check Again. The check never locks anyone out (owner requirement, 14 November 2026): the owner's own requests
/// (Draft a Reply, Ask Dot, Ask Dot for a Report) always go to Dot, and any answer to them activates Mail Dot;
/// once Dot has answered on this Mac, Mail Dot never goes inactive again. A run of unanswered requests (a
/// network failure, a Mac asleep, or a plan that changed) only shows a notice with Check Again.
public struct DotAccess:Codable,Sendable,Equatable {
    /// When Dot first answered on this Mac.
    public var confirmedAt:Date?
    public var lastAnsweredAt:Date?
    /// Requests in a row that Dot left unanswered past the answer limit.
    public var unanswered=0
    /// The owner pressed Check Again, or Mail Dot is checking on its own; the check request sent, if it was.
    public var checkRequestedAt:Date?
    public var checkRequestID:String?
    public var lastCheckAt:Date?
    public init() {}
    /// After this many unanswered requests in a row Mail Dot treats Dot as unreachable.
    public static let silenceLimit=3
    /// How often Mail Dot checks on its own while Dot has not answered.
    public static let recheckEvery:TimeInterval=30*60
    /// Dot has answered on this Mac at least once. Silence never takes this back.
    public var active:Bool { confirmedAt != nil }
    /// Dot has answered before but left several requests in a row unanswered: a notice, nothing stops.
    public var quiet:Bool { confirmedAt != nil && unanswered >= Self.silenceLimit }
    public var checking:Bool { checkRequestedAt != nil }
}

extension MailSettings {
    /// Dot's access, with setups that already had Dot answering counted as confirmed (their hourly
    /// keep-connected job was confirmed by Dot).
    public var effectiveDotAccess:DotAccess {
        if let dotAccess { return dotAccess }
        var assumed=DotAccess()
        if let confirmed=keepConnectedConfirmedAt { assumed.confirmedAt=confirmed; assumed.lastAnsweredAt=confirmed }
        return assumed
    }
    public var dotActive:Bool { effectiveDotAccess.active }
    /// Dot answered a request: Mail Dot is active, and any silence is forgotten.
    public mutating func noteDotAnswered(now:Date=Date()) {
        var access=effectiveDotAccess
        access.confirmedAt=access.confirmedAt ?? now; access.lastAnsweredAt=now; access.unanswered=0
        access.checkRequestedAt=nil; access.checkRequestID=nil
        dotAccess=access
    }
    /// A request Dot left unanswered past the answer limit.
    public mutating func noteDotSilent(_ count:Int=1) {
        guard count > 0 else { return }
        var access=effectiveDotAccess
        access.unanswered += count
        dotAccess=access
    }
    /// Check Again, or Mail Dot's own check: a light request goes to Dot.
    public mutating func requestDotCheck(now:Date=Date()) {
        var access=effectiveDotAccess
        guard access.checkRequestedAt == nil else { return }
        access.checkRequestedAt=now; access.checkRequestID=nil
        dotAccess=access
    }
    /// Whether Mail Dot should check on its own now: Dot is not active, no check is waiting, and the last
    /// was long enough ago.
    public func dotCheckDue(now:Date=Date()) -> Bool {
        let access=effectiveDotAccess
        guard !access.active,access.checkRequestedAt == nil else { return false }
        return now.timeIntervalSince(access.lastCheckAt ?? .distantPast) >= DotAccess.recheckEvery
    }
    public mutating func markDotCheckSent(requestID:String,now:Date=Date()) {
        var access=effectiveDotAccess
        access.checkRequestID=requestID; access.lastCheckAt=now
        dotAccess=access
    }
    /// A check Dot did not answer within the answer limit counts as silence, and can be tried again.
    @discardableResult public mutating func expireDotCheck(now:Date=Date()) -> Bool {
        var access=effectiveDotAccess
        guard access.checkRequestID != nil,let asked=access.lastCheckAt,now.timeIntervalSince(asked) > MailTriageState.answerLimit else { return false }
        access.checkRequestID=nil; access.checkRequestedAt=nil
        if access.confirmedAt != nil { access.unanswered += 1 }
        dotAccess=access
        return true
    }
}

public enum DotAccessInstructions {
    public static let text="For action check, Mail Dot is confirming that you can answer for the owner on this Mac. Do nothing else: read no mail and change nothing. Report ready with summary set to Ready."
}
