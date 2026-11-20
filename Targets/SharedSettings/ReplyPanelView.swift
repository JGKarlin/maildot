import SwiftUI
import AppKit
import OSLog
import BridgeCore

/// The Mail Dot panel on a reply. Its purpose is the owner's: opening it sets Dot drafting the reply; the
/// owner says here whether the reply is saved, sent or ignored; and when Dot needs guidance, its question
/// is answered here with one press, in a line of text, or on a call. It knows nothing of MailKit, so the
/// same view is shown in Mail's compose popover and can be run for inspection outside Mail.
@MainActor struct ReplyPanelView: View {
    /// 520 points, or wider where the interface language's button names need it (owner request, 14 November 2026:
    /// the top row ran out of room in about 30 languages). Measured once.
    static let size=CGSize(width:max(520,ReplyChoicesRow.idealWidth+32+8),height:600)
    let contextID:String
    /// Records this compose window's envelope as a reply context if it is not yet known.
    let registerContext:() throws -> Void
    let willShare:() -> Void
    /// Takes the message's headers as Mail has them now, such as a subject the owner just typed.
    var refreshEnvelope:() -> Void = {}
    /// Where the panel notes how far it got, when it is shown by the extension.
    var trace:(String) -> Void = { _ in }
    @State private var context:ReplyContext?
    @State private var loaded=false
    @State private var connected=true
    @State private var editor=""
    @State private var loadedText=""
    @State private var loadedRevision=0
    /// The revision of Dot's draft this panel has already asked Mail to place, so it is asked once.
    @State private var placedRevision=0
    @State private var working:String?
    @State private var failure:(text:String,kind:String)?
    /// The failed action the owner has already seen and moved on from, so it is not shown again.
    @State private var dismissedFailure:String?
    @State private var lastFailureID:String?
    @State private var sent=false
    @State private var note:String?
    @State private var words=""
    @State private var opened=false
    @State private var lastTold=Date.distantPast
    @State private var preparedLooked=false
    @State private var otherOpen=false
    @State private var otherText=""
    /// Mail Dot's settings are shown in the panel instead of the draft.
    @State private var showingSettings=false
    /// The panel's newest request to Dot for this message, as Mail Dot recorded it, and the time now, so the
    /// progress line can count the seconds.
    @State private var requestProgress:(askedAt:Date,deliveredAt:Date?,readAt:Date?,ahead:Int)?
    @State private var now=Date()
    /// For a new message: what the owner wants it to say, before Dot is asked.
    @State private var newText=""
    /// The message this reply answers was marked No reply needed: the panel asks the owner what to say before Dot is
    /// asked (owner request, 20 November 2026).
    @State private var markedNoReply=false
    @FocusState private var newFocused:Bool
    /// When the panel last asked Mail to read a new message again after its recipients changed.
    @State private var lastNewShare=Date.distantPast
    @FocusState private var otherFocused:Bool
    @FocusState private var typing:Bool
    @FocusState private var editing:Bool
    private static let log=Logger(subsystem:"org.jgkarlin.MailBridge",category:"ReplyPanel")

