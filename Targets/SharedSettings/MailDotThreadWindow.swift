import SwiftUI
import AppKit
import BridgeCore

/// The Mail Dot window for one message, opened from its banner (owner request, 13 November 2026): Dot's report on
/// the thread (where it began, how it developed, what is decided and what is still to decide), Dot's
/// question, any meeting with Add to Calendar, and what Dot did, in one of three layouts the owner chooses
/// in Settings. It reports on this one message only. Without a report from Dot it shows what it showed before.
struct MailDotThreadWindow:View {
    /// 460 points wide, or wider where the interface language's button names need it (release review, 14 November
    /// 2026: the bottom bar ran past the window in 37 of 47 languages), as the reply panel does.
    static func size(_ layout:MailDotWindowLayout) -> CGSize { layout == .ledger ? CGSize(width:max(820,barWidth),height:730) : CGSize(width:max(460,barWidth),height:600) }
    private static let barWidth=ThreadActionBarRow.idealWidth
    /// Ledger needs room for 820 by 730; on a smaller screen the window shows Briefing.
    static func fits(_ layout:MailDotWindowLayout) -> Bool {
        guard layout == .ledger else { return true }
        let room=NSScreen.main?.visibleFrame.size ?? .zero
        return room.width >= 860 && room.height >= 770
    }
    let entryID:String
    /// Tells the window around this view its new size, when the layout changes.
    var resize:(CGSize) -> Void = { _ in }
    /// For rendering previews: an entry and layout given instead of read from the stores.
    var fixed:(entry:MailTriageEntry,layout:MailDotWindowLayout)?
    @State private var entry:MailTriageEntry?
    @State private var rule:MailTriage.Rule?
    @State private var reportRule:MailTriage.Rule?
    @State private var connection=ConnectionSnapshot()
    /// Whether the owner keeps drafting notes for this sender, and whether their page is shown.
    @State private var hasNotes=false
    @State private var notesPage=false
    @State private var layout:MailDotWindowLayout = .briefing
    @State private var settings=false
    @State private var line:(text:String,failed:Bool)?
    @State private var loaded=false

