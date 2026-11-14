import Foundation
import BridgeCore

enum ReplyCapturePolicy {
    static func reconcile(native:MailDraft,visible:MailDraft) throws -> MailDraft {
        let readOnly=try validate(visible,matching:native)
        guard native.id >= 0,Data(native.body.utf8) == Data(readOnly.body.utf8) else { return readOnly }
        return native
    }
    static func tokenCount(_ text:String) throws -> Int {
        let scalars = text.unicodeScalars
        guard scalars.allSatisfy({ $0.value == 0xfffc || CharacterSet.whitespaces.contains($0) }) else {
            throw BridgeFailure("Finish entering each recipient in Mail before sharing.")
        }
        let count = scalars.filter { $0.value == 0xfffc }.count
        guard count <= 12 else { throw BridgeFailure("This prototype supports up to 12 recipients per field.") }
        return count
    }
    static func checkedAddress(_ titles:[String]) throws -> String {
        guard titles.count == 1, let address = titles.first, address.utf8.count <= 320,
              address.split(separator:"@",omittingEmptySubsequences:false).count == 2,
              address.first != "@", address.last != "@",
              !address.unicodeScalars.contains(where:{ CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !address.contains("<"), !address.contains(">") else {
            throw BridgeFailure("Mail did not expose one unambiguous checked recipient address.")
        }
        return address
    }
    static func validateBody(_ text:String,length:Int) throws {
        guard (0...MailBodyLimits.characters).contains(length), text.utf8.count <= MailBodyLimits.utf8Bytes else {
            throw BridgeFailure("This message is too long for Mail Dot to read (\(length) characters; the limit is \(MailBodyLimits.characters)).")
        }
        // Mail counts an image or other object in the quoted mail as a character it does not return as text,
        // so the text can be shorter than the reported length; it is never longer. Seen 12 November 2026 on a
        // real reply that Mail Dot then refused as "too long".
        guard text.utf16.count <= length, length - text.utf16.count <= max(64, length / 20) else {
            throw BridgeFailure("Mail returned only part of this message's text (\(text.utf16.count) of \(length) characters), so Mail Dot did not read it. Try again; if it repeats, the message holds something Mail Dot cannot read.")
        }
    }
    static func validate(_ draft:MailDraft,matching expected:MailDraft) throws -> MailDraft {
        guard draft.hasSameEnvelope(as:expected) else {
            throw BridgeFailure("Mail's complete sender and recipient fields do not match this MailKit session. Nothing was shared.")
        }
        var result = draft
        // A read-only AX snapshot does not supply a Mail scripting identifier or
        // a verified attachment inventory. Never manufacture either capability.
        result.id = -1; result.attachmentCount = -1
        return result
    }
}
