import Foundation
import Carbon
import BridgeCore

/// Puts the flag of a message's Mail Dot state on it, or takes Mail Dot's flag off, through Mail's own
/// scripting, and reports whether the owner has replied to it. A flag the owner set themselves is never
/// changed: Mail Dot touches a message's flag only while it is unflagged or carries the flag Mail Dot put
/// there. The message is found by its Message-ID in the inbox; values are passed as Apple-event
/// parameters, never written into the script.
public enum MailListMarker {
    public struct Result:Sendable {
        public let found:Bool
        public let replied:Bool
        /// The flag now on the message as Mail Dot left it (-1 for none), or nil if it did not touch it.
        public let applied:Int?
        public let ownerFlagged:Bool
    }

    private static let source = #"""
        on flagmessage(targetID, wantedIndex, previousIndex)
            with timeout of 15 seconds
                tell application "Mail"
                    set found to (messages of inbox whose message id is targetID)
                    if (count of found) is 0 then return "missing"
                    set m to item 1 of found
                    set wasReplied to was replied to of m
                    if wasReplied then set wantedIndex to -1
                    set current to -1
                    if flagged status of m then set current to flag index of m
                    if wantedIndex is -2 then
                        if wasReplied then return "look|replied"
                        return "look|open"
                    end if
                    if current is not -1 and current is not previousIndex then
                        if wasReplied then return "owner|replied"
                        return "owner|open"
                    end if
                    if wantedIndex is -1 then
                        if current is not -1 then set flagged status of m to false
                    else if current is not wantedIndex then
                        set flag index of m to wantedIndex
                    end if
                    if wasReplied then return "done|replied|" & (wantedIndex as string)
                    return "done|open|" & (wantedIndex as string)
                end tell
            end timeout
        end flagmessage
        """#

    /// `wanted` and `previous` are Mail's flag indexes, -1 for no flag; `previous` is the flag Mail Dot put
    /// on the message before, if any. `wanted` -2 only looks: nothing about the message is changed.
    @MainActor public static func flag(messageID:String,wanted:Int,previous:Int?) throws -> Result {
        // Flags are not used for Mail Dot's states (the owner's decision of 12 November 2026); only `-2`, a look.
        let event=NSAppleEventDescriptor(eventClass:AEEventClass(kASAppleScriptSuite),eventID:AEEventID(kASSubroutineEvent),
                                         targetDescriptor:nil,returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        event.setParam(.init(string:"flagmessage"),forKeyword:AEKeyword(keyASSubroutineName))
        let parameters=NSAppleEventDescriptor.list()
        parameters.insert(.init(string:messageID),at:1)
        parameters.insert(.init(int32:Int32(wanted)),at:2)
        parameters.insert(.init(int32:Int32(previous ?? -1)),at:3)
        event.setParam(parameters,forKeyword:AEKeyword(keyDirectObject))
        let answer=try MailScriptHost.shared.call(source:source,event:event,failure:"Mail Dot could not flag the message in Mail. Check Automation permissions for Mail Dot.").stringValue ?? ""
        let parts=answer.split(separator:"|").map(String.init)
        guard parts.first != "missing" else { return Result(found:false,replied:false,applied:nil,ownerFlagged:false) }
        let replied=parts.count > 1 && parts[1] == "replied"
        if parts.first == "owner" { return Result(found:true,replied:replied,applied:nil,ownerFlagged:true) }
        if parts.first == "look" { return Result(found:true,replied:replied,applied:nil,ownerFlagged:false) }
        return Result(found:true,replied:replied,applied:parts.count > 2 ? Int(parts[2]) : nil,ownerFlagged:false)
    }
}
