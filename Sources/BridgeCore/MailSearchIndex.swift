import Foundation
internal import SQLCipher

/// One message as Mail Dot's search index holds it: who, when, the subject, and its own text without the history
/// quoted beneath it.
public struct IndexedMessage: Sendable, Equatable {
    public var account: String
    public var mailbox: String
    /// The RFC 822 Message-ID, without angle brackets, as Mail Dot compares them.
    public var messageID: String
    public var date: Date
    public var sender: String
    public var recipients: [String]
    public var subject: String
    /// The owner sent it.
    public var sent: Bool
    public var attachments: Int
    public var text: String
    public init(account: String, mailbox: String, messageID: String, date: Date, sender: String, recipients: [String], subject: String, sent: Bool, attachments: Int, text: String) {
        self.account = account; self.mailbox = mailbox; self.messageID = messageID; self.date = date; self.sender = sender
        self.recipients = recipients; self.subject = subject; self.sent = sent; self.attachments = attachments; self.text = text
    }
}

public struct MailSearchQuery: Sendable {
    public enum Direction: String, Sendable { case both, received, sent }
    public var account: String
    /// The folders the owner allows now; nothing outside them is returned, whatever the index still holds.
    public var mailboxes: [String]
    public var words: [String] = []
    public var person: String?
    public var direction = Direction.both
    public var since: Date?
    public var until: Date?
    public var hasAttachments = false
    public var limit = 25
    public init(account: String, mailboxes: [String]) { self.account = account; self.mailboxes = mailboxes }
}

/// Where the background pass stands in one folder. New mail is listed from `newest` on; older mail is walked
/// downward through each stretch of time not yet listed, newest stretch first. Messages listed and not yet read
/// wait in `pending` under Mail's own ids.
public struct MailIndexProgress: Codable, Sendable, Equatable {
    public struct Gap: Codable, Sendable, Equatable {
        public var low: Date
        public var high: Date
        /// How much time the next listing covers; it shrinks where mail is dense and grows where it is sparse.
        public var span: TimeInterval
        public init(low: Date, high: Date, span: TimeInterval = 7 * 86_400) { self.low = low; self.high = high; self.span = span }
    }
    public var newest: Date
    public var gaps: [Gap]
    public var pending: [Int] = []
    public var listedAt: Date?
    /// After Mail refused a listing or a read in this folder, the pass leaves it alone until then.
    public var restUntil: Date?
    /// Where the standing check of mail already read has come to, when it last listed, and how long it rests after a round.
    public var check: Gap?
    public var checkedAt: Date?
    public var checkRestsUntil: Date?
    public var complete: Bool { gaps.isEmpty && pending.isEmpty }
    public init(newest: Date, gaps: [Gap]) { self.newest = newest; self.gaps = gaps }
}

public struct MailSearchHit: Sendable, Equatable {
    public let messageID: String
    public let mailbox: String
    public let date: Date
    public let sender: String
    public let subject: String
    public let sent: Bool
    public let attachments: Int
    /// About 300 characters of the message around the first word found.
    public let passage: String
}

/// Mail Dot's own search index (Ask Dot review, 15 November 2026). Mail's full-text index is closed to other
/// software and its header database needs Full Disk Access, so Mail Dot keeps a small one itself: a SQLite database
/// in its private container, with the full-text engine built into macOS, holding the mail of the folders the owner
/// allowed and nothing else. The trigram tokenizer matches Japanese, which a word tokenizer does not. Each call
/// opens the database, does its work and closes it, so the extension, the background app and the helper can all
/// use it.
public struct MailSearchIndex: Sendable {
    public static let limit = 25
    /// The most text kept for one message, in characters. The index for a year of mail is several times the size
    /// of its text, and what a long message says beyond this is read from Mail itself.
    public static let textLimit = 32_000
    public let file: URL
    public init(bridgeDirectory: URL) { file = bridgeDirectory.appendingPathComponent("Search", isDirectory: true).appendingPathComponent("index.sqlite") }

    // MARK: Writing

