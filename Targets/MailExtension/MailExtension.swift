import AppKit
import SwiftUI
import MailKit
import OSLog
import BridgeCore

@MainActor final class MailExtension: NSObject, MEExtension {
    nonisolated override init() { super.init() }
    nonisolated func handler(for session:MEComposeSession) -> any MEComposeSessionHandler { ComposeHandler() }
    nonisolated func handlerForMessageSecurity() -> any MEMessageSecurityHandler { MessageReportHandler() }
    nonisolated func handlerForMessageActions() -> any MEMessageActionHandler { ArrivalHandler() }
}

/// Puts Dot's report on the message it concerns, inside Mail. MailKit gives an extension one place on a
/// received message: as Mail displays a message it asks the extension to "decode" it, and the answer may
/// carry a banner for the top of the message and a context; clicking the banner, or the extension's icon in
/// the message header, asks for a view controller for that context. Mail Dot answers only for a message
/// Dot has reported on, hands the message back exactly as it came, and signs and encrypts nothing.
@MainActor private final class MessageReportHandler:NSObject,MEMessageSecurityHandler {
    nonisolated override init() { super.init() }

    // Outgoing mail is left entirely alone.
    nonisolated func getEncodingStatus(for message:MEMessage,composeContext:MEComposeContext,completionHandler:@escaping (MEOutgoingMessageEncodingStatus) -> Void) {
        completionHandler(MEOutgoingMessageEncodingStatus(canSign:false,canEncrypt:false,securityError:nil,addressesFailingEncryption:[]))
    }
    nonisolated func encode(_ message:MEMessage,composeContext:MEComposeContext,completionHandler:@escaping (MEMessageEncodingResult) -> Void) {
        completionHandler(MEMessageEncodingResult(encodedMessage:nil,signingError:nil,encryptionError:nil))
    }