    private var shown:MailDotWindowLayout { Self.fits(layout) ? layout : .briefing }
    var body:some View {
        let size=Self.size(shown)
        VStack(spacing:0) {
            topBar
            Divider()
            if settings {
                MailDotSettingsView(startTab:.layout)
            } else if notesPage,let entry {
                // A page of its own for the sender's drafting notes (owner request, 14 November 2026).
                ScrollView { SenderNotesEditor(address:entry.sender,name:entry.senderName).padding(16) }
            } else if let entry {
                // One line naming why Dot cannot take requests, and nothing else (owner approval, 14 November 2026).
                // Previews drawn from given entries show the window as it is with Dot available.
                if fixed == nil,!connection.availability.isAvailable {
                    DotUnavailableLine(snapshot:connection,act:act)
                    Divider()
                }
                if entry.dotWorking { ThreadWorkingStrip(words:entry.workingWords) } else if entry.reportPending { ThreadWorkingStrip(words:"Dot is writing the report…") }
                switch shown {
                case .briefing: ScrollView { BriefingLayout(entry:entry,act:act).padding(16) }
                case .storyline: ScrollView { StorylineLayout(entry:entry,act:act).padding(16) }
                case .ledger: LedgerLayout(entry:entry,act:act)
                }
                Divider()
                ThreadActionBar(entry:entry,line:line,act:act) { settings=true }
            } else {
                Text(loaded ? "Mail Dot no longer lists this message." : "Loading…").foregroundStyle(MailDotStyle.supporting).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .frame(width:size.width,height:size.height)
        .background(Color(nsColor:.windowBackgroundColor))
        .tint(MailDotStyle.tint)
        .onChange(of:shown) { _,value in resize(Self.size(value)) }
        .task {
            if let fixed { entry=fixed.entry; layout=fixed.layout; loaded=true; return }
            while !Task.isCancelled { await reload(); try? await Task.sleep(for:.seconds(2)) }
        }
    }
    @ViewBuilder private var topBar:some View {
        if settings {
            MailDotSettingsBar(returnsTo:Text(verbatim:"Mail Dot")) { settings=false }.padding(.horizontal,14).padding(.vertical,9)
        } else { ordinaryBar }
    }
    private var ordinaryBar:some View {
        HStack(spacing:7) {
            Image(systemName:"at.circle.fill").foregroundStyle(MailDotStyle.brand).accessibilityHidden(true)
            if notesPage,let entry {
                VStack(alignment:.leading,spacing:0) {
                    Text("Drafting Notes").font(.headline)
                    Text(entry.senderName ?? entry.sender).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
                }
            } else {
                Text("Mail Dot").font(.headline)
            }
            Spacer()
            if notesPage,let entry {
                // Done sends the notes added or changed to Dot to polish, in one request.
                Button("Done",systemImage:"checkmark") {
                    notesPage=false
                    if let refusal=DotCallCommands.polishNotes(for:entry.sender) { line=(refusal,true) }
                }.buttonStyle(.borderless)
            }
            if !settings,!notesPage,let entry {
                SenderMenuButton(groups:[
                    .init(title:String(localized:"Automatic drafts for this sender"),symbol:"square.and.pencil",rule:rule) { value in act(nil) { try TriageCommands.rule(value,for:entry.sender) } },
                    .init(title:String(localized:"Dot’s report for this sender"),symbol:"doc.text.magnifyingglass",rule:reportRule) { value in act(nil) { try TriageCommands.reportRule(value,for:entry.sender) } }
                ],note:.init(exists:hasNotes) { notesPage=true })
                .fixedSize()
            }
            // Settings is the gear at the bottom right (owner request, 14 November 2026); the way back from it is the
            // chevron at the left of its own bar.
            if entry == nil {
                Button("Settings",systemImage:"gearshape") { settings=true }.buttonStyle(.borderless)
            }
        }.padding(.horizontal,14).padding(.vertical,9)
    }
    private func reload() async {
        let fresh=await TriageCommands.load()
        let found=fresh.entries.first{$0.id == entryID}
        if found != entry { entry=found }
        rule=found.flatMap{fresh.rules[$0.sender]}
        if let sender=found?.sender {
            let choices=await TriageCommands.senderChoices(sender)
            reportRule=choices.report; hasNotes=choices.hasNotes
        }
        if fixed == nil { let fresh=await ConnectionSnapshot.load(); if fresh != connection { connection=fresh } }
        let chosen=await TriageCommands.layout()
        if chosen != layout { layout=chosen }
        loaded=true
    }
    /// Runs one of the owner's actions; its result, or its failure, shows in the action bar.
    private func act(_ success:String?=nil,_ body:() throws -> Void) {
        do { try body(); line=success.map{($0,false)} } catch { line=(error.localizedDescription,true) }
        Task { await reload() }
    }
}

typealias ThreadAct = (_ success:String?,_ body:() throws -> Void) -> Void

// MARK: Pieces shared by the three layouts

/// Dates as Dot writes them, shown in the Mac's own way.
enum ThreadDates {
    static func short(_ text:String?) -> String? {
        guard let text else { return nil }
        guard let date=ThreadReport.date(text) else { return text }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    static func weekday(_ text:String?) -> String? {
        guard let text else { return nil }
        guard let date=ThreadReport.date(text) else { return text }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    static func range(_ from:String?,_ to:String?) -> String? {
        switch (short(from),short(to)) {
        case let (a?,b?): a == b ? a : String(localized:"\(a) to \(b)")
        case let (a?,nil): a
        case let (nil,b?): b
        default: nil
        }
    }
    /// The meeting's day and hours, in the Mac's locale and time zone.
    static func meeting(_ meeting:ThreadReport.Meeting) -> String {
        guard let start=meeting.startDate else { return meeting.start }
        let day=start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let from=start.formatted(date:.omitted,time:.shortened)
        guard let end=meeting.endDate else { return "\(day) · \(from)" }
        return "\(day) · "+String(localized:"\(from) to \(end.formatted(date:.omitted,time:.shortened))")
    }
}

extension MailTriageEntry {
    /// The banner's words without its emoji, for the state pill.
    var stateWords:String? {
        guard let title=MailDotBanner(self)?.title else { return nil }
        return title.split(separator:" ",maxSplits:1).last.map(String.init) ?? title
    }
    var stateColor:Color {
        switch outcome {
        case .needsGuidance: .orange
        case .drafted: .green
        case .pending,.asked: MailDotStyle.tint
        case .failed: .yellow
        default: .secondary
        }
    }
    /// Dot is working on this message: waiting its turn or asked and not yet answered.
    var dotWorking:Bool { outcome == .pending || outcome == .asked }
    /// What Dot is doing, in words: a draft the owner asked for comes first (owner decision, 15 November 2026).
    var workingWords:LocalizedStringKey { draftRequested == true || ownerAnswer != nil ? "Dot is writing the draft…" : "Dot is updating this report…" }
    /// What Dot did: the report's list, or else the Done: lines of its answer.
    var shownWork:[ThreadReport.Work] {
        if let work=report?.work,!work.isEmpty { return work.filter{!$0.needsOwner}+work.filter(\.needsOwner) }
        return (tasksDone ?? []).map{ ThreadReport.Work(text:$0,source:nil,sourceLabel:nil,state:"done") }
    }
}

/// A slim strip at the top of the window while Dot works on the message, visible however far the window is scrolled.
struct ThreadWorkingStrip:View {
    var words:LocalizedStringKey="Dot is updating this report…"
    var body:some View {
        HStack(spacing:8) {
            ProgressView().controlSize(.small)
            Text(words).font(.callout)
            Spacer(minLength:0)
        }
        .padding(.horizontal,16).padding(.vertical,7)
        .background(MailDotStyle.tint.opacity(0.12))
        .overlay(alignment:.bottom) { Divider() }
        .accessibilityElement(children:.combine)
    }
}

struct ThreadPill:View {
    let text:String
    let color:Color
    var body:some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color == .secondary ? MailDotStyle.supporting : color).lineLimit(1)
            .padding(.horizontal,8).padding(.vertical,2).background(Capsule().fill((color == .secondary ? Color.primary : color).opacity(0.14)))
    }
}

struct ThreadSection<Content:View>:View {
    let title:LocalizedStringKey
    @ViewBuilder let content:Content
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            Text(title).textCase(.uppercase).font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5)
            content
        }
    }
}

/// A rounded panel on the window's background, as Mail's own grouped content: a control background with a hairline.
struct ThreadCard<Content:View>:View {
    var spacing:CGFloat=9
    var tint:Color?=nil
    @ViewBuilder let content:Content
    var body:some View {
        VStack(alignment:.leading,spacing:spacing) { content }
            .padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(RoundedRectangle(cornerRadius:10).fill(tint.map{$0.opacity(0.10)} ?? Color(nsColor:.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(tint.map{$0.opacity(0.30)} ?? Color.primary.opacity(0.09)))
    }
}

struct ThreadHeader:View {
    let entry:MailTriageEntry
    var pill=true
    var fullParticipants=false
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            HStack(alignment:.firstTextBaseline,spacing:8) {
                Text(entry.subject.isEmpty ? String(localized:"(no subject)") : entry.subject).font(.headline).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:4)
                // The pill keeps its full width however long the subject is (a long subject squeezed it out, 13 November 2026).
                if pill,let words=entry.stateWords { ThreadPill(text:words,color:entry.stateColor).fixedSize().layoutPriority(1) }
            }
            Text(byline).font(.callout).foregroundStyle(MailDotStyle.supporting).lineLimit(2)
        }
    }
    private var byline:String {
        let sender=entry.senderName ?? entry.sender
        guard let thread=entry.report?.thread,let count=thread.messageCount,count > 1 else {
            return [sender,entry.receivedAt.map{$0.formatted(date:.abbreviated,time:.shortened)}].compactMap{$0}.joined(separator:" · ")
        }
        let people=thread.participants ?? []
        let who:String
        if fullParticipants,!people.isEmpty { who=people.joined(separator:", ") }
        else if let first=people.first { who=people.count > 1 ? String(localized:"\(first) and \(people.count-1) others") : first }
        else { who=sender }
        return [who,String(localized:"\(count) messages"),ThreadDates.range(thread.first,thread.last)].compactMap{$0}.joined(separator:" · ")
    }
}

