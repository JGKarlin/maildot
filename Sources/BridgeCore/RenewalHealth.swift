import Foundation

/// Whether renewal is working, judged only from evidence this Mac holds: when Dot last made its connection
/// check, and whether every subscription is live. Dot's own statement that a job exists is not used.
public enum RenewalHealth:Equatable,Sendable {
    case working(lastCheck:Date)
    case lapsed(lastCheck:Date?)
    case notChecking(since:Date?)
    /// Dot's check runs every six hours, so twice that without one means a run was missed.
    public static let checkLimit:TimeInterval = 2 * DotHandlers.keepConnectedInterval

    public static func evaluate(lastStatusCheck:Date?,allSubscriptionsLive:Bool,now:Date = .now) -> RenewalHealth {
        guard let lastStatusCheck,now.timeIntervalSince(lastStatusCheck) <= checkLimit else { return .notChecking(since:lastStatusCheck) }
        return allSubscriptionsLive ? .working(lastCheck:lastStatusCheck) : .lapsed(lastCheck:lastStatusCheck)
    }
    public var isHealthy:Bool { if case .working = self { true } else { false } }
    public var summary:String {
        switch self {
        case .working(let lastCheck):
            "Working. Dot last checked at \(lastCheck.formatted(date:.omitted,time:.shortened))."
        case .lapsed(let lastCheck):
            "A connection has lapsed. Dot last checked \(lastCheck.map { "at " + $0.formatted(date:.omitted,time:.shortened) } ?? "at no recorded time") and should restore it at its next check."
        case .notChecking(let since):
            since.map { "Dot has not checked since \($0.formatted(date:.abbreviated,time:.shortened)). If this Mac was asleep, the next check is due within six hours." }
                ?? "Dot has not made a connection check yet."
        }
    }
}
