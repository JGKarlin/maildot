import SwiftUI
import AppKit
import BridgeCore

/// Mail Dot inside Mail. Mail shows this panel when the owner clicks the Mail Dot banner at the top of a
/// message, or the Mail Dot icon in a message's header. It holds what the owner asked to have in Mail
/// itself: Dot's report on the message (the summary, the decision with its numbered options and Dot's
/// recommendation, Dot's work, the reply draft's state and the actions, by click or by key), and the list
/// of all of Dot's reports by where each stands, from which any of them is one click away.
@MainActor struct MessageReportView:View {
    static let size=CGSize(width:460,height:600)
    /// Dot's report on the message this panel was opened from, or nil when Dot has not reported on it.
    let recordID:String?
    /// The report shown, which the owner may change from the list or with Next.
    @State private var shownID:String?
    @State private var listing:Bool
    @State private var showingSettings=false
    @State private var queue:[UpdateQueueGroup]=[]
    @State private var entry:UpdateEntry?
    @State private var loaded=false
    @State private var line:(text:String,failed:Bool,undo:Bool)?
    @State private var discussing=false
    @State private var words=""
    @State private var confirming=false
    @FocusState private var typing:Bool

    init(recordID:String?) {
        self.recordID=recordID
        _shownID=State(initialValue:recordID)
        _listing=State(initialValue:recordID == nil)
    }

    var body:some View {
        VStack(spacing:0) {
            topBar
            Divider()
            if showingSettings {
                MailDotSettingsView()
            } else if listing || shownID == nil {
                list
                Divider()
                footer
            } else if let entry {
                ScrollView { report(entry).padding(16).frame(maxWidth:.infinity,alignment:.leading) }
                Divider()
                if confirming { confirmBar(entry) } else if discussing { discussBar(entry) } else { actionBar(entry) }
            } else {
                notice(loaded ? String(localized:"Dot’s report is no longer listed") : String(localized:"Loading Dot’s report…"),nil)
                Divider()
                footer
            }
        }
        .frame(width:Self.size.width,height:Self.size.height)
        .tint(MailDotStyle.tint)
        .task(id:shownID) {
            while !Task.isCancelled {
                if let fresh=try? await UpdateEntry.loadQueue(),fresh != queue { queue=fresh }
                if let shownID {
                    if let fresh=try? await UpdateEntry.load(recordID:shownID) { if fresh != entry { entry=fresh } } else { entry=nil }
                }
                loaded=true
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
            }
        }
    }

    // MARK: The list of Dot's reports