/// Dot's question, when it has one; the report adds what bears on it and a note on each answer.
struct ThreadQuestion:View {
    let entry:MailTriageEntry
    let act:ThreadAct
    var columns=1
    var boxAlwaysOpen=false
    var showsHeading=true
    var plain=false
    var body:some View {
        if entry.outcome == .needsGuidance,let question=entry.dotNote {
            TriageQuestionCard(question:question,context:entry.report?.questionContext,notes:entry.report?.answerNotes ?? [],
                               columns:columns,boxAlwaysOpen:boxAlwaysOpen,showsHeading:showsHeading,plain:plain) { words in
                act(String(localized:"Sent to Dot. It drafts the reply with your answer.")) { try TriageCommands.answer(entry.id,words,opensReply:true) }
            }
        }
    }
}

/// Where the message stands when Dot sent no report: the state in words, and the draft when there is one.
struct ThreadPlainState:View {
    let entry:MailTriageEntry
    var body:some View {
        if !(entry.outcome == .needsGuidance && entry.dotNote != nil) {
            Text(entry.report?.now ?? entry.stateLine).foregroundStyle(entry.report?.now == nil ? .secondary : .primary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
        }
    }
}

/// Where the message stands: Dot's summary when it wrote a report; otherwise, in the report's own layout, why there is
/// none and the way to ask for one (owner choice, 13 November 2026). A report is asked for only by the owner's press: never
/// automatically, never for a draft.
struct ThreadStatus:View {
    let entry:MailTriageEntry
    let act:ThreadAct
    var body:some View {
        if entry.report != nil || entry.dotWorking {
            ThreadPlainState(entry:entry)
        } else if entry.reportPending {
            ThreadReportPlaceholder()
        } else {
            ThreadSection(title:"Where it stands") {
                ThreadCard(spacing:8) {
                    ForEach(Array(reasons.enumerated()),id:\.offset) { index,line in
                        Text(line).foregroundStyle(index == 0 ? .primary : .secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    if let failure=entry.reportFailed {
                        Label(String(localized:"Dot could not write the report: \(failure)"),systemImage:"exclamationmark.triangle")
                            .font(.callout).foregroundStyle(MailDotStyle.warningText).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
        }
    }
    /// Why there is no report, in plain words, then the message's state.
    private var reasons:[String] {
        switch entry.outcome {
        case .skipped where entry.reason == "Sent by you.":
            return [String(localized:"You sent this message, so Dot hasn’t written a report.")]
        case .skipped,.held:
            return [entry.stateLine]
        case .needsGuidance:
            return [String(localized:"Dot looked at this message before it wrote reports.")]
        default:
            return [entry.stateLine,String(localized:"Dot looked at this message before it wrote reports.")]
        }
    }
}

/// The report's sections, drawn grey while Dot writes the report.
struct ThreadReportPlaceholder:View {
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            ForEach(Array(["Where it stands","How it got here"].enumerated()),id:\.offset) { _,title in
                ThreadSection(title:LocalizedStringKey(title)) {
                    ThreadCard(spacing:9) {
                        ForEach([0.9,0.7,0.8],id:\.self) { share in
                            GeometryReader { proxy in RoundedRectangle(cornerRadius:3).fill(Color.primary.opacity(0.08)).frame(width:proxy.size.width*share,height:10) }.frame(height:10)
                        }
                    }
                }
            }
            HStack(spacing:6) { ProgressView().controlSize(.small); Text("Dot is writing the report…").font(.callout).foregroundStyle(MailDotStyle.supporting) }
        }
        .accessibilityElement(children:.ignore).accessibilityLabel("Dot is writing the report")
    }
}

struct ThreadDraft:View {
    let entry:MailTriageEntry
    var body:some View {
        if entry.outcome == .drafted,let draft=entry.draft {
            ThreadSection(title:"Dot’s draft") {
                ThreadCard(spacing:6) {
                    Text(draft).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                }
            }
        }
    }
}

struct ThreadStands:View {
    let report:ThreadReport
    var body:some View {
        let decided=report.decided ?? [],open=report.open ?? []
        if !decided.isEmpty || !open.isEmpty {
            ThreadSection(title:"Where it stands") {
                ThreadCard {
                    HStack(alignment:.top,spacing:14) {
                        if !decided.isEmpty {
                            VStack(alignment:.leading,spacing:8) {
                                Text("Decided").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.successText)
                                ForEach(Array(decided.enumerated()),id:\.offset) { _,item in
                                    mark("checkmark.circle",.green,[item.item,item.value].compactMap{$0}.joined(separator:": "),
                                         [item.by,ThreadDates.short(item.date)].compactMap{$0}.joined(separator:", "))
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                        if !open.isEmpty {
                            VStack(alignment:.leading,spacing:8) {
                                Text("Still to decide").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.warningText)
                                ForEach(Array(open.enumerated()),id:\.offset) { _,item in
                                    mark("circle",item.isOwners ? .orange : .secondary,item.item,ThreadOpenLine.text(item))
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }
                }
            }
        }
    }
    private func mark(_ symbol:String,_ color:Color,_ title:String,_ detail:String) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:7) {
            Image(systemName:symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:1) {
                Text(title).fontWeight(.medium).fixedSize(horizontal:false,vertical:true)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true) }
            }
        }
    }
}

enum ThreadOpenLine {
    /// Who decides an open matter and by when: "Yours · due Mon, Nov 16", "Priya · waits on the hall".
    static func text(_ item:ThreadReport.Open) -> String {
        let who=item.isOwners ? String(localized:"Yours") : item.owner
        let due=item.due.flatMap{ThreadDates.weekday($0)}.map{String(localized:"due \($0)")}
        return [who,due ?? item.note].compactMap{$0}.joined(separator:" · ")
    }
}

struct ThreadHistory:View {
    let entry:MailTriageEntry
    var body:some View {
        if let report=entry.report,report.origin != nil || report.development != nil || report.thisMessage != nil {
            ThreadSection(title:"How it got here") {
                ThreadCard(spacing:10) {
                    if let origin=report.origin { row("Origin",ThreadDates.short(origin.date),origin.text,.primary) }
                    if let development=report.development { row("Development",ThreadDates.range(development.from,development.to),development.text,.primary) }
                    if let now=report.thisMessage { row("This message",ThreadDates.short(now.date),now.text,MailDotStyle.tint) }
                }
            }
        }
    }
    private func row(_ title:LocalizedStringKey,_ date:String?,_ text:String,_ color:Color) -> some View {
        HStack(alignment:.top,spacing:10) {
            VStack(alignment:.leading,spacing:1) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
                if let date { Text(date).font(.caption).foregroundStyle(MailDotStyle.supporting) }
            }.frame(width:92,alignment:.leading)
            Text(text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
        }
    }
}

/// The meeting the message sets or proposes, with Add to Calendar. The button adds the event to the
/// owner's own calendar only: it never accepts or declines an invitation and notifies no one.
struct ThreadMeeting:View {
    let entry:MailTriageEntry
    let act:ThreadAct
    var titled=true
    var body:some View {
        if let meeting=entry.report?.meeting {
            if titled { ThreadSection(title:"Meeting in this message") { card(meeting) } } else { card(meeting) }
        }
    }
    private func card(_ meeting:ThreadReport.Meeting) -> some View {
        ThreadCard {
            HStack(alignment:.center,spacing:10) {
                Image(systemName:meeting.url != nil ? "video" : "calendar").font(.system(size:16)).foregroundStyle(MailDotStyle.tint)
                    .frame(width:34,height:34).background(RoundedRectangle(cornerRadius:8).fill(MailDotStyle.tint.opacity(0.14))).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:1) {
                    Text([meeting.title,meeting.platform].compactMap{$0}.joined(separator:" · ")).fontWeight(.semibold).lineLimit(2)
                    Text(ThreadDates.meeting(meeting)).font(.callout)
                    let details=[meeting.meetingID.map{String(localized:"ID \($0)")},meeting.location,availability(meeting)].compactMap{$0}
                    if !details.isEmpty { Text(details.joined(separator:" · ")).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(2) }
                }
                Spacer(minLength:6)
                buttons(meeting)
            }
            if let note=entry.calendarNote { Text(note).font(.caption).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true) }
        }
    }
    private func availability(_ meeting:ThreadReport.Meeting) -> String? {
        switch meeting.availability {
        case "free": String(localized:"you are free then")
        case "busy": meeting.conflict.map{String(localized:"conflicts with \($0)")} ?? String(localized:"you are busy then")
        default: nil
        }
    }
    @ViewBuilder private func buttons(_ meeting:ThreadReport.Meeting) -> some View {
        VStack(alignment:.trailing,spacing:5) {
            if meeting.added == true || entry.calendarAdded == true {
                Text(meeting.added == true ? "In your calendar" : "Added").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.successText)
                Button("Show in Calendar") { ThreadCalendar.show(meeting) }.controlSize(.small)
            } else if entry.calendarRequestedAt != nil {
                HStack(spacing:5) { ProgressView().controlSize(.mini); Text("Adding…").font(.caption).foregroundStyle(MailDotStyle.supporting) }
            } else {
                Button("Add to Calendar") { act(nil) { try TriageCommands.addToCalendar(entry.id) } }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            if let url=meeting.url {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType:.string)
                    act(String(localized:"Meeting link copied.")) {}
                }.controlSize(.small)
            }
        }.fixedSize()
    }
}