    /// Called for every message Mail displays. Every message is answered, unchanged, so that Mail shows the
    /// Mail Dot icon in the message's header, in the main window and in a message's own window alike; that
    /// icon is the nearest thing to a toolbar button that Mail gives an extension outside a compose window.
    /// A banner is added only for a message Dot has reported on.
    nonisolated func decodedMessage(forMessageData data:Data) -> MEDecodedMessage? {
        let headers=MailMessageHeaders(rawMessage:data)
        // Mail is showing this message: Mail Dot redraws shown messages only when one of these changes.
        if let directory=try? BridgeStore.shared().directory { ShownMessages.note(messageID:headers.messageID,bridgeDirectory:directory) }
        let record=ReportIndex.shared.record(for:headers)
        // The banner says the state only, with its symbol; what is needed is shown in the panel.
        var banner=record.map{ report -> MEDecodedMessageBanner in
            let state=MailDotBanner(report:MailUpdatePresentation(report.update).status)
            return MEDecodedMessageBanner(title:state.title,primaryActionTitle:state.action,dismissable:false)
        }
        // Never empty: Mail opens the panel from the header icon only for a message that carries a context,
        // and the owner reaches Mail Dot (and its settings) from any message.
        var context=record?.id ?? MessageReportViewController.anyMessage
        // A report on this message is remembered with its Message-ID, so that once the owner has replied to
        // the message, by hand or through Mail Dot, the report is closed and its banner goes.
        if let record,let id=headers.messageID,ReportIndex.shared.linkNeeded(record.id,messageID:id) {
            try? MailTriageStore.shared().transaction { $0.linkReport(record.id,messageID:id) }
        }
        // A message the owner wrote, shown in a conversation or in Sent: it carries no state, and the message it
        // answers is marked replied, also for replies written before Mail Dot read the owner's own mail.
        if ReportIndex.shared.isOwner(headers.senderAddress) {
            if let parent=headers.inReplyTo,ReportIndex.shared.ownerReplyNeedsNoting(parent) {
                try? MailTriageStore.shared().transaction { $0.noteOwnerSent(inReplyTo:parent) }
            }
            return MEDecodedMessage(data:data,securityInformation:MEMessageSecurityInformation(signers:[],isEncrypted:false,signingError:nil,encryptionError:nil),context:Data(MessageReportViewController.anyMessage.utf8))
        }
        // A message Mail Dot saw arrive: its state in words, where the list can show only a colour.
        if record == nil,let id=headers.messageID,let entry=ReportIndex.shared.triage(forMessageID:id),let state=MailDotBanner(entry) {
            // While Dot cannot take requests, a message waiting on it says so, not "Drafting" (owner approval, 14
            // November 2026); the Mail Dot window names the reason.
            banner=MEDecodedMessageBanner(title:state.shown(ReportIndex.shared.dotAvailability()).title(place:ReportIndex.shared.queuePlace(entry)),primaryActionTitle:state.action,dismissable:false)
            context="triage:"+entry.id
        }
        // A message the owner was only copied on that names them goes to Dot after all.
        if let id=headers.messageID,let entry=ReportIndex.shared.triage(forMessageID:id),entry.outcome == .skipped,entry.reason == MailTriage.copiedOnlyReason,
           let settings=try? MailSettingsStore.shared().read(),MailBodyText.mentions(settings.effectiveOwnerNames,inRawMessage:data) {
            try? MailTriageStore.shared().transaction { $0.noteMention(messageID:id,sender:entry.sender) }
        }
        // The owner opened this message: an important one is recorded, so its state shows on its banner.
        if let id=headers.messageID {
            let known=ReportIndex.shared.triage(forMessageID:id)
            if known == nil || (known?.openedAt == nil && known?.outcome == .held && known?.heldAsOlder == true) { OpenedMessages.note(data) }
        }
        let plain=MEMessageSecurityInformation(signers:[],isEncrypted:false,signingError:nil,encryptionError:nil)
        return MEDecodedMessage(data:data,securityInformation:plain,context:Data(context.utf8),banner:banner)
    }
    func extensionViewController(signers messageSigners:[MEMessageSigner]) -> MEExtensionViewController? { nil }
    // Mail Dot's icon in the message header opens Settings; the banner's button opens the message (owner request, 15 November 2026).
    func extensionViewController(messageContext context:Data) -> MEExtensionViewController? { MessageReportViewController(context:context,settingsFirst:true) }
    func primaryActionClicked(forMessageContext context:Data,completionHandler:@escaping (MEExtensionViewController?) -> Void) {
        completionHandler(MessageReportViewController(context:context))
    }
}

/// Messages the owner opens, recorded for drafting. Each is noted once; the companion offers it to Dot under
/// the same switches, hourly limit and "already replied" check as arriving mail.
private enum OpenedMessages {
    static func note(_ data:Data) {
        guard let settings=try? MailSettingsStore.shared().read(),let store=try? MailTriageStore.shared() else { return }
        let input=MailTriage.Input(rawMessage:data)
        let owner=settings.ownerAddresses
        guard settings.mailDot(forRecipients:input.to+input.cc) else { return }
        let received=(input.to+input.cc).filter(owner.contains)
        let changed=(try? store.transaction { $0.noteOpened(input,owner:owner,automatic:settings.automaticReplies(forRecipients:received)) }) ?? false
        if changed,let url=URL(string:"mailbridge://operations") {
            let configuration=NSWorkspace.OpenConfiguration(); configuration.activates=false
            NSWorkspace.shared.open(url,configuration:configuration) { _,_ in }
        }
    }
}

