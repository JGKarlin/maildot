import Foundation

/// A file Dot finished for a reply (a form with names updated, a document filled in as before), handed back
/// with attach_reply_file and attached to the message in Mail when the owner presses Insert or Save Draft.
/// The files live beside Mail Dot's shared state, one folder per reply, never inside the state itself.
public struct ReplyFile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var filename: String
    public var mediaType: String
    public var size: Int
    public var addedAt: Date
    public init(id: String = UUID().uuidString, filename: String, mediaType: String, size: Int, addedAt: Date = Date()) {
        self.id = id; self.filename = filename; self.mediaType = mediaType; self.size = size; self.addedAt = addedAt
    }
}

public enum ReplyFiles {
    public static let perReply = 5
    /// One file fits in one request to Mail Dot (512 KiB, base64 included).
    public static let maxBytes = 360_000
    /// Documents, spreadsheets, slides, PDFs, text and images: nothing that runs.
    public static let allowedExtensions: Set<String> = ["docx","doc","xlsx","xls","pptx","ppt","pdf","txt","csv","rtf","md","png","jpg","jpeg","odt","ods","pages","numbers","key"]

    /// A file name safe to keep and to show: no folders, no hidden or control characters, a known extension.
    public static func safeName(_ name: String) throws -> String {
        let base = (name as NSString).lastPathComponent.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let ext = (base as NSString).pathExtension.lowercased()
        guard !base.isEmpty, base.count <= 120, allowedExtensions.contains(ext) else {
            throw BridgeFailure("Attach a document, spreadsheet, PDF, text or image file with a plain name (\(allowedExtensions.sorted().joined(separator: ", "))).")
        }
        return base
    }
    public static func folder(_ bridgeDirectory: URL, owner: String) -> URL {
        bridgeDirectory.appendingPathComponent("ReplyFiles", isDirectory: true).appendingPathComponent(owner, isDirectory: true)
    }
    public static func url(_ bridgeDirectory: URL, owner: String, file: ReplyFile) -> URL {
        folder(bridgeDirectory, owner: owner).appendingPathComponent(file.id, isDirectory: true).appendingPathComponent(file.filename)
    }
    /// Writes a file Dot finished. `owner` is the reply's id, or "triage-<entry id>" for an automatic draft.
    public static func save(_ data: Data, filename: String, mediaType: String?, owner: String, bridgeDirectory: URL, existing: [ReplyFile]) throws -> ReplyFile {
        let name = try safeName(filename)
        guard !data.isEmpty, data.count <= maxBytes else { throw BridgeFailure("Each file must be between 1 byte and \(maxBytes / 1000) KB.") }
        guard existing.count < perReply else { throw BridgeFailure("A reply can carry at most \(perReply) files from Dot.") }
        let file = ReplyFile(filename: name, mediaType: (mediaType?.isEmpty == false ? mediaType! : "application/octet-stream"), size: data.count)
        let destination = url(bridgeDirectory, owner: owner, file: file)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: [.atomic])
        return file
    }
    /// Moves an automatic draft's files to the reply that now shows it.
    public static func move(_ files: [ReplyFile], from: String, to: String, bridgeDirectory: URL) {
        for file in files {
            let source = url(bridgeDirectory, owner: from, file: file), target = url(bridgeDirectory, owner: to, file: file)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.moveItem(at: source, to: target)
        }
    }
    /// What Dot is told about finishing tasks the message asks for (owner request, 13 November 2026).
    public static let instruction = "Tasks in the message: do, without asking, any routine task the message asks of the owner that you can finish with your own connectors, especially one the owner has done before in the same way: edit or fill in a document (for example update names or dates in an attached form as asked, or fill it in as last time) and hand back each finished file with attach_reply_file before you give the reply; add or change events in the owner's own calendar for dates and meetings the message sets; look up the facts or past figures it asks for; prepare files in the owner's Drive. Then mention in the reply what is attached or done, and list each thing you did as one short line in tasks_done (in the language of the owner's Mac). Anything that faces other people waits for the owner: never send, submit, sign, accept or decline an invitation, or notify anyone on the owner's behalf; leave such steps, and anything needing the owner's own judgment, to them and say so in status."
}