enum ThreadCalendar {
    /// Opens Calendar, where the meeting now is.
    @MainActor static func show(_ meeting:ThreadReport.Meeting) {
        if let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.iCal") {
            NSWorkspace.shared.openApplication(at:app,configuration:NSWorkspace.OpenConfiguration()) { _,_ in }
        }
    }
}

struct ThreadWork:View {
    let entry:MailTriageEntry
    var titled=true
    var body:some View {
        let work=entry.shownWork
        if !work.isEmpty {
            if titled { ThreadSection(title:"What Dot did") { list(work) } } else { list(work) }
        }
    }
    private func list(_ work:[ThreadReport.Work]) -> some View {
        ThreadCard(spacing:8) {
            ForEach(Array(work.enumerated()),id:\.offset) { _,item in
                HStack(alignment:.firstTextBaseline,spacing:7) {
                    Image(systemName:item.needsOwner ? "clock" : "checkmark").foregroundStyle(item.needsOwner ? MailDotStyle.warningText : Color.green).accessibilityHidden(true)
                    Text(item.text).foregroundStyle(item.needsOwner ? .secondary : .primary).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                    if let chip=item.chip { ThreadPill(text:chip,color:.secondary) }
                }
            }
        }
    }
}

/// The bar at the bottom: the state's own actions, Call Dot, and when Dot last looked (owner request, 13 November 2026:
/// "Ask Dot Again" is no longer a standing button, and there is no refresh).
struct ThreadActionBar:View {
    let entry:MailTriageEntry
    let line:(text:String,failed:Bool)?
    let act:ThreadAct
    var openSettings:() -> Void = {}
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            // The status line: what was just done, then when Dot last reported (moved up from the button row, owner
            // decision, 15 November 2026, so that Open in Reply has its room). No refresh button (owner decision,
            // 13 November 2026): asking Dot again takes minutes.
            let shown=line ?? entry.openReplyFailed.map{ ($0,true) }
            TimelineView(.periodic(from:.now,by:30)) { context in
                let words=entry.dotWorking ? nil : ThreadUpdated.words(entry,now:context.date)
                if shown != nil || words != nil {
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        if let shown { Text(shown.text).font(.callout).foregroundStyle(shown.failed ? MailDotStyle.dangerText : MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true) }
                        Spacer(minLength:8)
                        if let words { Text(words).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1).fixedSize() }
                    }
                }
            }
            // Four labelled buttons with icons fit on one line (owner request, 14 November 2026): tighter spacing and
            // small controls in the window's 460 points, or the wider window a longer language is given.
            HStack(spacing:6) {
                HStack(spacing:6) {
                actions
                // With no report, asking for one sits here with the other actions (owner request, 14 November 2026);
                // beside a draft it gives way to Open in Reply, since Dot has read the thread to write the draft.
                if entry.report == nil,!entry.dotWorking,!entry.reportPending,entry.outcome != .drafted {
                    Button("Get Report",systemImage:"doc.text.magnifyingglass") { act(nil) { try TriageCommands.askForReport(entry.id) } }
                        .help("Dot reads the thread and writes its report. No draft. This can take a minute or more.")
                }
                Button { act(DotCallCommands.call() ?? String(localized:"Opening a call with Dot in ChatGPT.")) {} } label: { Label("Call Dot",systemImage:"phone") }
                // Ask Dot: a question about the whole account, in the floating ask bar (owner request, 14 November 2026).
                Button { act(nil) { try TriageCommands.showAskBar() } } label: { Label("Ask Dot",systemImage:"sparkle.magnifyingglass") }
                    .help("Ask Dot a question about your mail (⇧⌥⌘F)")
                }.fixedSize()
                Spacer(minLength:6)
                Button(action:openSettings) { Image(systemName:"gearshape") }
                    .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
                if entry.dotWorking {
                    // While Dot works on the message (owner request, 13 November 2026): a spinner and words saying so,
                    // until Dot's answer arrives.
                    Text(entry.workingWords).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
                    ProgressView().controlSize(.small).frame(width:28,height:22).accessibilityLabel(Text(entry.workingWords))
                }
            }
            .controlSize(.small)
        }.padding(.horizontal,14).padding(.vertical,10)
    }
    @ViewBuilder private var actions:some View {
        switch entry.outcome {
        case .needsGuidance:
            Button("No Reply Needed",systemImage:"checkmark.circle") { act(String(localized:"Marked No reply needed. Dot was not asked.")) { try TriageCommands.noReplyNeeded(entry.id) } }
        case .drafted:
            // Open in Reply first, as the main action (owner decision, 15 November 2026).
            Button("Open in Reply",systemImage:"arrowshape.turn.up.left") { act(String(localized:"Close this window, and the reply opens with Dot’s draft in it.")) { try TriageCommands.openInReply(entry.id) } }
                .help("Opens a reply in Mail with Dot’s draft in it. You edit it and send it from Mail.")
            Button("Discard Draft",systemImage:"trash") { act(nil) { try TriageCommands.discardDraft(entry.id) } }
        case .noDraft:
            // "Draft a Reply" in every state that offers a draft (owner decision, 14 November 2026: "Draft Anyway" did not say what it drafted).
            draftReply
        case .failed:
            Button("Try Again",systemImage:"arrow.clockwise") { act(String(localized:"Asked Dot again.")) { try TriageCommands.ask(entry.id,opensReply:true) } }
        case .held,.skipped:
            draftReply
        case .pending,.asked,.replied:
            EmptyView()
        }
    }
}