/// Dot's reports, read once and kept until the file changes, because Mail asks about every message it displays.
private final class ReportIndex:@unchecked Sendable {
    static let shared=ReportIndex()
    private let lock=NSLock()
    private var stamp:Date?
    private var state:ScheduledMailUpdateState?
    func record(for headers:MailMessageHeaders) -> ScheduledMailUpdateRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let directory=try? BridgeStore.shared().directory else { return nil }
        let file=directory.appendingPathComponent("ScheduledUpdates/updates.json")
        let modified=(try? FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate]) as? Date
        if state == nil || modified != stamp {
            state=try? ScheduledMailUpdateStore(bridgeDirectory:directory).read()
            stamp=modified
        }
        return state?.record(for:headers)
    }
    private var linked:[String:String]=[:]
    /// Whether this report and message have not been linked yet in this run of the extension.
    func linkNeeded(_ reportKey:String,messageID:String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard linked[messageID] != reportKey else { return false }
        linked[messageID]=reportKey
        return true
    }
    private var activeCheckedAt=Date.distantPast
    private var availability=DotAvailability.available
    /// Whether Dot can take requests now, read at most every 30 seconds: Mail asks about every message it shows.
    func dotAvailability() -> DotAvailability {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(activeCheckedAt) > 30 {
            if let bridge=try? BridgeStore.shared().directory,let settings=try? MailSettingsStore(bridgeDirectory:bridge).read() {
                availability=DotAvailability(access:settings.effectiveDotAccess,
                                             connection:(try? MailTriageStore(bridgeDirectory:bridge).read())?.connection,
                                             listening:(try? MailWorkflowStore(bridgeDirectory:bridge).read())?.workerListening() ?? false)
            }
            activeCheckedAt=Date()
        }
        return availability
    }
    private var ownerCheckedAt=Date.distantPast
    private var owner:Set<String>=[]
    /// Whether an address is one of the owner's, read at most every 30 seconds.
    func isOwner(_ address:String?) -> Bool {
        guard let address else { return false }
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(ownerCheckedAt) > 30 {
            owner=(try? MailSettingsStore.shared().read())?.ownerAddresses ?? owner
            ownerCheckedAt=Date()
        }
        return owner.contains(address.lowercased())
    }
    private var notedReplies:Set<String>=[]
    /// Whether the owner's reply to this message has not been noted yet in this run of the extension.
    func ownerReplyNeedsNoting(_ parent:String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return notedReplies.insert(parent).inserted
    }
    private var triageStamp:Date?
    private var triageState:MailTriageState?
    func triage(forMessageID id:String) -> MailTriageEntry? {
        lock.lock(); defer { lock.unlock() }
        guard let store=try? MailTriageStore.shared() else { return nil }
        let modified=(try? FileManager.default.attributesOfItem(atPath:store.directory.appendingPathComponent("triage.json").path)[.modificationDate]) as? Date
        if triageState == nil || modified != triageStamp { triageState=try? store.read(); triageStamp=modified }
        return triageState?.entry(forMessageID:id)
    }
    private var workflowStamp:Date?
    private var workflowState:MailWorkflowState?
    /// The message's place in Dot's queue, from the triage state read above and Dot's requests, read again only when
    /// their file changes.
    func queuePlace(_ entry:MailTriageEntry) -> DotQueuePlace? {
        guard [.pending,.asked].contains(entry.outcome) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let triageState,let bridge=try? BridgeStore.shared().directory else { return nil }
        let store=MailWorkflowStore(bridgeDirectory:bridge)
        let modified=(try? FileManager.default.attributesOfItem(atPath:bridge.appendingPathComponent("Workflow/workflow.json").path)[.modificationDate]) as? Date
        if workflowState == nil || modified != workflowStamp { workflowState=try? store.read(); workflowStamp=modified }
        guard let workflowState else { return nil }
        return DotQueuePlace.of(entry,triage:triageState,workflow:workflowState)
    }
}

