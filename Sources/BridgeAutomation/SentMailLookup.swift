import Foundation
import Carbon
import BridgeCore

/// The opening of the owner's most recent message to one person, found in Mail's Sent mailbox on the Mac.
/// NOT USED: on the owner's Mac Mail took over 40 seconds to count the unified Sent mailbox through scripting
/// (12 November 2026), far too slow to run while Dot starts. Kept for a faster source of the same text.
/// It settles how the owner greets and writes to that person (salutation, register, language) without Dot
/// having to search for it. Only the newest few hundred sent messages are looked at, and only the first
/// lines of the one found are kept. Values pass as Apple-event parameters, never written into the script.
public enum SentMailLookup {
    public struct Opening:Sendable {
        public let sentAt:Date?
        public let text:String
    }
    private static let source = #"""
        on lastopening(targetAddress, scanCount)
            with timeout of 25 seconds
                tell application "Mail"
                    set box to sent mailbox
                    set total to count of messages of box
                    if total is 0 then return ""
                    if scanCount > total then set scanCount to total
                    set recipientLists to address of to recipients of (messages 1 thru scanCount of box)
                    set sentDates to date sent of (messages 1 thru scanCount of box)
                    set bestIndex to 0
                    set bestDate to missing value
                    repeat with i from 1 to scanCount
                        set found to false
                        repeat with a in (item i of recipientLists)
                            if (a as string) is targetAddress then set found to true
                        end repeat
                        if found then
                            set d to item i of sentDates
                            if bestDate is missing value or d > bestDate then
                                set bestDate to d
                                set bestIndex to i
                            end if
                        end if
                    end repeat
                    if bestIndex is 0 then return ""
                    set body to content of message bestIndex of box
                    if (length of body) > 900 then set body to text 1 thru 900 of body
                    set secondsAgo to ((current date) - bestDate) as integer
                    return (secondsAgo as string) & "|" & body
                end tell
            end timeout
        end lastopening
        """#

    /// Nil when there is no sent message to this address among the newest `scan`, or Mail is closed.
    @MainActor public static func latestOpening(to address:String,scan:Int=300) throws -> Opening? {
        let target=address.lowercased().trimmingCharacters(in:.whitespaces)
        guard !target.isEmpty else { return nil }
        let event=NSAppleEventDescriptor(eventClass:AEEventClass(kASAppleScriptSuite),eventID:AEEventID(kASSubroutineEvent),
                                         targetDescriptor:nil,returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        event.setParam(.init(string:"lastopening"),forKeyword:AEKeyword(keyASSubroutineName))
        let parameters=NSAppleEventDescriptor.list()
        parameters.insert(.init(string:target),at:1)
        parameters.insert(.init(int32:Int32(scan)),at:2)
        event.setParam(parameters,forKeyword:AEKeyword(keyDirectObject))
        let answer=try MailScriptHost.shared.call(source:source,event:event,failure:"Mail Dot could not look in Sent mail.").stringValue ?? ""
        guard let bar=answer.firstIndex(of:"|"),let ago=Double(answer[..<bar]) else { return nil }
        let text=opening(String(answer[answer.index(after:bar)...]))
        guard !text.isEmpty else { return nil }
        return Opening(sentAt:Date().addingTimeInterval(-ago),text:text)
    }

    /// The first lines the owner wrote, before any quoted mail: the greeting and the start of the message.
    static func opening(_ body:String) -> String {
        var kept:[String]=[]
        for line in body.components(separatedBy:.newlines) {
            let trimmed=line.trimmingCharacters(in:.whitespaces)
            if trimmed.hasPrefix(">") || (trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:")) || trimmed.hasSuffix("のメッセージ:") || trimmed.hasSuffix("wrote:") { break }
            kept.append(line)
            if kept.joined(separator:"\n").count > 500 { break }
        }
        return String(kept.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines).prefix(500))
    }
}
