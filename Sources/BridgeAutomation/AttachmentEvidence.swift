import Foundation
import BridgeCore

/// Fail closed on incomplete or inconsistent live attributed text. This does not
/// infer attachment absence from AX roles (Mail represents the test file as AXButton).
enum AttachmentEvidence {
    /// How many pictures, files and other objects the message's text holds, counted from complete and
    /// consistent live evidence (owner report, 13 November 2026: a reply whose quoted mail carried three photos and a
    /// signature logo could be neither inserted into, saved nor sent). The count is bound into the reviewed
    /// draft's fingerprint, so a send goes only with exactly the objects that were there at review.
    static func count(_ attributed:NSAttributedString?,length:Int,matching body:String) throws -> Int {
        guard let attributed, attributed.length == length else {
            throw BridgeFailure("Mail did not return complete attachment evidence. Sending is unavailable.")
        }
        try ReplyCapturePolicy.validateBody(attributed.string,length:length)
        guard Data(attributed.string.utf8) == Data(body.utf8) else {
            throw BridgeFailure("The message changed during attachment verification. Review it again.")
        }
        var runs=0
        attributed.enumerateAttributes(in:NSRange(location:0,length:length)) { attributes,_,_ in
            if attributes.keys.contains(where:{$0.rawValue.localizedCaseInsensitiveContains("attachment")}) { runs += 1 }
        }
        return max(runs,body.unicodeScalars.filter{$0.value == 0xfffc}.count)
    }
    static func requireAbsent(_ attributed:NSAttributedString?,length:Int,matching body:String) throws {
        guard let attributed, attributed.length == length else {
            throw BridgeFailure("Mail did not return complete attachment evidence. Sending is unavailable.")
        }
        try ReplyCapturePolicy.validateBody(attributed.string,length:length)
        guard Data(attributed.string.utf8) == Data(body.utf8) else {
            throw BridgeFailure("The message changed during attachment verification. Review it again.")
        }
        var attachmentAttribute=false
        attributed.enumerateAttributes(in:NSRange(location:0,length:length)) { attributes,_,stop in
            if attributes.keys.contains(where:{$0.rawValue.localizedCaseInsensitiveContains("attachment")}) {
                attachmentAttribute=true; stop.pointee=true
            }
        }
        guard !attachmentAttribute,!body.contains("\u{fffc}") else {
            throw BridgeFailure("Reviewed voice sending supports messages without attachments only.")
        }
    }
}
