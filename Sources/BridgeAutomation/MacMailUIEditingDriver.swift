import AppKit
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox
import BridgeCore

/// All AX handles remain isolated to this actor. Bindings live only for this helper process.
actor MacMailUIEditingDriver:MailUIEditingDriver {
    private struct Target {
        let pid:pid_t
        let app:AXUIElement
        let window:AXUIElement
        let body:AXUIElement
        let popovers:[AXUIElement]
        let sendButtons:[AXUIElement]
    }
    private struct Binding {
        let token:String
        let target:Target
        let subject:String
        var deadline=Date.distantPast
        var began=Date.distantPast
        var pieces=0
        var original=""
        var inserted=""
        var started=false
        /// The part of the message below Mail Dot's typing, which it never touches: empty when the whole body
        /// is replaced, and everything under Dot's reply when the reply is inserted at the top.
        var remainder=""
        /// When inserting at the top: the text that must be selected as typing begins (nothing, or Dot's
        /// earlier reply), and the exact place Mail confirmed for it.
        var topSelection:String?
        var topRange:CFTypeRef?
    }
    private var bindings:[String:Binding]=[:]
    private var pendingSendButtons:[String:AXUIElement]=[:]
    private let reader=MailReplyReader()
    func bind(contextID:String,matching envelope:MailDraft) async throws -> MailUIReplyBinding {
        guard AXIsProcessTrusted() else { throw BridgeFailure("Mail Dot needs its approved Accessibility access.") }
        let pid=await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first(where:{$0.bundleURL?.path == "/System/Applications/Mail.app"})?.processIdentifier
        }
        guard let pid else { throw BridgeFailure("Mail is not running.") }
        try await ensureEditorExposed(pid:pid,subject:envelope.subject)
        let target=try locate(pid:pid,subject:envelope.subject)
        noteSelection(target,stage:"before capture")
        let snapshot=try await reader.capture(matching:envelope)
        noteSelection(target,stage:"after capture",expected:snapshot.body)
        try sameTarget(target,subject:envelope.subject)
        guard bindings[contextID] != nil || bindings.count < 30 else { throw BridgeFailure("Too many live message bindings. Restart Mail Dot and share the current message again.") }
        let token=UUID().uuidString
        bindings[contextID]=Binding(token:token,target:target,subject:envelope.subject)
        return MailUIReplyBinding(token:token,snapshot:snapshot)
    }
    /// Everything that must hold before a key is sent to a reply: the bound window is still the one shared,
    /// the message reads exactly as expected, no other panel is open, and the body has the keyboard.
    /// `wholeBody`: the whole message is about to be selected and replaced. Pictures or files in it would be
    /// lost, so that is refused. Typing at the top touches nothing below, so pictures and attachments in the
    /// quoted mail are fine there (owner report, 13 November 2026: a reply quoting three photos could not be inserted into).
    private func focusForTyping(contextID:String,token:String,expected:MailDraft,wholeBody:Bool) async throws -> Binding {
        let binding=try binding(contextID,token:token)
        guard CGPreflightPostEventAccess() else { throw BridgeFailure("macOS has not allowed native text input for Mail Dot. No text was entered.") }
        try await ensureEditorExposed(pid:binding.target.pid,subject:binding.subject)
        let live=try await reader.capture(matching:expected)
        guard live.fingerprint == expected.fingerprint else { throw BridgeFailure("The message changed in Mail since Mail Dot last read it. Refresh and try again. Nothing was typed.") }
        guard !wholeBody || !live.body.contains("\u{fffc}") else { throw BridgeFailure("This message holds pictures or attachments, so Mail Dot will not replace its whole text. Nothing was typed.") }
        try sameTarget(binding.target,subject:binding.subject)
        let current=try locate(pid:binding.target.pid,subject:binding.subject)
        guard current.popovers.count <= 1 else { throw BridgeFailure("Dismiss other Mail panels before applying text.") }
        for popover in current.popovers {
            guard AXUIElementPerformAction(popover,kAXCancelAction as CFString) == .success else { throw BridgeFailure("Close Mail Dot’s panel and try applying again. No text was entered.") }
        }
        guard AXUIElementSetAttributeValue(binding.target.body,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else { throw BridgeFailure("Mail did not allow the bound message body to receive focus. No text was entered.") }
        // Focus arrives a moment after the panel closes. Checking once, immediately, refused attempts that
        // would have succeeded, so wait briefly for it, as the selection step below already does.
        let focusDeadline=Date().addingTimeInterval(1.5)
        var focusError:(any Error)?
        repeat {
            do { try await checkFocus(binding.target); focusError=nil }
            catch { focusError=error; try await Task.sleep(for:.milliseconds(50)) }
        } while focusError != nil && Date() < focusDeadline
        do { if let focusError { throw focusError } }
        catch {
            #if DEBUG
            // Observation only: a failed attempt stays failed even if focus arrives later.
            if binding.subject == "Re: Mail Dot native read test - UNSENT" {
                let start=ContinuousClock.now
                for pause in [50,100,350,1000] {
                    try await Task.sleep(for:.milliseconds(pause))
                    noteSelection(binding.target,stage:"focus timeline \(start.duration(to:.now))")
                }
            }
            #endif
            throw error
        }
        let range=try bodyRange(binding.target.body)
        guard Data(try markerText(binding.target.body,range:range).utf8) == Data(expected.body.utf8) else { throw BridgeFailure("The message changed before selection. Nothing was typed.") }
        return binding
    }
    func selectBody(contextID:String,token:String,expected:MailDraft) async throws {
        let binding=try await focusForTyping(contextID:contextID,token:token,expected:expected,wholeBody:true)
        let selectAll=try selectAllItem(binding.target.app)
        try sameTarget(binding.target,subject:binding.subject)
        try await checkFocus(binding.target)
        guard Data(try markerText(binding.target.body,range:bodyRange(binding.target.body)).utf8) == Data(expected.body.utf8) else {
            throw BridgeFailure("The message changed before Mail's selection command. Nothing was typed.")
        }
        guard AXUIElementPerformAction(selectAll,kAXPressAction as CFString) == .success else {
            throw BridgeFailure("Mail did not accept its Select All command. Nothing was typed.")
        }
        let deadline=Date().addingTimeInterval(2)
        var selected=false
        while Date() < deadline {
            try await checkFocus(binding.target)
            if let text=selectedText(binding.target.body),MailUIEditPolicy.completeSelection(text,source:expected.body) { selected=true; break }
            try await Task.sleep(for:.milliseconds(40))
        }
        guard selected else {
            noteSelection(binding.target,stage:"selection not confirmed",expected:expected.body)
            throw BridgeFailure("Mail did not confirm selection of the complete message body. Nothing was typed.")
        }
        var ready=try self.binding(contextID,token:token)
        ready.began=Date(); ready.deadline=Date().addingTimeInterval(Self.stallLimit); ready.original=expected.body; ready.inserted=""; ready.started=false; ready.pieces=0
        ready.remainder=""; ready.topSelection=nil; ready.topRange=nil
        bindings[contextID]=ready
    }
    /// Puts the caret at the very top of the message, or selects Dot's earlier reply there, so that what is
    /// typed next goes above the quoted mail and nothing below it is touched. Mail must confirm the exact
    /// place, and the selected text must read exactly as the earlier reply (or be empty); otherwise nothing
    /// is typed.
    func selectTop(contextID:String,token:String,expected:MailDraft,replacing previous:String) async throws {
        let binding=try await focusForTyping(contextID:contextID,token:token,expected:expected,wholeBody:false)
        guard expected.body.hasPrefix(previous) else { throw BridgeFailure("Dot’s earlier reply is no longer at the top of this message. Nothing was typed.") }
        let body=binding.target.body
        guard let start=value(body,"AXStartTextMarker") else { throw BridgeFailure("Mail did not expose the top of the message text. Nothing was typed.") }
        var end:CFTypeRef=start
        if !previous.isEmpty {
            var marker:CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(body,"AXTextMarkerForIndex" as CFString,NSNumber(value:previous.utf16.count),&marker) == .success,let marker else {
                throw BridgeFailure("Mail did not expose the end of Dot’s earlier reply. Nothing was typed.")
            }
            end=marker
        }
        var made:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(body,"AXTextMarkerRangeForUnorderedTextMarkers" as CFString,[start,end] as CFArray,&made) == .success,let range=made,
              Data(try markerText(body,range:range).utf8) == Data(previous.utf8) else {
            throw BridgeFailure("Mail Dot could not mark the place for Dot’s reply at the top of the message exactly. Nothing was typed.")
        }
        try sameTarget(binding.target,subject:binding.subject)
        try await checkFocus(binding.target)
        guard AXUIElementSetAttributeValue(body,"AXSelectedTextMarkerRange" as CFString,range) == .success else {
            throw BridgeFailure("Mail did not allow the caret to be placed at the top of the message. Nothing was typed.")
        }
        let deadline=Date().addingTimeInterval(1.5)
        var placed=false
        while Date() < deadline {
            try await checkFocus(binding.target)
            if let now=value(body,"AXSelectedTextMarkerRange"),CFEqual(now,range),let text=selectedText(body),Data(text.utf8) == Data(previous.utf8) { placed=true; break }
            try await Task.sleep(for:.milliseconds(40))
        }
        guard placed else { throw BridgeFailure("Mail did not confirm the place at the top of the message. Nothing was typed.") }
        var ready=try self.binding(contextID,token:token)
        ready.began=Date(); ready.deadline=Date().addingTimeInterval(Self.stallLimit); ready.original=expected.body; ready.inserted=""; ready.started=false; ready.pieces=0
        ready.remainder=String(expected.body.dropFirst(previous.count)); ready.topSelection=previous; ready.topRange=range
        bindings[contextID]=ready
    }
    func insert(_ text:String,contextID:String,token:String,authorize:@Sendable () throws -> Void) async throws {
        var binding=try self.binding(contextID,token:token)
        guard binding.deadline > .now else { throw BridgeFailure("Native text insertion expired.") }
        try await MailUIKeyDispatch.perform(identity:{
            try sameTarget(binding.target,subject:binding.subject)
        },selection:{
            if !binding.started {
                if let top=binding.topSelection {
                    // Still exactly the place Mail confirmed at the top, with exactly the text to be replaced.
                    guard let range=binding.topRange,let now=value(binding.target.body,"AXSelectedTextMarkerRange"),CFEqual(now,range),
                          let selected=selectedText(binding.target.body),Data(selected.utf8) == Data(top.utf8) else { throw BridgeFailure("The place for Dot’s reply at the top of the message changed. Nothing was typed.") }
                } else {
                    guard let selected=selectedText(binding.target.body),MailUIEditPolicy.completeSelection(selected,source:binding.original) else { throw BridgeFailure("The complete body selection changed. Nothing was typed.") }
                }
            }
        },focus:{
            try await checkFocus(binding.target)
            try Task.checkCancellation()
            guard binding.deadline > .now else { throw BridgeFailure("Native text insertion expired before input.") }
        },authorization:authorize,post:{
            try Task.checkCancellation()
            guard binding.deadline > .now else { throw BridgeFailure("Native text insertion expired before dispatch.") }
            binding.started=true; bindings[contextID]=binding
            if text == "\n" { try postKey(pid:binding.target.pid,key:36) }
            else { try postText(text,pid:binding.target.pid) }
        })
        // Each piece that lands renews the allowance, so a long reply is not cut off part-way. Typing still
        // stops if no piece lands for the stall limit, or when the whole insertion reaches its ceiling.
        binding.inserted += text; binding.pieces += 1
        binding.deadline=min(Date().addingTimeInterval(Self.stallLimit),binding.began.addingTimeInterval(Self.insertionCeiling))
        bindings[contextID]=binding
    }
    private static let stallLimit:TimeInterval=10
    private static let insertionCeiling:TimeInterval=300
    func readback(contextID:String,token:String,matching envelope:MailDraft) async throws -> MailDraft {
        let binding=try self.binding(contextID,token:token)
        let deadline=Date().addingTimeInterval(3)
        while true {
            try sameTarget(binding.target,subject:binding.subject)
            let result=try await reader.capture(matching:envelope)
            try sameTarget(binding.target,subject:binding.subject)
            if (try? MailUIEditPolicy.verify(result,text:binding.inserted+binding.remainder,expected:envelope)) != nil { return result }
            guard Date() < deadline else { return result }
            try await Task.sleep(for:.milliseconds(150))
        }
    }
    func reviewSnapshot(contextID:String,token:String,expected:MailDraft) async throws -> MailDraft {
        let retained=try binding(contextID,token:token)
        try sameTarget(retained.target,subject:retained.subject)
        let live=try await reader.captureForSend(matching:expected)
        _ = try binding(contextID,token:token)
        try sameTarget(retained.target,subject:retained.subject)
        return live
    }
    func send(contextID:String,token:String,expected:MailDraft,review:SendReview,consume:@Sendable (MailDraft) throws -> Void) async throws {
        let retained=try binding(contextID,token:token)
        let current=try locate(pid:retained.target.pid,subject:retained.subject)
        guard CFEqual(current.window,retained.target.window),CFEqual(current.body,retained.target.body) else {
            throw BridgeFailure("The reviewed Mail window was replaced. Share and review the current message again.")
        }
        guard current.popovers.count <= 1 else { throw BridgeFailure("Close other Mail panels before sending the reviewed message.") }
        for popover in current.popovers {
            guard AXUIElementPerformAction(popover,kAXCancelAction as CFString) == .success else { throw BridgeFailure("Close Mail Dot's panel before sending the reviewed message.") }
        }
        // Closing the panel is not instant: Mail keeps it in the window, and keeps focus away from the message,
        // while it animates away. Send was refused at once on 13 and 16 November because the check below ran
        // during that moment. Wait, briefly, for the message window to be ready again before checking it.
        // The owner's confirmation can leave another app in front (the Mail Dot confirmation, or a notification):
        // Send was refused on 17 November with "Mail is not in front". Mail and the reviewed message window, and
        // only that window, are brought forward through Accessibility, which works for a background app where
        // activating another app does not.
        let readyBy=Date().addingTimeInterval(4)
        while let target=try? locate(pid:retained.target.pid,subject:retained.subject),
              let reason=sendReadiness(target,retained:retained.target),Date() < readyBy {
            if ["Mail is not in front","another window has focus"].contains(reason),CFEqual(target.window,retained.target.window) {
                AXUIElementSetAttributeValue(target.app,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
                AXUIElementSetAttributeValue(target.window,kAXMainAttribute as CFString,kCFBooleanTrue)
                AXUIElementPerformAction(target.window,kAXRaiseAction as CFString)
            }
            try await Task.sleep(for:.milliseconds(150))
        }
        let dispatchID=UUID().uuidString
        defer { pendingSendButtons.removeValue(forKey:dispatchID) }
        try await MailUISendDispatch.perform(review:review,token:token,verify:{
            try await reviewSnapshot(contextID:contextID,token:token,expected:expected)
        },checkTarget:{
            _ = try binding(contextID,token:token)
            try sameTarget(retained.target,subject:retained.subject)
            let target=try locate(pid:retained.target.pid,subject:retained.subject)
            if let reason=sendReadiness(target,retained:retained.target) {
                throw BridgeFailure("Bring the reviewed message to the front with its Send button available (\(reason)). Nothing was sent.")
            }
            guard let button=target.sendButtons.first else { throw BridgeFailure("Mail's Send button is missing. Nothing was sent.") }
            guard Data(try markerText(target.body,range:bodyRange(target.body)).utf8) == Data(expected.body.utf8) else {
                throw BridgeFailure("The message body changed before Send. Review it again.")
            }
            // Exactly the pictures and files that were there when the owner's send was checked, no more.
            guard expected.attachmentCount >= 0,try MailReplyReader.embeddedObjects(target.body,matching:expected.body) == expected.attachmentCount else {
                throw BridgeFailure("The message's pictures or attachments changed before Send. Review it again. Nothing was sent.")
            }
            pendingSendButtons[dispatchID]=button
        },consume:consume,press:{
            guard value(retained.target.app,kAXFrontmostAttribute) as? Bool == true,
                  let focused=element(retained.target.app,kAXFocusedWindowAttribute),CFEqual(focused,retained.target.window),
                  let sendButton=pendingSendButtons[dispatchID],value(sendButton,kAXEnabledAttribute) as? Bool == true,
                  AXUIElementPerformAction(sendButton,kAXPressAction as CFString) == .success else {
                throw BridgeFailure("Mail did not confirm accepting the Send action.")
            }
        })
        // Pressing Send is not the same as the message leaving. If Mail keeps the window open it is usually
        // asking the owner something, and that must not be reported as sent.
        let closeDeadline=Date().addingTimeInterval(5)
        var sawWindowList=false
        while Date() < closeDeadline {
            if let open=try? children(retained.target.app,attribute:kAXWindowsAttribute,limit:40) {
                sawWindowList=true
                if !open.contains(where:{ CFEqual($0,retained.target.window) }) { return }
            }
            try await Task.sleep(for:.milliseconds(200))
        }
        throw BridgeFailure(sawWindowList
            ? "Mail accepted Send but the message window is still open. Mail may be waiting for you to confirm something. Check that window before doing anything else."
            : "Mail accepted Send, but Mail Dot could not confirm that the message window closed. Check Mail before doing anything else.")
    }
    /// Why the message window is not ready for Send, in a few words for the record, or nil when it is.
    private func sendReadiness(_ target:Target,retained:Target) -> String? {
        guard CFEqual(target.window,retained.window),CFEqual(target.body,retained.body) else { return "the message window changed" }
        guard value(target.app,kAXFrontmostAttribute) as? Bool == true else { return "Mail is not in front" }
        guard let focused=element(target.app,kAXFocusedWindowAttribute),CFEqual(focused,target.window) else { return "another window has focus" }
        guard target.popovers.isEmpty else { return "a panel is still open" }
        guard target.sendButtons.count == 1 else { return "\(target.sendButtons.count) Send buttons" }
        guard value(target.sendButtons[0],kAXEnabledAttribute) as? Bool == true else { return "Send is not available" }
        return nil
    }
    @MainActor private static func asciiCapableInputSource() -> Bool {
        guard let source=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
    func requestSave(contextID:String,token:String) async -> Bool {
        guard let binding=bindings[contextID],binding.token == token,(try? sameTarget(binding.target,subject:binding.subject)) != nil,
              (try? await checkFocus(binding.target)) != nil,
              let down=CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(kVK_ANSI_S),keyDown:true),
              let up=CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(kVK_ANSI_S),keyDown:false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(binding.target.pid); up.postToPid(binding.target.pid)
        return true
    }
    /// Puts the reply back after a failed insertion by pressing Mail's own Undo command, under the rule in
    /// `UndoRestoration`: only while the body shows nothing but this typing, and never more often than the
    /// pieces typed plus a small margin. Undo is pressed through its menu item, found by its key equivalent,
    /// so it works on any keyboard layout and does not need Mail to be in front or the modifier keys to be
    /// free, which are the very conditions whose loss most often causes the failure.
    func restoreOriginal(contextID:String,token:String) async -> Bool {
        guard let binding=bindings[contextID],binding.token == token else { return false }
        func bodyText() -> String? {
            guard let range=try? bodyRange(binding.target.body) else { return nil }
            return try? markerText(binding.target.body,range:range)
        }
        var presses=0
        while true {
            guard let current=bodyText() else { return false }
            if !binding.started { return Data(current.utf8) == Data(binding.original.utf8) }
            switch UndoRestoration.next(current:current,original:binding.original,typed:binding.inserted,remainder:binding.remainder,presses:presses,piecesTyped:binding.pieces) {
            case .restored: return true
            case .stop: return false
            case .press:
                // Undo acts on whatever Mail has in focus, so the reply's body must still be that.
                guard (try? sameTarget(binding.target,subject:binding.subject)) != nil,
                      let window=element(binding.target.app,kAXFocusedWindowAttribute),CFEqual(window,binding.target.window),
                      let focus=element(binding.target.app,kAXFocusedUIElementAttribute),CFEqual(focus,binding.target.body),
                      let undo=undoItem(binding.target.app),
                      AXUIElementPerformAction(undo,kAXPressAction as CFString) == .success else { return false }
                presses += 1
                try? await Task.sleep(for:.milliseconds(120))
            }
        }
    }
    /// Edit > Undo, identified as the enabled item in Mail's Edit menu whose key is Command-Z with no other
    /// modifier. Its title and position vary with language and version; its key equivalent does not.
    private func undoItem(_ app:AXUIElement) -> AXUIElement? {
        guard let bar=element(app,kAXMenuBarAttribute),
              let edit=(try? children(bar,limit:20))?.first(where:{ value($0,kAXIdentifierAttribute) as? String == "Mail.menuBar.editMenu" }),
              let menu=(try? children(edit,limit:2))?.first(where:{ value($0,kAXRoleAttribute) as? String == kAXMenuRole }),
              let items=try? children(menu,limit:100) else { return nil }
        return items.first { item in
            (value(item,kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "Z"
                && (value(item,kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0
                && (value(item,kAXEnabledAttribute) as? Bool) == true
        }
    }
    #if DEBUG
    /// Development diagnosis: the shape of Mail's compose windows as Accessibility presents them. Roles,
    /// developer identifiers, counts and sizes only. No titles, values, addresses or text are read.
    func probeStructure() async -> [String] {
        guard AXIsProcessTrusted() else { return ["accessibility: not trusted"] }
        let pid=await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first?.processIdentifier }
        guard let pid else { return ["mail: not running"] }
        let app=AXUIElementCreateApplication(pid)
        var lines:[String]=[]
        let before=value(app,"AXEnhancedUserInterface") as? Bool
        lines.append("enhanced before: \(String(describing:before))")
        if CommandLine.arguments.contains("--enhance") {
            let status=AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
            lines.append("set enhanced: \(status.rawValue)")
            try? await Task.sleep(for:.seconds(2))
        }
        defer {
            if CommandLine.arguments.contains("--enhance"),CommandLine.arguments.contains("--restore") {
                _ = AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,(before ?? false) ? kCFBooleanTrue : kCFBooleanFalse)
            }
        }
        guard let windows=try? children(app,attribute:kAXWindowsAttribute,limit:40) else { return lines+["windows: unavailable"] }
        lines.append("windows: \(windows.count)")
        for (index,window) in windows.enumerated() {
            var queue:[(AXUIElement,Int)]=[(window,0)],visited=0,rows:[String]=[],webAreas=0,sendButtons=0
            while !queue.isEmpty,visited < 600 {
                let (item,depth)=queue.removeFirst(); visited += 1
                let role=value(item,kAXRoleAttribute) as? String ?? "?"
                let identifier=value(item,kAXIdentifierAttribute) as? String ?? "-"
                var count=0; _ = AXUIElementGetAttributeValueCount(item,kAXChildrenAttribute as CFString,&count)
                var settable:DarwinBoolean=false; _ = AXUIElementIsAttributeSettable(item,kAXFocusedAttribute as CFString,&settable)
                var detail=""
                if role == "AXWebArea" {
                    webAreas += 1
                    var names:CFArray?; _ = AXUIElementCopyParameterizedAttributeNames(item,&names)
                    let markers=Set(names as? [String] ?? []).isSuperset(of:["AXTextMarkerRangeForUIElement","AXLengthForTextMarkerRange","AXStringForTextMarkerRange"])
                    var size=CGSize.zero
                    if let raw=value(item,kAXSizeAttribute),CFGetTypeID(raw) == AXValueGetTypeID() { _ = AXValueGetValue(raw as! AXValue,.cgSize,&size) }
                    var attributes:CFArray?; _ = AXUIElementCopyAttributeNames(item,&attributes)
                    let editable=(attributes as? [String] ?? []).filter { $0.lowercased().contains("edit") }.joined(separator:"+")
                    detail=" markers=\(markers) size=\(Int(size.width))x\(Int(size.height)) loaded=\(String(describing:value(item,"AXLoaded") as? Bool)) editAttrs=\(editable.isEmpty ? "-" : editable)"
                }
                if role == kAXButtonRole,identifier == "send" { sendButtons += 1 }
                if role == "AXWebArea" || role == "AXPopover" || role == "AXScrollArea" || role == "AXSplitGroup" || identifier != "-" || depth <= 2 {
                    rows.append("  w\(index) d\(depth) \(role) id=\(identifier) children=\(count) focusable=\(settable.boolValue)\(detail)")
                }
                if role == "AXWebArea" || role == "AXPopover" { continue }
                guard depth < 12,let found=try? children(item,limit:200) else { continue }
                queue.append(contentsOf:found.map {($0,depth+1)})
            }
            if sendButtons > 0,webAreas == 0,let top=try? children(window,limit:200) {
                for candidate in top where value(candidate,kAXRoleAttribute) as? String == "AXGroup" {
                    var settable:DarwinBoolean=false; _ = AXUIElementIsAttributeSettable(candidate,kAXFocusedAttribute as CFString,&settable)
                    var count=0; _ = AXUIElementGetAttributeValueCount(candidate,kAXChildrenAttribute as CFString,&count)
                    guard settable.boolValue,count == 0 else { continue }
                    var names:CFArray?; _ = AXUIElementCopyAttributeNames(candidate,&names)
                    rows.append("  placeholder attrs: " + (names as? [String] ?? []).joined(separator:","))
                    var parameterized:CFArray?; _ = AXUIElementCopyParameterizedAttributeNames(candidate,&parameterized)
                    rows.append("  placeholder parameterized: " + (parameterized as? [String] ?? []).joined(separator:","))
                    rows.append("  placeholder subrole=\(value(candidate,kAXSubroleAttribute) as? String ?? "-") roleDescription-length=\((value(candidate,kAXRoleDescriptionAttribute) as? String)?.count ?? -1)")
                    var origin=CGPoint.zero,size=CGSize.zero
                    if let raw=value(candidate,kAXPositionAttribute),CFGetTypeID(raw) == AXValueGetTypeID() { _ = AXValueGetValue(raw as! AXValue,.cgPoint,&origin) }
                    if let raw=value(candidate,kAXSizeAttribute),CFGetTypeID(raw) == AXValueGetTypeID() { _ = AXValueGetValue(raw as! AXValue,.cgSize,&size) }
                    rows.append("  placeholder size=\(Int(size.width))x\(Int(size.height))")
                    var hit:AXUIElement?
                    let status=AXUIElementCopyElementAtPosition(app,Float(origin.x+size.width/2),Float(origin.y+min(size.height/2,60)),&hit)
                    var chain:[String]=[]
                    var cursor=hit
                    while let current=cursor,chain.count < 12 {
                        chain.append(value(current,kAXRoleAttribute) as? String ?? "?")
                        cursor=element(current,kAXParentAttribute)
                    }
                    rows.append("  hit-test status=\(status.rawValue) chain=" + chain.joined(separator:" < "))
                    var raw:CFTypeRef?
                    let copy=AXUIElementCopyAttributeValue(candidate,kAXChildrenAttribute as CFString,&raw)
                    rows.append("  children copy status=\(copy.rawValue) count=\((raw as? [AXUIElement])?.count ?? -1)")
                    var windowOrigin=CGPoint.zero
                    if let raw=value(window,kAXPositionAttribute),CFGetTypeID(raw) == AXValueGetTypeID() { _ = AXValueGetValue(raw as! AXValue,.cgPoint,&windowOrigin) }
                    let state=await MainActor.run { () -> String in
                        let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first
                        return "hidden=\(mail?.isHidden ?? false) active=\(mail?.isActive ?? false)"
                    }
                    rows.append("  window minimized=\(String(describing:value(window,kAXMinimizedAttribute) as? Bool)) origin=\(Int(windowOrigin.x)),\(Int(windowOrigin.y)) placeholderOrigin=\(Int(origin.x)),\(Int(origin.y)) mail \(state) main=\(String(describing:value(window,kAXMainAttribute) as? Bool))")
                    var later=0
                    for attempt in 1...6 {
                        var again:CFTypeRef?
                        let status=AXUIElementCopyAttributeValue(candidate,kAXChildrenAttribute as CFString,&again)
                        _ = AXUIElementGetAttributeValueCount(candidate,kAXChildrenAttribute as CFString,&later)
                        rows.append("  attempt \(attempt): status=\(status.rawValue) children=\(later)")
                        if later > 0 { break }
                        try? await Task.sleep(for:.seconds(1))
                    }
                    if let kids=try? children(candidate,limit:50) { rows.append("  child roles: " + kids.map { value($0,kAXRoleAttribute) as? String ?? "?" }.joined(separator:",")) }
                    let focused=element(app,kAXFocusedUIElementAttribute)
                    rows.append("  app focused role=\(focused.flatMap { value($0,kAXRoleAttribute) as? String } ?? "none")")
                }
            }
            guard webAreas > 0 || sendButtons > 0 else { lines.append("w\(index): no editor and no send button (visited \(visited))"); continue }
            lines.append("w\(index): webAreas=\(webAreas) sendButtons=\(sendButtons) visited=\(visited)")
            lines.append(contentsOf:rows)
        }
        return lines
    }
    #endif
    private func binding(_ contextID:String,token:String) throws -> Binding {
        guard let binding=bindings[contextID],binding.token == token else { throw BridgeFailure("This message’s live editor binding expired. Refresh the shared message before applying text.") }
        return binding
    }
    private func checkFocus(_ target:Target) async throws {
        let pid=target.pid
        let foreground=await MainActor.run {
            let app=NSWorkspace.shared.frontmostApplication
            return (matches:app?.processIdentifier == pid,name:app?.localizedName ?? "an unidentified app",asciiInput:Self.asciiCapableInputSource())
        }
        // Typed characters pass through the active input source. A composing method such as Japanese kana
        // would transform or swallow them, so typing is allowed only with a plain Latin source selected.
        guard foreground.asciiInput else { throw BridgeFailure("Switch the keyboard to an English input source, such as ABC, before Mail Dot types the reply. Nothing was typed by this check.") }
        let modifiers=CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift])
        guard foreground.matches else { throw BridgeFailure("Bring this Mail message to the front before applying text. macOS reports \(foreground.name) receiving keyboard input. Nothing was typed by this check.") }
        guard modifiers.isEmpty else { throw BridgeFailure("Release Command, Control, Option and Shift before applying text. Nothing was typed by this check.") }
        guard let window=element(target.app,kAXFocusedWindowAttribute),CFEqual(window,target.window) else { throw BridgeFailure("The bound Mail message is not the focused window. Nothing was typed by this check.") }
        guard let focus=element(target.app,kAXFocusedUIElementAttribute),CFEqual(focus,target.body) else {
            noteSelection(target,stage:"body focus not confirmed")
            throw BridgeFailure("Mail did not focus the bound message body. Nothing was typed by this check.")
        }
    }
    /// The message's window, chosen as ComposeWindowChoice says: the window bound earlier, the one titled with the
    /// subject, or, where that leaves several or none, the message being written that Mail has in front. One window
    /// or none is returned.
    private func composeWindows(_ app:AXUIElement,subject:String,bound:AXUIElement?) throws -> [AXUIElement] {
        let windows=try children(app,attribute:kAXWindowsAttribute,limit:20)
        let main=value(app,kAXMainWindowAttribute).flatMap{ CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        let candidates=windows.map{ window in
            ComposeWindowChoice.Candidate(title:value(window,kAXTitleAttribute) as? String,isMain:main.map{ CFEqual($0,window) } ?? false,isBound:bound.map{ CFEqual($0,window) } ?? false)
        }
        var asked=0
        let chosen=ComposeWindowChoice.choose(candidates,subject:subject) { index in asked += 1; return hasSendButton(windows[index]) }
        if asked > 0 { MailEditorDiagnostics.note("window chosen among \(windows.count) by its Send button: \(chosen == nil ? "none" : "found") (asked \(asked))") }
        return chosen.map{ [windows[$0]] } ?? []
    }
    /// Whether a window is a message being written: it has Mail's Send button. Looked for near the top of the window,
    /// within a small limit, and never read beyond roles and the button's own identifier.
    private func hasSendButton(_ window:AXUIElement) -> Bool {
        var queue:[(AXUIElement,Int)]=[(window,0)],visited=0
        let deadline=Date().addingTimeInterval(1.5)
        while !queue.isEmpty,visited < 200,Date() < deadline {
            let (item,depth)=queue.removeFirst(); visited += 1
            guard let role=role(item) else { continue }
            if role == kAXButtonRole,value(item,kAXIdentifierAttribute) as? String == "send" { return true }
            if role == "AXWebArea" || depth >= 6 { continue }
            queue.append(contentsOf:((try? children(item,limit:200-visited)) ?? []).map{ ($0,depth+1) })
        }
        return false
    }
    private func sameTarget(_ target:Target,subject:String) throws {
        let current=try locate(pid:target.pid,subject:subject,bound:target.window)
        guard CFEqual(current.window,target.window),CFEqual(current.body,target.body) else { throw BridgeFailure("The bound Mail window or editor was replaced. Share the current message again.") }
    }
    private func locate(pid:pid_t,subject:String,bound:AXUIElement?=nil) throws -> Target {
        let app=AXUIElementCreateApplication(pid)
        let windows=try composeWindows(app,subject:subject,bound:bound)
        guard windows.count == 1,let window=windows.first else { throw BridgeFailure(subject.isEmpty ? "Mail Dot could not find this new message's window. Click in it, then try again." : "Mail Dot could not find this message's window. Click in it, then try again.") }
        let deadline=Date().addingTimeInterval(3)
        var queue:[(AXUIElement,Int)]=[(window,0)],visited=0,bodies:[AXUIElement]=[],popovers:[AXUIElement]=[],sendButtons:[AXUIElement]=[],unreadable=0
        defer { if unreadable > 0 { MailEditorDiagnostics.note("editor discovery passed over \(unreadable) element(s) without a role") } }
        while !queue.isEmpty {
            guard visited < 250,Date() < deadline else { throw BridgeFailure("Mail editor discovery exceeded its limit.") }
            let (item,depth)=queue.removeFirst(); visited += 1
            // An element that gives no role is passed over, not a reason to stop (owner reports, 13 and 14 November 2026:
            // "Incomplete Mail editor metadata" on a reply with Mail's suggested-reply chip above the quote; Mail
            // answers slowly or not at all for some transient elements). It is asked again with more time first.
            // Neither the message body nor the Send button can be such an element: both are found by their role.
            guard let role=role(item) else { unreadable += 1; continue }
            if role == "AXPopover" { popovers.append(item); continue }
            if role == "AXWebArea" { bodies.append(item); continue }
            if role == kAXButtonRole,value(item,kAXIdentifierAttribute) as? String == "send" { sendButtons.append(item) }
            let found=try children(item,limit:250-visited-queue.count)
            guard depth < 8 || found.isEmpty else { throw BridgeFailure("Mail editor discovery exceeded its depth limit.") }
            queue.append(contentsOf:found.map {($0,depth+1)})
        }
        let editors=bodies.count > 1 ? bodies.filter(supportsTextMarkers) : bodies
        guard editors.count == 1,let body=editors.first else {
            MailEditorDiagnostics.note("editor discovery failed: webAreas=\(bodies.count) textEditors=\(editors.count) visited=\(visited)")
            throw BridgeFailure(bodies.isEmpty
                ? "Mail has not made this message's text available to Mail Dot. Click once in the message text, then press Share with Dot again. If it keeps happening, quit and reopen Mail."
                : "Mail shows more than one text area in this message window, and Mail Dot cannot tell which is the message. Nothing was read or changed.")
        }
        return Target(pid:pid,app:app,window:window,body:body,popovers:popovers,sendButtons:sendButtons)
    }
    /// An element's role, asked for again with a longer wait when Mail does not answer at once.
    private func role(_ item:AXUIElement) -> String? {
        if let role=value(item,kAXRoleAttribute) as? String { return role }
        for wait in [Float(0.6),1.2] {
            _ = AXUIElementSetMessagingTimeout(item,wait)
            var raw:CFTypeRef?
            if AXUIElementCopyAttributeValue(item,kAXRoleAttribute as CFString,&raw) == .success,let role=raw as? String { return role }
        }
        return nil
    }
    private func supportsTextMarkers(_ element:AXUIElement) -> Bool {
        var names:CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element,&names) == .success else { return false }
        return Set(names as? [String] ?? []).isSuperset(of:["AXTextMarkerRangeForUIElement","AXLengthForTextMarkerRange","AXStringForTextMarkerRange"])
    }
    /// Mail's message editor is web content. WebKit attaches that content to the window's accessibility tree
    /// only once something has asked for it, so the first look at a compose window can find an empty
    /// placeholder where the editor will be. This asks, waits briefly and looks again, and as a last resort
    /// gives the editor keyboard focus, which also makes Mail present it. Observed on November 11, 2026: a
    /// real reply window showed a focusable group with no children and no web area at all.
    private func ensureEditorExposed(pid:pid_t,subject:String) async throws {
        var placeholders=0,areas=0
        for attempt in 0..<12 {
            let app=AXUIElementCreateApplication(pid)
            let windows=try composeWindows(app,subject:subject,bound:nil)
            guard windows.count == 1,let window=windows.first else { return } // locate() reports this case in its own words.
            var queue:[(AXUIElement,Int)]=[(window,0)],visited=0,empty:[AXUIElement]=[]
            areas=0
            while !queue.isEmpty,visited < 250 {
                let (item,depth)=queue.removeFirst(); visited += 1
                let role=value(item,kAXRoleAttribute) as? String ?? ""
                if role == "AXPopover" { continue }
                if role == "AXWebArea" { areas += 1; continue }
                var count=0; _ = AXUIElementGetAttributeValueCount(item,kAXChildrenAttribute as CFString,&count)
                if role == kAXGroupRole,count == 0,depth <= 3 {
                    var settable:DarwinBoolean=false
                    if AXUIElementIsAttributeSettable(item,kAXFocusedAttribute as CFString,&settable) == .success,settable.boolValue { empty.append(item) }
                }
                guard depth < 8,count > 0,let found=try? children(item,limit:250) else { continue }
                queue.append(contentsOf:found.map {($0,depth+1)})
            }
            if areas > 0 { return }
            placeholders=empty.count
            // Asking for the placeholder's content is what prompts WebKit to provide it.
            for item in empty { var ignored:CFTypeRef?; _ = AXUIElementCopyAttributeValue(item,kAXChildrenAttribute as CFString,&ignored) }
            if attempt == 8,empty.count == 1 { _ = AXUIElementSetAttributeValue(empty[0],kAXFocusedAttribute as CFString,kCFBooleanTrue) }
            try await Task.sleep(for:.milliseconds(300))
        }
        let hidden=await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first?.isHidden ?? false }
        MailEditorDiagnostics.note("editor not exposed after waiting: webAreas=\(areas) emptyFocusableGroups=\(placeholders) mailHidden=\(hidden)")
    }
    /// Development diagnostics contain counts/booleans only, never correspondence or AX descriptions.
    private func noteSelection(_ target:Target,stage:String,expected:String?=nil) {
        #if DEBUG
        guard value(target.window,kAXTitleAttribute) as? String == "Re: Mail Dot native read test - UNSENT",
              let whole=try? markerText(target.body,range:bodyRange(target.body)) else { return }
        let marker=value(target.body,kAXSelectedTextMarkerRangeAttribute).flatMap { try? markerText(target.body,range:$0) }
        let plain=value(target.body,kAXSelectedTextAttribute) as? String
        var selectedRange=CFRange(location:-1,length:-1)
        if let raw=value(target.body,kAXSelectedTextRangeAttribute),CFGetTypeID(raw) == AXValueGetTypeID(),
           AXValueGetType(raw as! AXValue) == .cfRange {
            _ = AXValueGetValue(raw as! AXValue,.cfRange,&selectedRange)
        }
        let focus=element(target.app,kAXFocusedUIElementAttribute)
        let focusRole=focus.flatMap { value($0,kAXRoleAttribute) as? String } ?? "unavailable"
        let knownRoles:Set<String>=["AXWebArea","AXTextField","AXTextArea","AXMenu","AXPopover","unavailable"]
        func matches(_ text:String?) -> Bool {
            guard let text,let expected else { return false }
            return Data(text.utf8) == Data(expected.utf8)
        }
        let summary="Native editor \(stage): sourceUnits=\(whole.utf16.count), markerUnits=\(marker?.utf16.count ?? -1), plainUnits=\(plain?.utf16.count ?? -1), "
            + "range=\(selectedRange.location):\(selectedRange.length), expectedUnits=\(expected?.utf16.count ?? -1), "
            + "markerMatches=\(matches(marker)), plainMatches=\(matches(plain)), focusMatches=\(focus.map { CFEqual($0,target.body) } ?? false), "
            + "focusRole=\(knownRoles.contains(focusRole) ? focusRole : "other"), bodyFocused=\((value(target.body,kAXFocusedAttribute) as? Bool) == true)"
        try? BridgeStore.shared().transaction { $0.audit.append(summary) }
        #endif
    }
    private func bodyRange(_ body:AXUIElement) throws -> CFTypeRef {
        var range:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(body,"AXTextMarkerRangeForUIElement" as CFString,body,&range) == .success,let range else { throw BridgeFailure("Mail did not expose the complete editor text range.") }
        return range
    }
    private func selectAllItem(_ app:AXUIElement) throws -> AXUIElement {
        guard let bar=element(app,kAXMenuBarAttribute) else { throw BridgeFailure("Mail did not expose its menu bar. Nothing was typed.") }
        let edits=try children(bar,limit:20).filter { value($0,kAXIdentifierAttribute) as? String == "Mail.menuBar.editMenu" }
        guard edits.count == 1,let edit=edits.first else { throw BridgeFailure("Mail did not expose one Edit menu. Nothing was typed.") }
        let menus=try children(edit,limit:2).filter { value($0,kAXRoleAttribute) as? String == kAXMenuRole }
        guard menus.count == 1,let menu=menus.first else { throw BridgeFailure("Mail did not expose its Edit commands. Nothing was typed.") }
        let items=try children(menu,limit:100).filter { value($0,kAXIdentifierAttribute) as? String == "Mail.menuBar.editMenu.selectAll" }
        guard items.count == 1,let item=items.first,value(item,kAXRoleAttribute) as? String == kAXMenuItemRole,
              (value(item,kAXEnabledAttribute) as? Bool) == true else {
            throw BridgeFailure("Mail's Select All command is unavailable. Nothing was typed.")
        }
        return item
    }
    private func selectedText(_ body:AXUIElement) -> String? {
        if let range=value(body,"AXSelectedTextMarkerRange"),let text=try? markerText(body,range:range) { return text }
        // Current body was bounded/read immediately before selecting it.
        guard let text=value(body,kAXSelectedTextAttribute) as? String,text.utf16.count <= MailBodyLimits.characters,text.utf8.count <= MailBodyLimits.utf8Bytes else { return nil }
        return text
    }
    private func markerText(_ body:AXUIElement,range:CFTypeRef) throws -> String {
        var rawLength:CFTypeRef?,rawText:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(body,"AXLengthForTextMarkerRange" as CFString,range,&rawLength) == .success,
              let length=rawLength as? NSNumber,length.doubleValue.isFinite,length.doubleValue.rounded(.towardZero) == length.doubleValue,
              (0...Double(MailBodyLimits.characters)).contains(length.doubleValue),
              AXUIElementCopyParameterizedAttributeValue(body,"AXStringForTextMarkerRange" as CFString,range,&rawText) == .success,let text=rawText as? String else { throw BridgeFailure("Mail did not return bounded editor text.") }
        try ReplyCapturePolicy.validateBody(text,length:length.intValue); return text
    }
    private func postKey(pid:pid_t,key:CGKeyCode) throws {
        guard let down=CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:true),let up=CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:false) else { throw BridgeFailure("Cannot prepare native text input.") }
        down.flags=[]; up.flags=[]
        down.postToPid(pid); up.postToPid(pid)
    }
    /// Attaches files to the bound message where its caret is, just after the reply Mail Dot typed: the
    /// files are put on the pasteboard and pasted, as a person would, and the pasteboard is then restored.
    /// Returns the message as it reads afterwards.
    func attachFiles(_ urls:[URL],contextID:String,token:String,expected:MailDraft) async throws -> MailDraft {
        let binding=try self.binding(contextID,token:token)
        guard CGPreflightPostEventAccess() else { throw BridgeFailure("macOS has not allowed native input for Mail Dot. Dot's files were not attached.") }
        guard !urls.isEmpty,urls.allSatisfy({ FileManager.default.isReadableFile(atPath:$0.path) }) else { throw BridgeFailure("Dot's files are no longer available, so none were attached.") }
        try sameTarget(binding.target,subject:binding.subject)
        try await checkFocus(binding.target)
        let saved:[[(String,Data)]]=await MainActor.run {
            let board=NSPasteboard.general
            let kept=board.pasteboardItems?.map{ item in item.types.compactMap{ type in item.data(forType:type).map{(type.rawValue,$0)} } } ?? []
            board.clearContents(); board.writeObjects(urls.map{$0 as NSURL})
            return kept
        }
        defer {
            Task { @MainActor in
                let board=NSPasteboard.general; board.clearContents()
                let items=saved.map{ pairs -> NSPasteboardItem in let item=NSPasteboardItem(); for (type,data) in pairs { item.setData(data,forType:NSPasteboard.PasteboardType(type)) }; return item }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        guard let down=CGEvent(keyboardEventSource:nil,virtualKey:9,keyDown:true),let up=CGEvent(keyboardEventSource:nil,virtualKey:9,keyDown:false) else { throw BridgeFailure("Cannot prepare the paste. Dot's files were not attached.") }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(binding.target.pid); up.postToPid(binding.target.pid)
        // A key sent with the Command flag leaves the system believing Command is held: say it was released.
        if let released=CGEvent(keyboardEventSource:nil,virtualKey:55,keyDown:false) { released.type = .flagsChanged; released.flags=[]; released.postToPid(binding.target.pid) }
        try await Task.sleep(for:.seconds(2))
        return try await readback(contextID:contextID,token:token,matching:expected)
    }
    /// Types Dot's subject line into the bound new message's Subject field, which must be empty, and checks
    /// that Mail shows exactly it. Typed rather than set, so that Mail's own message takes the subject.
    func setSubject(_ subject:String,contextID:String,token:String) async throws {
        var binding=try self.binding(contextID,token:token)
        guard binding.subject.isEmpty else { throw BridgeFailure("This message already has a subject, so Mail Dot left it as it is.") }
        guard CGPreflightPostEventAccess() else { throw BridgeFailure("macOS has not allowed native text input for Mail Dot. The subject was not filled in.") }
        try sameTarget(binding.target,subject:binding.subject)
        var queue:[(AXUIElement,Int)]=[(binding.target.window,0)],visited=0,field:AXUIElement?
        while !queue.isEmpty,visited < 250,field == nil {
            let (item,depth)=queue.removeFirst(); visited += 1
            if value(item,kAXIdentifierAttribute) as? String == "Mail.subjectField" { field=item; break }
            let role=value(item,kAXRoleAttribute) as? String ?? ""
            guard role != "AXWebArea",role != "AXPopover",depth < 8,let found=try? children(item,limit:250) else { continue }
            queue.append(contentsOf:found.map {($0,depth+1)})
        }
        guard let field else { throw BridgeFailure("Mail Dot could not find this message's Subject field. The subject was not filled in.") }
        guard (value(field,kAXValueAttribute) as? String ?? "").isEmpty else { throw BridgeFailure("This message already has a subject, so Mail Dot left it as it is.") }
        guard AXUIElementSetAttributeValue(field,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else { throw BridgeFailure("Mail did not let Mail Dot fill in the subject.") }
        var focused=false
        for _ in 0..<15 {
            if value(field,kAXFocusedAttribute) as? Bool == true { focused=true; break }
            try await Task.sleep(for:.milliseconds(100))
        }
        guard focused else { throw BridgeFailure("Mail did not put the cursor in the Subject field. The subject was not filled in.") }
        for segment in try MailUIEditPolicy.segments(subject) where segment != "\n" {
            try postText(segment,pid:binding.target.pid)
            try await Task.sleep(for:.milliseconds(30))
        }
        var shown=""
        for _ in 0..<20 {
            shown=value(field,kAXValueAttribute) as? String ?? ""
            if shown == subject { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        guard shown == subject else { throw BridgeFailure("The Subject field does not read exactly as Dot wrote it. Look at it in Mail before sending.") }
        // From now on the message's window carries the subject as its title, and is found by it.
        binding=Binding(token:binding.token,target:binding.target,subject:subject)
        bindings[contextID]=binding
    }
    private func postText(_ text:String,pid:pid_t) throws {
        guard let down=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true),let up=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:false) else { throw BridgeFailure("Cannot prepare native Unicode input.") }
        let units=Array(text.utf16)
        units.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength:units.count,unicodeString:$0.baseAddress) }
        down.flags=[]; up.flags=[]; down.postToPid(pid); up.postToPid(pid)
    }
    private func children(_ item:AXUIElement,attribute:String=kAXChildrenAttribute,limit:Int) throws -> [AXUIElement] {
        _ = AXUIElementSetMessagingTimeout(item,0.25)
        var count=0
        let status=AXUIElementGetAttributeValueCount(item,attribute as CFString,&count)
        if status == .attributeUnsupported || status == .noValue { return [] }
        guard status == .success,count >= 0,count <= limit else { throw BridgeFailure("Mail editor metadata exceeded its bounds.") }
        if count == 0 { return [] }
        var raw:CFArray?
        guard AXUIElementCopyAttributeValues(item,attribute as CFString,0,count,&raw) == .success,let result=raw as? [AXUIElement],result.count == count else { throw BridgeFailure("Incomplete Mail editor children.") }
        return result
    }
    private func element(_ item:AXUIElement,_ name:String)->AXUIElement? {
        guard let raw=value(item,name),CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }; return (raw as! AXUIElement)
    }
    private func value(_ item:AXUIElement,_ name:String)->CFTypeRef? {
        _ = AXUIElementSetMessagingTimeout(item,0.25)
        var raw:CFTypeRef?
        guard AXUIElementCopyAttributeValue(item,name as CFString,&raw) == .success else { return nil }; return raw
    }
}