/// The bottom bar at its widest, in the interface language, measured once for the window's width: each first button
/// the bar can show, with Get Report, Call Dot and Ask Dot, then the gear and the bar's margins.
@MainActor enum ThreadActionBarRow {
    static var idealWidth:CGFloat {
        func width(_ first:LocalizedStringKey,_ symbol:String) -> CGFloat {
            let row=HStack(spacing:6) {
                Button(first,systemImage:symbol) {}
                Button("Get Report",systemImage:"doc.text.magnifyingglass") {}
                Button { } label: { Label("Call Dot",systemImage:"phone") }
                Button { } label: { Label("Ask Dot",systemImage:"sparkle.magnifyingglass") }
                Spacer().frame(width:6)
                Button { } label: { Image(systemName:"gearshape") }.buttonStyle(.borderless)
            }.controlSize(.small).fixedSize()
            return NSHostingView(rootView:row).fittingSize.width
        }
        // Beside a draft: Open in Reply and Discard Draft, with Call Dot and Ask Dot (Get Report is not shown there).
        let drafted=NSHostingView(rootView:HStack(spacing:6) {
            Button("Open in Reply",systemImage:"arrowshape.turn.up.left") {}
            Button("Discard Draft",systemImage:"trash") {}
            Button { } label: { Label("Call Dot",systemImage:"phone") }
            Button { } label: { Label("Ask Dot",systemImage:"sparkle.magnifyingglass") }
            Spacer().frame(width:6)
            Button { } label: { Image(systemName:"gearshape") }.buttonStyle(.borderless)
        }.controlSize(.small).fixedSize()).fittingSize.width
        let widest=[width("No Reply Needed","checkmark.circle"),drafted,width("Draft a Reply","square.and.pencil"),width("Try Again","arrow.clockwise")].max() ?? 0
        return ceil(widest)+28   // the bar's side padding
    }
}

extension ThreadActionBar {
    private var draftReply:some View {
        DraftReplyButton { words in act(String(localized:"Asked Dot for a draft.")) { try TriageCommands.draftReply(entry.id,guidance:words,opensReply:true) } }
    }
}

