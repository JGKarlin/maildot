import Foundation

/// What Mail Dot needs in place to work with Dot, as its background app last found it (owner approval of the
/// Connection mock-ups, 14 November 2026). The background app checks every few seconds and saves this for Settings,
/// the Mail Dot window and the banner to show; a button pressed in Settings is left here for it to act on.
public struct ConnectionState: Codable, Sendable, Equatable {
    public enum MailAccess: String, Codable, Sendable { case unknown, allowed, notAllowed }
    public enum ChatGPT: String, Codable, Sendable { case open, closed, notInstalled }
    public enum Request: String, Codable, Sendable { case allowMail, openAccessibility, openChatGPT, askDotToListen, openFullDiskAccess, openSetup }

    /// Whether macOS lets Mail Dot work with Mail. Unknown until Mail has been open once since Mail Dot started.
    public var mail = MailAccess.unknown
    public var accessibility = false
    public var chatGPT = ChatGPT.closed
    /// Dot in the cloud can be told of requests through the tunnel, where one is set up.
    public var tunnelConnected = false
    /// With search by meaning on: whether macOS lets Mail Dot read the Mail folder. Absent while the option is off,
    /// when Mail Dot does not look.
    public var fullDiskAccess: Bool?
    /// Whether setup is complete on this Mac: Mail Dot has its connection and Dot has answered setup's tests. Until it
    /// is, nothing can reach Dot, and the Connection tab says so with a button that opens setup (second-account test,
    /// 18 November 2026: the tab said "Asking Dot…" for a check that could not arrive). Absent from older records.
    public var setUp: Bool?
    /// While setup is not complete: whether Dot is at work on it now, or it has stopped (no report for a while, or
    /// Dot reported what stops it). Absent when setup has not started or is complete.
    public enum SetupProgress: String, Codable, Sendable { case working, stopped }
    public var setupProgress: SetupProgress?
    /// When Mail Dot last asked Dot to listen, and how many times since a listener was last present.
    public var askedToListenAt: Date?
    public var asks = 0
    /// The button the owner pressed in Settings, until the background app has acted on it.
    public var request: Request?
    public init() {}

    /// Mail Dot may type its request to Dot into the ChatGPT app: the first three lines are in place.
    public var canReachDot: Bool { mail == .allowed && accessibility && chatGPT == .open }
    /// Dot was asked to listen moments ago and has not started yet.
    public func asking(now: Date = Date()) -> Bool { askedToListenAt.map { now.timeIntervalSince($0) < 120 } ?? false }
    /// The same findings, whatever was asked or pressed: what decides whether to save again.
    public func sameFindings(as other: ConnectionState) -> Bool {
        mail == other.mail && accessibility == other.accessibility && chatGPT == other.chatGPT && tunnelConnected == other.tunnelConnected && fullDiskAccess == other.fullDiskAccess && setUp == other.setUp && setupProgress == other.setupProgress
    }
}

/// Whether Dot can take Mail Dot's requests now, and if not, the one reason shown (owner approval, 14 November
/// 2026: one state on the banner and one line in the Mail Dot window, nothing else).
public enum DotAvailability: Equatable, Sendable {
    case available
    /// Mail Dot's connection to Dot is not up, so Dot cannot be told of anything.
    case notConnected
    /// Dot answered before and has left several requests in a row unanswered.
    case silent(since: Date?)
    /// Dot has never answered on this Mac.
    case notYetAnswered

    /// `listening`: a worker on this Mac is taking requests. With no findings saved yet (an earlier build's state),
    /// only Dot's own record of answering is judged, as before.
    public init(access: DotAccess, connection: ConnectionState?, listening: Bool) {
        if listening { self = .available; return }
        // Mail Dot's connection to Dot is down. Whether ChatGPT is open is not the reason: Dot works in the cloud.
        if let connection, !connection.tunnelConnected { self = .notConnected; return }
        if !access.active { self = .notYetAnswered }
        else if access.quiet { self = .silent(since: access.lastAnsweredAt) }
        else { self = .available }
    }
    public var isAvailable: Bool { self == .available }
}

extension MailWorkflowState {
    /// The latest moment the listener on this Mac took a request or reported on one it holds. Dot in the cloud
    /// takes requests too, and that says nothing about a listener here.
    public var lastClaimAt: Date? { requests.compactMap { $0.claim }.filter { $0.worker == listenerWorker }.map(\.at).max() }
    /// A worker on this Mac is taking Mail Dot's requests: it asked for work, or reported on some, in the last minutes.
    public func workerListening(now: Date = Date()) -> Bool {
        var input = ListenerWatch.Input()
        input.now = now; input.listenerSeenAt = listenerSeenAt; input.lastClaimAt = lastClaimAt
        return ListenerWatch.listening(input)
    }
    /// The oldest request no worker holds and none has answered, by when it was made; calls with Dot are not counted.
    public func oldestWaiting(now: Date = Date()) -> Date? {
        requests.filter { $0.stage == .pending && !$0.opensCall && !$0.hasActiveClaim(now: now) }.map(\.createdAt).min()
    }
}

/// What Mail Dot writes to Dot in the ChatGPT app to have it listen on this Mac. In English whatever the interface
/// language: it is an instruction to the assistant, not text the owner reads in Mail Dot.
public enum ListenRequest {
    public static let text = "Mail Dot on this Mac asks you to listen for its requests. Start a task on this computer and, in it, call the maildot tool wait_for_work. Each time it returns work, handle every request it lists with get_mail_workflow and report_mail_workflow, exactly as that request's own instructions say, then call wait_for_work again. Keep doing this until I tell you to stop. Send nothing and change nothing in Mail beyond what a request's instructions allow. If you cannot reach the maildot tools on this computer, say so in one line and stop."
}
