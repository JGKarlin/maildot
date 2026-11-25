import Foundation

/// The messages Mail has most recently shown, as the extension sees them: Mail asks it about each message it displays.
/// Mail lets Mail Dot ask only for every shown message to be redrawn, never one, so Mail Dot asks only when the banner of
/// one of these would change; work on any other message redraws nothing (owner report, 24 November 2026: open messages
/// flickered while Dot worked through other mail).
public enum ShownMessages {
    public static let keep=12
    private static let lock=NSLock()
    nonisolated(unsafe) private static var lastNoted:String?

    private static func file(_ directory:URL) -> URL { directory.appendingPathComponent("shown-messages.json") }

    /// Notes that Mail showed this message. Written only when the most recent one changes, since Mail asks about the same
    /// message many times.
    public static func note(messageID raw:String?,bridgeDirectory directory:URL) {
        guard let raw,let id=MailMessageIdentity.normalized(raw) else { return }
        lock.lock(); defer { lock.unlock() }
        guard lastNoted != id else { return }
        lastNoted=id
        var ids=read(bridgeDirectory:directory).filter{ $0 != id }
        ids.insert(id,at:0)
        if let data=try? JSONEncoder().encode(Array(ids.prefix(keep))) { try? data.write(to:file(directory),options:.atomic) }
    }
    /// The messages most recently shown, the latest first.
    public static func read(bridgeDirectory directory:URL) -> [String] {
        guard let data=try? Data(contentsOf:file(directory)),let ids=try? JSONDecoder().decode([String].self,from:data) else { return [] }
        return ids
    }
}

/// What the banner of each message Mail has shown last said, kept to tell a real change of a shown banner from a message
/// that has only come into view. Mail shows the messages of a long conversation a few at a time, so the list of shown
/// messages turns over at each redraw; counting a message new to the list as a change asked Mail to redraw again, which
/// brought other messages into the list, every ten seconds without end (owner report, 25 November 2026: the messages of
/// a conversation kept blanking and loading).
public struct ShownBannerTexts:Sendable,Equatable {
    private var known:[String:String]=[:]
    /// The most messages remembered; beyond it the oldest knowledge is let go, and those messages count as new.
    public static let limit=500
    public init() {}
    /// Records what the shown messages' banners say now, and answers whether any of them says something other than it
    /// said when last seen. A message seen for the first time is no change: Mail drew its banner as it showed it.
    public mutating func changed(_ texts:[String:String]) -> Bool {
        var changed=false
        for (id,text) in texts {
            if let before=known[id],before != text { changed=true }
            known[id]=text
        }
        if known.count > Self.limit { known=texts }
        return changed
    }
}

extension MailDotBanner {
    /// What the banner of a message Mail Dot recorded says now, as the extension draws it: its state, as shown while Dot
    /// is or is not available, with its place in Dot's queue. Nil when the message has no banner.
    public static func text(for entry:MailTriageEntry,triage:MailTriageState,workflow:MailWorkflowState,availability:DotAvailability) -> String? {
        guard let state=MailDotBanner(entry) else { return nil }
        return state.shown(availability).title(place:DotQueuePlace.of(entry,triage:triage,workflow:workflow))
    }
}