/// Draft a Reply asks what the reply should say (owner request, 14 November 2026): Dot may have found no reply needed,
/// or never read the message, so it needs the owner's word. The words are optional; a sender's drafting note still applies.
struct DraftReplyButton:View {
    let send:(String) -> Void
    @State private var open=false
    @State private var words=""
    var body:some View {
        Button("Draft a Reply",systemImage:"square.and.pencil") { open=true }
            .popover(isPresented:$open,arrowEdge:.top) {
                DraftGuidanceForm(words:$words,cancel:{ open=false }) { let text=words; open=false; words=""; send(text) }
            }
    }
}

/// The popover's question, its optional box, and Cancel and Draft.
struct DraftGuidanceForm:View {
    @Binding var words:String
    let cancel:() -> Void
    let draft:() -> Void
    @FocusState private var focused:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("What should the reply say?").font(.headline)
            TextField("For example: decline politely, or confirm Friday at 3",text:$words,axis:.vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Spacer()
                Button("Cancel",action:cancel).keyboardShortcut(.cancelAction)
                Button("Draft",action:draft).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width:320)
        .onAppear { focused=true }
    }
}

enum ThreadUpdated {
    /// "Updated 2 min ago": whole minutes, then hours, then a date; never seconds.
    static func words(_ entry:MailTriageEntry,now:Date) -> String? {
        guard let at=entry.reportedAt else { return nil }
        let minutes=Int(now.timeIntervalSince(at)/60)
        if minutes < 1 { return String(localized:"Updated just now") }
        if minutes < 60 { return String(localized:"Updated \(minutes) min ago") }
        if minutes < 24*60 { return String(localized:"Updated \(minutes/60) hr ago") }
        return String(localized:"Updated \(at.formatted(date:.abbreviated,time:.omitted))")
    }
}

// MARK: A · Briefing