    /// Adds messages, or replaces those already held under the same account and Message-ID.
    public func add(_ messages: [IndexedMessage]) throws {
        guard !messages.isEmpty else { return }
        try open { database in
            try database.run("BEGIN IMMEDIATE")
            do {
                for message in messages {
                    guard let id = Self.key(message.messageID) else { continue }
                    if let held = try database.rows("SELECT id,sender FROM messages WHERE account=? AND message_id=?", [.text(message.account), .text(id)]).first, let old = held[0].integer {
                        // A Message-ID is known to everyone in a thread. A later message that bears an earlier one's
                        // identifier but comes from someone else does not take its place: the earlier one stands.
                        let before = MailMessageIdentity.address(in: held[1].text ?? ""), now = MailMessageIdentity.address(in: message.sender)
                        if let before, let now, before != now { continue }
                        try Self.remove([old], from: database)
                    }
                    try database.run("DELETE FROM excluded WHERE account=? AND message_id=?", [.text(message.account), .text(id)])
                    let people = ([message.sender] + message.recipients).joined(separator: " ")
                    try database.run("INSERT INTO messages(account,mailbox,message_id,date,sender,recipients,subject,sent,attachments) VALUES(?,?,?,?,?,?,?,?,?)",
                                     [.text(message.account), .text(message.mailbox), .text(id), .real(message.date.timeIntervalSince1970), .text(message.sender),
                                      .text(message.recipients.joined(separator: ", ")), .text(message.subject), .integer(message.sent ? 1 : 0), .integer(Int64(message.attachments))])
                    try database.run("INSERT INTO texts(rowid,subject,people,body) VALUES(last_insert_rowid(),?,?,?)",
                                     [.text(message.subject), .text(people), .text(String(Self.withoutQuotedHistory(message.text).prefix(Self.textLimit)))])
                }
                try database.run("COMMIT")
            } catch { try? database.run("ROLLBACK"); throw error }
        }
    }

    /// Takes messages out of the index with everything derived from them: their text and their embeddings.
    static func remove(_ rows: [Int64], from database: SQLiteDatabase) throws {
        for row in rows {
            try database.run("DELETE FROM files WHERE message=?", [.integer(row)])
            try MailSearchIndex.forgetEmbedding(of: row, in: database)
            try database.run("DELETE FROM texts WHERE rowid=?", [.integer(row)])
            try database.run("DELETE FROM messages WHERE id=?", [.integer(row)])
        }
    }

