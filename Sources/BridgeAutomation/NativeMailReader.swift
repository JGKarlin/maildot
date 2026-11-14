import Foundation
import AppKit
import Carbon
import BridgeCore

/// Fixed, read-only Apple Events. Only the signed companion invokes this reader.
public protocol NativeMailReading:Sendable {
    func mailboxes(accountID:String) async throws -> [NativeMailbox]
    func listMessages(accountID:String,mailbox:NativeMailbox,query:NativeMailQuery) async throws -> JSONValue
    func readMessage(accountID:String,mailbox:NativeMailbox,messageID:Int,expectedFingerprint:String) async throws -> NativeMailBody
}

public actor NativeMailReader:NativeMailReading {
    private let automation=MailAutomation()
    private let authorize:@Sendable () throws -> Void
    private let operationDeadline:Date?
    public init(operationDeadline:Date?=nil,authorize:@escaping @Sendable () throws -> Void = {}) {
        self.operationDeadline=operationDeadline; self.authorize=authorize
    }
    public static func validateScript() throws {
        var error:NSDictionary?
        guard let script=NSAppleScript(source:source),script.compileAndReturnError(&error) else {
            throw BridgeFailure(error?[NSAppleScript.errorMessage] as? String ?? "Native Mail reader script did not compile.")
        }
    }
    private func requireAvailable() async throws {
        let running=await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").contains { $0.bundleURL?.path == "/System/Applications/Mail.app" } }
        guard running else { throw BridgeFailure("Mail is not running. No mailbox check was completed.") }
        guard await automation.permissionStatus() == 0 else { throw BridgeFailure("Allow Mail Dot to control Mail in macOS Automation settings before continuing.") }
        try Task.checkCancellation()
    }
    public func mailboxes(accountID:String) async throws -> [NativeMailbox] {
        try NativeMailbox(accountID:accountID,path:["validation"]).validate()
        try await requireAvailable()
        let result=try await invoke("listmailboxes",arguments:[.init(string:accountID)])
        guard result.descriptorType == typeAEList,result.numberOfItems <= 100 else { throw BridgeFailure("Mail returned an oversized mailbox list.") }
        var boxes:[NativeMailbox]=[]
        for index in 0..<result.numberOfItems {
            guard let row=result.atIndex(index+1),row.numberOfItems == 2,
                  let returnedAccount=row.atIndex(1)?.stringValue,returnedAccount == accountID,let path=row.atIndex(2) else { throw BridgeFailure("Mail returned a mailbox outside the requested account.") }
            let box=NativeMailbox(accountID:returnedAccount,path:try strings(path,maximum:8))
            try box.validate(); boxes.append(box)
        }
        guard Set(boxes.map(\.id)).count == boxes.count else { throw BridgeFailure("Mailbox names are ambiguous in this account.") }
        return boxes
    }
    public func listMessages(accountID:String,mailbox:NativeMailbox,query:NativeMailQuery) async throws -> JSONValue {
        try mailbox.validate(); try query.validate(kind:.listMessages)
        guard mailbox.accountID == accountID else { throw BridgeFailure("Mailbox belongs to another account.") }
        try await requireAvailable()
        let result=try await invoke("listmetadata",arguments:[.init(string:accountID),list(mailbox.path),.init(date:query.since),.init(date:query.until),.init(int32:Int32(query.offset)),.init(int32:Int32(query.limit))])
        guard result.numberOfItems == 2,let count=result.atIndex(1),let rows=result.atIndex(2),rows.descriptorType == typeAEList,
              rows.numberOfItems <= query.limit else { throw BridgeFailure("Mail returned an incomplete metadata page.") }
        let total=Int(count.int32Value)
        guard total >= 0,total <= 500 else { throw BridgeFailure("Narrow the time window; more than 500 messages match.") }
        var records:[JSONValue]=[]
        for index in 0..<rows.numberOfItems {
            guard let row=rows.atIndex(index+1) else { throw BridgeFailure("Missing message metadata.") }
            let message=try decode(row,mailboxID:mailbox.id)
            var value=try JSONValue.encode(message).object ?? [:]
            value["fingerprint"] = .string(message.fingerprint); records.append(.object(value))
        }
        let next=query.offset+records.count
        return ["account_id":.string(accountID),"mailbox_id":.string(mailbox.id),"messages":.array(records),"matching_count":.number(Double(total)),
                "next_offset":next < total ? .number(Double(next)) : .null,
                "collection_complete":.bool(query.offset == 0 && records.count == total),
                "coverage":"Mail cache page; pagination is not an atomic server snapshot.","server_freshness_verified":false,"observed_at":.string(Date().ISO8601Format())]
    }
    public func readMessage(accountID:String,mailbox:NativeMailbox,messageID:Int,expectedFingerprint:String) async throws -> NativeMailBody {
        try mailbox.validate()
        guard mailbox.accountID == accountID,messageID >= 0,messageID <= Int32.max,!expectedFingerprint.isEmpty,expectedFingerprint.utf8.count <= 128 else { throw BridgeFailure("Select a current message in the authorized mailbox.") }
        try await requireAvailable()
        let arguments:[NSAppleEventDescriptor]=[.init(string:accountID),list(mailbox.path),.init(int32:Int32(messageID))]
        let before=try decode(await invoke("metadataforid",arguments:arguments),mailboxID:mailbox.id)
        // The limit applies to the text Mail extracts, not to the raw message, which for HTML mail or mail
        // with attachments is far larger than what is read.
        guard before.fingerprint == expectedFingerprint else { throw BridgeFailure("The selected message changed since it was listed. List the mailbox again. No body was read.") }
        let result=try await invoke("readbody",arguments:arguments)
        guard result.numberOfItems == 2,let metadata=result.atIndex(1),let text=result.atIndex(2)?.stringValue else { throw BridgeFailure("Mail returned incomplete message content.") }
        let after=try decode(metadata,mailboxID:mailbox.id)
        guard before == after else { throw BridgeFailure("The message or read flag changed during reading. Inspect Mail; no content was shared.") }
        return try NativeMailBody(message:after,text:text,expectedFingerprint:expectedFingerprint)
    }
    private func decode(_ row:NSAppleEventDescriptor,mailboxID:String) throws -> NativeMailMessage {
        guard row.descriptorType == typeAEList,row.numberOfItems == 11,let date=row.atIndex(5)?.dateValue else { throw BridgeFailure("Mail returned incomplete message metadata.") }
        func text(_ index:Int)throws->String { guard let value=row.atIndex(index)?.stringValue else { throw BridgeFailure("Mail omitted a message field.") }; return value }
        func addresses(_ index:Int)throws->[String] { guard let value=row.atIndex(index) else { throw BridgeFailure("Mail omitted recipients.") }; return try strings(value,maximum:100) }
        let message=NativeMailMessage(id:Int(row.atIndex(1)?.int32Value ?? -1),mailboxID:mailboxID,headerID:try text(2),subject:try text(3),sender:try text(4),receivedAt:date,isRead:row.atIndex(6)?.booleanValue ?? false,size:Int(row.atIndex(7)?.int32Value ?? -1),to:try addresses(8),cc:try addresses(9),bcc:try addresses(10),attachmentCount:Int(row.atIndex(11)?.int32Value ?? -1))
        try message.validate(); return message
    }
    private func strings(_ value:NSAppleEventDescriptor,maximum:Int) throws -> [String] {
        guard value.descriptorType == typeAEList,value.numberOfItems <= maximum else { throw BridgeFailure("Mail returned an invalid list.") }
        return try (0..<value.numberOfItems).map { index in
            guard let text=value.atIndex(index+1)?.stringValue,text.utf8.count <= 2048 else { throw BridgeFailure("Mail returned an invalid list value.") }
            return text
        }
    }
    private func list(_ strings:[String])->NSAppleEventDescriptor {
        let value=NSAppleEventDescriptor.list()
        for (index,text) in strings.enumerated() { value.insert(.init(string:text),at:index+1) }
        return value
    }
    private func invoke(_ handler:String,arguments:[NSAppleEventDescriptor]) async throws -> NSAppleEventDescriptor {
        let event=NSAppleEventDescriptor(eventClass:AEEventClass(kASAppleScriptSuite),eventID:AEEventID(kASSubroutineEvent),targetDescriptor:nil,returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        event.setParam(.init(string:handler),forKeyword:AEKeyword(keyASSubroutineName))
        let parameters=NSAppleEventDescriptor.list()
        for (index,value) in arguments.enumerated() { parameters.insert(value,at:index+1) }
        let deadline=min(operationDeadline ?? .distantFuture,Date().addingTimeInterval(20))
        guard deadline > Date() else { throw BridgeFailure("This native Mail read expired before execution.") }
        parameters.insert(.init(date:deadline),at:arguments.count+1)
        event.setParam(parameters,forKeyword:AEKeyword(keyDirectObject))
        try authorize()
        let call=ScriptValue(value:event),source=Self.source
        return try await MainActor.run {
            ScriptValue(value:try MailScriptHost.shared.call(source:source,event:call.value,failure:"Native Mail read failed."))
        }.value
    }

    static let source = #"""
    property readDeadline : missing value
    on checkdeadline()
        if readDeadline is missing value or (current date) is greater than or equal to readDeadline then error "Native Mail read deadline expired. No further reads were started." number -1712
    end checkdeadline
    using terms from application "Mail"
        on sametext(lhs, rhs)
            return (id of (lhs as text)) is equal to (id of (rhs as text))
        end sametext
        on resolveaccount(targetID)
            tell application "Mail"
                set matches to {}
                my checkdeadline()
                if (count of accounts) > 100 then error "Too many Mail accounts."
                my checkdeadline()
                set candidates to accounts
                repeat with candidate in candidates
                    my checkdeadline()
                    if my sametext(id of candidate, targetID) then set end of matches to contents of candidate
                end repeat
                if (count of matches) is not 1 then error "The selected Mail account is unavailable or ambiguous."
                return item 1 of matches
            end tell
        end resolveaccount
        on walkboxes(boxes, targetID, prefixPath, depth)
            if depth > 8 or (count of boxes) > 100 then error "Mailbox discovery limit reached."
            set rows to {}
            repeat with boxRef in boxes
                tell application "Mail"
                    my checkdeadline()
                    set owningAccount to account of boxRef
                    if owningAccount is missing value then error "Mailbox account is unavailable."
                    my checkdeadline()
                    if not my sametext(id of owningAccount, targetID) then error "Mailbox is outside the selected account."
                    my checkdeadline()
                    set boxPath to prefixPath & {name of boxRef as text}
                    my checkdeadline()
                    set children to mailboxes of boxRef
                end tell
                set end of rows to {targetID, boxPath}
                if (count of children) > 0 then set rows to rows & my walkboxes(children, targetID, boxPath, depth + 1)
                if (count of rows) > 100 then error "Mailbox discovery limit reached."
            end repeat
            return rows
        end walkboxes
        on listmailboxes(targetID, deadlineValue)
            set my readDeadline to deadlineValue
            with timeout of 10 seconds
                set selectedAccount to my resolveaccount(targetID)
                my checkdeadline()
                tell application "Mail" to set boxes to mailboxes of selectedAccount
                return my walkboxes(boxes, targetID, {}, 1)
            end timeout
        end listmailboxes
        on resolvebox(targetID, boxPath)
            if (count of boxPath) < 1 or (count of boxPath) > 8 then error "Invalid mailbox path."
            set selectedAccount to my resolveaccount(targetID)
            my checkdeadline()
            tell application "Mail" to set boxes to mailboxes of selectedAccount
            repeat with component in boxPath
                set matches to {}
                if (count of boxes) > 100 then error "Mailbox resolution limit reached."
                repeat with boxRef in boxes
                    my checkdeadline()
                    tell application "Mail" to set candidateName to name of boxRef
                    if my sametext(candidateName, component) then set end of matches to contents of boxRef
                end repeat
                if (count of matches) is not 1 then error "The selected mailbox is unavailable or ambiguous."
                set selectedBox to item 1 of matches
                tell application "Mail"
                    my checkdeadline()
                    set owningAccount to account of selectedBox
                    if owningAccount is missing value then error "Mailbox has no account."
                    my checkdeadline()
                    if not my sametext(id of owningAccount, targetID) then error "Mailbox is outside the selected account."
                    my checkdeadline()
                    set boxes to mailboxes of selectedBox
                end tell
            end repeat
            return selectedBox
        end resolvebox
        on metadatarecord(theMessage, targetID)
            tell application "Mail"
                my checkdeadline()
                set actualAccount to account of mailbox of theMessage
                if actualAccount is missing value then error "Message account is unavailable."
                my checkdeadline()
                if not my sametext(id of actualAccount, targetID) then error "Message is outside the selected account."
                my checkdeadline()
                set localID to id of theMessage
                my checkdeadline()
                set headerID to message id of theMessage
                my checkdeadline()
                set subjectText to subject of theMessage
                my checkdeadline()
                set senderText to sender of theMessage
                my checkdeadline()
                set receivedDate to date received of theMessage
                my checkdeadline()
                set readFlag to read status of theMessage
                my checkdeadline()
                set byteSize to message size of theMessage
                my checkdeadline()
                set toAddresses to address of every to recipient of theMessage
                my checkdeadline()
                set ccAddresses to address of every cc recipient of theMessage
                my checkdeadline()
                set bccAddresses to address of every bcc recipient of theMessage
                my checkdeadline()
                set attachmentTotal to count of mail attachments of theMessage
                return {localID, headerID, subjectText, senderText, receivedDate, readFlag, byteSize, toAddresses, ccAddresses, bccAddresses, attachmentTotal}
            end tell
        end metadatarecord
        on listmetadata(targetID, boxPath, fromDate, untilDate, offsetValue, pageLimit, deadlineValue)
            set my readDeadline to deadlineValue
            with timeout of 10 seconds
                if pageLimit < 1 or pageLimit > 50 or offsetValue < 0 or offsetValue > 499 then error "Invalid metadata page."
                set selectedBox to my resolvebox(targetID, boxPath)
                tell application "Mail"
                    my checkdeadline()
                    set candidates to messages of selectedBox whose date received is greater than or equal to fromDate and date received is less than or equal to untilDate
                    set matchingCount to count of candidates
                    if matchingCount > 500 then error "Narrow the time window; more than 500 messages match."
                end tell
                set rows to {}
                if offsetValue < matchingCount then
                    set finalIndex to offsetValue + pageLimit
                    if finalIndex > matchingCount then set finalIndex to matchingCount
                    repeat with itemIndex from (offsetValue + 1) to finalIndex
                        set end of rows to my metadatarecord(item itemIndex of candidates, targetID)
                    end repeat
                end if
                return {matchingCount, rows}
            end timeout
        end listmetadata
        on scopedmessage(targetID, boxPath, messageID)
            set selectedBox to my resolvebox(targetID, boxPath)
            my checkdeadline()
            tell application "Mail" to set matches to messages of selectedBox whose id is messageID
            if (count of matches) is not 1 then error "The selected message is no longer in this mailbox."
            return item 1 of matches
        end scopedmessage
        on metadataforid(targetID, boxPath, messageID, deadlineValue)
            set my readDeadline to deadlineValue
            with timeout of 10 seconds
                return my metadatarecord(my scopedmessage(targetID, boxPath, messageID), targetID)
            end timeout
        end metadataforid
        on readbody(targetID, boxPath, messageID, deadlineValue)
            set my readDeadline to deadlineValue
            with timeout of 10 seconds
                set selectedMessage to my scopedmessage(targetID, boxPath, messageID)
                tell application "Mail"
                    my checkdeadline()
                    set bodyText to content of selectedMessage as text
                    my checkdeadline()
                    if (length of bodyText) > 65536 then error "This message's text is longer than Mail Dot can share (64 KiB). No body was read."
                end tell
                set finalMessage to my scopedmessage(targetID, boxPath, messageID)
                return {my metadatarecord(finalMessage, targetID), bodyText}
            end timeout
        end readbody
    end using terms from
    """#
}
