#if DEBUG
import SwiftUI
import AppKit
import BridgeCore

/// Development only: draws each pane to an image from a synthetic store, so that the layout can be looked at
/// without Mail and without the owner's data. It refuses to run against the real store.
@MainActor enum PreviewRenderer {
    static func render(to directory:URL) async {
        guard ProcessInfo.processInfo.environment["MAILDOT_PREVIEW_STORE"]?.isEmpty == false else { print("PREVIEW_REFUSED: set MAILDOT_PREVIEW_STORE to a synthetic folder"); return }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try seed()
            var panes:[(String,CGSize,AnyView)]=[
                ("reply-not-shared",ReplyPanelView.size,AnyView(ReplyPanelView(contextID:"preview-new",registerContext:{},willShare:{}))),
                ("reply-confirm-send",ReplyPanelView.size,AnyView(ReplyPanelView(contextID:"preview-reply",registerContext:{},willShare:{}))),
                ("reply-failed-apply",ReplyPanelView.size,AnyView(ReplyPanelView(contextID:"preview-failed",registerContext:{},willShare:{})))
            ]
            // Dot's report as Mail shows it on a message: one structured, one asking a question, one in the older form.
            if let records=try? ScheduledMailUpdateStore(bridgeDirectory:BridgeStore.shared().directory).read().records {
                for (name,id) in [("report-decision","review"),("report-question","expense"),("report-chosen","seminar"),("report-old-form","item-0")] {
                    if let record=records.first(where:{$0.update.id == id}) { panes.append((name,MessageReportView.size,AnyView(MessageReportView(recordID:record.id).background(Color(nsColor:.windowBackgroundColor))))) }
                }
            }
            panes.append(("report-list",MessageReportView.size,AnyView(MessageReportView(recordID:nil).background(Color(nsColor:.windowBackgroundColor)))))
            panes.append(("about-light",MailDotAboutView.size,AnyView(MailDotAboutView().environment(\.colorScheme,.light))))
            panes.append(("about-dark",MailDotAboutView.size,AnyView(MailDotAboutView().environment(\.colorScheme,.dark))))
            // Mail Dot Settings, both tabs, in light and in dark.
            // The Mail Dot window's three layouts, on invented messages: a thread with a question and a meeting,
            // a single message with a draft, and an entry without a report.
            for (caseName,entry) in MailDotThreadWindow.previewEntries() {
                for layout in MailDotWindowLayout.allCases {
                    for dark in [false,true] {
                        panes.append(("thread-\(layout.rawValue)-\(caseName)-\(dark ? "dark" : "light")",MailDotThreadWindow.size(layout),
                                      AnyView(MailDotThreadWindow(entryID:entry.id,fixed:(entry,layout)).environment(\.colorScheme,dark ? .dark : .light))))
                    }
                }
            }
            for (tabName,tab) in [("accounts",MailDotSettingsView.Tab.accounts),("rules",.rules),("layout",.layout)] {
                for dark in [false,true] {
                    panes.append(("settings-\(tabName)-\(dark ? "dark" : "light")",CGSize(width:460,height:600),
                                  AnyView(MailDotSettingsView(startTab:tab).background(Color(nsColor:.windowBackgroundColor)).tint(MailDotStyle.tint).environment(\.colorScheme,dark ? .dark : .light))))
                }
            }
            for (name,size,view) in panes {
                let host=NSHostingView(rootView:view.frame(width:size.width,height:size.height))
                let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
                window.appearance=NSAppearance(named:name.hasSuffix("-dark") ? .darkAqua : .aqua)
                window.contentView=host; window.alphaValue=0; window.orderFrontRegardless()
                try await Task.sleep(for:.seconds(3))
                host.layoutSubtreeIfNeeded()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { continue }
                host.cacheDisplay(in:host.bounds,to:bitmap)
                if let data=bitmap.representation(using:.png,properties:[:]) { try data.write(to:directory.appendingPathComponent(name+".png")) }
                window.orderOut(nil)
            }
            print("PREVIEWS_RENDERED: \(panes.count)")
        } catch { print("PREVIEW_FAILED: \(error.localizedDescription)") }
    }

    /// Runs the real Mail Dot window, titled and resizable as the installed app makes it, over the synthetic
    /// store, and carries out scripted steps in it: real key events through the window, changes of size and
    /// appearance, and captures of the window as the screen shows it. The borderless frame that `render`
    /// draws hid faults a real window has (build 71 was handed over on that evidence and was broken), so
    /// this is the check that counts. Steps: shot:<name>, key:<name>, wait:<seconds>, size:<w>x<h>,
    /// appearance:<light|dark>, review:<on|off>.
    static func harness(steps:[String],to directory:URL) async {
        guard ProcessInfo.processInfo.environment["MAILDOT_PREVIEW_STORE"]?.isEmpty == false else { print("HARNESS_REFUSED: set MAILDOT_PREVIEW_STORE to a synthetic folder"); return }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try seed()
        } catch { print("HARNESS_FAILED: \(error.localizedDescription)"); return }
        // A first step "panel:<update id>" or "panel:none" shows the report panel instead, in a titled window
        // of the size Mail gives it, as Mail does for a message with that report or with none.
        var steps=steps
        var panel:String??
        if let first=steps.first,first.hasPrefix("panel:") { let id=String(first.dropFirst(6)); panel = .some(id == "none" ? nil : id); steps.removeFirst() }
        let window:NSWindow
        if let first=steps.first,first.hasPrefix("reply:") {
            // The reply panel for one seeded reply, in a window of the popover's size.
            steps.removeFirst()
            window=NSWindow(contentRect:NSRect(origin:.zero,size:ReplyPanelView.size),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.contentView=NSHostingView(rootView:ReplyPanelView(contextID:String(first.dropFirst(6)),registerContext:{},willShare:{}))
        } else if let panel {
            let records=(try? ScheduledMailUpdateStore(bridgeDirectory:BridgeStore.shared().directory).read().records) ?? []
            window=NSWindow(contentRect:NSRect(origin:.zero,size:MessageReportView.size),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.contentView=NSHostingView(rootView:MessageReportView(recordID:panel.flatMap{id in records.first{$0.update.id == id}?.id}))
        } else {
            window=NSWindow(contentRect:NSRect(origin:.zero,size:MailDotAboutView.size),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.contentView=NSHostingView(rootView:MailDotAboutView())
        }
        window.title="Mail Dot"
        window.isReleasedWhenClosed=false
        window.setFrameOrigin(NSPoint(x:40,y:60))
        let front=NSWorkspace.shared.frontmostApplication
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        try? await Task.sleep(for:.seconds(4))
        let keys:[String:(UInt16,String)]=["up":(126,"\u{F700}"),"down":(125,"\u{F701}"),"left":(123,"\u{F702}"),"right":(124,"\u{F703}"),"return":(36,"\r"),"escape":(53,"\u{1B}"),"delete":(51,"\u{7F}"),
            "j":(38,"j"),"k":(40,"k"),"d":(2,"d"),"e":(14,"e"),"o":(31,"o"),"u":(32,"u"),"z":(6,"z"),"1":(18,"1"),"2":(19,"2"),"3":(20,"3"),"4":(21,"4"),"n":(45,"n"),"a":(0,"a"),"x":(7,"x")]
        for step in steps {
            let parts=step.split(separator:":",maxSplits:1).map(String.init)
            guard parts.count == 2 else { print("bad step \(step)"); continue }
            switch parts[0] {
            case "shot":
                let file=directory.appendingPathComponent(parts[1]+".png")
                let capture=Process()
                capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
                capture.arguments=["-x","-o","-l","\(window.windowNumber)",file.path]
                try? capture.run(); capture.waitUntilExit()
                print("shot \(parts[1]) status=\(capture.terminationStatus) firstResponder=\(type(of:window.firstResponder as Any)) key=\(window.isKeyWindow)")
            case "key":
                var name=parts[1],flags:NSEvent.ModifierFlags=[]
                if name.hasPrefix("cmd+") { flags = .command; name=String(name.dropFirst(4)) }
                guard let (code,characters)=keys[name] else { print("unknown key \(name)"); continue }
                for type in [NSEvent.EventType.keyDown,.keyUp] {
                    if let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code) { window.sendEvent(event) }
                }
                try? await Task.sleep(for:.milliseconds(900))
            case "wait": try? await Task.sleep(for:.seconds(Double(parts[1]) ?? 1))
            case "size":
                let numbers=parts[1].split(separator:"x").compactMap{Double($0)}
                if numbers.count == 2 { window.setContentSize(NSSize(width:numbers[0],height:numbers[1])); try? await Task.sleep(for:.seconds(1)) }
            case "appearance": window.appearance=NSAppearance(named:parts[1] == "light" ? .aqua : .darkAqua); try? await Task.sleep(for:.seconds(1))
            default: print("unknown step \(step)")
            }
        }
        window.orderOut(nil)
        front?.activate()
        print("HARNESS_DONE")
    }

    static func seed() throws {
        let root=try BridgeStore.shared().directory
        var settings=MailSettings()
        var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link"); profile.observedAt=Date()
        var second=MailConnection(id:"work",email:"owner@work.example.invalid",connectionID:"link-2"); second.observedAt=Date()
        settings.connections=[profile,second]
        var schedule=MailSchedule(id:"schedule",title:"Mail Dot · General email review",accountEmails:[profile.email],cadence:"Every hour",conditions:"Report mail that needs a decision")
        schedule.observedAt=Date(); schedule.sources=[MailScheduleSource(kind:"gmail",id:profile.id,addresses:[profile.email],connectionID:profile.connectionID)]
        settings.schedules=[schedule]; settings.linkedScheduleIDs=[schedule.id]; settings.keepConnectedConfirmedAt=Date().addingTimeInterval(-7200)
        settings.lastAccountsSync=Date(); settings.lastSchedulesSync=Date()
        try MailSettingsStore(bridgeDirectory:root).transaction { $0=settings }
        let accounts=try MailWorkflowAccount.available(settings:settings,native:NativeMailState())
        try ScheduledMailUpdateStore(bridgeDirectory:root).transaction { state in
            for (index,title) in ["Meeting request from a colleague","Travel approval is ready to review"].enumerated() {
                let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let fields:[String:Any]=["id":"item-\(index)","scheduleID":schedule.id,"runID":"run-\(index)","revision":0,"accountIDs":accounts.prefix(1).map(\.id),"sourceIDs":["message-\(index)"],"title":title,
                    "summary":"A synthetic summary of the matter, long enough to wrap onto a second line in the list so that spacing can be judged.",
                    "action":index == 0 ? "decision" : "reviewDraft","actionText":index == 0 ? "Choose Tuesday or Thursday." : "Open the draft and review it.",
                    "checkedAt":Date().addingTimeInterval(-600).ISO8601Format(),"coverage":"Inbox checked; calendar not checked."]
                let update=try decoder.decode(ScheduledMailUpdate.self,from:JSONSerialization.data(withJSONObject:fields))
                try state.accept(update,settings:settings,accounts:accounts)
            }
            // Structured updates, as Dot is asked to report them from build 71.
            func structured(_ id:String,_ title:String,_ shape:(inout ScheduledMailUpdate)->Void) throws {
                let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let fields:[String:Any]=["id":id,"scheduleID":schedule.id,"runID":"run-"+id,"revision":0,"accountIDs":accounts.prefix(1).map(\.id),"sourceIDs":["message-"+id],"title":title,
                    "summary":"A synthetic summary.","action":"decision","actionText":"Decide.","checkedAt":Date().addingTimeInterval(-300).ISO8601Format(),"coverage":"One message read in full. Calendar read for the week of December 7."]
                var update=try decoder.decode(ScheduledMailUpdate.self,from:JSONSerialization.data(withJSONObject:fields))
                shape(&update)
                try state.accept(update,settings:settings,accounts:accounts)
            }
            try structured("review","Invitation to review a manuscript") {
                $0.message=MailUpdateMessage(sender:"Journal editorial office",subject:"Invitation to review a manuscript",receivedAt:Date().addingTimeInterval(-9000))
                $0.gist="A review of a 9,000-word manuscript is requested by December 9."
                $0.summaryPoints=["The editor invites a review of a manuscript on fan labor and streaming platforms, about 9,000 words.","The report is due December 9; the editor asks for an answer within a week."]
                $0.unverified=["whether the deadline can move"]
                $0.status = .awaitingInstruction
                $0.decision=MailUpdateDecision(question:"How should Dot reply?",options:[
                    MailUpdateOption(id:"accept",label:"Accept for December 9",detail:"Agree to the stated deadline.",effect:.draftReply,replyPreview:"Thank you for the invitation. I accept and will submit the review by December 9."),
                    MailUpdateOption(id:"later",label:"Accept and ask for December 20",detail:"Two deadlines already fall in the week of December 7.",effect:.draftReply,replyPreview:"Thank you for the invitation. I can review the manuscript, although two deadlines fall in the week of December 7. Could the report follow by December 20?"),
                    MailUpdateOption(id:"suggest",label:"Decline and suggest reviewers",detail:"Dot proposes two names from your correspondence.",effect:.draftReply),
                    MailUpdateOption(id:"decline",label:"Decline",detail:"A brief, courteous refusal.",effect:.draftReply)],recommended:"later")
                $0.work=[MailUpdateWork(state:.done,text:"Checked the week of December 7: two deadlines already fall there",source:.calendar),MailUpdateWork(state:.done,text:"Found your last review for this journal, March 2025",source:.mailHistory)]
                $0.tags=[MailUpdateTag(state:.done,label:"Calendar checked")]
            }
            try structured("expense","Expense report for the Kyoto symposium") {
                $0.message=MailUpdateMessage(sender:"Department accounting office",subject:"Expense report for the Kyoto symposium",receivedAt:Date().addingTimeInterval(-16000))
                $0.summaryPoints=["Accounting requests the completed expense form and the receipts for the Kyoto symposium by November 14.","Dot completed the form from four receipts, ¥48,260 ($311) in total, and attached both files to the drafted reply."]
                $0.status = .draftedQueued
                $0.decision=MailUpdateDecision(kind:.question,question:"The taxi receipt for ¥3,400 ($22) shows no date. Which date applies?",options:[
                    MailUpdateOption(id:"sixth",label:"November 6",detail:"The day you arrived, by your calendar.",effect:.answer),
                    MailUpdateOption(id:"seventh",label:"November 7",detail:"The day of the symposium.",effect:.answer),
                    MailUpdateOption(id:"omit",label:"Leave the receipt out",detail:"The total falls to ¥44,860 ($289).",effect:.answer)],recommended:"sixth")
                $0.work=[MailUpdateWork(state:.done,text:"Completed the expense form from the department template",source:.drive),MailUpdateWork(state:.done,text:"Gathered four receipts from the symposium folder into one PDF",source:.drive),
                         MailUpdateWork(state:.inProgress,text:"Watching for the office’s acknowledgement",source:.schedule),MailUpdateWork(state:.needsOwner,text:"One taxi receipt carries no date",source:.none,sourceLabel:"Needs you")]
                $0.tags=[MailUpdateTag(state:.done,label:"Form completed"),MailUpdateTag(state:.done,label:"Receipts attached")]
                $0.draft=MailUpdateDraft(delivery:.send,to:["accounting@example.invalid"],preview:"Please find attached the completed expense form and the receipts for the Kyoto symposium. The total comes to ¥48,260 ($311).",attachments:["Expense form (completed).pdf","Receipts, Kyoto symposium.pdf"])
            }
            try structured("seminar","Research funding seminar, November 18") {
                $0.message=MailUpdateMessage(sender:"Research administration",subject:"Research funding seminar, November 18",receivedAt:Date().addingTimeInterval(-7000))
                $0.summaryPoints=["Research administration announces an optional seminar on external funding, November 18 at 13:30.","It overlaps your class, 13:00 to 14:45."]
                $0.status = .information
                $0.decision=MailUpdateDecision(question:"What should Dot do with this announcement?",options:[
                    MailUpdateOption(id:"calendar",label:"Add it to the calendar",detail:"Entered as optional beside the class.",effect:.close),
                    MailUpdateOption(id:"ignore",label:"Ignore it",detail:"Close this update; the message stays in Mail.",effect:.ignore)],recommended:"ignore")
                $0.work=[MailUpdateWork(state:.done,text:"Checked November 18: the seminar overlaps your class",source:.calendar)]
            }
            // One instruction already given, to show the pending state.
            if let record=state.records.first(where:{$0.update.id == "seminar"}) {
                try state.choose(record.id,revision:0,option:"calendar")
            }
        }
        try MailWorkflowStore(bridgeDirectory:root).transaction { state in
            let question=try state.ask("For the seminar reply: shall I draft and save, or draft and send?",contextID:nil)
            let call=try state.requestCall(accountIDs:accounts.map(\.id),allowedAccountIDs:Set(accounts.map(\.id)),questionID:question.id)
            state.recordCallLaunch(requestID:call.id,started:true,note:nil)
            _ = try state.requestSpokenReport(accountIDs:accounts.prefix(1).map(\.id),allowedAccountIDs:Set(accounts.map(\.id)))
        }
        try ToolCallLogStore(bridgeDirectory:root).append(ToolCallRecord(at:Date().addingTimeInterval(-900),method:"tools/call",tool:"bridge_status",outcome:.ok,detail:nil))
        try BridgeStore(directory:root).transaction { state in
            state.agentSeenAt = .now
            let expires=Date().addingTimeInterval(80_000).timeIntervalSinceReferenceDate,verified=Date().timeIntervalSinceReferenceDate
            state.subscriptions=try EventHub.eventNames.map { name in
                let fields:[String:Any]=["id":"sub-"+name,"callbackURL":"https://chatgpt.com/preview","secret":"whsec_preview","expiresAt":expires,"verifiedAt":verified,"eventName":name]
                return try JSONDecoder().decode(EventSubscription.self,from:JSONSerialization.data(withJSONObject:fields))
            }
            let draft=MailDraft(id:-1,subject:"Re: Seminar schedule",sender:"owner@example.invalid",to:["colleague@example.invalid"],cc:["office@example.invalid"],bcc:[],body:"Dear colleague,\n\nThank you for the proposal. Thursday at three suits me well, and I will bring the revised outline.\n\nWith best wishes,\nOwner",attachmentCount:-1)
            state.contexts["preview-new"]=ReplyContext(id:"preview-new",envelope:draft)
            var ready=ReplyContext(id:"preview-reply",envelope:draft)
            BridgeCoordinator.share(draft,with:&ready)
            ready.uiEditorToken=UUID().uuidString
            ready.dotStatus="I drafted a short acceptance of Thursday at three."; ready.lastDotUpdate=Date()
            var proposal=DotProposal(body:draft.body,revision:1,snapshotRevision:ready.snapshotRevision)
            proposal.delivery = .send; proposal.appliedFingerprint=draft.fingerprint
            ready.proposal=proposal
            try BridgeCoordinator.requestSendConfirmation(context:&ready)
            state.contexts[ready.id]=ready
            var done=NativeOperation(contextID:ready.id,kind:"apply"); done.claimedAt=Date(); done.result="Dot's text is in the Mail draft. Confirm on this Mac before Dot can send it. Nothing has been sent."
            var failed=ReplyContext(id:"preview-failed",envelope:draft)
            BridgeCoordinator.share(draft,with:&failed)
            failed.dotStatus="I tried to place my draft in your reply."; failed.lastDotUpdate=Date()
            var draftOnly=DotProposal(body:"Thank you. Thursday at three suits me.",revision:1,snapshotRevision:failed.snapshotRevision); draftOnly.delivery = .save
            failed.proposal=draftOnly
            state.contexts[failed.id]=failed
            var broken=NativeOperation(contextID:failed.id,kind:"apply"); broken.claimedAt=Date()
            broken.error="Mail Dot could not finish placing the text, so it put your original reply back. Nothing was lost. Switch the keyboard to an English input source, such as ABC, before Mail Dot types the reply."
            state.operations=[done,broken]
            // The reply panel's other states, as the owner specified it.
            func reply(_ id:String,_ shape:(inout ReplyContext) throws -> Void) rethrows {
                var context=ReplyContext(id:id,envelope:draft,originalSubject:"Thursday meeting",originalSender:"Aiko Tanaka <tanaka@example.invalid>")
                BridgeCoordinator.ownerOpensPanel(context:&context)
                BridgeCoordinator.share(draft,with:&context)
                context.uiEditorToken=UUID().uuidString
                context.event?.receiptAt=Date()
                try shape(&context)
                state.contexts[id]=context
            }
            reply("preview-drafting") { $0.dotStatus="Reading the thread and your calendar for Thursday."; $0.lastDotUpdate=Date() }
            reply("preview-question") {
                $0.dotStatus="I need one thing before I can draft."; $0.lastDotUpdate=Date()
                $0.dotQuestion="Tanaka proposes Thursday at 15:00, but your calendar shows the faculty meeting until 15:30. What should I say? 1) Propose Thursday at 16:00 2) Propose Friday at 10:00 3) Accept 15:00 and leave the meeting early"
            }
            try reply("preview-draft") {
                $0.dotStatus="Drafted an acceptance for Thursday at 16:00."
                try BridgeCoordinator.propose("Dear Tanaka-san,\n\nThank you for arranging this. Thursday works for me, though I am in a faculty meeting until 15:30. Could we begin at 16:00 instead?\n\nBest regards,\nAlex",expectedRevision:$0.snapshotRevision,eventID:nil,delivery:.save,context:&$0)
            }
            try reply("preview-saved") {
                $0.ownerRequest?.delivery = .save
                try BridgeCoordinator.propose(draft.body,expectedRevision:$0.snapshotRevision,eventID:nil,delivery:.save,context:&$0)
                $0.proposal?.appliedFingerprint=draft.fingerprint
            }
            reply("preview-ignored") { $0.ownerRequest?.ignored=true }
            var unread=ReplyContext(id:"preview-unreadable",envelope:draft,originalSender:"Aiko Tanaka <tanaka@example.invalid>")
            BridgeCoordinator.ownerOpensPanel(context:&unread)
            state.contexts[unread.id]=unread
            var lost=NativeOperation(contextID:unread.id,kind:"share"); lost.claimedAt=Date()
            lost.error="Mail Dot could not find this reply’s window in Mail. Click in the reply, then try again."
            state.operations.append(lost)
        }
    }
}
#endif
