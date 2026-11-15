import Foundation
import AppKit
import Carbon
import BridgeCore

public actor MailAutomation {
    public init() {}

    public func permissionStatus(requestConsent:Bool = false) -> Int32 {
        let target = NSAppleEventDescriptor(bundleIdentifier:"com.apple.mail")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc,typeWildCard,typeWildCard,requestConsent)
    }

    private func requirePermission() throws {
        switch permissionStatus() {
        case 0: return
        case -1744: throw BridgeFailure("Mail automation needs your permission. Open Mail Dot’s connection window and request permission to connect to Mail.")
        case -1743: throw BridgeFailure("Mail automation is not allowed. Check System Settings → Privacy & Security → Automation for Mail Dot.")
        case -600: throw BridgeFailure("Open Mail before connecting a message.")
        case let code: throw BridgeFailure("Cannot verify permission to connect to Mail (\(code)).")
        }
    }

    public static func validateScript() throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source), script.compileAndReturnError(&error) else {
            let range = (error?[NSAppleScript.errorRange] as? NSValue)?.rangeValue ?? NSRange(location: 0, length: 0)
            let prefix = (source as NSString).substring(to: min(range.location, (source as NSString).length))
            let line = prefix.filter { $0 == "\n" }.count + 1
            throw BridgeFailure("Mail script line \(line): \(error?[NSAppleScript.errorMessage] as? String ?? "Cannot compile Mail automation.")")
        }
    }

    #if DEBUG
    /// Explicit local diagnostic invocation only; never part of a read-only MCP grant.
    public func createSyntheticReply(body:NativeMailBody,account:NativeMailAccount,mailbox:NativeMailbox) async throws -> Int {
        try NativeReplyProbe.validate(body:body,account:account,mailbox:mailbox)
        try requirePermission()
        let result=try await invoke("createsyntheticreply",arguments:[.init(string:account.id),try integer(body.message.id),.init(string:body.text)])
        guard let number=result.coerce(toDescriptorType:typeSInt32) else { throw BridgeFailure("Mail returned no usable message ID. Inspect Mail; nothing was sent.") }
        let id=Int(number.int32Value)
        guard id >= 0 else { throw BridgeFailure("Mail created no trackable message. Inspect Mail; nothing was sent.") }
        return id
    }
    #endif

    public func connect(_ envelope: MailDraft) async throws -> MailDraft {
        try requirePermission()
        let result = try await invoke("opendrafts", arguments: [])
        guard result.numberOfItems == 2, let rows = result.atIndex(2) else { throw BridgeFailure("Mail returned an incomplete compose inventory.") }
        let outgoingCount = Int(result.atIndex(1)?.int32Value ?? -1)
        let drafts = try (1...max(1, rows.numberOfItems)).compactMap { index -> MailDraft? in
            guard index <= rows.numberOfItems, let item = rows.atIndex(index) else { return nil }
            return try decode(item)
        }
        do { return try DraftMatcher.unique(drafts, matching: envelope) }
        catch {
            let peers = drafts.filter { $0.subject == envelope.subject }
            var details = "Mail scripting reports \(outgoingCount) outgoing objects, \(drafts.count) visible compose windows; \(peers.count) have this subject."
            if peers.count == 1, let peer = peers.first {
                var differences:[String] = []
                if MailDraft.address(peer.sender) != MailDraft.address(envelope.sender) { differences.append("sender") }
                if MailDraft.addresses(peer.to) != MailDraft.addresses(envelope.to) { differences.append("To") }
                if MailDraft.addresses(peer.cc) != MailDraft.addresses(envelope.cc) { differences.append("Cc") }
                if MailDraft.addresses(peer.bcc) != MailDraft.addresses(envelope.bcc) { differences.append("Bcc") }
                if !differences.isEmpty { details += " Differing fields: " + differences.joined(separator:", ") + "." }
            }
            throw BridgeFailure(error.localizedDescription + " " + details)
        }
    }

    /// Account identity metadata only. This neither reads inboxes nor starts Mail.
    public func accounts(operationDeadline:Date?=nil,authorize:@Sendable () throws -> Void = {}) async throws -> [NativeMailAccount] {
        let deadline=min(operationDeadline ?? .distantFuture,Date().addingTimeInterval(20))
        guard deadline > .now else { throw BridgeFailure("Mail setup deadline expired before account discovery.") }
        try Task.checkCancellation(); try authorize()
        let running=await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").contains { $0.bundleURL?.path == "/System/Applications/Mail.app" } }
        guard running else { throw BridgeFailure("Open Mail to refresh its account list.") }
        try requirePermission()
        guard deadline > .now else { throw BridgeFailure("Mail setup deadline expired before account discovery.") }
        try authorize()
        let rows=try await invoke("accountmetadata",arguments:[.init(date:deadline)])
        try Task.checkCancellation(); try authorize()
        guard deadline > .now else { throw BridgeFailure("Mail setup deadline expired during account discovery.") }
        guard rows.numberOfItems <= 100 else { throw BridgeFailure("Mail returned too many account records.") }
        var result:[NativeMailAccount]=[]
        if rows.numberOfItems > 0 {
            for index in 1...rows.numberOfItems {
                guard let row=rows.atIndex(index),[4,5].contains(row.numberOfItems),let list=row.atIndex(3),list.numberOfItems <= 30 else { throw BridgeFailure("Mail returned incomplete account metadata.") }
                let addresses = list.numberOfItems > 0 ? (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue } : []
                var account=NativeMailAccount(id:row.atIndex(1)?.stringValue ?? "",name:row.atIndex(2)?.stringValue ?? "",addresses:addresses,server:row.atIndex(4)?.stringValue ?? "")
                // The user's name as registered on the account in Mail, for noticing mail that names them.
                if row.numberOfItems == 5,let full=row.atIndex(5)?.stringValue?.trimmingCharacters(in:.whitespaces),!full.isEmpty,full.count <= 200 { account.fullName=full }
                result.append(account)
            }
        }
        var settings=MailSettings(); settings.nativeAccounts=result; try settings.validate()
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func snapshot(id: Int) async throws -> MailDraft {
        try requirePermission()
        return try decode(await invoke("snapshotbyid", arguments: [try integer(id)]))
    }

    /// The caller must revalidate the saved request, linked account and plan
    /// against these fresh accounts, then durably consume the creation attempt.
    /// A thrown/uncertain native result must never cause automatic retry.
    public func createDraft(_ plan:NativeCompositionPlan,deadline:Date,
                            consume:@Sendable ([NativeMailAccount])throws->Void) async throws -> MailDraft {
        guard deadline > .now else { throw BridgeFailure("Draft creation deadline expired before native access.") }
        try plan.composition.validate()
        let liveAccounts=try await accounts(operationDeadline:deadline)
        let proposal=plan.composition
        let arguments:[NSAppleEventDescriptor]=[
            .init(string:plan.nativeAccountID),.init(string:proposal.sender),
            strings(proposal.to),strings(proposal.cc),strings(proposal.bcc),
            .init(string:proposal.subject),.init(string:proposal.body),.init(date:deadline)
        ]
        return try await MailCompositionDispatch.perform(plan:plan,check:{
            guard deadline > .now else { throw BridgeFailure("Draft creation deadline expired before dispatch.") }
            try requirePermission()
        },consume:{try consume(liveAccounts)},create:{
            try decode(await invoke("createproposeddraft",arguments:arguments))
        })
    }

    public func apply(_ text: String, to expected: MailDraft) async throws -> MailDraft {
        try requirePermission()
        let result = try await invoke("applybody", arguments: [try integer(expected.id), try descriptor(expected), .init(string: text)])
        let updated = try decode(result)
        guard updated.body == text else { throw BridgeFailure("Mail did not return the exact applied text. Inspect the open message before continuing.") }
        return updated
    }

    /// Open in Reply: Mail opens a reply to the inbox message with this Message-ID, as the owner's Reply would. Nothing
    /// is typed or sent here; the reply as Mail opened it is returned.
    public func openReply(toMessageID messageID:String) async throws -> MailDraft {
        try requirePermission()
        guard let id=MailMessageIdentity.normalized(messageID) else { throw BridgeFailure("Mail Dot cannot find this message in Mail.") }
        return try decode(await invoke("replytomessage", arguments: [.init(string:id)]))
    }

    public func send(_ expected: MailDraft) async throws -> Bool {
        try requirePermission()
        return try await invoke("sendreviewed", arguments: [try integer(expected.id), try descriptor(expected)]).booleanValue
    }

    // Exercises the same recursive native guard without reading or changing any Mail message.
    func recordsEqualForTesting(_ lhs:String,_ rhs:String) async throws -> Bool {
        try await invoke("recordsidentical",arguments:[strings([lhs]),strings([rhs])]).booleanValue
    }

    private func integer(_ value: Int) throws -> NSAppleEventDescriptor {
        guard let value = Int32(exactly: value) else { throw BridgeFailure("Mail message identifier is out of range.") }
        return NSAppleEventDescriptor(int32: value)
    }

    private func descriptor(_ draft: MailDraft) throws -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        let values = [try integer(draft.id), .init(string: draft.subject), .init(string: draft.sender),
                      strings(draft.to), strings(draft.cc), strings(draft.bcc), .init(string: draft.body), try integer(draft.attachmentCount)]
        for (index, value) in values.enumerated() { list.insert(value, at: index + 1) }
        return list
    }

    private func strings(_ values: [String]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, value) in values.enumerated() { list.insert(.init(string: value), at: index + 1) }
        return list
    }

    private func decode(_ value: NSAppleEventDescriptor) throws -> MailDraft {
        guard value.numberOfItems == 8 else { throw BridgeFailure("Mail returned an incomplete draft record.") }
        func text(_ index: Int) -> String { value.atIndex(index)?.stringValue ?? "" }
        func list(_ index: Int) -> [String] {
            guard let item = value.atIndex(index), item.numberOfItems > 0 else { return [] }
            return (1...item.numberOfItems).compactMap { item.atIndex($0)?.stringValue }
        }
        return MailDraft(id: Int(value.atIndex(1)?.int32Value ?? -1), subject: text(2), sender: text(3),
                         to: list(4), cc: list(5), bcc: list(6), body: text(7),
                         attachmentCount: Int(value.atIndex(8)?.int32Value ?? -1))
    }

    private func invoke(_ name: String, arguments: [NSAppleEventDescriptor]) async throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(.init(string: name), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() { parameters.insert(argument, at: index + 1) }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        let call = ScriptValue(value: event), source = Self.source
        return try await MainActor.run {
            ScriptValue(value: try MailScriptHost.shared.call(source: source, event: call.value, failure: "Mail automation failed. Check Automation permissions for Mail Dot."))
        }.value
    }

    // Message text and addresses are passed as Apple-event values, never interpolated into this script.
    // The handler that fabricates a reply exists for development checks only and is not shipped.
    #if DEBUG
    private static let syntheticReplyHandler = #"""
        on createsyntheticreply(targetAccountID, targetMessageID, expectedBody)
            with timeout of 10 seconds
                tell application "Mail"
                    set accountMatches to accounts whose id is targetAccountID
                    if (count of accountMatches) is not 1 then error "Synthetic source account is unavailable."
                    set fixtureAccount to item 1 of accountMatches
                    if not my recordsidentical(id of fixtureAccount, targetAccountID) then error "Synthetic source account changed."
                    set messageMatches to messages of mailbox "Drafts" of fixtureAccount whose id is targetMessageID
                    if (count of messageMatches) is not 1 then error "Synthetic source message is unavailable."
                    set fixtureMessage to item 1 of messageMatches
                    if not my recordsidentical(name of mailbox of fixtureMessage, "Drafts") then error "Synthetic source mailbox changed."
                    if not my recordsidentical(id of account of mailbox of fixtureMessage, targetAccountID) then error "Synthetic source account changed."
                    if not my recordsidentical(subject of fixtureMessage, "Mail Dot native read test - UNSENT") then error "Synthetic source title changed."
                    set fixtureFromAddress to extract address from (sender of fixtureMessage)
                    if fixtureFromAddress is not in (email addresses of fixtureAccount) then error "Synthetic source sender is not owned by this account."
                    if (count of to recipients of fixtureMessage) is not 0 or (count of cc recipients of fixtureMessage) is not 0 or (count of bcc recipients of fixtureMessage) is not 0 then error "Synthetic source recipients changed."
                    if (count of mail attachments of fixtureMessage) is not 0 then error "Synthetic source has attachments."
                    if not my recordsidentical(content of fixtureMessage as text, expectedBody) then error "Synthetic source text changed."
                    set generatedReply to reply fixtureMessage opening window yes
                    return id of generatedReply
                end tell
            end timeout
        end createsyntheticreply
    """#
    #else
    private static let syntheticReplyHandler = ""
    #endif
    private static let source = #"""
    property accountDeadline : missing value
    on checkaccountdeadline()
        if accountDeadline is missing value or (current date) is greater than or equal to accountDeadline then error "Mail setup deadline expired. No further account reads were started." number -1712
    end checkaccountdeadline
    using terms from application "Mail"
        on accountmetadata(deadlineValue)
            set my accountDeadline to deadlineValue
            with timeout of 10 seconds
                set accountRows to {}
                tell application "Mail"
                    my checkaccountdeadline()
                    if (count of accounts) > 100 then error "Too many Mail accounts."
                    my checkaccountdeadline()
                    set accountRefs to accounts
                    repeat with mailAccount in accountRefs
                        set hostName to ""
                        try
                            my checkaccountdeadline()
                            set hostName to server name of mailAccount
                        end try
                        my checkaccountdeadline()
                        set accountIDValue to id of mailAccount
                        my checkaccountdeadline()
                        set accountNameValue to name of mailAccount
                        my checkaccountdeadline()
                        set accountAddressesValue to email addresses of mailAccount
                        set fullNameValue to ""
                        try
                            set fullNameValue to full name of mailAccount
                        end try
                        set end of accountRows to {accountIDValue, accountNameValue, accountAddressesValue, hostName, fullNameValue}
                    end repeat
                end tell
                return accountRows
            end timeout
        end accountmetadata

        on recordsidentical(lhs, rhs)
            if class of lhs is list then
                if class of rhs is not list then return false
                if (count of lhs) is not (count of rhs) then return false
                repeat with i from 1 to count of lhs
                    if not my recordsidentical(item i of lhs, item i of rhs) then return false
                end repeat
                return true
            end if
            if class of lhs is text then
                if class of rhs is not text then return false
                return (id of lhs) is equal to (id of rhs)
            end if
            return lhs is equal to rhs
        end recordsidentical

        on draftrecord(theDraft)
            tell application "Mail"
                set fromAddress to extract address from (sender of theDraft)
                set toList to address of every to recipient of theDraft
                set ccList to address of every cc recipient of theDraft
                set bccList to address of every bcc recipient of theDraft
                set bodyText to content of theDraft as text
                set attachmentTotal to -1
                try
                    set attachmentTotal to count of attachments of content of theDraft
                end try
                return {id of theDraft, subject of theDraft, fromAddress, toList, ccList, bccList, bodyText, attachmentTotal}
            end tell
        end draftrecord

        on opendrafts()
            with timeout of 15 seconds
                set draftRows to {}
                tell application "Mail"
                    set outgoingTotal to count of outgoing messages
                    repeat with theDraft in outgoing messages
                        if visible of theDraft then set end of draftRows to my draftrecord(theDraft)
                    end repeat
                end tell
                return {outgoingTotal, draftRows}
            end timeout
        end opendrafts

        on snapshotbyid(targetID)
            with timeout of 15 seconds
                tell application "Mail"
                    set matches to outgoing messages whose id is targetID
                    if (count of matches) is not 1 then error "The connected message is no longer open in Mail. Nothing was changed."
                    return my draftrecord(item 1 of matches)
                end tell
            end timeout
        end snapshotbyid

        on createproposeddraft(targetAccountID, senderValue, toValues, ccValues, bccValues, subjectValue, bodyValue, deadlineValue)
            set my accountDeadline to deadlineValue
            with timeout of 15 seconds
                tell application "Mail"
                    my checkaccountdeadline()
                    if (count of accounts) > 100 then error "Too many Mail accounts."
                    set matchedIDs to {}
                    repeat with candidate in accounts
                        my checkaccountdeadline()
                        if senderValue is in (email addresses of candidate) then
                            set end of matchedIDs to id of candidate
                        end if
                    end repeat
                    if (count of matchedIDs) is not 1 then error "The draft sender is not unique in Mail."
                    if not my recordsidentical(item 1 of matchedIDs, targetAccountID) then error "The draft sender account changed."
                    my checkaccountdeadline()
                    set createdDraft to make new outgoing message with properties {sender:senderValue, subject:subjectValue, content:bodyValue, visible:false}
                    try
                        tell createdDraft
                            repeat with recipientValue in toValues
                                make new to recipient at end of to recipients with properties {address:(contents of recipientValue)}
                            end repeat
                            repeat with recipientValue in ccValues
                                make new cc recipient at end of cc recipients with properties {address:(contents of recipientValue)}
                            end repeat
                            repeat with recipientValue in bccValues
                                make new bcc recipient at end of bcc recipients with properties {address:(contents of recipientValue)}
                            end repeat
                            set visible to true
                        end tell
                    on error failureText number failureCode
                        -- The message exists but is still hidden. Remove it rather than leave an orphan.
                        try
                            delete createdDraft
                        end try
                        error failureText number failureCode
                    end try
                    return my draftrecord(createdDraft)
                end tell
            end timeout
        end createproposeddraft

        \#(syntheticReplyHandler)

        on applybody(targetID, expectedRecord, newBody)
            with timeout of 15 seconds
                if not my recordsidentical(my snapshotbyid(targetID), expectedRecord) then error "The draft changed. Share its current context again before applying text."
                tell application "Mail"
                    set targetDraft to first outgoing message whose id is targetID
                    set content of targetDraft to newBody
                end tell
                return my snapshotbyid(targetID)
            end timeout
        end applybody

        on replytomessage(targetMessageID)
            with timeout of 30 seconds
                tell application "Mail"
                    set found to (messages of inbox whose message id is targetMessageID)
                    if (count of found) is 0 then error "Mail Dot could not find this message in your inbox, so no reply was opened."
                    set newReply to reply (item 1 of found) opening window yes
                    return my draftrecord(newReply)
                end tell
            end timeout
        end replytomessage

        on sendreviewed(targetID, expectedRecord)
            with timeout of 15 seconds
                set liveRecord to my snapshotbyid(targetID)
                if not my recordsidentical(liveRecord, expectedRecord) then error "The draft changed after review. Nothing was sent."
                if item 8 of liveRecord is not 0 then error "Attachments are unsupported for voice sending in this prototype."
                tell application "Mail"
                    set targetDraft to first outgoing message whose id is targetID
                    return send targetDraft
                end tell
            end timeout
        end sendreviewed
    end using terms from
    """#
}