/// Mail hands each arriving message to Mail Dot once, with the headers Mail Dot asked for. Mail Dot decides
/// there, on the Mac, whether the message is essential (a person wrote to the owner directly, and it is not
/// a receipt, code, notice, list, automated mail or spam), records the verdict, and, when automatic
/// drafting is on, queues it to be offered to Dot. The message itself is not changed, and nothing of it is
/// sent anywhere from here.
private final class ArrivalHandler:NSObject,MEMessageActionHandler {
    nonisolated var requiredHeaders:[String] { MailTriage.requiredHeaders }
    nonisolated func decideAction(for message:MEMessage,completionHandler:@escaping (MEMessageActionDecision?) -> Void) {
        let raw=message.fromAddress.rawString
        let address=message.fromAddress.addressString ?? MailMessageIdentity.address(in:raw) ?? raw
        let name=raw.lastIndex(of:"<").map{raw[..<$0].trimmingCharacters(in:CharacterSet(charactersIn:"\" ").union(.whitespaces))}.flatMap{$0.isEmpty ? nil : $0}
        var headers:[String:[String]]=[:]
        for (key,values) in message.headers ?? [:] { headers[key.lowercased(),default:[]] += values }
        var input=MailTriage.Input(messageID:headers["message-id"]?.first,senderAddress:address,senderName:name.map{MailMessageHeaders.decoded($0)},
                                   to:message.toAddresses.map{$0.addressString ?? $0.rawString},cc:message.ccAddresses.map{$0.addressString ?? $0.rawString},
                                   subject:message.subject,receivedAt:Date(),headers:headers)
        guard let settings=try? MailSettingsStore.shared().read(),let store=try? MailTriageStore.shared() else { completionHandler(nil); return }
        // The owner's own mail, sent from here or elsewhere: it is not listed, and the message it answers is replied.
        if settings.ownerAddresses.contains(input.senderAddress.lowercased()) {
            let parent=headers["in-reply-to"]?.first.flatMap(MailMessageHeaders.firstMessageID)
            try? store.transaction { $0.noteOwnerSent(inReplyTo:parent) }
            completionHandler(nil); return
        }
        if let body=message.rawData { input.mentionsOwner=MailBodyText.mentions(settings.effectiveOwnerNames,inRawMessage:body) }
        // Mail Dot is switched off for the account that received it: the message is not even looked at.
        guard settings.mailDot(forRecipients:input.to+input.cc) else { completionHandler(nil); return }
        let owner=settings.ownerAddresses
        let received=(input.to+input.cc).filter(owner.contains)
        let automatic=settings.automaticReplies(forRecipients:received)
        try? store.transaction { state in
            let verdict=MailTriage.assess(input,owner:owner,correspondents:Set(state.correspondents),rules:state.rules)
            var entry=MailTriageEntry(messageID:input.messageID,sender:input.senderAddress,senderName:input.senderName,subject:input.subject,receivedAt:input.receivedAt,verdict:verdict,automatic:automatic)
            entry.recipients=received
            state.record(entry)
            state.requestReportIfAlways(messageID:entry.messageID)
        }
        // The message is left exactly as it arrived; a flag comes only later, if the message comes to need the owner.
        completionHandler(nil)
    }
}

@MainActor private final class MessageReportViewController:MEExtensionViewController {
    private let recordID:String?
    private let settingsFirst:Bool
    /// The context of a message Dot has not reported on and Mail Dot did not see arrive.
    nonisolated static let anyMessage="message"
    init(context:Data,settingsFirst:Bool=false) {
        let id=String(decoding:context,as:UTF8.self)
        recordID=id.isEmpty || id == Self.anyMessage ? nil : id
        self.settingsFirst=settingsFirst
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { nil }
    override func loadView() {
        if settingsFirst || recordID?.hasPrefix("triage:") == true {
            let id=recordID.flatMap{ $0.hasPrefix("triage:") ? String($0.dropFirst("triage:".count)) : nil } ?? ""
            // The layout the owner chose in Settings; the window changes size when they choose another.
            let chosen=(try? MailSettingsStore.shared().read())?.windowLayout ?? .briefing
            let layout=MailDotThreadWindow.fits(chosen) ? chosen : .briefing
            view=NSHostingView(rootView:MailDotThreadWindow(entryID:id,resize:{ [weak self] size in
                self?.preferredContentSize=NSSize(width:size.width,height:size.height)
            },startsInSettings:settingsFirst))
            let size=MailDotThreadWindow.size(layout)
            preferredContentSize=NSSize(width:size.width,height:size.height)
            return
        }
        view=NSHostingView(rootView:MessageReportView(recordID:recordID))
        preferredContentSize=NSSize(width:MessageReportView.size.width,height:MessageReportView.size.height)
    }
    /// Mail takes a message's banner away once its button has been pressed. When this window closes, the
    /// companion is asked to have Mail show the message again, so its banner comes back (owner request, 13 November
    /// 2026). Asking Mail directly from here crashed the extension (build 121: MEExtensionManager is not for
    /// an extension's own use), and with it every banner, so the request goes through the shared store.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        QuitCloser.remove(self)
        try? MailTriageStore.shared().transaction { $0.bannerReloadRequestedAt = .now }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        QuitCloser.add(self)
    }
}