    var body: some View {
        VStack(spacing:0) {
            header
            Divider()
            // Mail Dot's settings open in place of the draft; Done brings the draft back as it was.
            if showingSettings { MailDotSettingsView() }
            else if awaitingGuidance {
                // A reply to a message marked No reply needed: the panel's usual "Tell Dot…" box, grown to fill the
                // panel, until the owner says what the reply should say (owner request, 20 November 2026).
                content.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                Spacer(minLength:0)
                Divider()
                guidanceBar
            }
            else {
                ScrollView { content.padding(16).frame(maxWidth:.infinity,alignment:.leading) }
                if showsChoices {
                    Divider()
                    choices
                }
            }
        }
        .frame(width:Self.size.width,height:Self.size.height)
        // Opaque, so that the message behind the popover does not show through its text.
        .background(Color(nsColor:.windowBackgroundColor))
        .tint(MailDotStyle.tint)
        .task {
            trace("the reply panel began its work")
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for:.seconds(1))
            }
        }
    }

    // MARK: What is shown

    private var request:ReplyOwnerRequest? { context?.ownerRequest }
    /// A new message the owner is writing, not a reply.
    private var isNew:Bool { context?.isNewMessage == true }
    /// A new message for which Dot has not been asked yet: the panel asks the owner what it should say.
    private var awaitingNewRequest:Bool { isNew && context?.proposal == nil && request?.direction == nil }
    /// A reply to a message marked No reply needed, for which the owner has not yet said what to write.
    private var awaitingGuidance:Bool { context.map{ BridgeCoordinator.waitsForOwnerWords($0,markedNoReplyNeeded:markedNoReply) } ?? false }
    private var question:(question:String,answers:[String])? {
        // With a draft already written, the draft is what the panel shows: a question is not put in front of it
        // again (owner report, 17 November 2026: the draft sat behind a repeat of a question already answered).
        guard context?.proposal == nil,let text=context?.dotQuestion,!text.isEmpty else { return nil }
        let parsed=BridgeCoordinator.answers(in:text)
        // The panel always ends with its own "Something else…", so an answer of Dot's that says the same is left out.
        let other=["something else","other","else","その他","ほか","別の"]
        return (parsed.question,parsed.answers.filter{answer in !other.contains{answer.lowercased().hasPrefix($0)}})
    }
    private var confirmation:SendConfirmation? {
        guard let context,let snapshot=context.snapshot,let confirmation=context.sendConfirmation,confirmation.fingerprint == snapshot.fingerprint else { return nil }
        return confirmation
    }
    /// Dot's draft is in the Mail message exactly as shown.
    private var placed:Bool {
        guard let context,let proposal=context.proposal,let snapshot=context.snapshot else { return false }
        return proposal.appliedFingerprint == snapshot.fingerprint
    }
    /// The owner has asked something of Dot that Dot has not yet answered: the draft, a direction, an answer.
    private var waitingOnDot:Bool {
        guard let context,let request,!request.ignored else { return false }
        // A new message asks nothing of Dot until the owner presses Draft.
        if awaitingNewRequest || awaitingGuidance { return false }
        if context.proposal == nil { return true }
        return request.askedAt > (context.lastDotUpdate ?? .distantPast) && Date().timeIntervalSince(request.askedAt) < 900
    }
    /// The choices and the revise box need a draft to come; while the panel asks how to reply to a message marked No
    /// reply needed, its card alone is shown (owner report, 20 November 2026: a second box sat under the card and
    /// pushed its buttons out of sight).
    private var showsChoices:Bool { context != nil && request?.ignored != true && confirmation == nil && !sent && !awaitingGuidance }

    @ViewBuilder private var header:some View {
        // Over Settings: the way back to the draft, at the left, where Done was at the right.
        if showingSettings {
            MailDotSettingsBar(returnsTo:Text(verbatim:"Mail Dot")) { showingSettings=false }.padding(.horizontal,16).padding(.vertical,10)
        } else { draftHeader }
    }
    private var draftHeader:some View {
        HStack(spacing:8) {
            Image(systemName:"at.circle.fill").foregroundStyle(MailDotStyle.brand)
            VStack(alignment:.leading,spacing:0) {
                Text("Mail Dot").font(.headline)
                if isNew {
                    if let who=context?.envelope.to.first { Text("New message to \(who)").font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1) }
                } else if let who=recipient { Text("Reply to \(who)").font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1) }
            }
            Spacer()
            if loaded,!connected { Label("Dot is not connected",systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(MailDotStyle.warningText) }
            else if let status { statusPill(status) }
            Button { showingSettings=true } label: { Image(systemName:"gearshape") }
                .buttonStyle(.borderless).help("Mail Dot Settings").accessibilityLabel("Mail Dot Settings")
            more
        }.padding(.horizontal,16).padding(.vertical,10)
    }
    /// Where this reply stands, in a few words at the top of the panel: what the owner sees on returning.
    private var status:(text:String,symbol:String,color:Color,busy:Bool)? {
        guard let context else { return nil }
        if sent { return (String(localized:"Sent"),"paperplane.fill",.green,false) }
        if request?.ignored == true { return (String(localized:"Set aside"),"nosign",.secondary,false) }
        if confirmation != nil { return (String(localized:"Confirm to send"),"paperplane",MailDotStyle.tint,false) }
        if context.snapshot == nil { return (String(localized:"Reading message"),"doc.text.magnifyingglass",.secondary,true) }
        if question != nil { return (String(localized:"Dot has a question"),"questionmark.bubble.fill",.orange,false) }
        if awaitingGuidance { return (String(localized:"No reply needed"),"minus.circle",.secondary,false) }
        if waitingOnDot { return (context.proposal == nil ? String(localized:"Drafting") : String(localized:"Revising"),"ellipsis.bubble",MailDotStyle.tint,true) }
        if context.proposal != nil {
            if placed { return (request?.saveToDrafts == true ? String(localized:"Saved to Drafts") : String(localized:"Inserted"),"checkmark.circle.fill",.green,false) }
            return (String(localized:"Draft ready"),"square.and.pencil",.green,false)
        }
        return nil
    }
    private func statusPill(_ value:(text:String,symbol:String,color:Color,busy:Bool)) -> some View {
        HStack(spacing:5) {
            if value.busy { ProgressView().controlSize(.mini) } else { StatusSymbol(name:value.symbol,key:value.text) }
            Text(value.text).fontWeight(.semibold)
        }
        .font(.caption).foregroundStyle(value.color)
        .padding(.horizontal,8).padding(.vertical,3)
        .background(Capsule().fill(value.color.opacity(0.14)))
        // A draft ready, or a question from Dot, needs the owner: the pill pulses once when it appears.
        .statusChange(value.text,needsOwner:["square.and.pencil","questionmark.bubble.fill"].contains(value.symbol))
        .accessibilityLabel("Status: \(value.text)")
    }
    private var recipient:String? {
        guard let context else { return nil }
        let original=context.originalSender.trimmingCharacters(in:.whitespaces)
        if !original.isEmpty { return original.split(separator:"<").first.map{$0.trimmingCharacters(in:CharacterSet(charactersIn:"\" "))}.flatMap{$0.isEmpty ? nil : $0} ?? original }
        return context.envelope.to.first
    }
    private var more:some View {
        Menu {
            Button("Read the Message from Mail Again",systemImage:"arrow.clockwise") { share() }
            Button("Spoken Mail Report",systemImage:"speaker.wave.2") { note=DotCallCommands.spokenReport() ?? String(localized:"Asked Dot for the report; your Mac reads it aloud when it arrives.") }
            Divider()
            Text(MailDotVersion.text)
        } label: { Image(systemName:"ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More Mail Dot commands")
    }

    @ViewBuilder private var content:some View {
        VStack(alignment:.leading,spacing:14) {
            if let failure { failureCard(failure) }
            if let note { Text(note).font(.callout).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true) }
            if sent {
                state("paperplane.fill",String(localized:"Sent"),String(localized:"Mail accepted the reply for sending."),.green)
            } else if let context,request?.ignored == true {
                state("nosign",String(localized:"You set this message aside"),String(localized:"Dot will not draft a reply, and nothing was sent."),.secondary)
                Button("Draft a Reply After All") { act { try BridgeCoordinator.ownerResumes(contextID:context.id,state:&$0) } }
            } else if let context,let snapshot=context.snapshot,let confirmation {
                confirmCard(snapshot,confirmation)
            } else if let context,awaitingNewRequest {
                newMessageCard(context)
            } else if awaitingGuidance {
                Text(String(localized:"Dot found this message needs no reply. What should your reply say?")).font(.callout).foregroundStyle(MailDotStyle.supporting)
                    .fixedSize(horizontal:false,vertical:true)
            } else if context?.snapshot == nil {
                if failure == nil { progress(loaded ? String(localized:"Reading this message from Mail…") : String(localized:"Opening…"),nil) }
            } else if let context {
                if let question { questionCard(question) }
                if context.proposal != nil { draftCard(context) }
                if waitingOnDot,question == nil { progress(context.proposal == nil ? (isNew ? String(localized:"Dot is drafting your message…") : String(localized:"Dot is drafting your reply…")) : String(localized:"Dot is revising the draft…"),dotLine(context)) }
                else if let working { progress(working,nil) }
            }
        }
    }
    /// Dot's own short account of what it is doing, once it has said anything.
    /// Where Dot's work stands, from Mail Dot's own records of the request (made, accepted by ChatGPT, first
    /// read by Dot) and Dot's own notes: the wait is mostly ChatGPT starting Dot's run, and the owner can see
    /// which stage it is in. No seconds are shown.
    private func dotLine(_ context:ReplyContext) -> String? {
        if !connected { return String(localized:"Dot is not connected to Mail Dot right now, so it has not seen this. It will draft when the connection returns.") }
        guard let progress=requestProgress else { return String(localized:"Sending your request to Dot") }
        let seconds=max(0,Int(now.timeIntervalSince(progress.askedAt)))
        let stage:String
        if let update=context.lastDotUpdate,update > progress.askedAt { stage=context.dotStatus }
        else if progress.readAt != nil { stage=String(localized:"Dot is reading the message") }
        else if progress.deliveredAt != nil {
            // Where the request stands in the queue, when others are ahead of it (owner request, 17 November 2026).
            let starting=String(localized:"ChatGPT is starting Dot")
            switch progress.ahead {
            case 0: stage=starting
            case 1: stage=starting+" · "+String(localized:"1 request ahead of yours")
            default: stage=starting+" · "+String(localized:"\(progress.ahead) requests ahead of yours")
            }
        }
        else if seconds > 45 { stage=String(localized:"Dot has not picked this up yet. You can call Dot instead.") }
        else { stage=String(localized:"Sending your request to Dot") }
        // The stage only: a running count of seconds made the wait feel longer (owner request, 12 November 2026).
        return stage
    }
    private func state(_ symbol:String,_ title:String,_ detail:String,_ color:Color) -> some View {
        HStack(alignment:.top,spacing:10) {
            Image(systemName:symbol).font(.title2).foregroundStyle(color)
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private func progress(_ title:String,_ detail:String?) -> some View {
        HStack(alignment:.top,spacing:10) {
            ProgressView().controlSize(.small).padding(.top,2)
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(.headline).statusChange(title)
                if let detail { Text(detail).font(.callout).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).statusChange(detail) }
            }
        }
    }
    private func card(_ tint:Color=Color.primary.opacity(0.05),@ViewBuilder _ body:()->some View) -> some View {
        VStack(alignment:.leading,spacing:8) { body() }
            .padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(RoundedRectangle(cornerRadius:10).fill(tint))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(Color.primary.opacity(0.10)))
    }
    private func caption(_ text:String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5)
    }
    private func failureCard(_ failure:(text:String,kind:String)) -> some View {
        card(MailDotStyle.dangerText.opacity(0.10)) {
            Label(failureTitle(failure.kind),systemImage:"exclamationmark.triangle.fill").font(.headline).foregroundStyle(MailDotStyle.dangerText)
            Text(failure.text).font(.callout).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            Button(failure.kind == "send" ? "Read the Message Again" : "Try Again") { dismissedFailure=lastFailureID; self.failure=nil; placedRevision=0; share() }
        }
    }
    private func failureTitle(_ kind:String) -> String {
        switch kind {
        case "share":String(localized:"Mail Dot could not read this message")
        case "apply":String(localized:"Dot’s reply could not be inserted")
        case "saveDraft":String(localized:"Your message could not be saved to Drafts")
        case "send":String(localized:"The reply was not sent")
        default:String(localized:"That did not work")
        }
    }

    /// Dot's question, with its answers one press each.
    private func questionCard(_ question:(question:String,answers:[String])) -> some View {
        card(MailDotStyle.warningText.opacity(0.10)) {
            caption(String(localized:"Dot needs to know"))
            Text(question.question).font(.body.weight(.semibold)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            ForEach(Array(question.answers.enumerated()),id:\.offset) { index,answer in
                Button { self.answer(answer,index:index) } label: {
                    HStack(spacing:9) {
                        Text("\(index+1)").font(.system(size:11,weight:.semibold)).foregroundStyle(MailDotStyle.supporting)
                            .frame(width:20,height:19).background(RoundedRectangle(cornerRadius:4).fill(Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius:4).stroke(Color.primary.opacity(0.22)))
                        Text(answer).fontWeight(.medium).multilineTextAlignment(.leading)
                        Spacer(minLength:0)
                    }
                    .padding(.horizontal,10).padding(.vertical,7)
                    .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.14)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(typing || editing || otherOpen ? nil : KeyboardShortcut(KeyEquivalent(Character("\(index+1)")),modifiers:[]))
                .accessibilityLabel("\(index+1), \(answer)")
            }
            // The last choice is always the owner's own answer: a box to type or dictate it, or a call. With no
            // answers of Dot's, a lone "Something else…" is no choice, so the box is simply open.
            let other=question.answers.count+1
            if !question.answers.isEmpty {
            Button { otherOpen.toggle(); if otherOpen { otherFocused=true } } label: {
                HStack(spacing:9) {
                    Text("\(other)").font(.system(size:11,weight:.semibold)).foregroundStyle(MailDotStyle.supporting)
                        .frame(width:20,height:19).background(RoundedRectangle(cornerRadius:4).fill(Color.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius:4).stroke(Color.primary.opacity(0.22)))
                    Text("Something else…").fontWeight(.medium)
                    Spacer(minLength:0)
                    Image(systemName:otherOpen ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(MailDotStyle.supporting)
                }
                .padding(.horizontal,10).padding(.vertical,7)
                .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(otherOpen ? 0.09 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.14)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(typing || editing || otherOpen || other > 9 ? nil : KeyboardShortcut(KeyEquivalent(Character("\(other)")),modifiers:[]))
            .accessibilityLabel("\(other), Something else")
            }
            if otherOpen || question.answers.isEmpty {
                VStack(alignment:.leading,spacing:6) {
                    TextField("Tell Dot your answer, or how to draft the reply",text:$otherText,axis:.vertical).guidanceCounter(otherText)
                        .lineLimit(3...6).textFieldStyle(.roundedBorder).focused($otherFocused)
                    HStack(spacing:8) {
                        Button { dictate() } label: { Label("Dictate",systemImage:"mic") }
                            .help("Start Dictation (same as your dictation shortcut). macOS types what you say into the box; this is not a call with Dot.")
                        Spacer(minLength:4)
                        Button("Call Dot",systemImage:"phone") { note=DotCallCommands.call(contextID:contextID) ?? String(localized:"Opening a call with Dot about this message.") }
                            .help("Talk the reply over with Dot on a voice call")
                        Button("Send to Dot") { answer(otherText.trimmingCharacters(in:.whitespacesAndNewlines)); otherText=""; otherOpen=false }
                            .buttonStyle(.borderedProminent)
                            .disabled(otherText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || otherText.count > ReplyOwnerRequest.textLimit)
                    }
                }
            }
        }
    }
    /// Starts macOS's own dictation in the instructions box: the system listens and types the words in.
    /// Mail Dot does not hear the microphone itself, and nothing goes to Dot until Send to Dot.
    private func dictate(intoNew:Bool=false,intoRevise:Bool=false) {
        if intoRevise { typing=true } else if intoNew { newFocused=true } else { otherFocused=true }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            if !NSApp.sendAction(Selector(("startDictation:")),to:nil,from:nil) {
                note=String(localized:"Dictation is not available. Turn it on in System Settings, Keyboard, Dictation.")
            }
        }
    }
    /// A new message: Dot needs a recipient, then the owner's words on what the message should say. Nothing
    /// is asked of Dot until the owner presses Draft.
    @ViewBuilder private func newMessageCard(_ context:ReplyContext) -> some View {
        if context.envelope.to.isEmpty {
            state("person.crop.circle.badge.plus",String(localized:"Add a recipient"),String(localized:"Add a recipient in To, and Dot will draft this message for them."),.secondary)
        } else {
            directionCard(context,caption:String(localized:"What should this message say?"),placeholder:"Tell Dot what to write")
        }
    }
    /// The owner's words on what Dot should write, asked before Dot is asked: for a new message, and for a reply to a
    /// message marked No reply needed.
    private func directionCard(_ context:ReplyContext,caption text:String,placeholder:LocalizedStringKey) -> some View {
        card {
                caption(text)
                // As tall as the fixed panel allows; longer text scrolls inside the box.
                TextField(placeholder,text:$newText,axis:.vertical).guidanceCounter(newText)
                    .lineLimit(23...23).textFieldStyle(.roundedBorder).focused($newFocused)
                HStack(spacing:8) {
                    Button { dictate(intoNew:true) } label: { Label("Dictate",systemImage:"mic") }
                        .help("Start Dictation (same as your dictation shortcut). macOS types what you say into the box; this is not a call with Dot.")
                    Spacer(minLength:4)
                    Button("Call Dot",systemImage:"phone") { note=DotCallCommands.call(contextID:contextID) ?? String(localized:"Opening a call with Dot about this message.") }
                        .help("Talk this message over with Dot on a voice call")
                    Button("Draft") {
                        let text=newText.trimmingCharacters(in:.whitespacesAndNewlines)
                        // A subject or recipient the owner added since the panel opened is read first, so that
                        // Dot is given them.
                        refreshEnvelope()
                        act { try BridgeCoordinator.ownerDirects(text,contextID:context.id,state:&$0) }
                        if (try? BridgeStore.shared().read().contexts[context.id]?.snapshot) == nil { share() }
                        newText=""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || newText.count > ReplyOwnerRequest.textLimit)
                }
        }
    }
    /// Dot's draft, which the owner may edit before it goes into the message.
    private func draftCard(_ context:ReplyContext) -> some View {
        card {
            HStack {
                caption(String(localized:"Dot’s draft"))
                Spacer()
                Text(draftState(context)).font(.caption.weight(.semibold)).foregroundStyle(placed && editor == loadedText ? MailDotStyle.successText : MailDotStyle.supporting)
            }
            // What Dot did besides writing, and the files it finished, which go into the message with the reply.
            if let done=context.proposal?.tasksDone,!done.isEmpty {
                VStack(alignment:.leading,spacing:3) {
                    Text("Dot did").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting)
                    ForEach(Array(done.enumerated()),id:\.offset) { _,line in
                        Label(line,systemImage:"checkmark.circle").font(.callout).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
            if let files=context.dotFiles,!files.isEmpty {
                VStack(alignment:.leading,spacing:3) {
                    Text(context.filesAttachedRevision == context.proposal?.revision ? "Attached to your message" : "Attached when you insert the reply").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting)
                    ForEach(files) { file in
                        HStack(spacing:6) {
                            Image(systemName:"doc").foregroundStyle(MailDotStyle.supporting)
                            Text(file.filename).lineLimit(1).truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount:Int64(file.size),countStyle:.file)).font(.caption).foregroundStyle(MailDotStyle.supporting)
                            Spacer(minLength:4)
                            if context.filesAttachedRevision != context.proposal?.revision {
                                Button { removeFile(file.id) } label: { Image(systemName:"xmark.circle") }.buttonStyle(.borderless).help("Do not attach this file").accessibilityLabel("Do not attach \(file.filename)")
                            }
                        }
                    }
                }
            }
            if context.isNewMessage,let subject=context.proposal?.subject ?? (context.snapshot?.subject.isEmpty == false ? context.snapshot?.subject : nil) {
                HStack(alignment:.firstTextBaseline,spacing:6) {
                    Text("Subject").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting)
                    Text(subject).fontWeight(.medium).textSelection(.enabled)
                }
            }
            TextEditor(text:$editor).font(.body).focused($editing).frame(minHeight:150,maxHeight:230)
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius:6).fill(Color(nsColor:.textBackgroundColor)))
                .accessibilityLabel("Dot’s draft of the reply")
            if let proposal=context.proposal,proposal.revision != loadedRevision,editor != loadedText {
                Button("Show Dot’s Newer Draft") { editor=proposal.body; loadedText=proposal.body; loadedRevision=proposal.revision }
            }
            // No instruction caption under the draft (owner, 14 November 2026: no directions in the interface).
        }
    }
    private func draftState(_ context:ReplyContext) -> String {
        if editor != loadedText { return String(localized:"Edited by you") }
        if placed { return request?.delivery == .send ? String(localized:"Inserted in your message") : String(localized:"Inserted in your message") }
        return working != nil ? String(localized:"Going into your message…") : String(localized:"Not yet in your message")
    }
    /// The one confirmation a send needs. It names who receives the reply and shows all of it.
    private func confirmCard(_ snapshot:MailDraft,_ confirmation:SendConfirmation) -> some View {
        card(MailDotStyle.tint.opacity(0.10)) {
            Label("Send this reply?",systemImage:"paperplane.fill").font(.headline)
            let summary=SendConfirmationSummary(draft:snapshot)
            LabeledContent("To",value:summary.recipients)
            ScrollView { Text(summary.text).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled) }
                .frame(maxHeight:250).padding(8)
                .background(RoundedRectangle(cornerRadius:6).fill(Color(nsColor:.textBackgroundColor)))
            Text("\(summary.characterCount) characters. This is the one confirmation; Mail sends it when you press Send.").font(.callout).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true)
            HStack {
                // Never on a bare Return: a stray key must not send mail. A click, or Command-Return.
                Button("Send") { confirmSend(confirmation.id) }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:.command)
                Button("Don’t Send") { act { try BridgeCoordinator.ownerChooses(.save,contextID:contextID,state:&$0) } }
                Spacer()
                if let working { ProgressView().controlSize(.small); Text(working).font(.callout).foregroundStyle(MailDotStyle.supporting) }
            }
        }
    }

    /// Always at hand: what becomes of this reply, a line to Dot, and the call.
    private var choices:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:8) {
                choice("Insert","text.insert",chosen:request?.delivery == .save && request?.saveToDrafts != true) { choose(.save) }
                    .help("Put Dot’s reply at the top of your message, above the quoted mail. Nothing is sent.")
                choice("Save Draft","tray.and.arrow.down",chosen:request?.delivery == .save && request?.saveToDrafts == true) { saveDraft() }
                    .help("Put Dot’s reply at the top of your message and save it in Drafts. Nothing is sent.")
                // Command-Return chooses Send (owner request, 16 November 2026); it still sends only after the one
                // confirmation, whose own Send button takes Command-Return while it is shown.
                choice("Send","paperplane",chosen:request?.delivery == .send) { choose(.send) }
                    .help("Put Dot’s reply in your message and send it, after you confirm once.")
                    .keyboardShortcut(confirmation == nil ? KeyboardShortcut(.return,modifiers:.command) : nil)
                // No Reply sits with the other choices for this reply (owner decision, 16 November 2026).
                Button("No Reply",systemImage:"nosign") { act { try BridgeCoordinator.ownerIgnores(contextID:contextID,state:&$0) } }
                Spacer(minLength:0)
            }
            // While Dot is asking, the answer box is "Something else…" in the question itself; a new message
            // not yet described is described in its own card above.
            if question == nil,!awaitingNewRequest,!awaitingGuidance {
            HStack(alignment:.bottom,spacing:8) {
                // Revising needs a draft: until Dot's draft is shown, the box and Tell Dot stay greyed.
                // Three lines from the start, growing to six (owner request, 14 November 2026), like the answer box.
                TextField("Tell Dot how to revise this reply",text:$words,axis:.vertical).guidanceCounter(words)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder).focused($typing).onSubmit { if context?.proposal != nil { say() } }
                    .disabled(context?.proposal == nil)
                // Call Dot right above Tell Dot, the box to their left (owner decision, 16 November 2026); Dictate above
                // them, as in the panel's other boxes (owner decision, 20 November 2026).
                VStack(alignment:.trailing,spacing:8) {
                    Button { dictate(intoRevise:true) } label: { Label("Dictate",systemImage:"mic") }
                        .help("Start Dictation (same as your dictation shortcut). macOS types what you say into the box; this is not a call with Dot.")
                        .disabled(context?.proposal == nil)
                    Button("Call Dot",systemImage:"phone") { note=DotCallCommands.call(contextID:contextID) ?? String(localized:"Opening a call with Dot about this message.") }
                        .help("Talk this reply over with Dot on a voice call")
                    Button("Tell Dot",systemImage:"text.bubble") { say() }
                        .disabled(context?.proposal == nil || words.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || words.count > ReplyOwnerRequest.textLimit)
                }.fixedSize()
            }
            }
        }.padding(.horizontal,16).padding(.vertical,10)
    }
    /// The bottom box of the panel, as tall as the panel allows, while it waits for the owner's words on a reply to a
    /// message marked No reply needed: the same box and buttons as for revising, with Dictate above them.
    private var guidanceBar:some View {
        HStack(alignment:.bottom,spacing:8) {
            TextField("Tell Dot how to reply",text:$newText,axis:.vertical).guidanceCounter(newText)
                .lineLimit(Self.guidanceLines...Self.guidanceLines).textFieldStyle(.roundedBorder).focused($newFocused)
            VStack(alignment:.trailing,spacing:8) {
                Button { dictate(intoNew:true) } label: { Label("Dictate",systemImage:"mic") }
                    .help("Start Dictation (same as your dictation shortcut). macOS types what you say into the box; this is not a call with Dot.")
                Button("Call Dot",systemImage:"phone") { note=DotCallCommands.call(contextID:contextID) ?? String(localized:"Opening a call with Dot about this message.") }
                    .help("Talk this reply over with Dot on a voice call")
                Button("Tell Dot",systemImage:"text.bubble") { direct() }
                    .disabled(newText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || newText.count > ReplyOwnerRequest.textLimit)
            }.fixedSize()
        }.padding(.horizontal,16).padding(.vertical,10)
    }
    private static let guidanceLines=29
    /// The owner's words on what to write go to Dot as the direction for the reply.
    private func direct() {
        guard let context else { return }
        let text=newText.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.count <= ReplyOwnerRequest.textLimit else { return }
        refreshEnvelope()
        act { try BridgeCoordinator.ownerDirects(text,contextID:context.id,state:&$0) }
        if (try? BridgeStore.shared().read().contexts[context.id]?.snapshot) == nil { share() }
        newText=""
    }
    @ViewBuilder private func choice(_ title:LocalizedStringKey,_ symbol:String,chosen:Bool,_ action:@escaping ()->Void) -> some View {
        if chosen { Button(title,systemImage:"checkmark",action:action).buttonStyle(.borderedProminent).accessibilityAddTraits(.isSelected) }
        else { Button(title,systemImage:symbol,action:action) }
    }

    // MARK: What it does

    /// Reads the shared store away from the main thread; only the small result is applied on it.
    private func reload() async {
        do {
            if !opened { opened=true; try open() }
            let state=try await Task.detached { try BridgeStore.shared().read() }.value
            context=state.contexts[contextID]
            now=Date()
            if let current=context,!current.isNewMessage,!current.originalMessageID.isEmpty {
                let marked=await Task.detached { [id=current.originalMessageID] in (try? MailTriageStore.shared().read())?.markedNoReplyNeeded(messageID:id) ?? false }.value
                if marked != markedNoReply { markedNoReply=marked }
            }
            requestProgress=await Task.detached { [contextID] in
                (try? MailWorkflowStore(bridgeDirectory:BridgeStore.shared().directory).read())?.replyProgress(contextID:contextID)
            }.value
            loaded=true
            let helper=state.agentSeenAt.map { Date().timeIntervalSince($0) < 8 } ?? false
            connected=helper && !state.subscriptions.deliverable(for:"mail.workflow_requested").isEmpty
            let mine=state.operations.filter{$0.contextID == contextID}
            let pending=mine.last{$0.result == nil && $0.error == nil}
            working=pending.map{ $0.kind == "share" ? String(localized:"Reading this message from Mail…") : $0.kind == "apply" ? String(localized:"Putting Dot’s reply into your message…") : $0.kind == "send" ? String(localized:"Sending…") : $0.kind == "saveDraft" ? String(localized:"Saving to Drafts…") : String(localized:"Checking the reply against Mail…") }
            if let last=mine.last(where:{$0.result != nil || $0.error != nil}),pending == nil {
                if let error=last.error {
                    if lastFailureID != last.id { Self.log.error("\(last.kind,privacy:.public) failed: \(error,privacy:.public)") }
                    lastFailureID=last.id
                    failure=dismissedFailure == last.id ? nil : (Self.plain(error),last.kind)
                } else {
                    failure=nil
                    if last.kind == "send" { sent=true }
                }
            }
            if let proposal=context?.proposal,proposal.revision != loadedRevision,editor == loadedText || loadedRevision == 0 {
                editor=proposal.body; loadedText=proposal.body; loadedRevision=proposal.revision
            }
            placeIfChosen()
            if let current=context,current.isNewMessage,current.snapshot == nil,!current.envelope.to.isEmpty,pending == nil,failure == nil,
               Date().timeIntervalSince(lastNewShare) > 5 {
                lastNewShare=Date(); share()
            }
            // A draft Dot already wrote for this message, found by the message it answers, is shown at once
            // and Dot is not asked again. Nothing enters the message.
            // While Dot is already drafting this message, the panel waits for that draft or question, for as long as
            // Dot may take, instead of starting a second request (the same check every reply request passes).
            var dotAlreadyOnIt=false
            // The owner's own words on the reply never wait: they go to Dot at once (see tellDotAboutReply).
            if let current=context,current.proposal == nil,current.snapshot != nil,current.ownerRequest?.toldDotAt == nil,!current.originalMessageID.isEmpty,
               current.ownerRequest?.direction == nil,current.ownerRequest?.answers.isEmpty ?? true {
                let drafting=await Task.detached { [id=current.originalMessageID] in (try? MailTriageStore.shared().read())?.dotIsDrafting(messageID:id) ?? false }.value
                if drafting {
                    dotAlreadyOnIt=true
                    preparedLooked=false
                }
            }
            var adopted=false
            if let current=context,current.proposal == nil,current.snapshot != nil,current.ownerRequest?.toldDotAt == nil,!preparedLooked {
                preparedLooked = !dotAlreadyOnIt
                adopted=usePrepared(current)
            }
            // Dot is sent the request as soon as the message has been read, and again whenever it changes, but
            // never in the same pass that adopted Dot's stored draft: the context read above predates it
            // (owner request, 13 November 2026: a ready draft was asked for again as the panel opened).
            let latest=adopted ? nil : try? BridgeStore.shared().read().contexts[contextID]
            if !adopted,!dotAlreadyOnIt,let latest,BridgeCoordinator.dotIsOwedWord(latest),!BridgeCoordinator.waitsForOwnerWords(latest,markedNoReplyNeeded:markedNoReply),
               Date().timeIntervalSince(lastTold) > 10 {
                lastTold=Date()
                if let refusal=DotCallCommands.tellDotAboutReply(contextID:contextID) { note=String(localized:"Dot could not be asked: ")+refusal }
            }
        } catch { failure=(error.localizedDescription,"open") }
    }
    /// A failure in words for the owner. The full text is in the log.
    private static func plain(_ error:String) -> String {
        let first=error.split(separator:"\n").first.map(String.init) ?? error
        return first.count > 220 ? String(first.prefix(217))+"…" : first
    }
    @discardableResult private func usePrepared(_ current:ReplyContext) -> Bool {
        let adopted=StoredDraft.adopt(contextID:contextID)
        Task { await reload() }
        return adopted
    }
    /// Opening the panel is the request: the message is read from Mail and Dot is asked for a draft.
    private func open() throws {
        try registerContext()
        // Someone the owner replies to is someone they correspond with: their mail counts for more in triage.
        if let to=try? BridgeStore.shared().read().contexts[contextID]?.envelope.to {
            try? MailTriageStore.shared().transaction { state in to.compactMap(MailMessageIdentity.address(in:)).forEach{state.learnCorrespondent($0)} }
        }
        var needsShare=false
        try BridgeStore.shared().transaction { state in
            guard var value=state.contexts[contextID] else { return }
            BridgeCoordinator.ownerOpensPanel(context:&value)
            state.contexts[contextID]=value
            needsShare=value.snapshot == nil && !state.operations.contains{$0.contextID == contextID && $0.kind == "share" && $0.result == nil && $0.error == nil}
        }
        if needsShare { share() }
    }
    private func share() {
        willShare()
        do { try registerContext(); try queue("share") } catch { failure=(error.localizedDescription,"share") }
    }
    /// Once the owner has said save or send, Dot's draft goes into the message without a further press.
    private func placeIfChosen() {
        guard let context,let proposal=context.proposal,let snapshot=context.snapshot,let request,!request.ignored,request.delivery != nil,
              working == nil,failure == nil,editor == loadedText,proposal.revision == loadedRevision,
              proposal.appliedFingerprint != snapshot.fingerprint,placedRevision != proposal.revision else { return }
        place()
    }
    private func place() {
        guard let fingerprint=context?.snapshot?.fingerprint else { return }
        do {
            var revision=loadedRevision
            try BridgeStore.shared().transaction { state in
                try BridgeCoordinator.enqueueApply(contextID:contextID,displayedFingerprint:fingerprint,displayedProposalRevision:loadedRevision,reviewedBody:editor,state:&state)
                revision=state.contexts[contextID]?.proposal?.revision ?? revision
            }
            loadedText=editor; loadedRevision=revision; placedRevision=revision
            working=String(localized:"Putting Dot’s reply into your message…")
            wakeCompanion()
        } catch { failure=(error.localizedDescription,"apply") }
    }
    private func choose(_ delivery:ProposalDelivery) {
        act { try BridgeCoordinator.ownerChooses(delivery,contextID:contextID,state:&$0) }
        guard context?.proposal != nil else { return }
        // The draft goes in on this press: as edited, if the owner edited it; and again when a draft already
        // in the message is now to be sent, because that is what asks for the confirmation.
        placedRevision=0
        if editor != loadedText || (delivery == .send && placed) { place() }
    }
    /// Save Draft: the reply goes in as Insert puts it, and Mail is asked to save the message to Drafts.
    private func saveDraft() {
        act { try BridgeCoordinator.ownerChooses(.save,saveToDrafts:true,contextID:contextID,state:&$0) }
        guard context?.proposal != nil else { return }
        placedRevision=0
        if editor != loadedText { place() }
        else if placed { do { try queue("saveDraft"); working=String(localized:"Saving to Drafts…") } catch { failure=(error.localizedDescription,"apply") } }
    }
    private func removeFile(_ id:String) {
        try? BridgeStore.shared().transaction { state in state.contexts[contextID]?.dotFiles?.removeAll{$0.id == id} }
        Task { await reload() }
    }
    private func say() {
        let text=words.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if question != nil { answer(text) } else { act { try BridgeCoordinator.ownerDirects(text,contextID:contextID,state:&$0) } }
        words=""
    }
    private func answer(_ text:String) { act { try BridgeCoordinator.ownerAnswers(text,contextID:contextID,state:&$0) } }
    /// A numbered answer: Dot's ready reply for it is shown at once when Dot gave one; otherwise the answer
    /// goes to Dot, which drafts from it.
    private func answer(_ text:String,index:Int) {
        act { state in
            if try !BridgeCoordinator.ownerAnswersWithDraft(index,contextID:contextID,state:&state) {
                try BridgeCoordinator.ownerAnswers(text,contextID:contextID,state:&state)
            }
        }
    }
    private func confirmSend(_ confirmationID:String) {
        act { try BridgeCoordinator.confirmSendFromPanel(contextID:contextID,confirmationID:confirmationID,state:&$0) }
        working=String(localized:"Checking the reply against Mail…")
        wakeCompanion()
    }
    private func act(_ change:(inout BridgeState) throws -> Void) {
        do {
            try BridgeStore.shared().transaction(change)
            dismissedFailure=lastFailureID; failure=nil; note=nil
            lastTold = .distantPast
            wakeCompanion()
            Task { await reload() }
        } catch { failure=(error.localizedDescription,"act") }
    }
    private func wakeCompanion() {
        if let url=URL(string:"mailbridge://operations") {
            let configuration=NSWorkspace.OpenConfiguration()
            configuration.activates=false
            NSWorkspace.shared.open(url,configuration:configuration) { _,_ in }
        }
    }
    private func queue(_ kind:String) throws {
        try BridgeStore.shared().transaction { state in
            guard let value=state.contexts[contextID] else { throw BridgeFailure("This Mail message is not available to Mail Dot. Close the panel and open it again.") }
            var operation=NativeOperation(contextID:contextID,kind:kind)
            operation.expectedFingerprint=value.snapshot?.fingerprint
            operation.proposalRevision=value.proposal?.revision
            state.operations.append(operation)
        }
        wakeCompanion()
    }
}

/// The panel's top row as drawn, in the interface language, measured for the panel's width.
@MainActor enum ReplyChoicesRow {
    static var idealWidth:CGFloat {
        let row=HStack(spacing:8) {
            Button("Insert",systemImage:"text.insert") {}
            Button("Save Draft",systemImage:"tray.and.arrow.down") {}
            Button("Send",systemImage:"paperplane") {}
            Button("No Reply",systemImage:"nosign") {}
        }.fixedSize()
        return ceil(NSHostingView(rootView:row).fittingSize.width)
    }
}
