import SwiftUI
import AppKit
import ApplicationServices
import BridgeCore
import BridgeAutomation
import UserNotifications
import AVFoundation
import NaturalLanguage
import MailKit
import OSLog

@main struct MailDotApp: App {
    @NSApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate
    // No menu bar item and no Dock icon (the owner's decision, 11 November 2026: Mail Dot lives inside Mail).
    // The app runs in the background because the Mail extension cannot do these things itself: place Dot's text
    // in a Mail draft, ask for the confirmation before a send, open a call, and keep the connection to Dot alive.
    // Its one window is the small about window, shown only when someone opens the app (owner decision, 14 November
    // 2026). Every setting is in Mail.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor final class CompanionDelegate: NSObject, NSApplicationDelegate {
    private var announcedSequence=UserDefaults.standard.integer(forKey:"announcedUpdateSequence")


    /// Announces each new update once.
    private func refreshUpdates() {
        guard let root=try? BridgeStore.shared().directory,let records=try? ScheduledMailUpdateStore(bridgeDirectory:root).read().records else { return }
        let fresh=records.filter { $0.sequence > announcedSequence && $0.unread }.sorted { $0.sequence < $1.sequence }
        guard let newest=records.map(\.sequence).max(),newest > announcedSequence else { return }
        // On first run there is a backlog; announce only the latest rather than a burst.
        for record in fresh.suffix(announcedSequence == 0 ? 1 : 3) {
            let content=UNMutableNotificationContent()
            content.title=String(localized:"Update from Dot")
            content.subtitle=record.update.title
            content.body=String((record.update.actionText.isEmpty ? record.update.summary : record.update.actionText).prefix(180))
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"update-\(record.sequence)",content:content,trigger:nil))
        }
        announcedSequence=newest
        UserDefaults.standard.set(newest,forKey:"announcedUpdateSequence")
    }

    // MARK: Calls with Dot

    /// A development or command-line run of this app (a preview drawn from a synthetic store, a probe, a
    /// one-shot switch) must never act for the owner. The background service wakes "the Mail Dot app" by
    /// address, and that wake can reach such a run instead of the installed app; on 11 November 2026 one
    /// did, and a layout check opened a voice chat. Every path that acts checks this first.
    private let inert=CommandLine.arguments.dropFirst().contains{$0.hasPrefix("--")} || ProcessInfo.processInfo.environment["MAILDOT_PREVIEW_STORE"] != nil
    private var openingCall=false
    /// The open questions at the last sweep of the notifications on screen; nil until the first sweep.
    private var sweptQuestions:Set<String>?
    nonisolated static let questionCategory="org.jgkarlin.MailBridge.question"
    nonisolated static let callActionID="org.jgkarlin.MailBridge.question.call"
    nonisolated static let answerActionID="org.jgkarlin.MailBridge.question.answer"
    nonisolated static let saveActionID="org.jgkarlin.MailBridge.question.save"
    nonisolated static let sendActionID="org.jgkarlin.MailBridge.question.send"
    nonisolated static let deliveryQuestionCategory="org.jgkarlin.MailBridge.question.delivery"

    /// A command with no page to show its refusal on puts it in an alert.
    func ownerCommand(_ refusal:String?,opensCall:Bool=true) {
        guard !inert else { return }
        if let refusal {
            let alert=NSAlert()
            alert.messageText=String(localized:"Mail Dot could not ask Dot")
            alert.informativeText=refusal
            NSApplication.shared.activate()
            alert.runModal()
        }
        speakReports()
        if opensCall { Task { await openRequestedCalls() } }
    }
    /// Opens the call for each fresh request that needs one, once. A request that waited too long is
    /// marked instead: the microphone must not come on long after the owner pressed.
    private func openRequestedCalls() async {
        guard !inert,!openingCall,let store=try? MailWorkflowStore.shared(),let state=try? store.read() else { return }
        for late in state.callsTooOldToLaunch() {
            try? store.transaction { $0.recordCallLaunch(requestID:late.id,started:false,note:"Mail Dot was not running when you asked, so no call was opened. Start a voice chat with Dot in ChatGPT, or ask again.") }
        }
        let waiting=state.callsAwaitingLaunch()
        guard !waiting.isEmpty else { return }
        openingCall=true; defer { openingCall=false }
        let before=NSWorkspace.shared.frontmostApplication
        defer {
            // Finding Dot's page can bring ChatGPT forward; once the call is open and Dot has been told why,
            // the owner is returned to where they were.
            if let before,before.bundleIdentifier != DotCallLauncher.chatGPTBundleID,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == DotCallLauncher.chatGPTBundleID { before.activate() }
        }
        // The owner hears none of the preliminaries: the speakers are silenced until the request has been
        // spoken to Dot, and put back exactly as they were on every path out of here.
        let voiceLine=DotCallCommands.voiceLineEnabled
        let speakers=voiceLine ? MacSpeakers.silence() : MacSpeakers.State(device:0,muted:nil,volume:nil)
        var speakersRestored = !voiceLine
        func restoreSpeakers() { if !speakersRestored { MacSpeakers.restore(speakers); speakersRestored=true } }
        defer { restoreSpeakers() }
        // For a call, the reason is also left with Dot in writing first, so its conversation holds it.
        var refusals:[String:DotCallLauncher.SayRefusal]=[:]
        var told:[MailWorkflowRequest]=[]
        let trace=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/Logs/tool-calls.log")
        // Each step Mail Dot takes for a call is noted with the request's own identifier, so one call can be followed
        // from the press to Dot's reading of the request. Identifiers only: never what the call is about.
        func step(_ text:String) { ToolCallLogStore.appendLine("\(Date().ISO8601Format()) call \(text)",to:trace) }
        // The call opens first and the message goes into it (owner's trial, 18 November 2026: with the message sent
        // ten seconds before the call the voice greeted him without it; sent into the open call, Dot acknowledged the
        // request at once and asked him to hold on while she looked it up). The earlier order, message first, is kept
        // for a test on a Mac.
        let callFirst = !UserDefaults.standard.bool(forKey:CallHandoff.messageFirstKey)
        func tell() async {
            for request in waiting {
                guard let prompt=DotCallPrompt.text(for:request,callOpen:callFirst) else { continue }
                step("request=\(request.id) made=\(request.createdAt.ISO8601Format())")
                if let refusal=await DotCallLauncher.say(prompt) { refusals[request.id]=refusal; step("request=\(request.id) message=notSent") }
                else { told.append(request); step("request=\(request.id) message=sent") }
            }
        }
        if !callFirst {
            await tell()
            // The call is held, briefly at most, for Dot to read each request it was just told of; it opens on the
            // read or at the limit. A message on screen is not Dot having read it, and neither is an open call
            // (owner's report, 18 November 2026). Where Dot has not read it yet, its first words ask the owner to hold on.
            if !told.isEmpty,let bridge=try? BridgeStore.shared() {
                let log=ToolCallLogStore(bridgeDirectory:bridge.directory)
                let limit=CallHandoff.limit(set:UserDefaults.standard.object(forKey:CallHandoff.limitKey) as? Double)
                let results=await CallHandoff.wait(for:told,limit:limit,records:{ (try? log.read()) ?? [] },pause:{ try? await Task.sleep(for:.milliseconds(400)) })
                for request in told {
                    switch results[request.id] {
                    case .read(let after)?: step("request=\(request.id) read=yes after=\(Int(after))s")
                    default: step("request=\(request.id) read=notYet after=\(Int(limit))s")
                    }
                }
            }
        }
        let outcome=await DotCallLauncher.start()
        step("launch requests=\(waiting.map(\.id).joined(separator:",")) started=\(outcome.started) order=\(callFirst ? "callFirst" : "messageFirst")")
        if callFirst,outcome.started { await tell() }
        // The request itself is spoken into the call, where Dot's voice answers what it hears.
        var spoken:Set<String>=[]
        var voiceNote:String?
        if outcome.started,voiceLine {
            if #available(macOS 14.2,*) {
                let line=DotVoiceLine()
                do {
                    try line.open()
                    // ChatGPT moves to its chosen microphone when that appears; wait to see it take this one.
                    var waited=0.0
                    while waited < 8,!DotVoiceLine.inUse(line.deviceID) { try? await Task.sleep(for:.milliseconds(250)); waited += 0.25 }
                    if DotVoiceLine.inUse(line.deviceID) {
                        try? await Task.sleep(for:.milliseconds(600))
                        for request in waiting {
                            guard let words=DotVoicePrompt.words(for:request) else { continue }
                            try await line.speak(words)
                            spoken.insert(request.id)
                        }
                        try? await Task.sleep(for:.milliseconds(300))
                    } else {
                        voiceNote="ChatGPT did not take the “Mail Dot Voice” microphone. In ChatGPT, open Settings, choose Voice, and set Microphone to Mail Dot Voice."
                    }
                } catch { voiceNote="Mail Dot could not speak into the call: \(error)" }
                line.close()
                let log=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/Logs/tool-calls.log")
                ToolCallLogStore.appendLine("\(Date().ISO8601Format()) voice spoken=\(spoken.count) of \(waiting.count) taken=\(voiceNote == nil)",to:log)
            } else { voiceNote="Speaking into the call needs macOS 14.2 or later." }
        }
        restoreSpeakers()
        var problem=outcome.explanation
        for request in waiting {
            if request.spoken == true {
                if spoken.contains(request.id) {
                    // Dot answers aloud in the call; there is no written report to wait for.
                    try? store.transaction { try $0.finishSpokenInCall(requestID:request.id) }
                } else {
                    // Could not be said in a call: hang up the bare call and ask Dot in writing; its report is read aloud here.
                    if outcome.started { await DotCallLauncher.hangUp() }
                    let note="Mail Dot could not ask Dot aloud in a call, so it asked in writing and will read the report here. "+(outcome.explanation ?? voiceNote ?? "")
                    try? store.transaction { $0.recordCallLaunch(requestID:request.id,started:false,note:note,prompted:false) }
                    if problem == nil { problem=voiceNote }
                }
            } else {
                let refusal=refusals[request.id]
                let note=outcome.explanation ?? (spoken.contains(request.id) || !voiceLine ? nil : voiceNote.map{"The call is open, but Dot was not told aloud why. \($0)"})
                if problem == nil { problem=note }
                try? store.transaction { $0.recordCallLaunch(requestID:request.id,started:outcome.started,note:note,prompted:refusal == nil) }
            }
        }
        speakReports()
        if let explanation=problem {
            let content=UNMutableNotificationContent()
            content.title=String(localized:"Mail Dot could not finish calling Dot")
            content.body=String(explanation.prefix(240))
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"call-\(UUID().uuidString)",content:content,trigger:nil))
        }
    }
    // MARK: Reading Dot's report aloud

    private let speaker=AVSpeechSynthesizer()
    /// Reads aloud, once, each spoken mail report Dot has answered. The words are Dot's summary; the voice is
    /// this Mac's, chosen for the language the summary is written in.
    private var acknowledgedReports=Set<String>()
    private func speakReports() {
        guard !inert,let store=try? MailWorkflowStore.shared(),let state=try? store.read() else { return }
        // When the request could not be spoken in a call and went in writing instead, say so at once,
        // since Dot's written report takes a minute or so.
        for request in state.requests where request.spoken == true && request.report == nil && request.callLaunch?.started == false && !acknowledgedReports.contains(request.id) {
            acknowledgedReports.insert(request.id)
            if Date().timeIntervalSince(request.createdAt) < 120 { speaker.speak(AVSpeechUtterance(string:"Asking Dot in writing for your mail report.")) }
        }
        let due=state.reportsToSpeak()
        for request in due {
            // Marked first, so a failure to speak can never turn into the report being read again and again.
            try? store.transaction { $0.markSpoken(requestID:request.id) }
            guard let text=SpokenReport.text(for:request) else { continue }
            let utterance=AVSpeechUtterance(string:text)
            let recognizer=NLLanguageRecognizer()
            recognizer.processString(text)
            let language=recognizer.dominantLanguage?.rawValue
            utterance.voice=language.flatMap{AVSpeechSynthesisVoice(language:$0)} ?? AVSpeechSynthesisVoice(language:AVSpeechSynthesisVoice.currentLanguageCode())
            speaker.speak(utterance)
            let log=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/Logs/tool-calls.log")
            ToolCallLogStore.appendLine("\(Date().ISO8601Format()) speech started characters=\(text.count) language=\(language ?? "default") stage=\(request.stage.rawValue) afterSeconds=\(Int(Date().timeIntervalSince(request.createdAt)))",to:log)
        }
    }
    func stopSpeaking() { speaker.stopSpeaking(at:.immediate) }

    /// Shows each of Dot's questions once, with a Call Dot action, and withdraws it when it is closed.
    private func announceQuestions() {
        guard !inert,let store=try? MailWorkflowStore.shared(),let state=try? store.read() else { return }
        let open=Set(state.questions.map(\.id))
        // Withdrawn by what is actually on screen, so a question closed while Mail Dot was not running goes too.
        if sweptQuestions != open {
            let center=UNUserNotificationCenter.current()
            center.getDeliveredNotifications { delivered in
                let stale=delivered.map(\.request.identifier).filter { $0.hasPrefix("question-") && !open.contains(String($0.dropFirst("question-".count))) }
                if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers:stale) }
            }
            sweptQuestions=open
        }
        for question in state.questions where question.notifiedAt == nil {
            let content=UNMutableNotificationContent()
            content.title=String(localized:"Dot has a question")
            content.body=question.text
            content.categoryIdentifier=DotCallCommands.offersDeliveryChoice(question) ? Self.deliveryQuestionCategory : Self.questionCategory
            content.userInfo=["questionID":question.id]
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"question-\(question.id)",content:content,trigger:nil))
            try? store.transaction { state in
                if let index=state.questions.firstIndex(where:{$0.id == question.id}) { state.questions[index].notifiedAt = .now }
            }
        }
    }
    /// The owner pressed Call Dot on a question's notification.
    fileprivate func callAbout(questionID:String) async {
        let context=(try? MailWorkflowStore.shared().read())?.questions.first{$0.id == questionID}?.contextID
        ownerCommand(DotCallCommands.call(contextID:context,questionID:questionID))
    }

    /// A failed Apply or Send must reach the owner even though the panel that started it has closed.
    private func announceFailure(of operation:NativeOperation,error:String) {
        guard ["apply","send","review"].contains(operation.kind) else { return }
        let content=UNMutableNotificationContent()
        content.title=operation.kind == "send" ? "Mail Dot could not send" : operation.kind == "apply" ? "Mail Dot could not place Dot’s text" : "Mail Dot could not ready the message"
        content.body=String(error.prefix(240))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"failure-"+operation.id,content:content,trigger:nil))
    }
    private let automation = MailAutomation()
    private let replyReader = MailReplyReader()
    private let replyActions=MailReplyActions()
    private let uiEditor=MailUIReplyEditor()
    private var processing = false
    private var reading = false
    private var worker: Task<Void,Never>?
    private var connectionWorker:Task<Void,Never>?
    private var nativeMailWorker:NativeMailWorker?
    private var mailSetupWorker:MailSetupWorker?
    private var compositionWorker:NativeCompositionWorker?

    /// Someone opened the app from Finder, Launchpad or Spotlight: not at login, not through one of its links.
    private var openedByPerson=false
    func applicationWillFinishLaunching(_ notification:Notification) {
        if let event=NSAppleEventManager.shared().currentAppleEvent,event.eventClass == AEEventClass(kCoreEventClass),event.eventID == AEEventID(kAEOpenApplication) {
            let loginItem=event.paramDescriptor(forKeyword:AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
            openedByPerson = !loginItem && CommandLine.arguments.count == 1
            // An automatic update starts the new copy by itself. It shows the window again only if the person had it
            // open when the update was installed; otherwise an update would put a window on screen unasked.
            if MailDotUpdater.relaunchedAfterUpdate { openedByPerson = MailDotUpdater.takeReopenWindow() }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--prepare-synthetic-native-message") || CommandLine.arguments.contains("--check-synthetic-body-roundtrip") { NSApplication.shared.setActivationPolicy(.prohibited) }
        #endif
        if CommandLine.arguments.contains("--check-synthetic-message-reading") || CommandLine.arguments.contains("--check-synthetic-recipient-menu") || CommandLine.arguments.contains("--check-synthetic-body-structure") || CommandLine.arguments.contains("--check-synthetic-attachment-structure") || CommandLine.arguments.contains("--check-installation") || CommandLine.arguments.contains("--check-keychain") {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Checks that the background helper can read a key saved in the Keychain through the app group. Only when no
        // key is saved: it saves a placeholder, asks the helper, and removes it. Prints a yes or no, never a key.
        if CommandLine.arguments.contains("--check-keychain") {
            if RuntimeSetup.hasKey() { print("KEYCHAIN_CHECK: skipped, a key is saved"); NSApplication.shared.terminate(nil); return }
            do {
                let runtime=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MailDotRuntime")
                try RuntimeSetup.storeKey("mail-dot-keychain-check",trustedPaths:[Bundle.main.bundlePath,runtime.path])
                let helper=Process(); let pipe=Pipe()
                helper.executableURL=runtime
                helper.arguments=["--check-key"]; helper.standardOutput=pipe
                try helper.run(); helper.waitUntilExit()
                let answer=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
                print("KEYCHAIN_CHECK: app saved it; helper says \(answer.trimmingCharacters(in:.whitespacesAndNewlines))")
            } catch { print("KEYCHAIN_CHECK_FAILED: \(error.localizedDescription)") }
            RuntimeSetup.deleteKey()
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--enable-background") || CommandLine.arguments.contains("--disable-background") {
            // Any local program can start this app with these switches, so the owner is asked, as for the links.
            guard confirmBackgroundChange(enabling:CommandLine.arguments.contains("--enable-background")) else {
                print("BACKGROUND_SERVICE_UNCHANGED")
                NSApplication.shared.terminate(nil)
                return
            }
            Task {
                do {
                    try await BackgroundConnection.setEnabled(CommandLine.arguments.contains("--enable-background"))
                    print("BACKGROUND_SERVICE_STATUS: \(BackgroundConnection.service.status.rawValue)")
                } catch { print("BACKGROUND_SERVICE_FAILED: \(error.localizedDescription)") }
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Development only, by hand: a stored automatic draft for one of the developer's synthetic test
        // messages (a Message-ID containing "maildot-synthetic" at example.invalid), as Dot's review of
        // arriving mail would leave it, so that the reply panel's use of stored drafts can be seen in Mail.
        // "--remove-test-draft <id>" takes it away again. Nothing else in the owner's store is touched.
        if let flag=CommandLine.arguments.firstIndex(where:{ ["--place-test-draft","--remove-test-draft"].contains($0) }),CommandLine.arguments.indices.contains(flag+1) {
            let wanted=CommandLine.arguments[flag+1]
            guard let id=MailMessageIdentity.normalized(wanted),id.contains("maildot-synthetic"),id.hasSuffix("@example.invalid") else {
                print("refused: only synthetic test messages"); NSApplication.shared.terminate(nil); return
            }
            do {
                try MailTriageStore.shared().transaction { state in
                    state.entries.removeAll{ $0.messageID.flatMap(MailMessageIdentity.normalized) == id }
                    guard CommandLine.arguments[flag] == "--place-test-draft" else { return }
                    var entry=MailTriageEntry(messageID:id,sender:"tanaka@example.invalid",senderName:"田中 愛子",subject:"Mail Dot synthetic test",receivedAt:Date(),
                                              verdict:MailTriage.Verdict(essential:true,reason:"developer test"),automatic:true)
                    entry.outcome = .drafted
                    entry.draft="田中様、\n\nTEST DRAFT stored by Mail Dot's developer, not written by Dot."
                    state.record(entry)
                }
                print("\(CommandLine.arguments[flag] == "--place-test-draft" ? "placed" : "removed") test draft for \(id)")
            } catch { print("failed: \(error.localizedDescription)") }
            NSApplication.shared.terminate(nil)
            return
        }
        #if DEBUG
        if CommandLine.arguments.contains("--check-synthetic-body-roundtrip") {
            Task {
                do { try await NativeBodyRoundtripProbe.run(); print("SYNTHETIC_BODY_ROUNDTRIP_COMPLETED") }
                catch { print("SYNTHETIC_BODY_ROUNDTRIP_STOPPED") }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--prepare-synthetic-native-message") {
            Task {
                do { print(try await NativeReplyProbe.run()) }
                catch { print("SYNTHETIC_REPLY_PROBE_FAILED: \(error.localizedDescription)") }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--check-synthetic-message-reading") || CommandLine.arguments.contains("--check-synthetic-recipient-menu") || CommandLine.arguments.contains("--check-synthetic-body-structure") || CommandLine.arguments.contains("--check-synthetic-attachment-structure") {
            // Development acceptance check: exact synthetic window only, no body output or Mail actions.
            Task {
                do {
                    let menu = CommandLine.arguments.contains("--check-synthetic-recipient-menu")
                    let attachment = CommandLine.arguments.contains("--check-synthetic-attachment-structure")
                    let structure = attachment || CommandLine.arguments.contains("--check-synthetic-body-structure")
                    let subject = attachment ? "Mail Dot current-build metadata test" : "Re: Mail Bridge synthetic reply test"
                    print(try await MailAccessibilityProbe().inspectReply(subject:subject,checkSyntheticValue:!menu && !structure,checkSyntheticMenu:menu,checkSyntheticStructure:structure))
                } catch { print("READING_CHECK_FAILED: \(error.localizedDescription)") }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let flag=CommandLine.arguments.firstIndex(where:{ $0 == "--export-state" || $0 == "--import-state" }),CommandLine.arguments.indices.contains(flag+1) {
            // The owner names where a backup goes or which file to restore; nothing is written elsewhere.
            let target=URL(fileURLWithPath:CommandLine.arguments[flag+1])
            let exporting=CommandLine.arguments[flag] == "--export-state"
            guard confirm(exporting ? "Export a Mail Dot backup?" : "Restore Mail Dot from a backup?",
                          detail:(exporting ? "Accounts, schedules and received updates will be written to:\n" : "Accounts, schedules and links will be replaced from:\n")+target.path,
                          action:exporting ? "Export" : "Restore") else {
                print("STATE_BACKUP_CANCELLED")
                NSApplication.shared.terminate(nil)
                return
            }
            do {
                let root=try BridgeStore.shared().directory
                if CommandLine.arguments[flag] == "--export-state" {
                    let info=Bundle.main.infoDictionary
                    let build="\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
                    print("STATE_EXPORTED: " + (try StateBackup.export(bridgeDirectory:root,to:target,build:build)).path)
                } else {
                    try StateBackup.restore(from:target,bridgeDirectory:root)
                    print("STATE_RESTORED")
                }
            } catch { print("STATE_BACKUP_FAILED: \(error.localizedDescription)") }
            NSApplication.shared.terminate(nil)
            return
        }
        #if DEBUG
        // Development only, by hand, after announcing it: records a call or spoken-report request in the owner's
        // real store, for the installed Mail Dot to carry out. A real call follows.
        if CommandLine.arguments.contains("--request-spoken-report") || CommandLine.arguments.contains("--request-call") {
            let refusal=CommandLine.arguments.contains("--request-call") ? DotCallCommands.call() : DotCallCommands.spokenReport()
            print("recorded=\(refusal == nil) \(refusal ?? "")")
            Task { try? await Task.sleep(for:.seconds(1)); NSApplication.shared.terminate(nil) }
            return
        }
        if let flag=CommandLine.arguments.firstIndex(of:"--observe-dot-call"),CommandLine.arguments.indices.contains(flag+2) {
            let seconds=Double(CommandLine.arguments[flag+1]) ?? 15,settle=Double(CommandLine.arguments[flag+2]) ?? 0
            let prime=CommandLine.arguments.indices.contains(flag+3) ? CommandLine.arguments[flag+3] : nil
            Task { print(await DotCallLauncher.observe(prime:prime,settle:settle,seconds:seconds)); NSApplication.shared.terminate(nil) }
            return
        }
        // Development only, by hand: answers the oldest open question as the Work with Dot page would, or
        // sends one message to Dot in ChatGPT.
        if let flag=CommandLine.arguments.firstIndex(of:"--answer-question"),CommandLine.arguments.indices.contains(flag+1) {
            let open=(try? MailWorkflowStore.shared().read())?.questions ?? []
            if let question=open.first {
                let refusal=DotCallCommands.answer(questionID:question.id,text:CommandLine.arguments[flag+1])
                print("open=\(open.count) answered=\(refusal == nil) \(refusal ?? "")")
            } else { print("no open question") }
            Task { try? await Task.sleep(for:.seconds(1)); NSApplication.shared.terminate(nil) }
            return
        }
        // Development only, by hand: places a test question in the owner's real store, as Dot's ask_owner would.
        if CommandLine.arguments.contains("--ask-test-question") {
            do {
                let question=try MailWorkflowStore.shared().transaction { try $0.ask("Test question from Mail Dot's developer, about no real mail: shall I draft and save, or draft and send?",contextID:nil) }
                print("asked=\(question.id.prefix(8))")
            } catch { print("failed: \(error.localizedDescription)") }
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--count-questions") {
            let open=(try? MailWorkflowStore.shared().read())?.questions ?? []
            print("open=\(open.count) answered=\(open.filter{$0.answer != nil}.count) lengths=\(open.map{$0.text.count}) deliveryChoice=\(open.map{DotCallCommands.offersDeliveryChoice($0)})")
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag=CommandLine.arguments.firstIndex(of:"--say-to-dot"),CommandLine.arguments.indices.contains(flag+1) {
            Task {
                let front=NSWorkspace.shared.frontmostApplication
                let refusal=await DotCallLauncher.say(CommandLine.arguments[flag+1])
                print("sent=\(refusal == nil) \(refusal?.rawValue ?? "")")
                front?.activate()
                NSApplication.shared.terminate(nil)
            }
            return
        }
        // Development only, by hand. "hold <seconds>" keeps the voice device present so it can be chosen in
        // ChatGPT's settings. "call <seconds> [words]" opens a real call with Dot (announce first), then
        // creates the device, speaks into it, removes it, and hangs up after the wait, reporting at each step
        // which microphone is in use.
        if let flag=CommandLine.arguments.firstIndex(of:"--trial-voice-line"),CommandLine.arguments.indices.contains(flag+1) {
            let mode=CommandLine.arguments[flag+1]
            let wait=CommandLine.arguments.indices.contains(flag+2) ? Double(CommandLine.arguments[flag+2]) ?? 30 : 30
            let words=CommandLine.arguments.indices.contains(flag+3) ? CommandLine.arguments[flag+3] : "Dot, give me my spoken mail report now."
            setvbuf(stdout,nil,_IONBF,0)
            Task {
                if #available(macOS 14.2,*) {
                    let line=DotVoiceLine()
                    let microphone=DotVoiceLine.defaultInput
                    @MainActor func state(_ label:String) { print("\(label): realMicInUse=\(DotVoiceLine.inUse(microphone)) voiceDeviceInUse=\(line.isOpen ? DotVoiceLine.inUse(line.deviceID) : false) \(DotCallLauncher.probe())") }
                    do {
                        if mode == "hold" {
                            try line.open()
                            print("holding \(DotVoiceLine.deviceName) for \(Int(wait)) s")
                            var elapsed=0.0
                            while elapsed < wait { try? await Task.sleep(for:.seconds(5)); elapsed += 5; if DotVoiceLine.inUse(line.deviceID) { print("in use at +\(Int(elapsed)) s") } }
                        } else {
                            let front=NSWorkspace.shared.frontmostApplication
                            let quiet=MacSpeakers.silence()
                            let outcome=await DotCallLauncher.start()
                            print("call outcome=\(outcome)")
                            front?.activate()
                            try? await Task.sleep(for:.seconds(1.5))
                            state("call open")
                            try line.open()
                            var waited=0.0
                            while waited < 6,!DotVoiceLine.inUse(line.deviceID) { try? await Task.sleep(for:.milliseconds(250)); waited += 0.25 }
                            state("device created, waited \(waited) s")
                            async let loudest=line.peak(for:8)
                            try await line.speak(words)
                            state("spoken")
                            line.close()
                            MacSpeakers.restore(quiet)
                            print("loudest sample on the device=\(await loudest)")
                            for second in [1,3,6] { try? await Task.sleep(for:.seconds(second == 1 ? 1 : second == 3 ? 2 : 3)); state("+\(second) s after removing the device") }
                            try? await Task.sleep(for:.seconds(max(0,wait-6)))
                            print("hangUp=\(await DotCallLauncher.hangUp())")
                            front?.activate()
                        }
                    } catch { print("failed: \(error)") }
                    line.close()
                } else { print("needs macOS 14.2") }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--probe-voice-settings") {
            Task { print(await DotCallLauncher.probeVoiceSettings()); NSApplication.shared.terminate(nil) }
            return
        }
        if CommandLine.arguments.contains("--probe-dot-marker") {
            print(DotCallLauncher.probeCallMarker())
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--probe-dot-records") {
            print(DotCallLauncher.probeCallRecords())
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--probe-dot-control") {
            print(DotCallLauncher.probeControlTree())
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--probe-dot-composer") {
            print(DotCallLauncher.probeComposer())
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--hang-up-dot-call") {
            Task {
                print("hangUp=\(await DotCallLauncher.hangUp())")
                try? await Task.sleep(for:.seconds(2))
                print(DotCallLauncher.probe())
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--probe-dot-call") {
            print(DotCallLauncher.probe())
            NSApplication.shared.terminate(nil)
            return
        }
        // Development only, and only by hand: places one real call with Dot, reports what ChatGPT showed,
        // and hangs up after the given number of seconds. It opens the microphone, so announce it first.
        if let flag=CommandLine.arguments.firstIndex(of:"--try-dot-call") {
            let seconds=CommandLine.arguments.indices.contains(flag+1) ? Double(CommandLine.arguments[flag+1]) ?? 5 : 5
            Task {
                let outcome=await DotCallLauncher.start()
                print("outcome=\(outcome) \(DotCallLauncher.probe())")
                try? await Task.sleep(for:.seconds(seconds))
                print("before hang up: \(DotCallLauncher.probe())")
                print("hangUp=\(await DotCallLauncher.hangUp())")
                try? await Task.sleep(for:.seconds(3))
                print("after hang up: \(DotCallLauncher.probe())")
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--probe-compose-structure") {
            Task {
                for line in await uiEditor.probeStructure() { print(line) }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        // Development only, by hand: places in the owner's real store a clearly marked test report bound to
        // one message's Message-ID, as Dot's report tool would, so the banner and panel can be seen in Mail;
        // and removes it again. Uses the first linked schedule and its first account.
        if let flag=CommandLine.arguments.firstIndex(of:"--place-test-report"),CommandLine.arguments.indices.contains(flag+1) {
            do {
                let directory=try BridgeStore.shared().directory
                let settings=try MailSettingsStore(bridgeDirectory:directory).read()
                let accounts=try MailWorkflowAccount.available(settings:settings,native:NativeMailStore(bridgeDirectory:directory).read())
                let candidates=settings.schedules.filter{settings.linkedScheduleIDs.contains($0.id) && $0.enabled && $0.available && $0.observedAt != nil}
                let pair=candidates.lazy.compactMap { schedule in
                    accounts.first{account in schedule.sources.contains{$0.kind == account.route && $0.id == account.sourceID && (account.route != "gmail" || $0.connectionID == account.connectionID)}}.map{(schedule,$0)}
                }.first
                guard let (schedule,account)=pair else {
                    print("no linked schedule and account: schedules=\(settings.schedules.count) linked=\(settings.linkedScheduleIDs.count) usable=\(candidates.count) accounts=\(accounts.count) sources=\(candidates.map{$0.sources.count})")
                    NSApplication.shared.terminate(nil); return
                }
                let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                // "from:<address>|<subject>" places a report that names no Message-ID, to be found by sender and subject.
                let argument=CommandLine.arguments[flag+1]
                let byHeaders=argument.hasPrefix("from:") ? argument.dropFirst(5).split(separator:"|",maxSplits:1).map(String.init) : nil
                let fields:[String:Any]=["id":byHeaders == nil ? "maildot-developer-test" : "maildot-developer-test-headers","scheduleID":schedule.id,"runID":"developer-test","revision":Int(Date().timeIntervalSince1970) % 1_000_000,"accountIDs":[account.id],"sourceIDs":[byHeaders == nil ? argument : "developer-test-headers"],
                    "title":"TEST REPORT placed by Mail Dot’s developer","summary":"This is a test report, not Dot’s. It checks that a report shows on its message inside Mail.","action":"decision","actionText":"Nothing to decide; this is a test.",
                    "checkedAt":Date().addingTimeInterval(-30).ISO8601Format(),"coverage":"Synthetic test content. No mail was read."]
                var update=try decoder.decode(ScheduledMailUpdate.self,from:JSONSerialization.data(withJSONObject:fields))
                update.message=byHeaders.map{MailUpdateMessage(sender:$0[0],subject:$0.count > 1 ? $0[1] : "",receivedAt:Date())} ?? MailUpdateMessage(sender:"Mail Dot developer test",messageID:argument)
                update.summaryPoints=["This is a test report placed by Mail Dot’s developer, not written by Dot.","It checks that Dot’s report appears on its message inside Mail, with options and actions."]
                update.unverified=["everything; the content is synthetic"]
                update.status = .awaitingInstruction
                update.decision=MailUpdateDecision(question:"Test question: which option should be chosen?",options:[
                    MailUpdateOption(id:"reply",label:"Test option that drafts a reply",detail:"Offers Draft and Save and Draft and Send.",effect:.draftReply,replyPreview:"This is the test reply Dot would draft."),
                    MailUpdateOption(id:"resolve",label:"Test option that Dot acts on",detail:"Offers Apply.",effect:.resolve),
                    MailUpdateOption(id:"ignore",label:"Test option that ignores",detail:"Closes this report; the message stays in Mail.",effect:.ignore)],recommended:"resolve")
                update.work=[MailUpdateWork(state:.done,text:"Test entry: something Dot completed",source:.drive),MailUpdateWork(state:.needsOwner,text:"Test entry: something Dot could not resolve",source:.none)]
                try ScheduledMailUpdateStore(bridgeDirectory:directory).transaction { state in
                    state.discard(update.key)
                    try state.accept(update,settings:settings,accounts:accounts)
                    try state.markRead(update.key,revision:update.revision)
                }
                print("placed test report for \(byHeaders.map{"sender and subject (\($0.count) parts)"} ?? MailMessageIdentity.normalized(argument) ?? "invalid id")")
            } catch { print("failed: \(error.localizedDescription)") }
            NSApplication.shared.terminate(nil)
            return
        }
        // Development only, by hand: asks Mail for the owner's own Mail Dot test messages (subject contains
        // "Mail Dot"), printing account, subject and Message-ID; or opens one message in its own Mail window.
        if CommandLine.arguments.contains("--find-test-messages") || CommandLine.arguments.contains("--open-message") {
            let wanted=CommandLine.arguments.firstIndex(of:"--open-message").flatMap{CommandLine.arguments.indices.contains($0+1) ? CommandLine.arguments[$0+1] : nil}
            let source=wanted == nil ? """
            tell application "Mail"
              set out to ""
              repeat with acc in accounts
                try
                  set found to (messages of mailbox "INBOX" of acc whose subject contains "Mail Dot")
                  set n to 0
                  repeat with m in found
                    set out to out & (name of acc) & " | " & (subject of m) & " | " & (message id of m) & linefeed
                    set n to n + 1
                    if n > 4 then exit repeat
                  end repeat
                end try
              end repeat
              return out
            end tell
            """ : """
            tell application "Mail"
              repeat with acc in accounts
                try
                  set found to (messages of mailbox "INBOX" of acc whose message id is "\(wanted!.replacingOccurrences(of:"\"",with:""))")
                  if (count of found) > 0 then
                    open (item 1 of found)
                    return "opened"
                  end if
                end try
              end repeat
              return "not found"
            end tell
            """
            var failure:NSDictionary?
            let result=NSAppleScript(source:source)?.executeAndReturnError(&failure)
            print(result?.stringValue ?? "error: \(failure?[NSAppleScript.errorMessage] ?? "unknown")")
            NSApplication.shared.terminate(nil)
            return
        }
        // Development only: a scripted sequence on Mail Dot's own report panel in Mail. Steps: show, press:<label>,
        // key:<name>, wait:<seconds>. Each "show" prints the panel's buttons and short texts.
        if let flag=CommandLine.arguments.firstIndex(of:"--panel") {
            setvbuf(stdout,nil,_IONBF,0)
            let steps=Array(CommandLine.arguments.dropFirst(flag+1))
            Task {
                for step in steps {
                    let parts=step.split(separator:":",maxSplits:1).map(String.init)
                    switch parts.first {
                    case "show": print("--- panel\n"+MailViewerProbe.describePanel())
                    case "rawkey": print(MailViewerProbe.keyToPanel(parts.count > 1 ? parts[1] : "",trusting:true)); try? await Task.sleep(for:.milliseconds(1200))
                    case "raise": print(MailViewerProbe.raiseTestWindow())
                    case "composebutton": print(MailViewerProbe.pressComposeButton())
                    case "wclick":
                        let numbers=(parts.count > 1 ? parts[1] : "").split(separator:",").compactMap{Double($0)}
                        if numbers.count == 2 { print(MailViewerProbe.clickInTestWindow(x:numbers[0],y:numbers[1])); try? await Task.sleep(for:.milliseconds(900)) }
                    case "wtype": print(MailViewerProbe.typeInTestWindow(parts.count > 1 ? parts[1] : "",key:false)); try? await Task.sleep(for:.milliseconds(600))
                    case "wkey": print(MailViewerProbe.typeInTestWindow(parts.count > 1 ? parts[1] : "",key:true)); try? await Task.sleep(for:.milliseconds(900))
                    case "wshot": print(MailViewerProbe.captureTestWindow(to:parts.count > 1 ? parts[1] : "/dev/null"))
                    case "controls": print("--- controls\n"+MailViewerProbe.describeExtension())
                    case "shot": print(MailViewerProbe.capturePanel(to:parts.count > 1 ? parts[1] : "/dev/null"))
                    case "clickat":
                        let numbers=(parts.count > 1 ? parts[1] : "").split(separator:",").compactMap{Double($0)}
                        if numbers.count == 2 { print(MailViewerProbe.clickInPanel(x:numbers[0],y:numbers[1])); try? await Task.sleep(for:.milliseconds(1200)) }
                    case "click": print(MailViewerProbe.pressInExtension(parts.count > 1 ? parts[1] : "")); try? await Task.sleep(for:.milliseconds(1200))
                    case "press": print(MailViewerProbe.pressInPanel(parts.count > 1 ? parts[1] : "")); try? await Task.sleep(for:.milliseconds(1200))
                    case "key": print(MailViewerProbe.keyToPanel(parts.count > 1 ? parts[1] : "")); try? await Task.sleep(for:.milliseconds(1200))
                    case "wait": try? await Task.sleep(for:.seconds(Double(parts.count > 1 ? parts[1] : "1") ?? 1))
                    default: print("unknown step \(step)")
                    }
                }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--probe-test-message") { print(MailViewerProbe.describe()); NSApplication.shared.terminate(nil); return }
        if let flag=CommandLine.arguments.firstIndex(of:"--press-in-test-message"),CommandLine.arguments.indices.contains(flag+1) {
            print(MailViewerProbe.press(CommandLine.arguments[flag+1])); NSApplication.shared.terminate(nil); return
        }
        if CommandLine.arguments.contains("--close-test-messages") { let panels=MailViewerProbe.closePanels(); usleep(400_000); print("closed \(MailViewerProbe.closeTestWindows()) message window(s), \(panels) panel(s)"); NSApplication.shared.terminate(nil); return }
        if let flag=CommandLine.arguments.firstIndex(of:"--close-window-at"),CommandLine.arguments.indices.contains(flag+1) {
            let numbers=CommandLine.arguments[flag+1].split(separator:",").compactMap{Double($0)}
            print(numbers.count == 2 ? MailViewerProbe.closeWindow(atX:numbers[0],y:numbers[1]) : "give x,y"); NSApplication.shared.terminate(nil); return
        }
        if CommandLine.arguments.contains("--mail-window-shapes") { print(MailViewerProbe.windowShapes()); NSApplication.shared.terminate(nil); return }
        if CommandLine.arguments.contains("--count-header-icons") { print(MailViewerProbe.countHeaderIcons()); NSApplication.shared.terminate(nil); return }
        if CommandLine.arguments.contains("--remove-test-report") {
            do {
                let directory=try BridgeStore.shared().directory
                let removed=try ScheduledMailUpdateStore(bridgeDirectory:directory).transaction { state -> Int in
                    let ids=state.records.filter{$0.update.id.hasPrefix("maildot-developer-test")}.map(\.id)
                    ids.forEach{state.discard($0)}
                    return ids.count
                }
                try MailWorkflowStore(bridgeDirectory:directory).transaction { state in
                    for request in state.requests where request.instruction?.updateID.hasPrefix("maildot-developer-test") == true { try state.dismiss(request.id) }
                }
                print("removed \(removed) test report(s)")
            } catch { print("failed: \(error.localizedDescription)") }
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag=CommandLine.arguments.firstIndex(of:"--ui-harness"),CommandLine.arguments.indices.contains(flag+1) {
            setvbuf(stdout,nil,_IONBF,0)
            Task {
                await PreviewRenderer.harness(steps:Array(CommandLine.arguments.dropFirst(flag+2)),to:URL(fileURLWithPath:CommandLine.arguments[flag+1],isDirectory:true))
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let flag=CommandLine.arguments.firstIndex(of:"--render-previews"),CommandLine.arguments.indices.contains(flag+1) {
            Task {
                await PreviewRenderer.render(to:URL(fileURLWithPath:CommandLine.arguments[flag+1],isDirectory:true))
                NSApplication.shared.terminate(nil)
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--check-installation") {
            do {
                let store = try BridgeStore.shared()
                try store.transaction { $0.audit.append("Signed companion accessed the shared container.") }
                try MailAutomation.validateScript()
                print("SHARED_GROUP_OK MAIL_SCRIPT_OK")
            } catch { print("INSTALLATION_CHECK_FAILED: \(error.localizedDescription)") }
            NSApplication.shared.terminate(nil)
            return
        }
        do {
            try BridgeStore.shared().transaction { state in
                for id in state.contexts.keys { state.contexts[id]?.uiEditorToken=nil }
                for index in state.operations.indices where state.operations[index].claimedAt != nil && state.operations[index].result == nil && state.operations[index].error == nil {
                    state.operations[index].error = "Mail Dot stopped during this action. Inspect Mail; it will not be replayed automatically."
                    state.contexts[state.operations[index].contextID]?.localStatus = state.operations[index].error!
                }
            }
        } catch { /* The native connection status reports storage errors. */ }
        do {
            let store=try NativeMailStore.shared()
            try store.transaction { state in
                for index in state.operations.indices where state.operations[index].claimedAt != nil && state.operations[index].result == nil && state.operations[index].error == nil {
                    NativeMailCoordinator.fail(state.operations[index].id,error:"Mail Dot restarted during this read. Request a fresh read.",state:&state)
                }
                for index in state.setupOperations.indices where state.setupOperations[index].claimedAt != nil && state.setupOperations[index].result == nil && state.setupOperations[index].error == nil {
                    MailSetupCoordinator.fail(state.setupOperations[index].id,error:"Mail Dot restarted during setup. Refresh to try again.",state:&state)
                }
            }
            nativeMailWorker=NativeMailWorker(store:store)
            mailSetupWorker=MailSetupWorker(store:store)
        } catch { /* Native account settings reports storage errors. */ }
        do {
            let bridge=try BridgeStore.shared()
            try NativeCompositionStore(bridgeDirectory:bridge.directory).transaction{$0.recoverInterrupted()}
            compositionWorker=NativeCompositionWorker(bridgeDirectory:bridge.directory)
        } catch { /* The menu reports creation-state failures. */ }
        BackgroundConnection.repairAgentPathIfMoved()
        configureNotifications()
        // A voice device left by a run that ended badly is removed, so ChatGPT is never left listening to it.
        if #available(macOS 14.2,*) { DotVoiceLine.removeStale() }
        AskDotController.shared.start()
        if !inert { MailQuitWatch.shared.start(); MailDotOutsideClick.shared.start() }
        if !inert { MailDotUpdater.shared.start() }
        // A setup entry left in ChatGPT's settings by a run that ended without warning goes at the next start: no
        // setup window is open at this moment, and pressing Ask Dot to Continue writes it again (review, M9).
        if !inert { SetupCodexEntry.remove() }
        connectionWorker=Task {
            while !Task.isCancelled {
                await AskDotController.shared.tick()
                await BackgroundConnection.publishStatus()
                self.refreshUpdates()
                self.announceQuestions()
                // Mail Dot posts no notifications about drafts (the owner's decision of 12 November 2026):
                // a draft's state is shown in the reply panel and on the message's banner instead.
                await self.checkTriage()
                await self.openRequestedReply()
                self.retireCoveredGrants()
                if !self.inert { await ConnectionWatch.tick(); SetupCodexEntry.tick(); SetupCodexEntry.forgetWhenVerified(); MailIndexRunner.shared.tickLocal() }
                self.speakReports()
                self.withdrawStaleConfirmations()
                try? await Task.sleep(for:.seconds(5))
            }
        }
        worker = Task { [weak self] in
            if let self {
                let permission = await self.automation.permissionStatus()
                try? BridgeStore.shared().transaction { $0.mailPermissionStatus = permission }
            }
            while !Task.isCancelled {
                await self?.processOperations()
                await self?.openRequestedCalls()
                // No mail read, setup or draft creation starts while an Apply, review or Send is running.
                if let self,!self.processing {
                    self.reading=true
                    await self.compositionWorker?.processNext()
                    await self.mailSetupWorker?.processNext()
                    await self.nativeMailWorker?.processNext()
                    if !self.inert { await MailIndexRunner.shared.tick() }
                    self.reading=false
                }
                // Requests wake the companion directly; this loop is only the fallback, so it need not spin.
                try? await Task.sleep(for:.seconds(2))
            }
        }
        // Until Mail Dot has a connection, opening the app shows setup instead (owner request, 14 November 2026).
        // Setup opens by itself whenever Mail Dot starts and is not set up, however it was started (owner's
        // direction, 18 November 2026: a new user who closed the setup window was left with no way to it). The
        // About window still opens only when a person opened the app.
        if MailDotSetupWindow.shown,!inert { MailDotSetupWindow.shared.show() }
        else if openedByPerson { MailDotAboutWindow.shared.show() }
    }
    /// Removal is under way: nothing writes to Mail Dot's stores again.
    func stopForRemoval() { removing=true; worker?.cancel(); connectionWorker?.cancel() }
    private var removing=false
    func applicationWillTerminate(_ notification: Notification) {
        worker?.cancel(); connectionWorker?.cancel()
        // The setup entry in ChatGPT's settings does not stay behind when Mail Dot quits.
        if !inert,!removing { SetupCodexEntry.remove() }
    }
    /// Opening the app again shows its small about window.
    func applicationShouldHandleReopen(_ sender:NSApplication, hasVisibleWindows:Bool) -> Bool {
        guard !removing else { return false }
        if MailDotSetupWindow.shown { MailDotSetupWindow.shared.show() } else { MailDotAboutWindow.shared.show() }
        return false
    }
    /// Once Mail Dot is removed, closing its last window ends it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { removing }
    func application(_ application: NSApplication, open urls:[URL]) {
        guard !inert,!removing else { return }
        if let command=urls.first(where:{ $0.scheme == "mailbridge" && ["enable-background","disable-background"].contains($0.host ?? "") }) {
            // Any app or web link can open this address, so the owner confirms before the service changes.
            guard confirmBackgroundChange(enabling:command.host == "enable-background") else {
                Task { await BackgroundConnection.publishStatus() }
                return
            }
            Task {
                do { try await BackgroundConnection.setEnabled(command.host == "enable-background"); await BackgroundConnection.publishStatus() }
                catch { await BackgroundConnection.publishStatus() }
            }
            return
        }

        Task { await AskDotController.shared.tick(); await processOperations(); announceQuestions(); speakReports(); await openRequestedCalls(); await ConnectionWatch.tick() }
    }

    private func processOperations() async {
        guard !inert,!processing else { return }
        processing = true; defer { processing = false }
        // Mail scripts share the main thread with Apply's own checks. A mail read that coincided with typing
        // could push those checks past their time limit, so an edit waits for a read in flight to finish.
        var waited=0
        while reading && waited < 150 { try? await Task.sleep(for:.milliseconds(100)); waited += 1 }
        do {
            let store = try BridgeStore.shared()
            while let pending = try store.read().operations.first(where: { $0.claimedAt == nil && $0.result == nil && $0.error == nil }) {
                try store.transaction { state in
                    guard let index = state.operations.firstIndex(where: { $0.id == pending.id }) else { throw BridgeFailure("Operation disappeared.") }
                    state.operations[index].claimedAt = .now
                }
                if let refusal = pending.refusalIfTooOld() {
                    try finish(pending, store:store, result:nil, error:refusal)
                    continue
                }
                do {
                    let result = try await execute(pending, store:store)
                    try finish(pending, store:store, result:result, error:nil)
                } catch {
                    try finish(pending, store:store, result:nil, error:error.localizedDescription)
                }
            }
        } catch { /* The popover surfaces shared-container failures directly. */ }
    }

    // MARK: Accounts Dot now reaches through a plugin

    /// An account set up through AppleScript, which Dot now reaches through its ChatGPT plugin (iCloud Mail or Gmail),
    /// switches to the plugin: its folder permission is withdrawn, its Search by Meaning is switched off, and with that
    /// the background app removes its part of the index and its embeddings (owner decision, 15 November 2026).
    private func retireCoveredGrants() {
        guard !inert,let bridge=try? BridgeStore.shared(),let settings=try? MailSettingsStore(bridgeDirectory:bridge.directory).read() else { return }
        let nativeStore=NativeMailStore(bridgeDirectory:bridge.directory)
        guard let native=try? nativeStore.read() else { return }
        let covered=Set(native.grants.filter{ $0.revokedAt == nil && MailIndexPass.coveredByConnector(account:$0.accountID,settings:settings) }.map(\.accountID))
        guard !covered.isEmpty else { return }
        try? nativeStore.transaction { state in for id in covered { NativeMailCoordinator.revoke(accountID:id,state:&state) } }
        try? MailSettingsStore(bridgeDirectory:bridge.directory).transaction { value in
            for id in covered where value.searchByMeaning(account:id) { value.setSearchByMeaning(false,account:id) }
        }
        Logger(subsystem:"org.jgkarlin.MailBridge",category:"accounts").info("\(covered.count,privacy:.public) account(s) now reached through a plugin: AppleScript access withdrawn")
    }

    // MARK: Open in Reply

    private var openingReply=false
    /// Open in Reply (owner decision, 15 November 2026): a Mail reply to the message, opened as the owner's Reply would
    /// open it, with Dot's draft put at its top by the same steps as Insert on the reply panel. Nothing is sent: the owner
    /// edits and sends from Mail. It waits while a Mail Dot window is open, since Mail holds its other windows meanwhile.
    private func openRequestedReply() async {
        guard !inert,!openingReply,let store=try? MailTriageStore.shared() else { return }
        // With Mail closed no Mail Dot window is open, whatever the store last heard; a reply waits for Mail.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").isEmpty else {
            if (try? store.read())?.mailDotWindowOpenAt != nil { try? store.transaction { $0.mailDotWindowOpenAt=nil } }
            return
        }
        // Mail holds a reply waiting while the Mail Dot window is open. What Mail itself shows is believed first; the
        // note the extension keeps is the fallback.
        let windowOpen=AXIsProcessTrusted() ? MailDotWindowCloser.open() > 0 : (try? store.read())?.mailDotWindowOpenAt.map{ Date().timeIntervalSince($0) < 3600 } ?? false
        if windowOpen {
            // Open in Reply was pressed in that window: Mail Dot closes it by its own close button, so the reply can open.
            // A draft that simply arrived while the window is open waits for the owner to close it.
            guard (try? store.read())?.entries.contains(where:{ $0.openReplyClosesWindow == true && $0.openReplyRequestedAt != nil }) == true else { return }
            guard await MailDotWindowCloser.closeAndWait() else {
                Logger(subsystem:"org.jgkarlin.MailBridge",category:"Reply").error("Open in Reply: the Mail Dot window did not close when its close button was pressed")
                return
            }
        }
        guard let entry=(try? store.transaction({ $0.nextReplyToOpen() })) ?? nil,let messageID=entry.messageID else { return }
        openingReply=true; defer { openingReply=false }
        let log=Logger(subsystem:"org.jgkarlin.MailBridge",category:"Reply")
        let contextID="open-"+entry.id
        do {
            let bridge=try BridgeStore.shared()
            let reply=try await automation.openReply(toMessageID:messageID)
            try bridge.transaction { state in
                var context=ReplyContext(id:contextID,envelope:reply,originalSubject:entry.subject,originalSender:entry.sender,originalMessageID:messageID)
                BridgeCoordinator.ownerOpensPanel(context:&context)
                context.ownerRequest?.delivery = .save
                state.contexts[contextID]=context; state.activeContextID=contextID
                state.operations.removeAll{ $0.contextID == contextID }
            }
            // Mail draws the reply first; it is read once it is on screen, with a few tries while it loads.
            var shared=false
            for attempt in 0..<5 where !shared {
                try? await Task.sleep(for:.seconds(attempt == 0 ? 1.5 : 2))
                try bridge.transaction { $0.operations.append(NativeOperation(contextID:contextID,kind:"share")) }
                await processOperations()
                shared=try bridge.read().contexts[contextID]?.snapshot != nil
            }
            guard shared else {
                let reason=try bridge.read().operations.last{ $0.contextID == contextID && $0.kind == "share" }?.error
                throw BridgeFailure(reason ?? String(localized:"Mail Dot could not read the new reply."))
            }
            // Reading the reply puts Dot's stored draft in it as the proposal, without asking Dot again.
            if try bridge.read().contexts[contextID]?.proposal == nil { StoredDraft.adopt(contextID:contextID) }
            try bridge.transaction { state in
                guard let context=state.contexts[contextID],let snapshot=context.snapshot,let proposal=context.proposal else {
                    throw BridgeFailure(String(localized:"Dot’s draft could not be put in the reply."))
                }
                try BridgeCoordinator.enqueueApply(contextID:contextID,displayedFingerprint:snapshot.fingerprint,displayedProposalRevision:proposal.revision,reviewedBody:proposal.body,state:&state)
            }
            await processOperations()
            if let failed=try bridge.read().operations.last(where:{ $0.contextID == contextID && $0.kind == "apply" })?.error { throw BridgeFailure(failed) }
            try? store.transaction { $0.noteReplyOpened(entry.id,failure:nil) }
            log.info("opened a reply with Dot's draft")
        } catch {
            let first=error.localizedDescription.split(separator:"\n").first.map(String.init) ?? error.localizedDescription
            try? store.transaction { $0.noteReplyOpened(entry.id,failure:String(localized:"The reply could not be opened with Dot’s draft: ")+first) }
            log.error("Open in Reply failed: \(error.localizedDescription,privacy:.public)")
        }
        // The reply is the owner's now; Mail Dot keeps no hold on it.
        try? BridgeStore.shared().transaction { state in
            state.contexts.removeValue(forKey:contextID)
            state.operations.removeAll{ $0.contextID == contextID }
            if state.activeContextID == contextID { state.activeContextID=nil }
        }
    }

    private func confirmBackgroundChange(enabling:Bool) -> Bool {
        confirm(enabling ? String(localized:"Start Mail Dot at login?") : String(localized:"Turn off Mail Dot’s background connection?"),
                detail:enabling ? String(localized:"Mail Dot will keep its connection to Dot available whenever you are logged in.")
                    : String(localized:"Dot will not be able to reach Mail on this Mac until you turn it on again."),
                action:enabling ? String(localized:"Start at Login") : String(localized:"Turn Off"))
    }
    private func confirm(_ message:String,detail:String,action:String) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps:true)
        let alert=NSAlert()
        alert.messageText=message; alert.informativeText=detail
        alert.addButton(withTitle:action)
        alert.addButton(withTitle:String(localized:"Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Confirming act before a "draft and send" mail

    private static let confirmCategory="org.jgkarlin.MailBridge.confirmSend"
    nonisolated static let confirmActionID="org.jgkarlin.MailBridge.confirmSend.confirm"
    nonisolated static let declineActionID="org.jgkarlin.MailBridge.confirmSend.decline"

    private func configureNotifications() {
        let center=UNUserNotificationCenter.current()
        center.delegate=self
        // The Confirm action is what lets a reply leave, so it requires the Mac to be unlocked.
        let confirm=UNNotificationAction(identifier:Self.confirmActionID,title:"Confirm",options:[.authenticationRequired])
        let decline=UNNotificationAction(identifier:Self.declineActionID,title:String(localized:"Don’t Send"),options:[.destructive])
        // Dot's question is answered where it appears: in writing (the field takes dictation), or with one
        // press when it is the draft and save or draft and send question. A call remains possible.
        let call=UNNotificationAction(identifier:Self.callActionID,title:"Call Dot Instead",options:[])
        let answer=UNTextInputNotificationAction(identifier:Self.answerActionID,title:"Answer…",options:[],textInputButtonTitle:"Send to Dot",textInputPlaceholder:"Your answer to Dot")
        let save=UNNotificationAction(identifier:Self.saveActionID,title:"Draft and Save",options:[])
        let send=UNNotificationAction(identifier:Self.sendActionID,title:"Draft and Send",options:[])
        // A reply Dot has drafted is disposed of with one press, from the notification that says it is ready.
        let replySave=UNNotificationAction(identifier:Self.replySaveID,title:"Insert",options:[])
        let replySend=UNNotificationAction(identifier:Self.replySendID,title:"Send",options:[])
        let replyIgnore=UNNotificationAction(identifier:Self.replyIgnoreID,title:String(localized:"No Reply"),options:[])
        baseCategories=[UNNotificationCategory(identifier:Self.confirmCategory,actions:[confirm,decline],intentIdentifiers:[],options:[]),
                        UNNotificationCategory(identifier:Self.questionCategory,actions:[answer,call],intentIdentifiers:[],options:[]),
                        UNNotificationCategory(identifier:Self.deliveryQuestionCategory,actions:[save,send,answer,call],intentIdentifiers:[],options:[]),
                        UNNotificationCategory(identifier:Self.replyReadyCategory,actions:[replySave,replySend,replyIgnore],intentIdentifiers:[],options:[])]
        center.setNotificationCategories(baseCategories)
        center.requestAuthorization(options:[.alert,.sound]) { _,_ in }
    }

    // MARK: Arriving mail the Mac judged essential

    private var learnedAccountNames=false
    /// The owner's names come from what is registered, never from Mail Dot's code: the Mac user's full name,
    /// and the full name on each account in Mail, read once per run while Mail is open (account details only,
    /// no mailbox is read).
    private func learnOwnerNames(_ settings:inout MailSettings,bridge:BridgeStore) async {
        let store=MailSettingsStore(bridgeDirectory:bridge.directory)
        let full=NSFullUserName().trimmingCharacters(in:.whitespaces)
        if !full.isEmpty,settings.macUserFullName != full,let saved=try? store.transaction({ value -> MailSettings in value.macUserFullName=full; return value }) { settings=saved }
        guard !learnedAccountNames,!settings.nativeAccounts.isEmpty,
              !NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").isEmpty,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.mail" else { return }
        learnedAccountNames=true
        guard let accounts=try? await automation.accounts() else { return }
        let names=Dictionary(accounts.compactMap{ account in account.fullName.map{ (account.id,$0) } },uniquingKeysWith:{ a,_ in a })
        guard !names.isEmpty,let saved=try? store.transaction({ value -> MailSettings in
            for index in value.nativeAccounts.indices { if let name=names[value.nativeAccounts[index].id] { value.nativeAccounts[index].fullName=name } }
            return value
        }) else { return }
        settings=saved
    }
    private var lastListPass=Date.distantPast
    private var lastBannerStates:[String:Int]?
    private var lastBannerReload=Date.distantPast
    private var bannerReloadOwed=false
    private var lastBannerReloadRequest=Date()
    nonisolated private static let bannerLog=Logger(subsystem:"org.jgkarlin.MailBridge",category:"Banners")
    /// Offers essential arriving mail to Dot one message at a time, tells the owner when Dot has drafted or
    /// needs guidance, and keeps each message's row colour in Mail current with its state. Only messages the
    /// Mac's filter judged essential, or the owner chose to ask about, are ever offered.
    /// Dot's access (see DotAccess): a check Dot left unanswered is given up, and a light check request goes to Dot
    /// when the owner pressed Check Again, or on Mail Dot's own while Dot has not answered (every half hour).
    private func checkDotAccess(_ settings:inout MailSettings,bridge:BridgeStore) async {
        let settingsStore=MailSettingsStore(bridgeDirectory:bridge.directory)
        // Drafting notes Dot did not polish in time keep the owner's words.
        if let updated=try? settingsStore.transaction({ value -> MailSettings in value.expireDotCheck(); value.expireNotePolish(); value.expireRuleTidying(); if value.dotCheckDue(),!MailDotSetupWindow.needed { value.requestDotCheck() }; return value }) { settings=updated }
        let access=settings.effectiveDotAccess
        guard access.checkRequestedAt != nil,access.checkRequestID == nil else { return }
        do {
            let available=try MailWorkflowAccount.available(settings:settings,native:NativeMailStore(bridgeDirectory:bridge.directory).read())
            // A check reads no mail: with no account linked yet (setup's test of Dot), it names none.
            let request=try MailWorkflowRequest(action:.check,accountIDs:available.isEmpty ? [] : DotCallCommands.scope(available))
            try MailWorkflowStore(bridgeDirectory:bridge.directory).transaction { try $0.enqueue(request,allowedAccountIDs:Set(available.map(\.id))) }
            if let updated=try? settingsStore.transaction({ value -> MailSettings in value.markDotCheckSent(requestID:request.id); return value }) { settings=updated }
        } catch {
            Self.bannerLog.error("could not ask Dot to confirm it answers: \(error.localizedDescription,privacy:.public)")
        }
    }
    private func checkTriage() async {
        guard !inert,let store=try? MailTriageStore.shared(),let bridge=try? BridgeStore.shared(),var settings=try? MailSettingsStore(bridgeDirectory:bridge.directory).read() else { return }
        await learnOwnerNames(&settings,bridge:bridge)
        // An account whose Automatic replies are on by default starts counting from the first time it is seen.
        if settings.knownAccountIDs.contains(where:{settings.automaticReplies(account:$0) && settings.automaticRepliesSince?[$0] == nil}),
           let stamped=try? MailSettingsStore(bridgeDirectory:bridge.directory).transaction({ value -> MailSettings in value.stampAutomaticReplies(); return value }) { settings=stamped }
        var changed=false
        if (try? store.transaction({ $0.discardOldDrafts() })) ?? 0 > 0 { changed=true }
        // Dot's silence is counted: a message given up after Dot twice left it unanswered (see DotAccess).
        let silentBefore=(try? store.read())?.entries.filter{ $0.outcome == .failed && ($0.dotNote ?? "").hasPrefix("Dot did not answer") }.count ?? 0
        if (try? store.transaction({ $0.expireUnanswered() })) ?? 0 > 0 { changed=true }
        let silentAfter=(try? store.read())?.entries.filter{ $0.outcome == .failed && ($0.dotNote ?? "").hasPrefix("Dot did not answer") }.count ?? 0
        if silentAfter > silentBefore,let updated=try? MailSettingsStore(bridgeDirectory:bridge.directory).transaction({ value -> MailSettings in value.noteDotSilent(silentAfter-silentBefore); return value }) { settings=updated }
        await checkDotAccess(&settings,bridge:bridge)
        await MeetingCalendar.addRequested(store)
        if (try? store.transaction({ $0.expireReportRequests() })) ?? 0 > 0 { changed=true }
        // Ask Dot for a Report: sent at once, as the owner pressed it; one request per message, never a draft.
        if let state=try? store.read() {
            for entry in state.reportsDue() {
                do {
                    let available=try MailWorkflowAccount.available(settings:settings,native:NativeMailStore(bridgeDirectory:bridge.directory).read())
                    guard !available.isEmpty else { break }
                    let request=try MailWorkflowRequest(action:.draftCheck,accountIDs:DotCallCommands.scope(available),triageID:entry.id)
                    try store.transaction { $0.markReportAsked(entry.id,requestID:request.id) }
                    try MailWorkflowStore(bridgeDirectory:bridge.directory).transaction { try $0.enqueue(request,allowedAccountIDs:Set(available.map(\.id))) }
                    changed=true
                } catch {
                    try? store.transaction { $0.noteReportFailure(entry.id,error.localizedDescription) }
                    Self.bannerLog.error("could not ask Dot for a report: \(error.localizedDescription,privacy:.public)")
                }
            }
        }
        if (try? store.transaction({ $0.recoverReports() })) ?? 0 > 0 { changed=true }
        let mailOpen = !NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").isEmpty
        // Until Dot has answered on this Mac, nothing is sent to it automatically (owner request, 14 November 2026);
        // what the owner asked for still goes.
        // A request the owner made themselves and Dot has not started goes first: nothing automatic is added in front of it.
        let ownerWaiting = !((try? MailWorkflowStore(bridgeDirectory:bridge.directory).read())?.ownerRequestsWaiting().isEmpty ?? true)
        if !ownerWaiting,let state=try? store.read() {
            for entry in state.dueForDot() where settings.dotActive || entry.askedByOwner {
                if !entry.askedByOwner {
                    let to=entry.recipients ?? []
                    if !settings.automaticReplies(forRecipients:to) { try? store.transaction { $0.hold(entry.id) }; continue }
                    // Only mail that arrived after Automatic replies went on (the owner's rule): never older mail,
                    // opened or not (owner request, 13 November 2026). Older mail is drafted when the owner asks in the panel.
                    guard let start=settings.automaticRepliesStart(forRecipients:to),(entry.receivedAt ?? entry.seenAt) >= start else {
                        try? store.transaction { $0.hold(entry.id,older:true) }; changed=true; continue
                    }
                    // Nor a message the owner has already answered from this Mac's Mail. Mail is not asked: its
                    // scripting searches the whole inbox on Mail's main thread, and the cursor spins meanwhile.
                    if let id=entry.messageID,state.ownerHasReplied(id) {
                        try? store.transaction { $0.noteFlag(entry.id,applied:nil,ownerFlagged:false,replied:true) }
                        changed=true; continue
                    }
                }
                do {
                    let available=try MailWorkflowAccount.available(settings:settings,native:NativeMailStore(bridgeDirectory:bridge.directory).read())
                    guard !available.isEmpty else { break }
                    let request=try MailWorkflowRequest(action:.draftCheck,accountIDs:DotCallCommands.scope(available),triageID:entry.id)
                    try MailWorkflowStore(bridgeDirectory:bridge.directory).transaction { try $0.enqueue(request,allowedAccountIDs:Set(available.map(\.id))) }
                    try store.transaction { $0.markAsked(entry.id,requestID:request.id) }
                    changed=true
                } catch {
                    // Said in the log: a refusal here used to leave new mail on Drafting without a trace.
                    Self.bannerLog.error("could not offer a message to Dot: \(error.localizedDescription,privacy:.public)")
                    break
                }
            }
            // No notification: a message's state shows on its banner and in the panels.
        }
        // Whether the owner has replied. A reply sent from this Mac's Mail is known at once: Mail Dot's extension
        // notes it as it is sent. Only a reply sent elsewhere, from a phone for example, needs Mail's scripting,
        // and that search runs on Mail's main thread for seconds, during which Mail's cursor spins (the owner's
        // report of 13 November 2026). So it is asked about one message at a time, at most every three minutes,
        // and only while the owner is not using Mail. Never while Mail is closed: a script would start it.
        if let state=try? store.read() {
            for entry in state.replyChecksDue(limit:20) where entry.messageID.map(state.ownerHasReplied) == true {
                try? store.transaction { $0.noteFlag(entry.id,applied:nil,ownerFlagged:false,replied:true) }
                changed=true
            }
        }
        let mailInFront=NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail"
        var mayAskMail=mailOpen && !mailInFront && Date().timeIntervalSince(lastListPass) >= 180
        if mayAskMail,let state=try? store.read(),let entry=state.replyChecksDue(limit:1).first,let id=entry.messageID {
            lastListPass=Date(); mayAskMail=false
            if let result=try? MailListMarker.flag(messageID:id,wanted:-2,previous:nil) {
                // A message Mail cannot find is not asked about again for five minutes either.
                try? store.transaction { $0.noteFlag(entry.id,applied:nil,ownerFlagged:false,replied:result.found && result.replied) }
                if result.found && result.replied { changed=true }
            }
        }
        // A report of Dot's on a message the owner has since answered, in Mail by hand or through Mail Dot, is
        // closed: it no longer asks for a decision.
        if let state=try? store.read(),let bridge=try? BridgeStore.shared() {
            for due in state.reportReplyChecksDue(limit:20) {
                var replied=state.ownerHasReplied(due.messageID)
                if !replied {
                    guard mayAskMail else { continue }
                    lastListPass=Date(); mayAskMail=false
                    guard let result=try? MailListMarker.flag(messageID:due.messageID,wanted:-2,previous:nil) else { continue }
                    replied=result.found && result.replied
                }
                try? store.transaction { $0.noteReportChecked(due.messageID,replied:replied) }
                guard replied else { continue }
                let updates=ScheduledMailUpdateStore(bridgeDirectory:bridge.directory)
                if let record=try? updates.read().records.first(where:{$0.id == due.reportKey}),!record.dismissedByOwner {
                    try? updates.transaction { try $0.handle(record.id,revision:record.update.revision,as:.closed,note:"The owner replied to this message.",requestID:nil) }
                    changed=true
                }
            }
        }
        // The banner on an open message says the new state too. Dot's answers are written by the agent, not
        // here, so a change is noticed by comparing each message's state with the last pass: without this, a
        // finished draft kept showing Drafting until the owner selected the message again (13 November 2026).
        // A message that has only just been recorded, because Mail showed it, is not a change of state: asking Mail to
        // redraw for it made Mail show messages again, record more, and redraw every five seconds (owner report, 15
        // November 2026). Its banner comes with the next redraw that a real change asks for.
        var onlyNew=false
        if let state=try? store.read() {
            var states:[String:Int]=[:]
            for entry in state.entries {
                var hasher=Hasher(); hasher.combine("\(entry.outcome)"); hasher.combine(entry.draft?.count ?? -1); hasher.combine(entry.dotNote); hasher.combine(entry.replyPanelDraftingAt)
                states[entry.id]=hasher.finalize()
            }
            if let last=lastBannerStates {
                if states.contains(where:{ id,value in last[id].map{ $0 != value } ?? false }) { changed=true }
                else if states.keys.contains(where:{ last[$0] == nil }) { onlyNew=true }
            }
            lastBannerStates=states
            // The extension's Mail Dot window closed: its message's banner is shown again.
            if let asked=state.bannerReloadRequestedAt,asked > lastBannerReloadRequest { lastBannerReloadRequest=asked; changed=true }
        }
        // Only while Mail is open: asking a closed Mail to reload starts it. Seen twice on 13 November 2026,
        // Mail reopened seconds after the owner quit it, or after Mail Dot restarted.
        // Never while the Mail Dot window is open: the message behind it redrew under the owner's eyes. The redraw is owed
        // and made when the window closes. Never more than once in ten seconds, and for newly recorded messages alone at
        // most once a minute.
        if changed { bannerReloadOwed=true }
        let sinceLast=Date().timeIntervalSince(lastBannerReload)
        let due=(bannerReloadOwed && sinceLast >= 10) || (onlyNew && sinceLast >= 60)
        let windowOpen=AXIsProcessTrusted() ? MailDotWindowCloser.open() > 0 : (try? store.read())?.mailDotWindowOpenAt != nil
        if due,!windowOpen,!NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").isEmpty {
            bannerReloadOwed=false; lastBannerReload=Date()
            do { try await MEExtensionManager.reloadVisibleMessages(); Self.bannerLog.info("asked Mail to reload visible messages (\(onlyNew && !changed ? "new messages" : "a change",privacy:.public))") }
            catch { Self.bannerLog.error("Mail refused to reload visible messages: \(error.localizedDescription,privacy:.public)") }
        }
    }

    // MARK: Replies Dot is drafting: said outside the panel

    private static let replyReadyCategory="org.jgkarlin.MailBridge.reply.ready"
    nonisolated static let replySaveID="org.jgkarlin.MailBridge.reply.save"
    nonisolated static let replySendID="org.jgkarlin.MailBridge.reply.send"
    nonisolated static let replyIgnoreID="org.jgkarlin.MailBridge.reply.ignore"
    nonisolated static let replyAnswerTextID="org.jgkarlin.MailBridge.reply.answerText"
    nonisolated static let replyAnswerPrefix="org.jgkarlin.MailBridge.reply.answer."
    private var baseCategories:Set<UNNotificationCategory>=[]
    /// One category for each question on screen, because a notification's buttons are its category's and
    /// the answers differ from question to question.
    private var replyQuestionCategories:[String:UNNotificationCategory]=[:]

    /// Tells the owner, outside the panel, where each reply they asked Dot to draft stands: drafting, ready,
    /// or waiting on their answer. One notification for each reply, replaced as its state changes and
    /// withdrawn when nothing is asked or the reply is closed. Each state is announced once.
    private func announceReplies() {
        guard !inert,let store=try? BridgeStore.shared(),let state=try? store.read() else { return }
        let center=UNUserNotificationCenter.current()
        var live=Set<String>()
        for (id,context) in state.contexts {
            // The confirmation has a notification of its own, and a reply already in the message asks nothing.
            guard let indicator=ReplyIndicator(context),indicator != .confirmSend,indicator != .placed else { continue }
            let identifier="reply-"+id
            live.insert(identifier)
            let key=indicator.key(for:context)
            guard context.ownerRequest?.announced != key else { continue }
            let content=UNMutableNotificationContent()
            content.title=indicator.title(to:context.replyingTo)
            content.subtitle=context.envelope.subject
            content.userInfo=["replyContextID":id]
            content.threadIdentifier=identifier
            switch indicator {
            case .drafting:
                content.body=String(localized:"You will be told here when the draft is ready, or if Dot needs to ask you something.")
            case .draftReady(let preview,_):
                content.body=preview
                content.categoryIdentifier=Self.replyReadyCategory
                content.sound = .default
            case .question(let text,let answers):
                content.body=answers.isEmpty ? text : text+"\n"+answers.enumerated().map{"\($0+1). \($1)"}.joined(separator:"   ")
                let typed=UNTextInputNotificationAction(identifier:Self.replyAnswerTextID,title:"Answer…",options:[],textInputButtonTitle:"Send to Dot",textInputPlaceholder:"Your answer to Dot")
                let presses=answers.prefix(4).enumerated().map{UNNotificationAction(identifier:Self.replyAnswerPrefix+"\($0)",title:"\($0+1). "+String($1.prefix(40)),options:[])}
                let category=UNNotificationCategory(identifier:"org.jgkarlin.MailBridge.reply.question."+id,actions:presses+[typed],intentIdentifiers:[],options:[])
                replyQuestionCategories[id]=category
                center.setNotificationCategories(baseCategories.union(replyQuestionCategories.values))
                content.categoryIdentifier=category.identifier
                content.sound = .default
            case .confirmSend,.placed: continue
            }
            center.add(UNNotificationRequest(identifier:identifier,content:content,trigger:nil))
            try? store.transaction { $0.contexts[id]?.ownerRequest?.announced=key }
        }
        for id in replyQuestionCategories.keys where !live.contains("reply-"+id) { replyQuestionCategories.removeValue(forKey:id) }
        let shown=live
        center.getDeliveredNotifications { delivered in
            let stale=delivered.map(\.request.identifier).filter{$0.hasPrefix("reply-") && !shown.contains($0)}
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers:stale) }
        }
    }

    /// The owner's press on a reply's notification: what becomes of the draft, or the answer to Dot's question.
    fileprivate func replyAction(contextID:String,action:String,typed:String?) async {
        do {
            let store=try BridgeStore.shared()
            switch action {
            case Self.replySaveID,Self.replySendID:
                try store.transaction { state in
                    try BridgeCoordinator.ownerChooses(action == Self.replySendID ? .send : .save,contextID:contextID,state:&state)
                    guard let context=state.contexts[contextID],let snapshot=context.snapshot,let proposal=context.proposal else { return }
                    try BridgeCoordinator.enqueueApply(contextID:contextID,displayedFingerprint:snapshot.fingerprint,displayedProposalRevision:proposal.revision,reviewedBody:proposal.body,state:&state)
                }
                // The text goes into the reply's own window, so Mail comes forward for it.
                NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first?.activate()
                try? await Task.sleep(for:.milliseconds(700))
                await processOperations()
            case Self.replyIgnoreID:
                try store.transaction { try BridgeCoordinator.ownerIgnores(contextID:contextID,state:&$0) }
                DotCallCommands.tellDotAboutReply(contextID:contextID)
            case Self.replyAnswerTextID:
                guard let typed,!typed.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
                try store.transaction { try BridgeCoordinator.ownerAnswers(typed,contextID:contextID,state:&$0) }
                DotCallCommands.tellDotAboutReply(contextID:contextID)
            case let press where press.hasPrefix(Self.replyAnswerPrefix):
                guard let index=Int(press.dropFirst(Self.replyAnswerPrefix.count)),let asked=try store.read().contexts[contextID]?.dotQuestion else { return }
                let answers=BridgeCoordinator.answers(in:asked).answers
                guard answers.indices.contains(index) else { return }
                try store.transaction { try BridgeCoordinator.ownerAnswers(answers[index],contextID:contextID,state:&$0) }
                DotCallCommands.tellDotAboutReply(contextID:contextID)
            default:
                // A click on the notification itself: Mail comes forward, where the reply and its panel are.
                NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first?.activate()
            }
        } catch {
            try? BridgeStore.shared().transaction { $0.contexts[contextID]?.localStatus=error.localizedDescription }
        }
        announceReplies()
    }

    private var postedConfirmations:[String:String]=[:]

    /// Asks the owner to confirm. A notification is small, so it states the reply's length and names both
    /// its beginning and its closing line; the reply panel shows the whole text. If notifications are not
    /// allowed, the same question is put in a window, so the confirmation never depends on a panel that
    /// Apply has just closed.
    private func postSendConfirmation(contextID:String,store:BridgeStore) {
        guard let context=try? store.read().contexts[contextID],let confirmation=context.sendConfirmation,let draft=context.snapshot else { return }
        withdrawConfirmationNotification(contextID:contextID)
        let summary=SendConfirmationSummary(draft:draft)
        let content=UNMutableNotificationContent()
        content.title=String(localized:"Confirm before Dot sends")
        content.subtitle=String(localized:"To: \(summary.recipients)")
        content.body=summary.notificationBody
        content.categoryIdentifier=Self.confirmCategory
        content.userInfo=["contextID":contextID,"confirmationID":confirmation.id]
        let identifier="confirm-"+confirmation.id
        postedConfirmations[contextID]=identifier
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:identifier,content:content,trigger:nil))
        Task { [weak self] in
            if await BackgroundConnection.notificationAuthorization() != UNAuthorizationStatus.authorized.rawValue {
                self?.askInWindow(contextID:contextID,confirmationID:confirmation.id,summary:summary)
            }
        }
    }

    private func withdrawConfirmationNotification(contextID:String) {
        guard let identifier=postedConfirmations.removeValue(forKey:contextID) else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:[identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:[identifier])
    }

    /// A confirmation that no longer applies must not stay on screen inviting a press.
    private func withdrawStaleConfirmations() {
        guard !postedConfirmations.isEmpty,let contexts=try? BridgeStore.shared().read().contexts else { return }
        for (contextID,identifier) in postedConfirmations where "confirm-"+(contexts[contextID]?.sendConfirmation?.id ?? "") != identifier {
            withdrawConfirmationNotification(contextID:contextID)
        }
    }

    private func askInWindow(contextID:String,confirmationID:String,summary:SendConfirmationSummary) {
        guard (try? BridgeStore.shared().read().contexts[contextID]?.sendConfirmation?.id) == confirmationID else { return }
        NSApplication.shared.activate(ignoringOtherApps:true)
        let alert=NSAlert()
        alert.messageText=String(localized:"Confirm before Dot sends")
        alert.informativeText=String(localized:"To: \(summary.recipients)\n\(summary.characterCount) characters. Nothing leaves until you confirm; then tell Dot to send.")
        let text=NSTextView(frame:NSRect(x:0,y:0,width:420,height:180))
        text.string=summary.text; text.isEditable=false; text.font = .systemFont(ofSize:NSFont.systemFontSize)
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:420,height:180))
        scroll.documentView=text; scroll.hasVerticalScroller=true; scroll.borderType = .bezelBorder
        alert.accessoryView=scroll
        alert.addButton(withTitle:String(localized:"Confirm Send"))
        alert.addButton(withTitle:String(localized:"Don’t Send"))
        let confirmed=alert.runModal() == .alertFirstButtonReturn
        Task { await self.answer(contextID:contextID,confirmationID:confirmationID,confirmed:confirmed) }
    }

    fileprivate func answer(contextID:String,confirmationID:String,confirmed:Bool) async {
        do {
            let store=try BridgeStore.shared()
            try store.transaction { state in
                // Where the owner chose draft and send on the panel, this is the one confirmation and Mail Dot sends.
                if confirmed { try BridgeCoordinator.confirmSendFromPanel(contextID:contextID,confirmationID:confirmationID,state:&state) }
                else { try BridgeCoordinator.withdrawSend(contextID:contextID,state:&state) }
            }
            withdrawConfirmationNotification(contextID:contextID)
            if confirmed { await processOperations() }
        } catch {
            try? BridgeStore.shared().transaction { $0.contexts[contextID]?.localStatus=error.localizedDescription }
        }
    }

    private func finish(_ operation:NativeOperation, store:BridgeStore, result:String?, error:String?) throws {
        try store.transaction { state in
            guard let index = state.operations.firstIndex(where: { $0.id == operation.id }) else { throw BridgeFailure("Operation disappeared.") }
            state.operations[index].result = result; state.operations[index].error = error
            state.contexts[operation.contextID]?.localStatus = result ?? error ?? "Unknown operation outcome. Inspect Mail."
            state.audit.append("\(Date().ISO8601Format()) \(operation.kind) \(operation.id): \(error == nil ? "completed" : "needs inspection")")
        }
        // A reply Mail Dot sent turns its message gray in the list.
        if operation.kind == "send",error == nil,let original=try? store.read().contexts[operation.contextID]?.originalMessageID,!original.isEmpty {
            try? MailTriageStore.shared().transaction { $0.markReplied(messageID:original) }
        }
        if let error { announceFailure(of:operation,error:error) }
    }

    private func execute(_ operation:NativeOperation, store:BridgeStore) async throws -> String {
        guard let context = try store.read().contexts[operation.contextID] else { throw BridgeFailure("No such connected message.") }
        switch operation.kind {
        case "share":
            let native:MailDraft?
            var nativeUnavailable:String?
            do {
                if let id = context.snapshot?.id, id >= 0 { native = try await automation.snapshot(id:id) }
                else { native = try await automation.connect(context.envelope) }
            } catch { native=nil; nativeUnavailable=error.localizedDescription }
            // Mail can return a scripted reply ID while omitting its visible quote.
            // A native action binding requires agreement with the complete UI body.
            let binding=try await uiEditor.bind(contextID:context.id,matching:context.envelope,native:native)
            let draft=binding.snapshot
            guard draft.body.utf8.count <= MailBodyLimits.utf8Bytes else { throw BridgeFailure("This message is too long for Mail Dot to read.") }
            try store.transaction { state in
                try BridgeCoordinator.completeShare(draft,contextID:context.id,expectedRevision:context.snapshotRevision,
                                                    expectedEnvelope:context.envelope,state:&state)
                state.contexts[context.id]?.uiEditorToken=binding.token
            }
            // How the message was reached is for the log, not for the owner.
            if draft.id < 0 { Logger(subsystem:"org.jgkarlin.MailBridge",category:"Reply").notice("shared through the editor binding; scripting: \(nativeUnavailable ?? "record does not match the visible message",privacy:.public)") }
            // If the owner asked for a draft on the panel, Dot is sent that request now, even if the panel has closed.
            DotCallCommands.tellDotAboutReply(contextID:context.id)
            // The owner's last message to this person is not looked up in Sent mail here: on this Mac, Mail took
            // over 40 seconds only to count the unified Sent mailbox through scripting (12 November 2026), and a
            // script holds the main thread. Dot finds it itself, first in its order of sources.
            return "Dot can read this message."
        case "apply":
            guard let expected = context.snapshot, let proposal = context.proposal,
                  expected.fingerprint == operation.expectedFingerprint, proposal.revision == operation.proposalRevision,
                  proposal.snapshotRevision == context.snapshotRevision else { throw BridgeFailure("The context or proposed wording changed. Review the current version before applying it.") }
            if proposal.appliedFingerprint == expected.fingerprint {
                if expected.id >= 0 {
                    let live=try await replyActions.checkedSnapshot(expected)
                    guard live.fingerprint == expected.fingerprint else { throw BridgeFailure("The message changed in Mail after application. Refresh its context and review again.") }
                } else if let token=context.uiEditorToken {
                    try await uiEditor.verifyUnchanged(contextID:context.id,token:token,expected:expected)
                } else { throw BridgeFailure("Refresh this message to verify its live editor before applying text.") }
                // A reply already in the message that the owner now chooses to send still needs their confirmation.
                if proposal.delivery == .send,context.sendConfirmation == nil,context.review == nil {
                    let confirms=(try? MailSettingsStore(bridgeDirectory:store.directory).read())?.confirmsPanelSends ?? true
                    let sending=try store.transaction { state in
                        guard var value=state.contexts[context.id] else { throw BridgeFailure("The message is no longer shared.") }
                        try BridgeCoordinator.requestSendConfirmation(context:&value)
                        state.contexts[context.id]=value
                        return try BridgeCoordinator.sendWithoutAsking(contextID:context.id,confirms:confirms,state:&state)
                    }
                    if sending { return String(localized:"Sending…") }
                    postSendConfirmation(contextID:context.id,store:store)
                    return String(localized:"Dot’s reply is in the message. Confirm to send it. Nothing has been sent.")
                }
                return "This exact text is already applied in Mail."
            }
            let applied:MailDraft
            // On the panel's request Dot's reply is inserted at the top, above the quoted mail, and the rest of
            // the message is not touched. `previous` is what Mail Dot typed there before, replaced by a revision.
            let onPanel=context.ownerRequest != nil
            let previous=onPanel ? (context.insertedTop.flatMap{expected.body.hasPrefix($0) ? $0 : nil} ?? "") : ""
            var typedTop:String?
            if expected.id >= 0 {
                if onPanel {
                    // A reply Mail exposes to scripting takes its whole text at once; the text below the reply is
                    // given back to it unchanged.
                    let remainder=String(expected.body.dropFirst(previous.count))
                    let typed=ReplyInsertion.typed(reply:proposal.body,above:remainder)
                    applied=try await replyActions.apply(typed+remainder,to:expected); typedTop=typed
                } else { applied=try await replyActions.apply(proposal.body,to:expected) }
            }
            else if let token=context.uiEditorToken {
                let authorize:@Sendable () throws -> Void = {
                    let current=try store.read()
                    guard current.activeContextID == context.id,let value=current.contexts[context.id],
                          value.snapshot?.fingerprint == expected.fingerprint,value.snapshotRevision == context.snapshotRevision,
                          value.proposal?.revision == proposal.revision,value.uiEditorToken == token,
                          current.operations.contains(where:{$0.id == operation.id && $0.claimedAt != nil && $0.error == nil && $0.result == nil}) else {
                        throw BridgeFailure("The shared message, reviewed wording or native operation changed before text insertion. Review the latest version.")
                    }
                }
                if onPanel {
                    let placed=try await uiEditor.insertAtTop(proposal.body,replacing:previous,contextID:context.id,token:token,expected:expected,authorize:authorize)
                    var draft=placed.draft
                    // A new message also takes Dot's subject line, if its Subject field is still empty.
                    if context.isNewMessage,let subject=proposal.subject,draft.subject.isEmpty {
                        try authorize()
                        try await uiEditor.setSubject(subject,contextID:context.id,token:token)
                        draft.subject=subject
                    }
                    // Files Dot finished go in just after the reply, once for each version of the draft.
                    if let files=context.dotFiles,!files.isEmpty,context.filesAttachedRevision != proposal.revision {
                        try authorize()
                        let urls=files.map{ ReplyFiles.url(store.directory,owner:context.id,file:$0) }
                        draft=try await uiEditor.attachFiles(urls,contextID:context.id,token:token,expected:draft)
                        try? store.transaction { $0.contexts[context.id]?.filesAttachedRevision=proposal.revision }
                    }
                    applied=draft; typedTop=placed.typed
                } else { applied=try await uiEditor.apply(proposal.body,contextID:context.id,token:token,expected:expected,authorize:authorize) }
            }
            else { throw BridgeFailure("Refresh this shared message to establish its live native editor binding before applying text.") }
            try store.transaction { state in
                guard var value = state.contexts[context.id], value.snapshot?.fingerprint == expected.fingerprint,
                      value.proposal?.revision == proposal.revision else { throw BridgeFailure("Mail text changed, but shared state changed concurrently. Inspect the message before continuing.") }
                value.snapshot = applied; value.snapshotRevision += 1; value.review = nil
                if value.envelope.subject != applied.subject { value.envelope.subject = applied.subject }
                value.proposal?.snapshotRevision = value.snapshotRevision
                value.proposal?.appliedFingerprint = applied.fingerprint
                if let typedTop { value.insertedTop=typedTop }
                state.contexts[context.id] = value
            }
            switch proposal.delivery {
            case .send:
                // Nothing is made ready here. The owner's confirming act on this Mac comes first, unless the owner
                // pressed Send in the panel with "Confirm before sending" off: that press is the confirmation.
                let confirms=(try? MailSettingsStore(bridgeDirectory:store.directory).read())?.confirmsPanelSends ?? true
                let sending=try store.transaction { state in
                    guard var value=state.contexts[context.id] else { throw BridgeFailure("The message is no longer shared.") }
                    try BridgeCoordinator.requestSendConfirmation(context:&value)
                    state.contexts[context.id]=value
                    return try BridgeCoordinator.sendWithoutAsking(contextID:context.id,confirms:confirms,state:&state)
                }
                if sending { return String(localized:"Sending…") }
                postSendConfirmation(contextID:context.id,store:store)
                return String(localized:"Dot’s reply is in the message. Confirm to send it. Nothing has been sent.")
            case .save:
                // Insert puts the reply in the message; Save Draft also asks Mail to save it to Drafts now.
                guard context.ownerRequest == nil || context.ownerRequest?.saveToDrafts == true else { return String(localized:"Dot’s reply is in your message. Nothing was sent.") }
                var saved=false
                if let token=context.uiEditorToken { saved=await uiEditor.save(contextID:context.id,token:token) }
                return saved ? String(localized:"Dot’s reply is in the message and saved in Drafts. Nothing was sent.")
                    : String(localized:"Dot’s reply is in the message. Mail keeps it in Drafts. Nothing was sent.")
            case nil: return String(localized:"Dot's reviewed text is applied in Mail. Nothing was sent.")
            }
        case "review":
            guard let expected = context.snapshot, expected.fingerprint == operation.expectedFingerprint else { throw BridgeFailure("The displayed draft changed. Refresh its context and review again.") }
            if expected.id < 0 {
                guard let token=operation.expectedEditorToken,token == context.uiEditorToken,
                      let revision=operation.expectedSnapshotRevision,revision == context.snapshotRevision else { throw BridgeFailure("The reviewed editor or revision changed. Refresh and review this message again.") }
                let live=try await uiEditor.prepareReview(contextID:context.id,token:token,expected:expected)
                try store.transaction { state in
                    guard var value=state.contexts[context.id],
                          state.operations.contains(where:{$0.id == operation.id && $0.contextID == context.id && $0.kind == "review" && $0.expectedEditorToken == token && $0.expectedSnapshotRevision == revision && $0.expectedFingerprint == expected.fingerprint && $0.claimedAt != nil && $0.result == nil && $0.error == nil}) else {
                        throw BridgeFailure("This native review operation is no longer current.")
                    }
                    try BridgeCoordinator.grantUIReview(live:live,displayedFingerprint:expected.fingerprint,expectedRevision:revision,token:token,context:&value)
                    state.contexts[context.id]=value
                }
                // The owner confirmed on the panel: that was the one confirmation, so the send follows now.
                if try store.transaction({ try BridgeCoordinator.enqueueOwnerSend(contextID:context.id,state:&$0) }) != nil { return "The reply was checked against Mail. Sending it now." }
                return "This exact draft is ready for a direct voice send instruction for 10 minutes. Any edit requires another review."
            }
            let live = try await replyActions.checkedSnapshot(expected)
            guard live.fingerprint == expected.fingerprint else { throw BridgeFailure("The draft changed in Mail. Share it again, review the updated text, then mark it ready.") }
            let review = SendReview(draft:live)
            try review.validate(draft:live)
            try store.transaction { state in
                guard state.contexts[context.id]?.snapshot?.fingerprint == expected.fingerprint else { throw BridgeFailure("Review context changed.") }
                state.contexts[context.id]?.review = review
            }
            if try store.transaction({ try BridgeCoordinator.enqueueOwnerSend(contextID:context.id,state:&$0) }) != nil { return "The reply was checked against Mail. Sending it now." }
            return "This exact draft is ready for a direct voice send instruction for 10 minutes. Any edit requires another review."
        case "send":
            guard let expected = context.snapshot, let reviewID = operation.reviewID else { throw BridgeFailure("No reviewed draft.") }
            if expected.id < 0 {
                guard let token=context.uiEditorToken,let review=context.review,review.id == reviewID else {
                    throw BridgeFailure("Review this exact draft in its current Mail window first.")
                }
                let consume:@Sendable (MailDraft) throws -> Void = { live in
                    try store.transaction { state in
                        try BridgeCoordinator.consumeUISend(operationID:operation.id,contextID:context.id,reviewID:reviewID,
                            expectedFingerprint:expected.fingerprint,expectedRevision:context.snapshotRevision,token:token,live:live,state:&state)
                    }
                }
                try await uiEditor.send(contextID:context.id,token:token,expected:expected,review:review,consume:consume)
                return "Mail accepted the reviewed Send action. Delivery is not confirmed."
            }
            let live = try await replyActions.checkedSnapshot(expected)
            // The checks above take time; a send that has grown too old must not be dispatched.
            if let refusal = operation.refusalIfTooOld() { throw BridgeFailure(refusal) }
            try store.transaction { state in
                guard var value = state.contexts[context.id] else { throw BridgeFailure("No reviewed context.") }
                try BridgeCoordinator.consumeReview(reviewID,live:live,context:&value)
                state.contexts[context.id] = value
            }
            do {
                guard try await replyActions.send(live) else { throw BridgeFailure("Mail did not confirm submission. Inspect Mail; this review cannot be retried.") }
                return "Mail accepted the reviewed message for sending. Delivery is not confirmed."
            } catch {
                throw BridgeFailure("Send outcome needs inspection: \(error.localizedDescription) Do not retry automatically.")
            }
        case "saveDraft":
            // Save Draft pressed after the reply was already inserted: only Mail's own Save.
            guard let token=context.uiEditorToken else { throw BridgeFailure("Read the message from Mail again, then save it.") }
            guard await uiEditor.save(contextID:context.id,token:token) else { throw BridgeFailure("Mail did not accept the Save command. Press Command-S in the reply window.") }
            return "Your message is saved in Drafts. Nothing was sent."
        default: throw BridgeFailure("Unsupported native operation.")
        }
    }
}


extension CompanionDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification) async -> UNNotificationPresentationOptions {
        [.banner,.sound]
    }
    /// Only the explicit Confirm or Don't Send action counts. Clicking the notification itself does nothing.
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse) async {
        let info=response.notification.request.content.userInfo
        if let questionID=info["questionID"] as? String {
            // The Call Dot action opens the call; clicking the notification itself only shows the question.
            let typed=(response as? UNTextInputNotificationResponse)?.userText
            let fixed=[CompanionDelegate.saveActionID:"Draft and save.",CompanionDelegate.sendActionID:"Draft and send."][response.actionIdentifier]
            if let text=fixed ?? (response.actionIdentifier == CompanionDelegate.answerActionID ? typed : nil) {
                await MainActor.run { ownerCommand(DotCallCommands.answer(questionID:questionID,text:text),opensCall:false) }
            } else if response.actionIdentifier == CompanionDelegate.callActionID { await callAbout(questionID:questionID) }
            else if response.actionIdentifier == UNNotificationDefaultActionIdentifier { await MainActor.run { _ = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first?.activate() } }
            return
        }
        if info["triageID"] is String {
            await MainActor.run { _ = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first?.activate() }
            return
        }
        if let replyID=info["replyContextID"] as? String {
            await replyAction(contextID:replyID,action:response.actionIdentifier,typed:(response as? UNTextInputNotificationResponse)?.userText)
            return
        }
        guard let contextID=info["contextID"] as? String,let confirmationID=info["confirmationID"] as? String else { return }
        let action=response.actionIdentifier
        guard action == CompanionDelegate.confirmActionID || action == CompanionDelegate.declineActionID else { return }
        await answer(contextID:contextID,confirmationID:confirmationID,confirmed:action == CompanionDelegate.confirmActionID)
    }
}