/// Whether a Mail Dot window is open in Mail, kept in the shared store. Mail shows that window as a modal dialog and
/// keeps its other windows waiting meanwhile, so a reply Open in Reply asked for is opened once it has closed. The window
/// cannot close itself: it can only let go of its contents, which left Mail's dialog open and empty (build 178).
@MainActor private enum QuitCloser {
    private static let open=NSHashTable<NSViewController>.weakObjects()
    static func add(_ controller:NSViewController) {
        open.add(controller)
        try? MailTriageStore.shared().transaction { $0.mailDotWindowOpenAt = .now }
    }
    static func remove(_ controller:NSViewController) {
        open.remove(controller)
        if open.allObjects.isEmpty { try? MailTriageStore.shared().transaction { $0.mailDotWindowOpenAt=nil } }
    }
}

@MainActor private final class ComposeHandler: NSObject, MEComposeSessionHandler {
    nonisolated override init() { super.init() }
    nonisolated func mailComposeSessionDidBegin(_ session:MEComposeSession) {}
    // Mail delivers these data callbacks on its XPC queue on macOS 27, despite
    // the protocol's UI-actor annotation. Keep them synchronous and UI-free;
    // BridgeStore serializes the cross-process read/modify/write transaction.
    nonisolated func annotateAddressesForSession(_ session:MEComposeSession,completion:@escaping ([MEEmailAddress:MEAddressAnnotation]) -> Void) {
        // A mark on the recipient's address is the one thing Mail lets an extension change in a reply window
        // besides its own panel. Build 79 put the state of Dot's draft there; Mail drew nothing for it, in
        // either the success or the warning style, so the state is shown by notification instead.
        defer { completion([:]) }
        // Observe the session Mail supplies in its documented address-annotation callback.
        // Persist metadata only for a session whose owner already opened the panel.
        try? BridgeStore.shared().transaction { state in
            let id = session.sessionID.uuidString
            guard var context = state.contexts[id] else { return }
            BridgeCoordinator.observeEnvelope(composeEnvelope(session),context:&context)
            state.contexts[id] = context
            if context.snapshot == nil, state.activeContextID == id { state.activeContextID = nil }
        }
    }
    /// Mail asks this when the owner presses Send. Mail Dot never holds a message back here: it only notes
    /// which message a reply answers, so that it knows the owner replied without asking Mail's scripting.
    nonisolated func allowMessageSendForSession(_ session:MEComposeSession,completion:@escaping (Error?) -> Void) {
        let action=session.composeContext.action
        if action == .reply || action == .replyAll,
           let id=session.composeContext.originalMessage?.headers?.first(where:{ $0.key.lowercased() == "message-id" })?.value.first {
            try? MailTriageStore.shared().transaction { $0.noteOwnerReplied(messageID:id) }
        }
        completion(nil)
    }
    nonisolated func mailComposeSessionDidEnd(_ session:MEComposeSession) {
        try? BridgeStore.shared().transaction { state in
            let id = session.sessionID.uuidString
            state.contexts.removeValue(forKey:id)
            if state.activeContextID == id { state.activeContextID = nil }
        }
    }
    func viewController(for session:MEComposeSession) -> MEExtensionViewController {
        PanelTrace.note("Mail asked for the reply panel")
        return ReplyViewController(session:session)
    }
}