    /// Brings one folder's part of the index into line with what Mail lists there for a stretch of time (owner's
    /// requirement, 15 November 2026: deleted mail leaves the index and its embeddings go with it). A message the
    /// index holds for this folder and stretch that Mail no longer lists has been deleted or moved away, and is
    /// removed; if it was moved to another allowed folder, it is found missing there and read again.
    /// Returns how many were removed.
    @discardableResult public func reconcile(account: String, mailbox: String, since: Date, until: Date, listed messageIDs: [String]) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        let present = Set(messageIDs.compactMap(Self.key))
        return try open { database in
            try database.run("BEGIN IMMEDIATE")
            do {
                let held = try database.rows("SELECT id,message_id FROM messages WHERE account=? AND mailbox=? AND date>=? AND date<?",
                                             [.text(account), .text(mailbox), .real(since.timeIntervalSince1970), .real(until.timeIntervalSince1970)])
                let gone = held.filter { !present.contains($0[1].text ?? "") }.compactMap { $0[0].integer }
                try Self.remove(gone, from: database)
                try database.run("COMMIT")
                return gone.count
            } catch { try? database.run("ROLLBACK"); throw error }
        }
    }

    /// After mail has been taken out in bulk: the file is rewritten without the space it held, and an index left
    /// empty is removed from the disk altogether.
    public func compact() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let empty: Bool = try open { database in
            let messages = try database.rows("SELECT count(*) FROM messages").first?[0].integer ?? 0
            let folders = try database.rows("SELECT count(*) FROM pass").first?[0].integer ?? 0
            let none = messages == 0 && folders == 0
            if !none { try database.run("VACUUM") }
            try database.run("PRAGMA wal_checkpoint(TRUNCATE)")
            return none
        }
        if empty { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
    }

    // MARK: Kept in step with Mail's own files

    /// The message files of a folder the index has already taken in, by their numbers in Mail.
    public func knownFiles(account: String, mailbox: String) throws -> Set<Int> {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try open { Set(try $0.rows("SELECT local FROM files WHERE account=? AND mailbox=?", [.text(account), .text(mailbox)]).compactMap { $0[0].integer.map(Int.init) }) }
    }
    /// Takes in message files read from a folder. A message the index already holds (the same message filed in
    /// another folder, or read earlier through Mail) is only noted as being in this file; nothing of it is read or
    /// embedded twice. A nil message is a file left out, as junk or deleted mail is. Returns how many were new.
    @discardableResult public func take(account: String, mailbox: String, files: [(local: Int, message: IndexedMessage?)], now: Date = .now) throws -> Int {
        guard !files.isEmpty else { return 0 }
        var added = 0
        for entry in files {
            var row: Int64?
            if let message = entry.message, let id = Self.key(message.messageID) {
                row = try open { try $0.rows("SELECT id FROM messages WHERE account=? AND message_id=?", [.text(account), .text(id)]).first?[0].integer }
                if row == nil {
                    try add([message]); added += 1
                    row = try open { try $0.rows("SELECT id FROM messages WHERE account=? AND message_id=?", [.text(account), .text(id)]).first?[0].integer }
                }
            }
            try open { database in
                try database.run("INSERT INTO files(account,mailbox,local,message,at) VALUES(?,?,?,?,?) ON CONFLICT(account,mailbox,local) DO UPDATE SET message=excluded.message,at=excluded.at",
                                 [.text(account), .text(mailbox), .integer(Int64(entry.local)), row.map { .integer($0) } ?? .null, .real(now.timeIntervalSince1970)])
            }
        }
        return added
    }
    /// Message files that are gone from a folder: a message with no file left in any allowed folder has been
    /// deleted or moved away, and leaves the index with its embeddings. Returns how many messages left.
    @discardableResult public func drop(account: String, mailbox: String, files locals: [Int]) throws -> Int {
        guard !locals.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try open { database in
            try database.run("BEGIN IMMEDIATE")
            do {
                var orphans: [Int64] = []
                for local in locals {
                    let message = try database.rows("SELECT message FROM files WHERE account=? AND mailbox=? AND local=?", [.text(account), .text(mailbox), .integer(Int64(local))]).first?[0].integer
                    try database.run("DELETE FROM files WHERE account=? AND mailbox=? AND local=?", [.text(account), .text(mailbox), .integer(Int64(local))])
                    if let message, (try database.rows("SELECT count(*) FROM files WHERE message=?", [.integer(message)]).first?[0].integer ?? 0) == 0 { orphans.append(message) }
                }
                try Self.remove(orphans, from: database)
                try database.run("COMMIT")
                return orphans.count
            } catch { try? database.run("ROLLBACK"); throw error }
        }
    }
    /// After a folder's files have all been taken in: what the index still holds for the folder without a file
    /// (mail read earlier through Mail and since deleted or moved) leaves. Files left out as junk or deleted are
    /// looked at again after a week, in case Mail has changed its mind about them.
    @discardableResult public func settle(account: String, mailbox: String, now: Date = .now) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try open { database in
            let rows = try database.rows("SELECT m.id FROM messages m WHERE m.account=? AND m.mailbox=? AND NOT EXISTS(SELECT 1 FROM files f WHERE f.message=m.id)", [.text(account), .text(mailbox)]).compactMap { $0[0].integer }
            try database.run("BEGIN IMMEDIATE")
            do {
                try Self.remove(rows, from: database)
                try database.run("DELETE FROM files WHERE account=? AND mailbox=? AND message IS NULL AND at<?", [.text(account), .text(mailbox), .real(now.timeIntervalSince1970 - 7 * 86_400)])
                try database.run("COMMIT")
            } catch { try? database.run("ROLLBACK"); throw error }
            return rows.count
        }
    }

    /// Notes messages Mail reported as junk or deleted, so they are not read again for a week.
    public func exclude(account: String, messageIDs: [String], now: Date = .now) throws {
        let ids = messageIDs.compactMap(Self.key)
        guard !ids.isEmpty else { return }
        try open { database in
            for id in ids {
                try database.run("INSERT INTO excluded(account,message_id,at) VALUES(?,?,?) ON CONFLICT(account,message_id) DO UPDATE SET at=excluded.at", [.text(account), .text(id), .real(now.timeIntervalSince1970)])
                if let held = try database.rows("SELECT id FROM messages WHERE account=? AND message_id=?", [.text(account), .text(id)]).first?[0].integer { try Self.remove([held], from: database) }
            }
            try database.run("DELETE FROM excluded WHERE at<?", [.real(now.timeIntervalSince1970 - 7 * 86_400)])
        }
    }

    /// Forgets everything outside the folders given, per account: an account the owner withdrew, or a folder
    /// they no longer allow, leaves nothing behind. Returns how many messages were forgotten.
    /// At most `limit` messages go in one call, so that forgetting a large account is done in short pieces; the
    /// caller calls again while the answer is not zero.
    @discardableResult public func keep(only allowed: [String: [String]], limit: Int = .max) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try open { database in
            let held = try database.rows("SELECT DISTINCT account,mailbox FROM messages")
            var removed = 0
            for row in held {
                guard removed < limit, let account = row[0].text, let mailbox = row[1].text, allowed[account]?.contains(mailbox) != true else { continue }
                let rows = try database.rows("SELECT id FROM messages WHERE account=? AND mailbox=? LIMIT ?", [.text(account), .text(mailbox), .integer(Int64(min(limit - removed, 1_000_000)))]).compactMap { $0[0].integer }
                removed += rows.count
                try database.run("BEGIN IMMEDIATE")
                do { try Self.remove(rows, from: database); try database.run("COMMIT") } catch { try? database.run("ROLLBACK"); throw error }
            }
            // The bookkeeping goes once the folder's messages are all gone.
            guard removed < limit else { return removed }
            for row in try database.rows("SELECT DISTINCT account,mailbox FROM files") {
                guard let account = row[0].text, let mailbox = row[1].text, allowed[account]?.contains(mailbox) != true else { continue }
                try database.run("DELETE FROM files WHERE account=? AND mailbox=?", [.text(account), .text(mailbox)])
            }
            for row in try database.rows("SELECT account,mailbox FROM pass") {
                guard let account = row[0].text, let mailbox = row[1].text, allowed[account]?.contains(mailbox) != true else { continue }
                try database.run("DELETE FROM pass WHERE account=? AND mailbox=?", [.text(account), .text(mailbox)])
            }
            return removed
        }
    }

    // MARK: The background pass that fills the index

    /// Where the background pass stands in a folder, or nil before it has begun there.
    public func progress(account: String, mailbox: String) throws -> MailIndexProgress? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try open { database in
            guard let text = try database.rows("SELECT state FROM pass WHERE account=? AND mailbox=?", [.text(account), .text(mailbox)]).first?[0].text else { return nil }
            return try? JSONDecoder().decode(MailIndexProgress.self, from: Data(text.utf8))
        }
    }
    public func setProgress(_ progress: MailIndexProgress, account: String, mailbox: String) throws {
        let text = String(decoding: try JSONEncoder().encode(progress), as: UTF8.self)
        try open { database in
            try database.run("INSERT INTO pass(account,mailbox,state) VALUES(?,?,?) ON CONFLICT(account,mailbox) DO UPDATE SET state=excluded.state", [.text(account), .text(mailbox), .text(text)])
        }
    }
    /// A Message-ID as the index keys it, or nil when the message has none.
    public static func key(_ messageID: String) -> String? {
        MailMessageIdentity.normalized(messageID) ?? (messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : messageID)
    }
    /// Which of these Message-IDs the index does not hold yet for the account.
    public func missing(account: String, messageIDs: [String]) throws -> Set<String> {
        let wanted = Set(messageIDs.compactMap(Self.key))
        guard !wanted.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return wanted }
        return try open { database in
            var absent = wanted
            for part in stride(from: 0, to: wanted.count, by: 400).map({ Array(Array(wanted)[$0..<min($0 + 400, wanted.count)]) }) {
                let rows = try database.rows("SELECT message_id FROM messages WHERE account=? AND message_id IN (\(part.map { _ in "?" }.joined(separator: ",")))", [.text(account)] + part.map { .text($0) })
                for row in rows { if let id = row[0].text { absent.remove(id) } }
                // Junk and deleted mail is left out, not waited for.
                let left = try database.rows("SELECT message_id FROM excluded WHERE account=? AND message_id IN (\(part.map { _ in "?" }.joined(separator: ",")))", [.text(account)] + part.map { .text($0) })
                for row in left { if let id = row[0].text { absent.remove(id) } }
            }
            return absent
        }
    }
    public func count(account: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try open { Int(try $0.rows("SELECT count(*) FROM messages WHERE account=?", [.text(account)]).first?[0].integer ?? 0) }
    }

    // MARK: Searching

    /// Up to 25 messages, best match first. Words of three characters or more are found through the full-text
    /// index and ranked by it; shorter ones (a two-character Japanese word, for instance) are found by reading,
    /// newest first. With no words, the filters alone choose, newest first.
    public func search(_ query: MailSearchQuery) throws -> [MailSearchHit] {
        guard !query.mailboxes.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return [] }
        let limit = min(max(query.limit, 1), Self.limit)
        let words = query.words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(12)
        let long = words.filter { $0.count >= 3 }, short = words.filter { $0.count < 3 }
        var filters = "m.account=? AND m.mailbox IN (\(query.mailboxes.map { _ in "?" }.joined(separator: ",")))"
        var values: [SQLiteValue] = [.text(query.account)] + query.mailboxes.map { .text($0) }
        if let person = query.person?.trimmingCharacters(in: .whitespaces), !person.isEmpty {
            filters += " AND (m.sender LIKE ? ESCAPE '\\' OR m.recipients LIKE ? ESCAPE '\\')"
            values += [.text(Self.pattern(person)), .text(Self.pattern(person))]
        }
        switch query.direction { case .received: filters += " AND m.sent=0"; case .sent: filters += " AND m.sent=1"; case .both: break }
        if let since = query.since { filters += " AND m.date>=?"; values.append(.real(since.timeIntervalSince1970)) }
        if let until = query.until { filters += " AND m.date<=?"; values.append(.real(until.timeIntervalSince1970)) }
        if query.hasAttachments { filters += " AND m.attachments>0" }
        let columns = "m.id,m.mailbox,m.message_id,m.date,m.sender,m.subject,m.sent,m.attachments,texts.body"
        return try open { database in
            var found: [[SQLiteValue]] = []
            if !long.isEmpty {
                let match = long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
                found += try database.rows("SELECT \(columns) FROM texts JOIN messages m ON m.id=texts.rowid WHERE texts MATCH ? AND \(filters) ORDER BY bm25(texts,4.0,2.0,1.0) LIMIT ?",
                                           [.text(match)] + values + [.integer(Int64(limit))])
            }
            if !short.isEmpty, found.count < limit {
                let like = short.map { _ in "(texts.body LIKE ? ESCAPE '\\' OR texts.subject LIKE ? ESCAPE '\\')" }.joined(separator: " OR ")
                found += try database.rows("SELECT \(columns) FROM texts JOIN messages m ON m.id=texts.rowid WHERE (\(like)) AND \(filters) ORDER BY m.date DESC LIMIT ?",
                                           short.flatMap { [SQLiteValue.text(Self.pattern($0)), .text(Self.pattern($0))] } + values + [.integer(Int64(limit))])
            }
            if words.isEmpty {
                found = try database.rows("SELECT \(columns) FROM texts JOIN messages m ON m.id=texts.rowid WHERE \(filters) ORDER BY m.date DESC LIMIT ?", values + [.integer(Int64(limit))])
            }
            var seen = Set<Int64>(), hits: [MailSearchHit] = []
            for row in found {
                guard let id = row[0].integer, seen.insert(id).inserted, hits.count < limit else { continue }
                hits.append(MailSearchHit(messageID: row[2].text ?? "", mailbox: row[1].text ?? "", date: Date(timeIntervalSince1970: row[3].real ?? 0), sender: row[4].text ?? "",
                                          subject: row[5].text ?? "", sent: row[6].integer == 1, attachments: Int(row[7].integer ?? 0),
                                          passage: Self.passage(row[8].text ?? "", around: Array(words))))
            }
            return hits
        }
    }

    /// The indexed text of messages by Message-ID, within the folders allowed now.
    public func texts(account: String, mailboxes: [String], messageIDs: [String]) throws -> [IndexedMessage] {
        guard !mailboxes.isEmpty, !messageIDs.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return [] }
        let ids = messageIDs.map { MailMessageIdentity.normalized($0) ?? $0 }
        return try open { database in
            let rows = try database.rows("SELECT m.mailbox,m.message_id,m.date,m.sender,m.recipients,m.subject,m.sent,m.attachments,texts.body FROM texts JOIN messages m ON m.id=texts.rowid WHERE m.account=? AND m.mailbox IN (\(mailboxes.map { _ in "?" }.joined(separator: ","))) AND m.message_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                                         [.text(account)] + mailboxes.map { .text($0) } + ids.map { .text($0) })
            let found = rows.map { row in
                IndexedMessage(account: account, mailbox: row[0].text ?? "", messageID: row[1].text ?? "", date: Date(timeIntervalSince1970: row[2].real ?? 0), sender: row[3].text ?? "",
                               recipients: (row[4].text ?? "").components(separatedBy: ", ").filter { !$0.isEmpty }, subject: row[5].text ?? "", sent: row[6].integer == 1,
                               attachments: Int(row[7].integer ?? 0), text: row[8].text ?? "")
            }
            // In the order asked for.
            return ids.compactMap { id in found.first { $0.messageID == id } }
        }
    }

    // MARK: Text

    /// A message's own words: quoted lines and the history under a reply header are left out, since each earlier
    /// message is in the index in its own right.
    public static func withoutQuotedHistory(_ text: String) -> String {
        var kept: [Substring] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            if trimmed.hasPrefix("-----Original Message-----") || trimmed.hasPrefix("-----元のメッセージ-----") { break }
            if trimmed.hasSuffix(":") || trimmed.hasSuffix("："), trimmed.count < 200,
               trimmed.range(of: #"^(On .+ wrote|Le .+ a écrit|Am .+ schrieb .+|El .+ escribió|\d{4}[年/].+)\s*[:：]$"#, options: .regularExpression) != nil { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// About 300 characters around the first of the words found in the text, or its beginning when none is.
    public static func passage(_ text: String, around words: [String], length: Int = 300) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard flat.count > length else { return flat }
        let first = words.compactMap { flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound }.min()
        guard let first else { return String(flat.prefix(length)) + "…" }
        let start = flat.index(first, offsetBy: -min(length / 3, flat.distance(from: flat.startIndex, to: first)))
        let end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
    static func pattern(_ word: String) -> String {
        "%" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    // MARK: The database

    /// The database opened with its key (owner's decision, 15 November 2026: the index is encrypted). A file the key
    /// does not open is an index from before encryption, or one whose key is gone: it holds only what can be read
    /// again from Mail, so it is deleted and the index begins anew.
    static func encrypted(_ file: URL) throws -> SQLiteDatabase {
        let key = try MailIndexKey.current()
        var database = try SQLiteDatabase(file)
        try database.run(MailIndexKey.pragma(key))
        if database.unreadable() {
            database.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
            database = try SQLiteDatabase(file)
            try database.run(MailIndexKey.pragma(key))
            guard !database.unreadable() else { database.close(); throw BridgeFailure("Mail Dot could not open its search index with its key.") }
        }
        return database
    }
    func open<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        var folder = file.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // A copy of mail text made for searching has no place in a backup; it is made again from Mail.
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        // Kept out of backups whether the folder is new or was made by an earlier build.
        if (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) != true {
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        let database = try Self.encrypted(file)
        defer { database.close() }
        try database.run("PRAGMA journal_mode=WAL")
        // Text taken out of the index is overwritten in the file, not left in its free pages.
        try database.run("PRAGMA secure_delete=ON")
        try database.run("CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY,account TEXT NOT NULL,mailbox TEXT NOT NULL,message_id TEXT NOT NULL,date REAL NOT NULL,sender TEXT NOT NULL,recipients TEXT NOT NULL,subject TEXT NOT NULL,sent INTEGER NOT NULL,attachments INTEGER NOT NULL,UNIQUE(account,message_id))")
        try database.run("CREATE INDEX IF NOT EXISTS messages_by_date ON messages(account,date)")
        let fresh = try database.rows("SELECT name FROM sqlite_master WHERE name='texts'").isEmpty
        try database.run("CREATE VIRTUAL TABLE IF NOT EXISTS texts USING fts5(subject,people,body,tokenize='trigram')")
        if fresh { try? database.run("INSERT INTO texts(texts,rank) VALUES('secure-delete',1)") }
        try database.run("CREATE INDEX IF NOT EXISTS messages_by_folder ON messages(account,mailbox)")
        try database.run("CREATE TABLE IF NOT EXISTS pass(account TEXT NOT NULL,mailbox TEXT NOT NULL,state TEXT NOT NULL,PRIMARY KEY(account,mailbox))")
        try database.run("CREATE TABLE IF NOT EXISTS excluded(account TEXT NOT NULL,message_id TEXT NOT NULL,at REAL NOT NULL,PRIMARY KEY(account,message_id))")
        try database.run("CREATE TABLE IF NOT EXISTS files(account TEXT NOT NULL,mailbox TEXT NOT NULL,local INTEGER NOT NULL,message INTEGER,at REAL NOT NULL,PRIMARY KEY(account,mailbox,local))")
        try database.run("CREATE INDEX IF NOT EXISTS files_by_message ON files(message)")
        try Self.createEmbeddingTables(in: database)
        return try body(database)
    }
}

enum SQLiteValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
    var blob: Data? { if case .blob(let value) = self { value } else { nil } }
    var text: String? { if case .text(let value) = self { value } else { nil } }
    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var real: Double? { switch self { case .real(let value): value; case .integer(let value): Double(value); default: nil } }
}

/// The few calls of SQLite that the index needs.
final class SQLiteDatabase {
    let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(_ file: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw BridgeFailure("Mail Dot could not open its search index.")
        }
        handle = opened
        sqlite3_busy_timeout(handle, 5000)
        chmod(file.path, 0o600)
    }
    func close() { sqlite3_close(handle) }
    /// The key does not open the file: SQLite reports it as no database at all.
    func unreadable() -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK else { return sqlite3_errcode(handle) == SQLITE_NOTADB }
        let code = sqlite3_step(statement)
        return code == SQLITE_NOTADB || sqlite3_errcode(handle) == SQLITE_NOTADB
    }
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws { _ = try rows(sql, values) }
    /// Visits the rows of a query one at a time without holding them: the body reads the columns it needs from the
    /// statement while the row is current.
    func each(_ sql: String, _ values: [SQLiteValue] = [], _ body: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .blob(let data): data.withUnsafeBytes { _ = sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            body(statement)
        }
    }
    func rows(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .blob(let data): data.withUnsafeBytes { _ = sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var result: [[SQLiteValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                case SQLITE_BLOB: .blob(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column))) } ?? Data())
                default: .null
                }
            })
        }
        return result
    }
    private func failure() -> BridgeFailure { BridgeFailure("Mail Dot's search index reported: " + String(cString: sqlite3_errmsg(handle))) }
}