    /// Always at the top: the way back to the list, how many reports stand where, and Next.
    private var topBar:some View {
        HStack(spacing:7) {
            if showingSettings {
                Image(systemName:"at.circle.fill").foregroundStyle(MailDotStyle.brand)
                Text("Mail Dot Settings").font(.headline)
            } else if listing || shownID == nil {
                Image(systemName:"at.circle.fill").foregroundStyle(MailDotStyle.brand)
                Text("Dot’s reports").font(.headline)
            } else {
                Button { listing=true; line=nil } label: { Label("All Reports",systemImage:"chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut("a",modifiers:[]).disabled(discussing || confirming).help("All of Dot’s reports")
            }
            Spacer(minLength:4)
            ForEach([MailUpdateStatus.awaitingInstruction,.draftedQueued,.draftedSent],id:\.self) { status in
                Pill(text:"\(count(status)) \(short(status))",color:count(status) == 0 ? .secondary : color(status)).help(status.title)
            }
            Button { showingSettings.toggle() } label: { Image(systemName:showingSettings ? "checkmark.circle" : "gearshape") }
                .buttonStyle(.borderless).help(showingSettings ? "Back to Dot’s reports" : "Mail Dot Settings").accessibilityLabel(showingSettings ? "Done" : "Mail Dot Settings")
            Button { next() } label: { Label("Next",systemImage:"chevron.right").labelStyle(.titleAndIcon) }
                .controlSize(.small).keyboardShortcut("n",modifiers:[]).disabled(queue.isEmpty || discussing || confirming).help("The next of Dot’s reports")
        }.padding(.horizontal,14).padding(.vertical,9)
    }
    private func count(_ status:MailUpdateStatus) -> Int { queue.first{$0.status == status}?.entries.count ?? 0 }
    private func short(_ status:MailUpdateStatus) -> String {
        switch status {
        case .awaitingInstruction:String(localized:"awaiting")
        case .draftedQueued:String(localized:"queued")
        case .draftedSent:String(localized:"sent")
        case .information:String(localized:"notes")
        }
    }
    @ViewBuilder private var list:some View {
        if queue.isEmpty {
            notice(recordID == nil ? String(localized:"Dot has not reported on this message") : String(localized:"Dot has no open reports"),
                   String(localized:"When Dot reports on a message, a banner appears at the top of that message in Mail, and the report, your options and Dot’s work show here."))
        } else {
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    if recordID == nil { Text("Dot has not reported on the message you opened this from. These are its reports on other messages.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                    ForEach(queue,id:\.status) { group in
                        VStack(alignment:.leading,spacing:4) {
                            HStack(spacing:6) {
                                Circle().fill(color(group.status)).frame(width:7,height:7)
                                Text(group.status.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                                Text("\(group.entries.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            ForEach(group.entries) { item in row(item) }
                        }
                    }
                }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
    private func row(_ item:UpdateEntry) -> some View {
        Button { show(item.id) } label: {
            HStack(alignment:.top,spacing:8) {
                Circle().fill(item.record.unread ? MailDotStyle.tint : Color.clear).frame(width:7,height:7).padding(.top,6)
                VStack(alignment:.leading,spacing:2) {
                    HStack(alignment:.firstTextBaseline,spacing:6) {
                        Text(item.record.update.title).fontWeight(item.record.unread ? .semibold : .regular).lineLimit(2).multilineTextAlignment(.leading)
                        if item.id == recordID { Pill(text:String(localized:"This message"),color:MailDotStyle.tint) }
                    }
                    Text([item.shown.sender,item.shown.gist].compactMap{$0}.joined(separator:" — ")).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    if item.shown.needsOwner || item.pending != nil {
                        Text(item.pending?.text ?? String(localized:"Dot needs something from you")).font(.caption.weight(.semibold)).foregroundStyle(item.pending?.failed == true ? Color.red : item.pending == nil ? Color.orange : Color.secondary)
                    }
                }
                Spacer(minLength:4)
                Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top,4)
            }
            .padding(.horizontal,9).padding(.vertical,7)
            .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(item.id == recordID ? 0.08 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Report: \(item.record.update.title)\(item.record.unread ? ", unread" : "")")
    }
    private func notice(_ title:String,_ detail:String?) -> some View {
        VStack(spacing:10) {
            Image(systemName:"at.circle.fill").font(.system(size:34)).foregroundStyle(MailDotStyle.brand)
            Text(title).font(.headline)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true) }
        }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var footer:some View {
        HStack(spacing:8) {
            commands
            if let line { Text(line.text).font(.caption).foregroundStyle(line.failed ? Color.red : Color.secondary).lineLimit(2) }
            Spacer()
            Text(MailDotVersion.text).font(.caption).foregroundStyle(.tertiary)
        }.padding(.horizontal,14).padding(.vertical,10)
    }
    private func show(_ id:String) {
        line=nil; discussing=false; confirming=false; words=""
        if id != shownID { entry=nil; loaded=false; shownID=id }
        listing=false
    }
    /// The next report in the order of the list, beginning with what awaits the owner.
    private func next() {
        let all=queue.flatMap(\.entries)
        guard !all.isEmpty else { return }
        let index=listing ? nil : all.firstIndex{$0.id == shownID}
        show(all[index.map{($0+1)%all.count} ?? 0].id)
    }
    /// Mail opens a message by its Message-ID through the message: address.
    private func openMessage(_ id:String) {
        var allowed=CharacterSet.urlPathAllowed; allowed.remove(charactersIn:"/?#%")
        guard let escaped=id.addingPercentEncoding(withAllowedCharacters:allowed),let url=URL(string:"message://%3C\(escaped)%3E") else { return }
        if !NSWorkspace.shared.open(url) { line=(String(localized:"Mail could not open that message."),true,false) }
    }

    // MARK: The report

    private func report(_ entry:UpdateEntry) -> some View {
        let shown=entry.shown
        return VStack(alignment:.leading,spacing:14) {
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:8) {
                    Image(systemName:"at.circle.fill").foregroundStyle(MailDotStyle.brand)
                    Text("Dot’s report").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Pill(text:shown.status.title,color:color(shown.status))
                    Spacer(minLength:0)
                }
                Text(entry.record.update.title).font(.title3.bold()).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                if entry.id != recordID {
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        Text(String(localized:"On another message")+(shown.sender.map{String(localized:", from \($0)")} ?? "")+(shown.receivedAt.map{String(localized:", received \($0.formatted(date:.abbreviated,time:.shortened))")} ?? "")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        if let id=entry.messageID { Button("Open Message") { openMessage(id) }.controlSize(.small).keyboardShortcut("o",modifiers:[]).disabled(discussing || confirming).help("Open that message in Mail") }
                    }
                }
            }
            if entry.record.dismissedByOwner { Label("You ignored this report. The message stays in Mail.",systemImage:"nosign").foregroundStyle(.secondary) }
            section(String(localized:"Summary")) {
                ForEach(Array(shown.points.enumerated()),id:\.offset) { _,point in
                    if shown.points.count > 1 {
                        HStack(alignment:.firstTextBaseline,spacing:7) { Text("•").foregroundStyle(.secondary); Text(point).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                    } else { Text(point).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                }
                if !shown.unverified.isEmpty {
                    (Text("Not verified: ").bold().foregroundStyle(.orange)+Text(shown.unverified.joined(separator:"; ")+".").foregroundStyle(.secondary)).fixedSize(horizontal:false,vertical:true)
                }
            }
            if let decision=shown.decision { decisionSection(entry,decision) }
            if let followUp=shown.followUp { section(String(localized:"Follow-up needed")) { Text(followUp).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) } }
            if let option=entry.chosenOption,let preview=option.replyPreview,entry.owner?.handled == nil {
                section(String(localized:"Reply Dot will draft")) { box { Text(preview).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) } }
            }
            if let note=entry.owner?.note {
                section(String(localized:"Your instruction")) {
                    Text(note).fontWeight(.semibold)
                    if let pending=entry.pending {
                        HStack {
                            Label(pending.text,systemImage:pending.failed ? "exclamationmark.triangle" : "paperplane").foregroundStyle(pending.failed ? .red : .secondary).fixedSize(horizontal:false,vertical:true)
                            if pending.failed { Button("Retry") { run(String(localized:"Sent to Dot again.")) { try UpdateCommands.retry(entry) } } }
                        }
                    }
                }
            }
            if let draft=shown.draft {
                section(String(localized:"Reply draft")) {
                    box {
                        Text(String(localized:"To \(draft.to.joined(separator:", "))")+" · "+(shown.status == .draftedSent ? String(localized:"Sent") : draft.delivery == .send ? String(localized:"Sends after one confirmation on this Mac") : String(localized:"Saved in Mail Drafts")))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(draft.preview).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        if !draft.attachments.isEmpty { Text(draft.attachments.map{"📎 "+$0}.joined(separator:"   ")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !shown.work.isEmpty {
                section(String(localized:"Dot’s work")) {
                    ForEach(Array([MailUpdateWorkState.needsOwner,.inProgress,.done].flatMap{state in shown.work.filter{$0.state == state}}.enumerated()),id:\.offset) { _,item in
                        HStack(alignment:.top,spacing:8) {
                            Image(systemName:item.state == .done ? "checkmark.circle.fill" : item.state == .needsOwner ? "questionmark.circle.fill" : "clock.fill").foregroundStyle(color(item.state))
                            VStack(alignment:.leading,spacing:1) {
                                Text(item.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                                Text(item.sourceTitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            DisclosureGroup("How Dot checked") {
                Text(entry.record.update.coverage+" "+String(localized:"Checked \(entry.record.update.checkedAt.formatted(date:.abbreviated,time:.shortened))."))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            }.font(.callout).foregroundStyle(.secondary)
            if !shown.structured {
                Text("Dot wrote this report as one block of text. Once Dot’s tool list is refreshed in ChatGPT, its reports arrive here with numbered options and its work listed.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private func section(_ title:String,@ViewBuilder _ content:()->some View) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            content()
        }
    }
    private func box(@ViewBuilder _ content:()->some View) -> some View {
        VStack(alignment:.leading,spacing:6) { content() }
            .padding(.horizontal,11).padding(.vertical,9).frame(maxWidth:.infinity,alignment:.leading)
            .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12)))
    }
    private func decisionSection(_ entry:UpdateEntry,_ decision:MailUpdateDecision) -> some View {
        section(decision.kind == .question ? String(localized:"Dot’s question") : String(localized:"Decision")) {
            Text(decision.question).font(.body.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            ForEach(Array(decision.options.enumerated()),id:\.element.id) { index,option in
                let chosen=entry.owner?.chosen == option.id
                Button { choose(entry,option) } label: {
                    HStack(alignment:.top,spacing:9) {
                        Text("\(index+1)").font(.system(size:11,weight:.semibold)).foregroundStyle(chosen ? Color.white : Color.secondary)
                            .frame(width:20,height:19).background(RoundedRectangle(cornerRadius:4).fill(chosen ? MailDotStyle.tint : Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius:4).stroke(chosen ? Color.clear : Color.primary.opacity(0.22)))
                        VStack(alignment:.leading,spacing:1) {
                            Text(option.label).fontWeight(.semibold)
                            if decision.recommended == option.id { Text("Dot recommends").font(.caption2.weight(.semibold)).foregroundStyle(MailDotStyle.tint) }
                            Text(option.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:0)
                    }
                    .padding(.horizontal,10).padding(.vertical,8)
                    .background(RoundedRectangle(cornerRadius:8).fill(chosen ? MailDotStyle.tint.opacity(0.16) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(chosen ? MailDotStyle.tint : Color.primary.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(entry.owner?.handled != nil || discussing || confirming)
                .keyboardShortcut(KeyEquivalent(Character("\(index+1)")),modifiers:[])
                .accessibilityLabel("\(index+1), \(option.label). \(option.detail)\(decision.recommended == option.id ? ". Dot recommends" : "")")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
    private func color(_ status:MailUpdateStatus) -> Color {
        switch status {
        case .awaitingInstruction:.orange
        case .draftedQueued:MailDotStyle.tint
        case .draftedSent:.green
        case .information:.secondary
        }
    }
    private func color(_ state:MailUpdateWorkState) -> Color {
        switch state {
        case .done:.green
        case .inProgress:MailDotStyle.tint
        case .needsOwner:.orange
        }
    }

    // MARK: The actions

    private func actionBar(_ entry:UpdateEntry) -> some View {
        VStack(alignment:.leading,spacing:7) {
            if let line {
                HStack {
                    Text(line.text).font(.callout.weight(.semibold)).foregroundStyle(line.failed ? Color.red : Color.primary).fixedSize(horizontal:false,vertical:true)
                    if line.undo { Button("Undo") { undo(entry) }.controlSize(.small).keyboardShortcut("z",modifiers:[]) }
                    Spacer(minLength:0)
                }
            }
            HStack(spacing:8) {
                ForEach(Array(entry.controls.enumerated()),id:\.offset) { index,control in
                    let (title,enabled)=label(control)
                    if index == 0 {
                        Button(title) { perform(control,entry) }.buttonStyle(.borderedProminent).disabled(!enabled).keyboardShortcut(.defaultAction)
                    } else {
                        Button(title) { perform(control,entry) }.disabled(!enabled).keyboardShortcut(.return,modifiers:.command)
                    }
                }
                Spacer(minLength:4)
                commands
                Button("Discuss with Dot",systemImage:"bubble.left") { discussing=true; typing=true }.keyboardShortcut("d",modifiers:[])
                    .disabled(entry.owner?.handled == .instructed)
                Button("Ignore",systemImage:"nosign") { ignore(entry) }.keyboardShortcut("e",modifiers:[])
                    .disabled(entry.record.dismissedByOwner)
            }.lineLimit(1)
        }.padding(.horizontal,14).padding(.vertical,10)
    }
    /// What used to be in the menu bar, now inside Mail: a call with Dot, a spoken report, and the settings.
    private var commands:some View {
        Menu {
            Button("Call Dot",systemImage:"phone") { note(DotCallCommands.call(),String(localized:"Opening a call with Dot in ChatGPT.")) }
            Button("Spoken Mail Report",systemImage:"speaker.wave.2") { note(DotCallCommands.spokenReport(),String(localized:"Asked Dot for the report; your Mac reads it aloud when it arrives.")) }
            Divider()
            Button("Mail Dot Settings",systemImage:"gearshape") { showingSettings=true }
            Text(MailDotVersion.text)
        } label: { Image(systemName:"ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Call Dot, Spoken Mail Report, Settings")
        .accessibilityLabel("More Mail Dot commands")
    }
    private func note(_ refusal:String?,_ success:String) { line=(refusal ?? success,refusal != nil,false) }
    private func label(_ control:MailUpdatePrimary) -> (String,Bool) {
        switch control {
        case .choose(let count): (String(localized:"Choose 1–\(count)"),false)
        case .draftAndSave: (String(localized:"Draft and Save"),true)
        case .draftAndSend: (String(localized:"Draft and Send…"),true)
        case .sendDraft: (String(localized:"Send Draft…"),true)
        case .openDraftInMail: (String(localized:"Open Draft"),true)
        case .apply: (String(localized:"Apply"),true)
        case .sentToDot: (String(localized:"Sent to Dot"),false)
        }
    }
    private func discussBar(_ entry:UpdateEntry) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text("Tell Dot what to change, or ask a question. Its answer arrives as a new version of this report.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            TextField("Your words to Dot",text:$words,axis:.vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).focused($typing)
            HStack {
                Spacer()
                Button("Cancel") { discussing=false; words="" }.keyboardShortcut(.cancelAction)
                Button("Send to Dot") {
                    let text=words
                    run(String(localized:"Sent to Dot."),undo:true) { try UpdateCommands.instruct(entry,option:nil,delivery:nil,text:text,closes:false) }
                    discussing=false; words=""
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:.command)
                    .disabled(words.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || words.utf8.count > MailUpdateInstruction.textLimit)
            }
        }.padding(.horizontal,14).padding(.vertical,10)
    }
    /// The one confirmation Mail Dot requires before Mail sends, here as a second face of the confirmation
    /// in the notification and the reply panel.
    private func confirmBar(_ entry:UpdateEntry) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text("Send this reply to \(entry.shown.draft?.to.joined(separator:", ") ?? "its recipients")?").font(.callout.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
            Text("This is the one confirmation Mail Dot requires before Mail sends. Cancel leaves the draft queued.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Spacer()
                Button("Cancel") { confirming=false }.keyboardShortcut(.cancelAction)
                Button("Send") {
                    if let reference=entry.shown.draft?.reference { run(String(localized:"Confirmed. Tell Dot to send it.")) { try UpdateCommands.confirmSend(reference:reference) } }
                    confirming=false
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal,14).padding(.vertical,10)
    }

    private func run(_ success:String,undo:Bool=false,_ body:() throws -> Void) {
        do { try body(); line=(success,false,undo) } catch { line=(error.localizedDescription,true,false) }
        reload()
    }
    private func reload() {
        Task {
            if let shownID,let fresh=try? await UpdateEntry.load(recordID:shownID) { entry=fresh }
            if let fresh=try? await UpdateEntry.loadQueue() { queue=fresh }
        }
    }
    private func choose(_ entry:UpdateEntry,_ option:MailUpdateOption) {
        do { try UpdateCommands.choose(entry,option:option.id); line=nil } catch { line=(error.localizedDescription,true,false) }
        reload()
    }
    private func ignore(_ entry:UpdateEntry) {
        run(String(localized:"Ignored. The message stays in Mail."),undo:true) { try UpdateCommands.close(entry,as:.ignored) }
    }
    private func undo(_ entry:UpdateEntry) {
        run(String(localized:"Taken back.")) { try UpdateCommands.undo(entry.id) }
    }
    private func perform(_ control:MailUpdatePrimary,_ entry:UpdateEntry) {
        let option=entry.chosenOption
        switch control {
        case .choose,.sentToDot: return
        case .draftAndSave,.draftAndSend:
            guard let option else { return }
            let delivery:ProposalDelivery=control == .draftAndSend ? .send : .save
            run(delivery == .send ? String(localized:"Asked Dot to draft and send: \(option.label). Nothing is sent until you confirm on this Mac.") : String(localized:"Asked Dot to draft and save: \(option.label)."),undo:true) {
                try UpdateCommands.instruct(entry,option:option,delivery:delivery,text:nil,closes:false)
            }
        case .sendDraft: confirming=true
        case .openDraftInMail:
            line=(String(localized:"Mail Dot is not bound to this draft, so it cannot send it from here. Open the draft in Mail’s Drafts mailbox."),false,false)
        case .apply(let effect):
            switch effect {
            case .discuss: discussing=true; typing=true
            case .ignore: ignore(entry)
            case .delete: line=(String(localized:"Deleting from here is not built yet. Delete the message in Mail, or choose No Reply to close this report."),true,false)
            case .close:
                guard let option else { return }
                run(String(localized:"Closed, and Dot was told: \(option.label)."),undo:true) { try UpdateCommands.instruct(entry,option:option,delivery:nil,text:nil,closes:true) }
            case .answer,.resolve,.sendAsDrafted,.draftReply:
                guard let option else { return }
                run(String(localized:"Told Dot: \(option.label)."),undo:true) { try UpdateCommands.instruct(entry,option:option,delivery:nil,text:nil,closes:false) }
            }
        }
    }
}

private struct Pill:View {
    let text:String
    let color:Color
    var body:some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal,8).padding(.vertical,1.5).background(Capsule().fill(color.opacity(0.15)))
    }
}

