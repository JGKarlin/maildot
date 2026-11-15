import Foundation

/// Open in Reply (owner decision, 15 November 2026). A draft the owner asked for in the Mail Dot window opens in a
/// Mail reply as soon as it is ready, and Open in Reply puts the current draft in a new reply. The owner edits and
/// sends in Mail, so a send still takes their own press. Drafts Dot writes on its own never open a reply.
extension MailTriageState {
    /// Open in Reply: the draft now on this message goes into a new reply.
    public mutating func requestOpenReply(_ id:String,now:Date=Date()) throws {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { throw BridgeFailure("That message is no longer in Mail Dot's list.") }
        guard entries[index].outcome == .drafted,entries[index].draft?.isEmpty == false else { throw BridgeFailure("This message has no draft to open.") }
        guard entries[index].messageID != nil else { throw BridgeFailure("Mail Dot cannot find this message in Mail.") }
        entries[index].openReplyRequestedAt=now; entries[index].openReplyFailed=nil; entries[index].openReplyClosesWindow=true
    }
    /// The owner asked for a draft, or a new one, in the Mail Dot window: it opens in a reply once Dot has written it.
    public mutating func openReplyWhenDrafted(_ id:String) {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { return }
        entries[index].openReplyWhenDrafted=true; entries[index].openReplyFailed=nil
    }
    /// Turns each awaited draft that has arrived into a reply to open, and returns the next one to open, if any.
    public mutating func nextReplyToOpen(now:Date=Date()) -> MailTriageEntry? {
        for index in entries.indices where entries[index].openReplyWhenDrafted == true {
            switch entries[index].outcome {
            case .drafted where entries[index].draft?.isEmpty == false:
                entries[index].openReplyWhenDrafted=nil; entries[index].openReplyRequestedAt=now
            case .pending,.asked,.drafted:
                break
            default:
                // Dot asked a question, found no reply needed, or failed: nothing to open, and nothing waits.
                entries[index].openReplyWhenDrafted=nil
            }
        }
        for index in entries.indices where entries[index].openReplyRequestedAt != nil {
            guard entries[index].outcome == .drafted,entries[index].draft?.isEmpty == false,entries[index].messageID != nil else {
                noteReplyOpened(entries[index].id,failure:nil); continue
            }
            return entries[index]
        }
        return nil
    }
    /// The reply was opened with the draft in it, or could not be: the request ends either way.
    public mutating func noteReplyOpened(_ id:String,failure:String?) {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { return }
        entries[index].openReplyRequestedAt=nil; entries[index].openReplyFailed=failure; entries[index].openReplyClosesWindow=nil
        // The draft came first; now Dot updates the report, in its own request.
        if entries[index].reportAfterReply == true {
            entries[index].reportAfterReply=nil
            if entries[index].reportRequestedAt == nil { entries[index].reportRequestedAt=Date(); entries[index].reportRequestID=nil; entries[index].reportFailed=nil }
        }
    }
}
