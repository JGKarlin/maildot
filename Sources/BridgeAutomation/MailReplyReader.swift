import AppKit
import ApplicationServices
import BridgeCore

/// Captures only an explicitly selected reply. It cannot edit or send messages.
/// Recipient menus are opened through their own token and immediately canceled.
public actor MailReplyReader {
    private var reading = false
    public init() {}

    public func capture(matching expected:MailDraft,native:MailDraft?=nil) async throws -> MailDraft {
        try await capture(matching:expected,native:native,requireNoAttachments:false)
    }
    public func captureForSend(matching expected:MailDraft) async throws -> MailDraft {
        try await capture(matching:expected,native:nil,requireNoAttachments:true)
    }
    private func capture(matching expected:MailDraft,native:MailDraft?,requireNoAttachments:Bool) async throws -> MailDraft {
        guard !reading else { throw BridgeFailure("A message capture is already in progress.") }
        reading = true; defer { reading = false }
        guard AXIsProcessTrusted() else { throw BridgeFailure("Mail Dot needs the approved Accessibility permission to read this message.") }
        let pid = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail")
                .first(where:{ $0.bundleURL?.path == "/System/Applications/Mail.app" })?.processIdentifier
        }
        guard let pid else { throw BridgeFailure("Apple Mail is not running.") }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app,0.25)
        let windows = try children(app,attribute:kAXWindowsAttribute,limit:20)
        // A new message without a subject is the window Mail has in front, where the owner opened the panel.
        let matches: [AXUIElement]
        if expected.subject.isEmpty {
            matches = value(app,kAXMainWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? [$0 as! AXUIElement] : nil } ?? []
        } else { matches = windows.filter { value($0,kAXTitleAttribute) as? String == expected.subject } }
        guard matches.count == 1, let window = matches.first else {
            throw BridgeFailure(expected.subject.isEmpty ? "Click in the new message's window, then try again." : "Keep exactly one compose window with this subject open in Mail.")
        }
        let title = value(window,kAXTitleAttribute) as? String
        let deadline = Date().addingTimeInterval(10)
        let fields = try scan(window,deadline:deadline)
        // All recipient fields must be visible. Hidden Bcc is never assumed empty.
        guard let subject = fields["Mail.subjectField"], let sender = fields["popup_from"],
              let to = fields["Mail.toField"], let cc = fields["Mail.ccField"],
              let bcc = fields["Mail.bccField"], let body = fields["body"] else {
            // Say exactly what is missing. A hidden address field is the owner's to show; a missing subject,
            // sender or body means Mail's own naming changed and Mail Dot must be updated.
            let hidden = [("To","Mail.toField"),("Cc","Mail.ccField"),("Bcc","Mail.bccField")].filter { fields[$0.1] == nil }.map(\.0)
            let unreadable = [("subject","Mail.subjectField"),("sender","popup_from"),("message text","body")].filter { fields[$0.1] == nil }.map(\.0)
            if !unreadable.isEmpty {
                if unreadable == ["message text"] {
                    MailEditorDiagnostics.note("reader found no message editor")
                    throw BridgeFailure("Mail has not made this message's text available to Mail Dot. Click once in the message text, then press Share with Dot again. If it keeps happening, quit and reopen Mail.")
                }
                MailEditorDiagnostics.note("reader could not find: \(unreadable.joined(separator:"+"))")
                throw BridgeFailure("Mail on this version of macOS does not present its \(unreadable.joined(separator:", ")) the way Mail Dot expects, so this message cannot be read. Mail Dot needs an update; nothing was changed.")
            }
            throw BridgeFailure("Show the \(hidden.joined(separator:" and ")) field\(hidden.count == 1 ? "" : "s") in this Mail message, then share again.")
        }
        func rawHeaders() throws -> [String] { try [subject,sender,to,cc,bcc].map { try text($0) } }
        func headers() async throws -> MailDraft {
            let subjectText = try text(subject)
            let senderText = try text(sender)
            guard let separator = senderText.range(of:" – ",options:.backwards) else {
                throw BridgeFailure("Mail did not expose the complete sending address.")
            }
            let from = try ReplyCapturePolicy.checkedAddress([String(senderText[separator.upperBound...])])
            let toAddresses = try await addresses(to,app:app,deadline:deadline)
            let ccAddresses = try await addresses(cc,app:app,deadline:deadline)
            let bccAddresses = try await addresses(bcc,app:app,deadline:deadline)
            return MailDraft(id:-1,subject:subjectText,sender:from,to:toAddresses,cc:ccAddresses,bcc:bccAddresses,body:"",attachmentCount:-1)
        }
        let rawBefore = try rawHeaders()
        let firstHeaders = try await headers()
        _ = try ReplyCapturePolicy.validate(firstHeaders,matching:expected)
        let firstBody = try bodyText(body)
        // For a send, the pictures and files in the message are counted, not refused: the count is bound into
        // the reviewed draft, so the send goes only with exactly these.
        let firstObjects = requireNoAttachments ? try Self.embeddedObjects(body,matching:firstBody) : -1
        // Menus take several AX round trips. Reject concurrent edits instead of
        // assembling a snapshot from different visible draft versions.
        // The addresses were read once, through each recipient's menu. A second pass through every menu
        // doubled the time and the on-screen flicker; comparing the fields' own text catches an edit as well.
        let secondHeaders = firstHeaders
        let secondBody = try bodyText(body)
        let secondObjects = requireNoAttachments ? try Self.embeddedObjects(body,matching:secondBody) : -1
        guard try rawHeaders() == rawBefore, firstObjects == secondObjects,
              Data(firstBody.utf8) == Data(secondBody.utf8), Date() < deadline,
              value(window,kAXTitleAttribute) as? String == title else {
            throw BridgeFailure("The message changed while reading. Share its current context again.")
        }
        var result = secondHeaders; result.body = secondBody
        var visible=try ReplyCapturePolicy.validate(result,matching:expected)
        if requireNoAttachments {
            // This separate send-preflight path never substitutes cached scripting
            // attachment metadata for the current editor's attributed evidence.
            visible.attachmentCount=secondObjects
            return visible
        }
        if let native { return try ReplyCapturePolicy.reconcile(native:native,visible:visible) }
        return visible
    }

    private func scan(_ window:AXUIElement,deadline:Date) throws -> [String:AXUIElement] {
        var queue:[(AXUIElement,Int)] = [(window,0)], visited = 0, result:[String:AXUIElement] = [:]
        let identifiers:Set<String> = ["Mail.subjectField","popup_from","Mail.toField","Mail.ccField","Mail.bccField"]
        while !queue.isEmpty {
            guard visited < 250, Date() < deadline else { throw BridgeFailure("Mail's compose field scan exceeded its limit.") }
            let (element,depth) = queue.removeFirst(); visited += 1
            // An element without a role is passed over; the fields wanted are all found by role or identifier, and a
            // missing one is reported below in its own words (see MacMailUIEditingDriver.locate, 14 November 2026).
            guard let role = role(element) else { continue }
            if role == "AXPopover" { continue } // The extension panel is not part of the draft.
            let key = role == "AXWebArea" ? "body" : (value(element,kAXIdentifierAttribute) as? String ?? "")
            if identifiers.contains(key) || key == "body" {
                guard result[key] == nil else { throw BridgeFailure("Mail exposed ambiguous compose fields.") }
                result[key] = element
            }
            if role == "AXWebArea" { continue } // Never traverse quoted correspondence.
            let children = try children(element,limit:250 - visited - queue.count)
            guard depth < 8 || children.isEmpty else { throw BridgeFailure("Mail's compose fields exceeded the scan depth.") }
            queue.append(contentsOf:children.map { ($0,depth+1) })
        }
        return result
    }

    private func addresses(_ field:AXUIElement,app:AXUIElement,deadline:Date) async throws -> [String] {
        let before = try text(field)
        let count = try ReplyCapturePolicy.tokenCount(before)
        guard count > 0 else { return [] }
        var range = CFRange(location:0,length:before.utf16.count)
        guard let parameter = AXValueCreate(.cfRange,&range) else { throw BridgeFailure("Cannot prepare the recipient range.") }
        var raw:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field,kAXAttributedStringForRangeParameterizedAttribute as CFString,parameter,&raw) == .success,
              let attributed = raw as? NSAttributedString, attributed.length == range.length else {
            throw BridgeFailure("Mail did not return the complete recipient token range.")
        }
        var tokens:[AXUIElement] = []
        for index in 0..<attributed.length where (attributed.string as NSString).character(at:index) == 0xfffc {
            guard let attachment = attributed.attribute(NSAttributedString.Key("AXAttachment"),at:index,effectiveRange:nil),
                  CFGetTypeID(attachment as CFTypeRef) == AXUIElementGetTypeID() else {
                throw BridgeFailure("Mail did not expose a recipient token's identity.")
            }
            tokens.append(attachment as! AXUIElement)
        }
        guard tokens.count == count else { throw BridgeFailure("Mail returned incomplete recipient tokens.") }
        var result:[String] = []
        for token in tokens {
            guard Date() < deadline else { throw BridgeFailure("Reading recipient addresses exceeded its time limit.") }
            guard try children(app,limit:50).allSatisfy({ value($0,kAXRoleAttribute) as? String != kAXMenuRole }),
                  try associatedMenu([token,field]) == nil else { throw BridgeFailure("Dismiss the open Mail menu, then share again.") }
            var actions:CFArray?
            guard AXUIElementCopyActionNames(token,&actions) == .success,
                  (actions as? [String])?.contains(kAXShowMenuAction) == true,
                  AXUIElementPerformAction(token,kAXShowMenuAction as CFString) == .success else {
                throw BridgeFailure("Mail could not expose this recipient's address menu.")
            }
            var menu:AXUIElement?
            while menu == nil, Date() < deadline {
                menu = try associatedMenu([token,field])
                if menu == nil { try await Task.sleep(for:.milliseconds(30)) }
            }
            guard let menu else { throw BridgeFailure("Mail did not expose an associated address menu. Dismiss it with Escape if visible.") }
            var canceled = false
            defer { if !canceled { _ = AXUIElementPerformAction(menu,kAXCancelAction as CFString) } }
            var checked:[String] = []
            for item in try children(menu,limit:40) {
                guard Date() < deadline else { throw BridgeFailure("Reading an address menu exceeded its time limit.") }
                if let mark = value(item,kAXMenuItemMarkCharAttribute) as? String, !mark.isEmpty {
                    checked.append(try text(item,attribute:kAXTitleAttribute))
                }
            }
            let address = try ReplyCapturePolicy.checkedAddress(checked)
            guard AXUIElementPerformAction(menu,kAXCancelAction as CFString) == .success else {
                throw BridgeFailure("Mail did not confirm address-menu dismissal. Press Escape and share again.")
            }
            canceled = true; result.append(address)
        }
        guard Data(try text(field).utf8) == Data(before.utf8) else { throw BridgeFailure("Recipients changed while reading.") }
        return result
    }

    private func bodyText(_ body:AXUIElement) throws -> String {
        var names:CFArray?
        let required:Set<String> = ["AXTextMarkerRangeForUIElement","AXLengthForTextMarkerRange","AXStringForTextMarkerRange"]
        guard AXUIElementCopyParameterizedAttributeNames(body,&names) == .success,
              required.isSubset(of:Set(names as? [String] ?? [])) else {
            throw BridgeFailure("Mail does not expose the required bounded message reader on this version.")
        }
        var range:CFTypeRef?, rawLength:CFTypeRef?, rawText:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(body,"AXTextMarkerRangeForUIElement" as CFString,body,&range) == .success,
              let range,
              AXUIElementCopyParameterizedAttributeValue(body,"AXLengthForTextMarkerRange" as CFString,range,&rawLength) == .success,
              let length = rawLength as? NSNumber, length.doubleValue.isFinite,
              length.doubleValue.rounded(.towardZero) == length.doubleValue, (0...Double(MailBodyLimits.characters)).contains(length.doubleValue),
              AXUIElementCopyParameterizedAttributeValue(body,"AXStringForTextMarkerRange" as CFString,range,&rawText) == .success,
              let text = rawText as? String else {
            throw BridgeFailure("Mail did not return a bounded complete message body.")
        }
        try ReplyCapturePolicy.validateBody(text,length:length.intValue)
        return text
    }

    /// The number of objects (pictures, files) in the message's text, from Mail's attributed text.
    nonisolated static func embeddedObjects(_ body:AXUIElement,matching text:String) throws -> Int {
        var range:CFTypeRef?, rawLength:CFTypeRef?, rawAttributed:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(body,"AXTextMarkerRangeForUIElement" as CFString,body,&range) == .success,
              let range,
              AXUIElementCopyParameterizedAttributeValue(body,"AXLengthForTextMarkerRange" as CFString,range,&rawLength) == .success,
              let length=rawLength as? NSNumber,length.doubleValue.isFinite,
              length.doubleValue.rounded(.towardZero) == length.doubleValue,(0...Double(MailBodyLimits.characters)).contains(length.doubleValue),
              AXUIElementCopyParameterizedAttributeValue(body,"AXAttributedStringForTextMarkerRange" as CFString,range,&rawAttributed) == .success else {
            throw BridgeFailure("Mail could not show Mail Dot the message's pictures and attachments. Sending is unavailable.")
        }
        return try AttachmentEvidence.count(rawAttributed as? NSAttributedString,length:length.intValue,matching:text)
    }
    nonisolated static func verifyNoAttachments(_ body:AXUIElement,matching text:String) throws {
        var range:CFTypeRef?, rawLength:CFTypeRef?, rawAttributed:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(body,"AXTextMarkerRangeForUIElement" as CFString,body,&range) == .success,
              let range,
              AXUIElementCopyParameterizedAttributeValue(body,"AXLengthForTextMarkerRange" as CFString,range,&rawLength) == .success,
              let length=rawLength as? NSNumber,length.doubleValue.isFinite,
              length.doubleValue.rounded(.towardZero) == length.doubleValue,(0...Double(MailBodyLimits.characters)).contains(length.doubleValue),
              AXUIElementCopyParameterizedAttributeValue(body,"AXAttributedStringForTextMarkerRange" as CFString,range,&rawAttributed) == .success else {
            throw BridgeFailure("Mail could not verify current attachments. Sending is unavailable.")
        }
        try AttachmentEvidence.requireAbsent(rawAttributed as? NSAttributedString,length:length.intValue,matching:text)
    }

    private func role(_ element:AXUIElement) -> String? {
        if let role = value(element,kAXRoleAttribute) as? String { return role }
        for wait in [Float(0.6),1.2] {
            _ = AXUIElementSetMessagingTimeout(element,wait)
            var raw:CFTypeRef?
            if AXUIElementCopyAttributeValue(element,kAXRoleAttribute as CFString,&raw) == .success, let role = raw as? String { return role }
        }
        return nil
    }
    private func associatedMenu(_ roots:[AXUIElement]) throws -> AXUIElement? {
        var found:[AXUIElement] = []
        for root in roots {
            if let raw = value(root,kAXShownMenuUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let element = raw as! AXUIElement
                if value(element,kAXRoleAttribute) as? String == kAXMenuRole { found.append(element) }
            }
            found += try children(root,limit:32).filter { value($0,kAXRoleAttribute) as? String == kAXMenuRole }
        }
        guard let first = found.first else { return nil }
        guard found.allSatisfy({ CFEqual(first,$0) }) else { throw BridgeFailure("Mail exposed ambiguous address menus.") }
        return first
    }
    private func children(_ element:AXUIElement,attribute:String = kAXChildrenAttribute,limit:Int) throws -> [AXUIElement] {
        _ = AXUIElementSetMessagingTimeout(element,0.25)
        var count = 0
        let status = AXUIElementGetAttributeValueCount(element,attribute as CFString,&count)
        if status == .attributeUnsupported || status == .noValue { return [] }
        guard status == .success, count >= 0, count <= limit else { throw BridgeFailure("Mail's field metadata was incomplete or exceeded its limit.") }
        if count == 0 { return [] }
        var raw:CFArray?
        guard AXUIElementCopyAttributeValues(element,attribute as CFString,0,count,&raw) == .success,
              let children = raw as? [AXUIElement], children.count == count else {
            throw BridgeFailure("Mail did not return complete field metadata.")
        }
        return children
    }
    private func text(_ element:AXUIElement,attribute:String = kAXValueAttribute) throws -> String {
        _ = AXUIElementSetMessagingTimeout(element,0.25)
        var raw:CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element,attribute as CFString,&raw)
        if status == .noValue, attribute == kAXValueAttribute { return "" }
        guard status == .success, let text = raw as? String, text.utf16.count <= 4096 else {
            throw BridgeFailure("Mail did not return a supported complete header field.")
        }
        return text
    }
    private func value(_ element:AXUIElement,_ attribute:String) -> CFTypeRef? {
        _ = AXUIElementSetMessagingTimeout(element,0.25)
        var raw:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,attribute as CFString,&raw) == .success else { return nil }
        return raw
    }
}
