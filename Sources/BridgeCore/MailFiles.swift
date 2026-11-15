import Foundation

/// Reading Mail's own files (owner's decision, 15 November 2026: with search by meaning on, Mail Dot may ask for
/// Full Disk Access so that past mail can be read without Mail being open). macOS grants that access for the whole
/// disk; Mail Dot uses it for one place only. Every path this code opens lies inside the user's Mail folder,
/// ~/Library/Mail, and `inside` is checked before each one. Nothing is written there.
///
/// Mail keeps each message as a file named by the message's number in Mail, ending in .emlx: a line giving the
/// message's length, the message as it came, and a small property list with Mail's own notes on it (when it was
/// received, whether it is deleted or junk). Folders are directories ending in .mbox, inside a directory named by
/// the account's identifier, inside a directory named V and a number.
public enum MailFiles {
    public enum Access: Equatable, Sendable { case granted, denied, absent }
    public static func root(home: URL) -> URL { home.appendingPathComponent("Library/Mail", isDirectory: true) }
    /// Whether a path lies inside the Mail folder. Symbolic links are resolved first, so a link out of it does not pass.
    static func inside(_ url: URL, root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path, base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }
    /// Whether Mail Dot may read the Mail folder now. macOS answers a listing with "not permitted" until the user
    /// gives Full Disk Access.
    public static func access(home: URL, fileManager: FileManager = .default) -> Access {
        let root = root(home: home)
        do { _ = try fileManager.contentsOfDirectory(atPath: root.path); return .granted }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return .absent }
            return .denied
        }
    }
    /// The newest of Mail's storage directories (V10, V11 and so on).
    static func storage(home: URL, fileManager: FileManager = .default) -> URL? {
        let root = root(home: home)
        let versions = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).compactMap { name -> (Int, String)? in
            guard name.hasPrefix("V"), let number = Int(name.dropFirst()) else { return nil }
            return (number, name)
        }
        return versions.max { $0.0 < $1.0 }.map { root.appendingPathComponent($0.1, isDirectory: true) }
    }
    /// The directory of one folder of one account, or nil when Mail keeps none by that name on this Mac.
    public static func folder(home: URL, accountID: String, path: [String], fileManager: FileManager = .default) -> URL? {
        guard let storage = storage(home: home, fileManager: fileManager), !path.isEmpty,
              !accountID.contains("/"), !accountID.hasPrefix("."), path.allSatisfy({ !$0.contains("/") && !$0.hasPrefix(".") }) else { return nil }
        var folder = storage.appendingPathComponent(accountID, isDirectory: true)
        for component in path { folder = folder.appendingPathComponent(component + ".mbox", isDirectory: true) }
        var isDirectory: ObjCBool = false
        guard inside(folder, root: root(home: home)), fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return folder
    }
    /// The message files of one folder, by the message's number in Mail. Folders inside the folder are folders of
    /// their own and are not entered.
    public static func messageFiles(in folder: URL, home: URL, fileManager: FileManager = .default) -> [Int: URL] {
        let root = root(home: home)
        guard inside(folder, root: root) else { return [:] }
        var found: [Int: URL] = [:], waiting = [folder], visited = 0
        while let directory = waiting.popLast(), visited < 20_000 {
            visited += 1
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let item = directory.appendingPathComponent(name)
                if name.hasSuffix(".emlx") {
                    // 123.emlx, or 123.partial.emlx for a message whose attachments Mail has not fetched.
                    if let number = Int(name.prefix { $0.isNumber }), number > 0, found[number] == nil || !name.contains(".partial.") { found[number] = item }
                } else if !name.hasSuffix(".mbox"), !name.contains(".") || name.count == 36 {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue, inside(item, root: root) { waiting.append(item) }
                }
            }
        }
        return found
    }

    public struct Message: Sendable, Equatable {
        /// Nil for a message that came without a Message-ID.
        public var messageID: String?
        public var sender: String
        public var recipients: [String]
        public var subject: String
        public var date: Date
        public var attachments: Int
        public var deleted: Bool
        public var junk: Bool
        public var text: String
    }
    /// The most of one message file that is read: the text of a message comes before its attachments.
    static let readLimit = 1_048_576
    /// Reads one message file. Nil when the file is not a message Mail Dot can make sense of.
    public static func read(_ file: URL, home: URL) -> Message? {
        guard inside(file, root: root(home: home)), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: readLimit + 32), let newline = head.firstIndex(of: 0x0A),
              let length = Int(String(decoding: head[head.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)), length > 0 else { return nil }
        let start = head.index(after: newline)
        let raw = Data(head[start..<min(head.endIndex, start + length)])
        // Mail's own notes follow the message.
        var notes: [String: Any] = [:]
        let offset = UInt64(head.distance(from: head.startIndex, to: start) + length)
        if (try? handle.seek(toOffset: offset)) != nil, let tail = try? handle.read(upToCount: 65_536), !tail.isEmpty {
            notes = (try? PropertyListSerialization.propertyList(from: tail, format: nil) as? [String: Any]) ?? [:]
        }
        let headers = MailMessageHeaders(rawMessage: raw)
        // A file that holds no headers at all is not a message; one that only lacks a Message-ID is.
        guard headers.messageID != nil || headers.senderAddress != nil || headers.subject != nil else { return nil }
        let messageID = headers.messageID
        let flags = (notes["flags"] as? NSNumber)?.int64Value ?? 0
        let received = (notes["date-received"] as? NSNumber)?.doubleValue
        let address = headers.senderAddress ?? ""
        let sender = headers.senderName.map { "\($0) <\(address)>" } ?? address
        return Message(messageID: messageID, sender: sender, recipients: addresses(in: raw, headers: ["to", "cc"]), subject: headers.subject ?? "",
                       date: received.map { Date(timeIntervalSince1970: $0) } ?? headers.date ?? Date(timeIntervalSince1970: 0),
                       attachments: Int((flags >> 10) & 0x3F), deleted: flags & (1 << 1) != 0, junk: flags & (1 << 24) != 0, text: MailBodyText.text(rawMessage: raw))
    }
    /// The addresses in the named headers of a message.
    static func addresses(in raw: Data, headers wanted: [String]) -> [String] {
        let head = raw.prefix(65_536)
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return [] }
        var collected = "", taking = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" { if taking { collected += line }; continue }
            taking = false
            guard let colon = line.firstIndex(of: ":") else { continue }
            if wanted.contains(line[..<colon].lowercased()) { taking = true; collected += " " + line[line.index(after: colon)...] }
        }
        guard let pattern = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}") else { return [] }
        var seen = Set<String>(), found: [String] = []
        for match in pattern.matches(in: collected, range: NSRange(collected.startIndex..., in: collected)).prefix(100) {
            let address = (collected as NSString).substring(with: match.range).lowercased()
            if seen.insert(address).inserted { found.append(address) }
        }
        return found
    }
    /// Whether a folder is an account's junk or trash, by the names mail services give those folders. Mail Dot
    /// leaves such folders out of its index even where the owner allowed them (owner's requirement, 15 November
    /// 2026: junk and deleted mail is not embedded).
    public static func isJunkOrTrash(path: [String]) -> Bool {
        // Every part of the path counts: a folder inside Trash is trash. Names that an ordinary folder might bear
        // ("Bin", "Bulk", "Deleted") are not in the list, so no folder of the owner's is left out by surprise.
        let names: Set<String> = ["junk", "junk e-mail", "junk email", "junk mail", "spam", "bulk mail", "trash", "deleted messages", "deleted items",
                                  "papierkorb", "gelöschte elemente", "corbeille", "éléments supprimés", "courrier indésirable", "indésirables", "papelera", "elementos eliminados",
                                  "correo no deseado", "cestino", "posta indesiderata", "posta eliminata", "lixo", "lixeira", "itens excluídos", "prullenmand", "ongewenste e-mail",
                                  "ゴミ箱", "ごみ箱", "迷惑メール", "削除済み", "削除済みアイテム", "垃圾邮件", "已删除邮件", "废纸篓", "垃圾郵件", "刪除的郵件", "휴지통", "스팸", "정크"]
        return path.contains { names.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }
    }
}