private func composeEnvelope(_ session:MEComposeSession) -> MailDraft {
    let message = session.mailMessage
    return MailDraft(id:-1,subject:message.subject,
                     sender:message.fromAddress.addressString ?? message.fromAddress.rawString,
                     to:message.toAddresses.map { $0.addressString ?? $0.rawString },
                     cc:message.ccAddresses.map { $0.addressString ?? $0.rawString },
                     bcc:message.bccAddresses.map { $0.addressString ?? $0.rawString },body:"",attachmentCount:-1)
}

@MainActor private final class ReplyViewController: MEExtensionViewController {
    private let session:MEComposeSession
    init(session:MEComposeSession) { self.session = session; super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { nil }
    override func viewDidAppear() {
        super.viewDidAppear()
        PanelTrace.note("the reply panel is on screen")
    }
    override func loadView() {
        PanelTrace.note("building the reply panel")
        defer { PanelTrace.note("the reply panel is built") }
        let session=self.session, contextID=session.sessionID.uuidString
        view = NSHostingView(rootView:ReplyPanelView(contextID:contextID,registerContext:{
            let envelope = composeEnvelope(session)
            let original = session.composeContext.originalMessage
            try BridgeStore.shared().transaction { state in
                if state.contexts[contextID] == nil {
                    var context = ReplyContext(id:contextID,envelope:envelope,
                        originalSubject:original?.subject ?? "",originalSender:original?.fromAddress.rawString ?? "",
                        originalMessageID:original?.headers?.first(where: { $0.key.lowercased() == "message-id" })?.value.first ?? "")
                    // A new message, not a reply or a forward: Dot drafts it only when asked, with a subject.
                    if session.composeContext.action == .newMessage { context.newMessage = true }
                    state.contexts[contextID] = context
                } else if state.contexts[contextID]?.snapshot == nil {
                    state.contexts[contextID]?.envelope = envelope
                }
            }
        },willShare:{
            // Nothing is asked of Mail here. The panel now reads the message as soon as it opens, and a
            // question put to Mail at that moment (the old diagnostic read the message's raw size) is one
            // Mail may be unable to answer while it is still showing the panel.
            PanelTrace.note("the reply panel asked for the message to be read")
        },refreshEnvelope:{
            try? BridgeStore.shared().transaction { state in
                guard var context = state.contexts[contextID] else { return }
                BridgeCoordinator.observeEnvelope(composeEnvelope(session),context:&context)
                state.contexts[contextID] = context
            }
        },trace:{ PanelTrace.note($0) }))
        preferredContentSize = NSSize(width:ReplyPanelView.size.width,height:ReplyPanelView.size.height)
    }
}

/// A few plain lines on what Mail asked of the extension and how far it got, kept in Mail Dot's own folder.
/// The system log is not readable from the tools that check Mail Dot, and a panel that fails to appear
/// leaves no other trace. It holds no mail content and is cut back when it grows.
enum PanelTrace {
    static func note(_ text:String) {
        guard let directory=try? BridgeStore.shared().directory else { return }
        let file=directory.appendingPathComponent("panel-trace.log")
        let line=Date().ISO8601Format()+" "+text+"\n"
        if let size=(try? FileManager.default.attributesOfItem(atPath:file.path)[.size]) as? Int,size > 65_536 { try? Data().write(to:file) }
        if let handle=try? FileHandle(forWritingTo:file) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf:Data(line.utf8)) }
        else { try? Data(line.utf8).write(to:file) }
    }
}