/// One column; what needs the owner comes first.
struct BriefingLayout:View {
    let entry:MailTriageEntry
    let act:ThreadAct
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            ThreadHeader(entry:entry)
            ThreadQuestion(entry:entry,act:act)
            ThreadStatus(entry:entry,act:act)
            ThreadDraft(entry:entry)
            if let report=entry.report { ThreadStands(report:report) }
            ThreadHistory(entry:entry)
            ThreadMeeting(entry:entry,act:act)
            ThreadWork(entry:entry)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

// MARK: B · Storyline

/// The thread as a timeline, ending at the owner's next step.
struct StorylineLayout:View {
    let entry:MailTriageEntry
    let act:ThreadAct
    @State private var workOpen=false
    var body:some View {
        let report=entry.report
        VStack(alignment:.leading,spacing:14) {
            ThreadHeader(entry:entry,pill:false)
            if let now=report?.now {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Image(systemName:entry.outcome == .needsGuidance ? "clock" : "info.circle").foregroundStyle(entry.stateColor).accessibilityHidden(true)
                    Text(now).fixedSize(horizontal:false,vertical:true)
                }
                .padding(.horizontal,12).padding(.vertical,9).frame(maxWidth:.infinity,alignment:.leading)
                .background(RoundedRectangle(cornerRadius:10).fill(entry.stateColor.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(entry.stateColor.opacity(0.28)))
            } else {
                ThreadStatus(entry:entry,act:act)
            }
            if let report { timeline(report) } else {
                ThreadQuestion(entry:entry,act:act)
                ThreadMeeting(entry:entry,act:act)
            }
            ThreadDraft(entry:entry)
            workRow
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func timeline(_ report:ThreadReport) -> some View {
        let question=entry.outcome == .needsGuidance && entry.dotNote != nil
        let steps=report.steps ?? []
        VStack(alignment:.leading,spacing:0) {
            if let origin=report.origin {
                node(.secondary) { stamp("Origin",ThreadDates.weekday(origin.date)); Text(origin.text).fixedSize(horizontal:false,vertical:true) }
            }
            if !steps.isEmpty {
                ForEach(Array(steps.enumerated()),id:\.offset) { _,step in
                    node(.secondary) { stamp(nil,ThreadDates.weekday(step.date)); Text(step.text).fixedSize(horizontal:false,vertical:true) }
                }
            } else if let development=report.development {
                node(.secondary) { stamp("Development",ThreadDates.range(development.from,development.to)); Text(development.text).fixedSize(horizontal:false,vertical:true) }
            }
            if let decided=report.decided,!decided.isEmpty {
                node(.green) {
                    stamp("Decided",ThreadDates.weekday(decided.compactMap(\.date).last),color:.green)
                    ForEach(Array(decided.enumerated()),id:\.offset) { _,item in
                        Label([item.item,item.value].compactMap{$0}.joined(separator:": "),systemImage:"checkmark").labelStyle(TightLabel(color:.green))
                    }
                }
            }
            if report.thisMessage != nil || report.meeting != nil {
                node(MailDotStyle.tint) {
                    stamp("This message",ThreadDates.weekday(report.thisMessage?.date),color:MailDotStyle.tint)
                    if let text=report.thisMessage?.text { Text(text).fixedSize(horizontal:false,vertical:true) }
                    ThreadMeeting(entry:entry,act:act,titled:false)
                }
            }
            if question {
                node(.orange,hollow:true,dashed:true) {
                    let due=report.open?.first(where:{$0.asked == true})?.due ?? report.open?.first(where:\.isOwners)?.due
                    stamp("Next: your decision",due.flatMap{ThreadDates.weekday($0)}.map{String(localized:"due \($0)")},color:.orange)
                    ThreadQuestion(entry:entry,act:act,showsHeading:false)
                }
            }
            if let next=report.next {
                node(.secondary,hollow:true,last:true) {
                    Text("After that").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting)
                    Text(next).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true)
                }
            }
        }
    }
    private func stamp(_ title:LocalizedStringKey?,_ date:String?,color:Color = .primary) -> some View {
        HStack(spacing:4) {
            if let title { Text(title).fontWeight(.semibold).foregroundStyle(color) }
            if title != nil,date != nil { Text(verbatim:"·").foregroundStyle(MailDotStyle.supporting) }
            if let date { Text(date).foregroundStyle(MailDotStyle.supporting) }
        }.font(.caption)
    }
    private func node(_ color:Color,hollow:Bool=false,dashed:Bool=false,last:Bool=false,@ViewBuilder _ content:() -> some View) -> some View {
        HStack(alignment:.top,spacing:10) {
            VStack(spacing:4) {
                Circle().strokeBorder(color == .secondary ? MailDotStyle.supporting : color,lineWidth:hollow ? 2.5 : 0)
                    .background(Circle().fill(hollow ? Color.clear : (color == .secondary ? MailDotStyle.supporting : color)))
                    .frame(width:10,height:10).padding(.top,4)
                if !last {
                    Rectangle().fill(Color.clear).frame(width:2).frame(maxHeight:.infinity)
                        .overlay(Line().stroke(Color.primary.opacity(dashed ? 0.25 : 0.15),style:StrokeStyle(lineWidth:2,dash:dashed ? [4,3] : [])))
                }
            }.frame(width:14).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:5) { content() }.padding(.bottom,last ? 0 : 14).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    @ViewBuilder private var workRow:some View {
        let work=entry.shownWork
        if !work.isEmpty {
            VStack(alignment:.leading,spacing:8) {
                Button { withAnimation(.snappy) { workOpen.toggle() } } label: {
                    HStack(spacing:8) {
                        Image(systemName:"checkmark.circle").foregroundStyle(.green).accessibilityHidden(true)
                        Text("Dot’s work").fontWeight(.medium)
                        Spacer(minLength:4)
                        ForEach(Array(Set(work.compactMap(\.chip))).sorted(),id:\.self) { ThreadPill(text:$0,color:.secondary) }
                        Image(systemName:workOpen ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(MailDotStyle.supporting)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(workOpen ? "Hide Dot’s work" : "Show Dot’s work")
                if workOpen { ThreadWork(entry:entry,titled:false) }
            }
            .padding(.horizontal,12).padding(.vertical,10)
            .background(RoundedRectangle(cornerRadius:10).fill(Color(nsColor:.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(Color.primary.opacity(0.09)))
        }
    }
}

private struct Line:Shape {
    func path(in rect:CGRect) -> Path { var path=Path(); path.move(to:CGPoint(x:rect.midX,y:rect.minY)); path.addLine(to:CGPoint(x:rect.midX,y:rect.maxY)); return path }
}

private struct TightLabel:LabelStyle {
    let color:Color
    func makeBody(configuration:Configuration) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:6) { configuration.icon.foregroundStyle(color).font(.caption.weight(.bold)); configuration.title.fixedSize(horizontal:false,vertical:true) }
    }
}

// MARK: C · Ledger

/// Two panes in a wider window; each decision is a row.
struct LedgerLayout:View {
    let entry:MailTriageEntry
    let act:ThreadAct
    var body:some View {
        let report=entry.report
        VStack(alignment:.leading,spacing:0) {
            ThreadHeader(entry:entry,fullParticipants:true).padding(.horizontal,16).padding(.vertical,14)
            HStack(alignment:.top,spacing:16) {
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        if let report,report.origin != nil || report.development != nil || report.now != nil || report.thisMessage != nil {
                            ThreadSection(title:"Thread report") {
                                ThreadCard(spacing:10) {
                                    if let origin=report.origin { item("Origin",ThreadDates.short(origin.date),origin.text,.primary) }
                                    if let development=report.development { item("Development",ThreadDates.range(development.from,development.to),development.text,.primary) }
                                    if let now=report.thisMessage ?? report.now.map({ThreadReport.Dated(date:nil,text:$0)}) {
                                        item("Now",ThreadDates.short(now.date),now.text,MailDotStyle.tint)
                                    }
                                }
                            }
                        } else {
                            ThreadStatus(entry:entry,act:act)
                        }
                        ThreadWork(entry:entry)
                    }.padding(.bottom,14)
                }.frame(width:270)
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        decisions(report)
                        ThreadDraft(entry:entry)
                        ThreadMeeting(entry:entry,act:act)
                    }.padding(.bottom,14)
                }
            }.padding(.horizontal,16)
        }
    }
    private func item(_ title:LocalizedStringKey,_ date:String?,_ text:String,_ color:Color) -> some View {
        VStack(alignment:.leading,spacing:2) {
            HStack(spacing:4) {
                Text(title).fontWeight(.semibold).foregroundStyle(color)
                if let date { Text(verbatim:"· "+date).foregroundStyle(MailDotStyle.supporting) }
            }.font(.caption)
            Text(text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
        }
    }
    @ViewBuilder private func decisions(_ report:ThreadReport?) -> some View {
        let decided=report?.decided ?? [],open=report?.open ?? []
        let question=entry.outcome == .needsGuidance && entry.dotNote != nil
        let askedRow=open.firstIndex{$0.asked == true}
        if !decided.isEmpty || !open.isEmpty || question {
            ThreadSection(title:"Decisions") {
                VStack(alignment:.leading,spacing:0) {
                    // Dot's question with no matter of the report to hang it on goes first.
                    if question,askedRow == nil { questionBlock.padding(12).background(MailDotStyle.warningText.opacity(0.10)) }
                    ForEach(Array(decided.enumerated()),id:\.offset) { index,item in
                        if index > 0 || (question && askedRow == nil) { Divider() }
                        row("checkmark.circle",.green,item.item,item.value ?? "",[item.by.map{String(localized:"Decided by \($0)")},ThreadDates.short(item.date)].compactMap{$0}.joined(separator:", "))
                    }
                    ForEach(Array(open.enumerated()),id:\.offset) { index,item in
                        if index > 0 || !decided.isEmpty || (question && askedRow == nil) { Divider() }
                        if question,index == askedRow {
                            VStack(alignment:.leading,spacing:8) {
                                row("circle",.orange,item.item,item.isOwners ? String(localized:"Yours to decide") : (item.owner ?? ""),item.due.flatMap{ThreadDates.weekday($0)}.map{String(localized:"Due \($0)")} ?? "",strong:true,padded:false)
                                questionBlock
                            }.padding(12).background(MailDotStyle.warningText.opacity(0.10))
                        } else {
                            row("circle",item.isOwners ? .orange : .secondary,item.item,item.isOwners ? String(localized:"Yours to decide") : (item.owner.map{String(localized:"\($0) to decide")} ?? ""),item.due.flatMap{ThreadDates.weekday($0)}.map{String(localized:"Due \($0)")} ?? item.note ?? "")
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius:10).fill(Color(nsColor:.controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(Color.primary.opacity(0.09)))
            }
        }
    }
    private var questionBlock:some View { ThreadQuestion(entry:entry,act:act,columns:2,boxAlwaysOpen:true,showsHeading:false,plain:true) }
    private func row(_ symbol:String,_ color:Color,_ title:String,_ value:String,_ detail:String,strong:Bool=false,padded:Bool=true) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {
            Image(systemName:symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(title).fontWeight(.semibold).frame(width:96,alignment:.leading).lineLimit(2)
            Text(value).fontWeight(strong ? .semibold : .regular).foregroundStyle(strong ? color : .primary).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(MailDotStyle.supporting).multilineTextAlignment(.trailing) }
        }
        .padding(.horizontal,padded ? 12 : 0).padding(.vertical,padded ? 9 : 0)
    }
}

#if DEBUG
extension MailDotThreadWindow {
    /// Invented messages for the thread window's previews. No real names or mail.
    static func previewEntries() -> [(String,MailTriageEntry)] {
        func make(_ subject:String,_ name:String,_ outcome:MailTriageEntry.Outcome) -> MailTriageEntry {
            var entry=MailTriageEntry(messageID:"\(UUID().uuidString)@example.invalid",sender:"sender@example.invalid",senderName:name,subject:subject,receivedAt:Date().addingTimeInterval(-3600),
                                      verdict:MailTriage.Verdict(essential:true,reason:"A person wrote to you directly."),automatic:true)
            entry.outcome=outcome; entry.reportedAt=Date().addingTimeInterval(-120)
            return entry
        }
        let year=Calendar.current.component(.year,from:.now)
        var thread=make("Spring workshop: venue and date","Maya Okafor",.needsGuidance)
        thread.dotNote="Which hall should the reply to Maya choose?\n1. Harbor Hall, both days\n2. Harbor Hall, then Cedar Room\n3. Cedar Room, both days"
        thread.report=ThreadReport.parse(#"{"thread":{"messageCount":7,"participants":["Maya Okafor","Daniel Reyes","Priya Nair","you"],"first":"\#(year)-11-03","last":"\#(year)-11-12"},"now":"Waiting on you: Maya asks for the hall by Monday.","origin":{"date":"\#(year)-11-03","text":"Maya Okafor asked the planning group to fix the dates and the venue for the spring workshop."},"development":{"from":"\#(year)-11-05","to":"\#(year)-11-11","text":"Daniel Reyes offered Harbor Hall (120 seats) and Cedar Room (60). Priya Nair said the budget covers Harbor Hall for one day only."},"steps":[{"date":"\#(year)-11-05","text":"Daniel Reyes offered two halls: Harbor Hall (120 seats) and Cedar Room (60 seats)."},{"date":"\#(year)-11-09","text":"Priya Nair said the budget covers Harbor Hall for one day only."}],"thisMessage":{"date":"\#(year)-11-12","text":"Maya asks you to choose the hall by Monday and invites the group to a planning call."},"decided":[{"item":"Dates","value":"March 11 and 12","by":"all","date":"\#(year)-11-11"},{"item":"Catering","value":"Same vendor","by":"Maya Okafor","date":"\#(year)-11-11"}],"open":[{"item":"Extra budget","owner":"Priya Nair","note":"waits on the hall"},{"item":"Hall","owner":"you","due":"\#(year)-11-16","asked":true}],"next":"Dot drafts your reply to Maya. Priya Nair then decides whether to request the extra budget.","questionContext":"Last year drew 85 people. Cedar Room seats 60.","answerNotes":["needs extra budget","within budget","25 seats short"],"meeting":{"title":"Planning call","start":"\#(year)-11-19T10:00:00+09:00","end":"\#(year)-11-19T10:45:00+09:00","platform":"Zoom","link":"https://example.invalid/j/84522071196","meetingID":"845 2207 1196","availability":"free"},"work":[{"text":"Checked your calendar for Nov 19: free.","source":"calendar","state":"done"},{"text":"Found last year’s attendance (85) in a Drive report.","source":"drive","state":"done"},{"text":"Compared the two halls’ prices in the attached quote.","sourceLabel":"Attachment","state":"done"},{"text":"Waiting for you: the reply to Maya.","state":"needsOwner"}]}"#)
        var single=make("Lunch on Friday?","Sam Lee",.drafted)
        single.dotNote="Sam asks whether you are free for lunch on Friday."
        single.draft="Dear Sam,\n\nFriday works well. Shall we meet at noon at the usual place?\n\nBest wishes"
        single.report=ThreadReport.parse(#"{"now":"Dot drafted a yes; it waits for you to send it.","thisMessage":{"date":"\#(year)-11-13","text":"Sam asks whether you are free for lunch on Friday."},"work":[{"text":"Checked your calendar for Friday noon: free.","source":"calendar","state":"done"}]}"#)
        var bare=make("Room booking","Front Desk",.noDraft)
        bare.dotNote="No reply needed: it confirms a booking you already made."; bare.reportedAt=nil
        return [("question",thread),("single",single),("noreport",bare)]
    }
}
#endif
