import AppKit
import ApplicationServices
import BridgeCore

/// Read-only diagnostics. No Mail value setters, keyboard events or clipboard access.
/// The explicit synthetic recipient-menu check may open and cancel that address menu.
public actor MailAccessibilityProbe {
    public init() {}

    public func trusted(requestPrompt:Bool = false) -> Bool {
        if requestPrompt {
            // The documented public key avoids Swift 6's imported mutable-C-global diagnostic.
            let options = ["AXTrustedCheckOptionPrompt":true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    public func inspectReply(subject:String,checkTextReading:Bool = false,checkSyntheticValue:Bool = false,checkSyntheticMenu:Bool = false,checkSyntheticStructure:Bool = false) async throws -> String {
        guard AXIsProcessTrusted() else { throw BridgeFailure("Accessibility permission has not been granted to Mail Dot.") }
        guard !subject.isEmpty else { throw BridgeFailure("Choose a reply with a subject for this read-only check.") }
        let pid = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail")
                .first(where:{ $0.bundleURL?.path == "/System/Applications/Mail.app" })?.processIdentifier
        }
        guard let pid else { throw BridgeFailure("Apple Mail is not running.") }
        let application = AXUIElementCreateApplication(pid)
        let windows = value(application,kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard windows.count <= 20 else { throw BridgeFailure("Mail has more windows than this bounded probe supports.") }
        let matches = windows.filter { value($0,kAXTitleAttribute) as? String == subject }
        guard matches.count == 1, let window = matches.first else {
            throw BridgeFailure("The probe needs exactly one open window with the selected reply's subject. Body access was not attempted.")
        }
        let deadline = Date().addingTimeInterval(5)
        var queue:[(AXUIElement,Int)] = [(window,0)], visited = 0
        var incomplete = false
        var subjectField = false, bodies:[AXUIElement] = [], recipientTokens:[AXUIElement] = []
        var headerFields:[String:AXUIElement] = [:]
        while !queue.isEmpty, visited < 250, Date() < deadline {
            let (element,depth) = queue.removeFirst(); visited += 1
            let identifier = value(element,kAXIdentifierAttribute) as? String
            if let identifier, ["Mail.subjectField","Mail.toField","Mail.ccField","Mail.bccField","popup_from"].contains(identifier) {
                headerFields[identifier] = element
            }
            if identifier == "Mail.subjectField" { subjectField = true }
            let role = value(element,kAXRoleAttribute) as? String
            if role == "AXPopover" { continue }
            if role == nil { incomplete = true }
            if role == "AXTextAttachment" { recipientTokens.append(element) }
            if role == "AXWebArea" {
                bodies.append(element)
                continue // Do not traverse quoted correspondence or read message text.
            }
            var childCount = 0
            let countResult = AXUIElementGetAttributeValueCount(element,kAXChildrenAttribute as CFString,&childCount)
            if countResult == .attributeUnsupported || countResult == .noValue { continue }
            guard countResult == .success else { incomplete = true; continue }
            if depth >= 8 {
                if childCount > 0 { incomplete = true }
                continue
            }
            let available = max(0,250 - visited - queue.count)
            if childCount > available { incomplete = true }
            let requested = min(childCount,available)
            if requested > 0 {
                var rawChildren:CFArray?
                let copied = AXUIElementCopyAttributeValues(element,kAXChildrenAttribute as CFString,0,requested,&rawChildren)
                guard copied == .success, let children = rawChildren as? [AXUIElement], children.count == requested else {
                    incomplete = true; continue
                }
                queue.append(contentsOf:children.map { ($0,depth+1) })
            }
        }
        guard queue.isEmpty, !incomplete, Date() < deadline else { throw BridgeFailure("The Mail field scan was incomplete or exceeded its time or size limit.") }
        guard subjectField, bodies.count == 1, let body = bodies.first else {
            throw BridgeFailure("The selected window did not expose one identifiable compose body within the probe limits.")
        }
        if checkSyntheticStructure {
            guard ["Re: Mail Bridge synthetic reply test","Mail Dot current-build metadata test"].contains(subject) else { throw BridgeFailure("This structure diagnostic is limited to the named synthetic fixtures.") }
            return try syntheticBodyStructure(body,deadline:deadline)
        }
        if checkSyntheticMenu {
            guard subject == "Re: Mail Bridge synthetic reply test", let field = headerFields["Mail.toField"] else {
                throw BridgeFailure("The recipient-menu check is limited to the named synthetic fixture.")
            }
            // This read-only check accepts only a menu directly associated with this token/field.
            // It never discovers a target from global focus or performs a Mail data mutation.
            return try await syntheticRecipientMenu(application:application,field:field,deadline:deadline)
        }
        var names:CFArray?
        guard AXUIElementCopyAttributeNames(body,&names) == .success, let bodyNames = names as? [String] else {
            throw BridgeFailure("Mail did not return body-field capabilities.")
        }
        let supported = Set(bodyNames)
        let attributes = [kAXValueAttribute,kAXSelectedTextAttribute,kAXSelectedTextRangeAttribute]
        var rows = attributes.map { name in
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(body,name as CFString,&settable)
            let writable = result == .success ? (settable.boolValue ? "yes" : "no") : (result == .attributeUnsupported ? "no" : "unknown (\(result.rawValue))")
            return "\(name): advertised \(supported.contains(name) ? "yes" : "no"), writable \(writable)"
        }
        var parameterized:CFArray?
        var parameterNames = Set<String>()
        if AXUIElementCopyParameterizedAttributeNames(body,&parameterized) == .success {
            let available = Set(parameterized as? [String] ?? [])
            parameterNames = available
            for name in ["AXStringForRange","AXAttributedStringForRange","AXTextMarkerRangeForUIElement","AXStringForTextMarkerRange"] {
                rows.append("\(name): advertised \(available.contains(name) ? "yes" : "no")")
            }
        }
        if checkSyntheticValue {
            guard subject == "Re: Mail Bridge synthetic reply test" else { throw BridgeFailure("The whole-value diagnostic is limited to the synthetic fixture.") }
            // AXValue has no pre-allocation size limit. This development-only check is distinct
            // from the bounded range reader and must not be advertised as a bounded allocation.
            guard let text = value(body,kAXValueAttribute) as? String else {
                throw BridgeFailure("The synthetic body did not return a String for AXValue. Nothing was shared or changed.")
            }
            guard Date() < deadline else { throw BridgeFailure("The synthetic value check exceeded its time limit.") }
            rows.append("Synthetic AXValue read locally: \(text.utf8.count) UTF-8 bytes; \(text.utf16.count) UTF-16 units.")
            for identifier in headerFields.keys.sorted() {
                guard let field = headerFields[identifier] else { continue }
                rows += syntheticHeaderMetadata(field,identifier:identifier,deadline:deadline)
            }
            rows.append("Parameterized readers: " + parameterNames.sorted().joined(separator:", "))
            if parameterNames.contains("AXTextMarkerRangeForUIElement"), parameterNames.contains("AXLengthForTextMarkerRange"), parameterNames.contains("AXStringForTextMarkerRange") {
                var markerRange:CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(body,"AXTextMarkerRangeForUIElement" as CFString,body,&markerRange) == .success,
                      let markerRange else { throw BridgeFailure("Mail did not return the synthetic body's text-marker range.") }
                var rawLength:CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(body,"AXLengthForTextMarkerRange" as CFString,markerRange,&rawLength) == .success,
                      let length = rawLength as? NSNumber, length.doubleValue.isFinite,
                      length.doubleValue.rounded(.towardZero) == length.doubleValue,
                      length.doubleValue >= 0, length.doubleValue <= 65_536 else {
                    throw BridgeFailure("Mail did not return a bounded synthetic text-marker length.")
                }
                var markerText:CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(body,"AXStringForTextMarkerRange" as CFString,markerRange,&markerText) == .success,
                      let markerText = markerText as? String, markerText.utf16.count == length.intValue else {
                    throw BridgeFailure("Mail did not return the complete synthetic text-marker range.")
                }
                rows.append("Synthetic text-marker read locally: \(markerText.utf8.count) UTF-8 bytes; \(markerText.utf16.count) UTF-16 units.")
            }
            guard Date() < deadline else { throw BridgeFailure("The synthetic reader check exceeded its time limit.") }
            return "Matched one synthetic reply window.\n" + rows.joined(separator:"\n") + "\nWhole-field development check; no pre-allocation size bound. Nothing was shared or changed."
        }
        if checkTextReading {
            guard let count = value(body,kAXNumberOfCharactersAttribute) as? NSNumber,
                  count.doubleValue.isFinite, count.doubleValue.rounded(.towardZero) == count.doubleValue,
                  count.doubleValue >= 0, count.doubleValue <= 65_536 else {
                throw BridgeFailure("Mail did not expose a supported bounded body length (up to 65,536 UTF-16 units). Nothing was shared or changed.")
            }
            var range = CFRange(location:0,length:count.intValue)
            guard let parameter = AXValueCreate(.cfRange,&range) else { throw BridgeFailure("Cannot prepare the bounded text range.") }
            var rawText:CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(body,kAXStringForRangeParameterizedAttribute as CFString,parameter,&rawText) == .success,
                  let text = rawText as? String, text.utf16.count == count.intValue else {
                throw BridgeFailure("Mail did not return the complete bounded text range. Nothing was shared or changed.")
            }
            guard text.utf8.count <= 131_072 else { throw BridgeFailure("The reply body exceeds this bounded local reading check.") }
            rows.append("Body text read locally: \(text.utf8.count) UTF-8 bytes; \(text.utf16.count) UTF-16 units.")
            // Header token metadata guides binding research; never print address values or body text.
            for (index,token) in recipientTokens.prefix(12).enumerated() {
                var rawNames:CFArray?
                if AXUIElementCopyAttributeNames(token,&rawNames) == .success, let names = rawNames as? [String] {
                    rows.append("Header token \(index + 1) attributes: " + names.sorted().joined(separator:", "))
                }
            }
            guard Date() < deadline else { throw BridgeFailure("The reading check exceeded its time limit. Nothing was shared or changed.") }
            return "Matched one Mail reply window.\n" + rows.joined(separator:"\n") + "\nReading check only. Nothing was shared or changed."
        }
        guard Date() < deadline else { throw BridgeFailure("The metadata check exceeded its time limit.") }
        return "Matched one Mail reply window.\n" + rows.joined(separator:"\n") + "\nChecked field metadata only."
    }

    private func value(_ element:AXUIElement,_ name:String) -> CFTypeRef? {
        _ = AXUIElementSetMessagingTimeout(element,0.25)
        var result:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&result) == .success else { return nil }
        return result
    }

    /// Metadata only, with no body text, filenames or attribute values in output.
    private func syntheticBodyStructure(_ body:AXUIElement,deadline:Date) throws -> String {
        var names:CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(body,&names) == .success,
              let names = names as? [String] else { throw BridgeFailure("Mail did not expose body reader metadata.") }
        var rows = ["Synthetic body parameter names: " + names.sorted().joined(separator:", ")]
        var queue:[(AXUIElement,Int)] = [(body,0)], visited = 0, roles:[String:Int] = [:]
        while !queue.isEmpty {
            guard visited < 256, Date() < deadline else { throw BridgeFailure("Synthetic body structure exceeded its limit.") }
            let (element,depth) = queue.removeFirst(); visited += 1
            guard let role = value(element,kAXRoleAttribute) as? String else { throw BridgeFailure("Incomplete body role metadata.") }
            roles[role,default:0] += 1
            var count = 0
            let status = AXUIElementGetAttributeValueCount(element,kAXChildrenAttribute as CFString,&count)
            if status == .attributeUnsupported || status == .noValue { continue }
            guard status == .success, count >= 0, count <= 256 - visited - queue.count,
                  depth < 12 || count == 0 else { throw BridgeFailure("Incomplete or oversized body tree.") }
            if count > 0 {
                var raw:CFArray?
                guard AXUIElementCopyAttributeValues(element,kAXChildrenAttribute as CFString,0,count,&raw) == .success,
                      let children = raw as? [AXUIElement], children.count == count else { throw BridgeFailure("Incomplete body children metadata.") }
                queue.append(contentsOf:children.map { ($0,depth+1) })
            }
        }
        rows.append("Synthetic body roles: " + roles.keys.sorted().map { "\($0)=\(roles[$0]!)" }.joined(separator:", "))
        guard names.contains("AXAttributedStringForTextMarkerRange") else { return rows.joined(separator:"\n") }
        var range:CFTypeRef?, lengthValue:CFTypeRef?, attributedValue:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(body,"AXTextMarkerRangeForUIElement" as CFString,body,&range) == .success, let range,
              AXUIElementCopyParameterizedAttributeValue(body,"AXLengthForTextMarkerRange" as CFString,range,&lengthValue) == .success,
              let length = lengthValue as? NSNumber, length.doubleValue.isFinite,
              length.doubleValue.rounded(.towardZero) == length.doubleValue, (0...65536).contains(length.doubleValue),
              AXUIElementCopyParameterizedAttributeValue(body,"AXAttributedStringForTextMarkerRange" as CFString,range,&attributedValue) == .success,
              let text = attributedValue as? NSAttributedString, text.length == length.intValue else {
            throw BridgeFailure("Mail did not return the complete bounded attributed body.")
        }
        var keys = Set<String>(), attachmentRuns = 0
        text.enumerateAttributes(in:NSRange(location:0,length:text.length)) { attrs,_,_ in
            keys.formUnion(attrs.keys.map(\.rawValue))
            if attrs.keys.contains(where:{ $0.rawValue.localizedCaseInsensitiveContains("attachment") }) { attachmentRuns += 1 }
        }
        rows.append("Attributed length: \(text.length); object replacement characters: \(text.string.unicodeScalars.filter { $0.value == 0xfffc }.count); attachment attribute runs: \(attachmentRuns)")
        rows.append("Attributed keys: " + keys.sorted().joined(separator:", "))
        guard Date() < deadline else { throw BridgeFailure("The synthetic structure check exceeded its time limit.") }
        return rows.joined(separator:"\n")
    }

    private func syntheticRecipientMenu(application:AXUIElement,field:AXUIElement,deadline:Date) async throws -> String {
        guard let fieldText = value(field,kAXValueAttribute) as? String, fieldText.utf16.count == 1 else {
            throw BridgeFailure("The synthetic menu check requires one recipient token.")
        }
        var range = CFRange(location:0,length:1)
        guard let parameter = AXValueCreate(.cfRange,&range) else { throw BridgeFailure("Cannot prepare the recipient range.") }
        var raw:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field,kAXAttributedStringForRangeParameterizedAttribute as CFString,parameter,&raw) == .success,
              let attributed = raw as? NSAttributedString, attributed.length == 1,
              let tokenValue = attributed.attribute(NSAttributedString.Key("AXAttachment"),at:0,effectiveRange:nil),
              CFGetTypeID(tokenValue as CFTypeRef) == AXUIElementGetTypeID() else {
            throw BridgeFailure("The synthetic recipient did not expose its token object.")
        }
        let token = tokenValue as! AXUIElement
        let roots = [token,field]
        guard associatedMenu(roots) == nil else { throw BridgeFailure("Dismiss the existing recipient menu before this check.") }
        if let children = value(application,kAXChildrenAttribute) as? [AXUIElement] {
            guard children.count <= 50 else { throw BridgeFailure("The Mail application tree exceeded the menu preflight limit.") }
            guard !children.contains(where:{ value($0,kAXRoleAttribute) as? String == kAXMenuRole }) else {
                throw BridgeFailure("Dismiss the existing Mail menu before this check.")
            }
        }
        var actions:CFArray?
        guard AXUIElementCopyActionNames(token,&actions) == .success,
              (actions as? [String])?.contains(kAXShowMenuAction) == true else {
            throw BridgeFailure("The recipient token does not expose the public Show Menu action.")
        }
        let status = AXUIElementPerformAction(token,kAXShowMenuAction as CFString)
        guard status == .success else {
            throw BridgeFailure("Mail did not open the synthetic address menu (\(status.rawValue)).")
        }
        var menu:AXUIElement?
        while menu == nil, Date() < deadline {
            menu = associatedMenu(roots)
            if menu == nil { try await Task.sleep(for:.milliseconds(30)) }
        }
        guard let menu else { throw BridgeFailure("Mail opened no accessible recipient-menu object within the limit. If a menu remains visible, dismiss it with Escape. No email field was changed.") }
        var canceled = false
        defer { if !canceled { _ = AXUIElementPerformAction(menu,kAXCancelAction as CFString) } }
        var count = 0
        guard AXUIElementGetAttributeValueCount(menu,kAXChildrenAttribute as CFString,&count) == .success, count <= 40 else {
            throw BridgeFailure("The synthetic address menu exceeded its metadata limit.")
        }
        var rawItems:CFArray?
        guard AXUIElementCopyAttributeValues(menu,kAXChildrenAttribute as CFString,0,count,&rawItems) == .success,
              let items = rawItems as? [AXUIElement], items.count == count else {
            throw BridgeFailure("Mail did not return the full synthetic menu metadata.")
        }
        var checked:[String] = []
        for item in items {
            guard Date() < deadline else { throw BridgeFailure("The recipient-menu check exceeded its time limit.") }
            let title = value(item,kAXTitleAttribute) as? String ?? ""
            let mark = value(item,kAXMenuItemMarkCharAttribute) as? String ?? ""
            if !mark.isEmpty { checked.append(title) }
        }
        guard checked == ["sender@example.invalid"] else { throw BridgeFailure("The named fixture's recipient differs from its expected synthetic address. No address values were returned.") }
        let cancelResult = AXUIElementPerformAction(menu,kAXCancelAction as CFString)
        guard cancelResult == .success else {
            throw BridgeFailure("The synthetic menu could not confirm dismissal (\(cancelResult.rawValue)); press Escape in Mail. No email field was changed.")
        }
        canceled = true
        return "Synthetic recipient menu matched its one expected checked address.\nMenu cancellation accepted. No email fields were changed."
    }

    private func associatedMenu(_ roots:[AXUIElement]) -> AXUIElement? {
        for root in roots {
            if let candidate = elementValue(root,kAXShownMenuUIElementAttribute), value(candidate,kAXRoleAttribute) as? String == kAXMenuRole { return candidate }
            var count = 0
            guard AXUIElementGetAttributeValueCount(root,kAXChildrenAttribute as CFString,&count) == .success, count <= 32 else { continue }
            if count == 0 { continue }
            var raw:CFArray?
            guard AXUIElementCopyAttributeValues(root,kAXChildrenAttribute as CFString,0,count,&raw) == .success,
                  let children = raw as? [AXUIElement] else { continue }
            if let menu = children.first(where:{ value($0,kAXRoleAttribute) as? String == kAXMenuRole }) { return menu }
        }
        return nil
    }

    private func elementValue(_ element:AXUIElement,_ name:String) -> AXUIElement? {
        guard let raw = value(element,name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Used only by the fixed synthetic-fixture development check. No setters or body reads.
    private func syntheticHeaderMetadata(_ element:AXUIElement,identifier:String,deadline:Date) -> [String] {
        var rows:[String] = []
        guard Date() < deadline else { return ["Header metadata deadline reached."] }
        let fieldText = value(element,kAXValueAttribute) as? String ?? ""
        guard fieldText.utf16.count <= 4096 else { return ["\(identifier): header exceeds diagnostic limit"] }
        rows.append("\(identifier) value length: \(fieldText.utf16.count) UTF-16 units")
        var range = CFRange(location:0,length:fieldText.utf16.count)
        guard let parameter = AXValueCreate(.cfRange,&range) else { return rows }
        var raw:CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element,kAXAttributedStringForRangeParameterizedAttribute as CFString,parameter,&raw)
        guard status == .success, let attributed = raw as? NSAttributedString, attributed.length == range.length else {
            rows.append("\(identifier): attributed range unavailable (\(status.rawValue))")
            return rows
        }
        var tokens = 0
        attributed.enumerateAttributes(in:NSRange(location:0,length:attributed.length)) { attributes,_,stop in
            guard Date() < deadline else { stop.pointee = true; return }
            rows.append("\(identifier) range attributes: " + attributes.keys.map(\.rawValue).sorted().joined(separator:", "))
            for name in ["AXAttachment","AXLink"] {
                guard let rawToken = attributes[NSAttributedString.Key(name)],
                      CFGetTypeID(rawToken as CFTypeRef) == AXUIElementGetTypeID() else { continue }
                tokens += 1
                if tokens > 32 || Date() >= deadline { stop.pointee = true; return }
                let token = rawToken as! AXUIElement
                var tokenNames:CFArray?, actionNames:CFArray?
                if AXUIElementCopyAttributeNames(token,&tokenNames) == .success, let names = tokenNames as? [String] {
                    rows.append("\(identifier) token attributes: " + names.sorted().joined(separator:", "))
                }
                if AXUIElementCopyActionNames(token,&actionNames) == .success, let names = actionNames as? [String] {
                    rows.append("\(identifier) token actions: " + names.sorted().joined(separator:", "))
                }
                for attribute in [kAXRoleAttribute,kAXValueAttribute,kAXDescriptionAttribute,kAXHelpAttribute,kAXURLAttribute] {
                    guard Date() < deadline else { stop.pointee = true; return }
                    let rawValue = value(token,attribute)
                    if let string = rawValue as? String {
                        rows.append("\(identifier) token \(attribute): String, \(string.utf16.count) UTF-16 units")
                    } else if rawValue is URL {
                        rows.append("\(identifier) token \(attribute): URL present")
                    }
                }
            }
        }
        rows.append("\(identifier): \(tokens) attributed token objects")
        return rows
    }
}
