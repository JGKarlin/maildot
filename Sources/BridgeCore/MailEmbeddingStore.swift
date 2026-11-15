import Foundation
internal import SQLCipher

/// The embeddings Mail Dot keeps beside its search index when the owner turns on search by meaning (owner's request,
/// 15 November 2026). Each message's own text is cut into a few passages and each passage is stored as one vector
/// from Apple's on-device language model; nothing leaves the Mac. Vectors are kept per model, since those of
/// different models cannot be compared, with the sum of each account's vectors, which a search subtracts so that
/// what all mail has in common does not drown what one message says.
extension MailSearchIndex {
    public struct EmbeddedPart: Sendable, Equatable {
        /// Where the passage lies in the message's indexed text, in characters.
        public var start: Int
        public var length: Int
        /// A unit vector.
        public var vector: [Float]
        public init(start: Int, length: Int, vector: [Float]) { self.start = start; self.length = length; self.vector = vector }
    }
    public struct Unembedded: Sendable, Equatable {
        public let row: Int64
        public let subject: String
        public let text: String
    }
    public struct MeaningHit: Sendable, Equatable {
        public let hit: MailSearchHit
        public let score: Float
    }

    static func createEmbeddingTables(in database: SQLiteDatabase) throws {
        try database.run("CREATE TABLE IF NOT EXISTS embedded(message INTEGER PRIMARY KEY,model TEXT NOT NULL,parts INTEGER NOT NULL)")
        try database.run("CREATE TABLE IF NOT EXISTS vectors(message INTEGER NOT NULL,part INTEGER NOT NULL,model TEXT NOT NULL,start INTEGER NOT NULL,length INTEGER NOT NULL,data BLOB NOT NULL,PRIMARY KEY(message,part))")
        try database.run("CREATE TABLE IF NOT EXISTS deferred(message INTEGER PRIMARY KEY,attempts INTEGER NOT NULL,at REAL NOT NULL)")
        try database.run("CREATE TABLE IF NOT EXISTS centres(account TEXT NOT NULL,model TEXT NOT NULL,n INTEGER NOT NULL,total BLOB NOT NULL,PRIMARY KEY(account,model))")
    }

    // MARK: Vectors as stored

    /// A unit vector as 16-bit numbers: half the size of the model's own, and exact enough to rank by.
    static func packed(_ vector: [Float]) -> Data {
        var values = vector.map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))) }
        return Data(bytes: &values, count: values.count * MemoryLayout<Int16>.size)
    }
    static func unpacked(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32767 } }
    }
    private static func doubles(_ data: Data) -> [Double] { data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) } }
    private static func data(_ values: [Double]) -> Data { var copy = values; return Data(bytes: &copy, count: copy.count * MemoryLayout<Double>.size) }
    private static func shift(account: String, model: String, by vectors: [[Float]], sign: Double, in database: SQLiteDatabase) throws {
        guard let width = vectors.first?.count else { return }
        let held = try database.rows("SELECT n,total FROM centres WHERE account=? AND model=?", [.text(account), .text(model)]).first
        var total = held?[1].blob.map(doubles) ?? []
        if total.count != width { total = [Double](repeating: 0, count: width) }
        for vector in vectors where vector.count == width { for index in 0..<width { total[index] += sign * Double(vector[index]) } }
        let count = max(0, (held?[0].integer ?? 0) + Int64(sign) * Int64(vectors.count))
        try database.run("INSERT INTO centres(account,model,n,total) VALUES(?,?,?,?) ON CONFLICT(account,model) DO UPDATE SET n=excluded.n,total=excluded.total",
                         [.text(account), .text(model), .integer(count), .blob(data(count == 0 ? [Double](repeating: 0, count: width) : total))])
    }

    // MARK: Writing

    /// Messages of the allowed folders that have no embedding yet, newest first.
    /// How long a message whose model macOS is still fetching waits before it is tried again, and how often.
    public static let deferral: TimeInterval = 3_600
    public static let deferralLimit = 6
    /// Puts a message aside for an hour. After six tries it is marked as looked at, like one in a language no model covers.
    public func deferEmbedding(row: Int64, now: Date = .now) throws {
        try open { database in
            let attempts = (try database.rows("SELECT attempts FROM deferred WHERE message=?", [.integer(row)]).first?[0].integer ?? 0) + 1
            if attempts >= Int64(Self.deferralLimit) {
                try database.run("DELETE FROM deferred WHERE message=?", [.integer(row)])
                try database.run("INSERT OR REPLACE INTO embedded(message,model,parts) VALUES(?,?,0)", [.integer(row), .text("")])
            } else {
                try database.run("INSERT INTO deferred(message,attempts,at) VALUES(?,?,?) ON CONFLICT(message) DO UPDATE SET attempts=excluded.attempts,at=excluded.at", [.integer(row), .integer(attempts), .real(now.timeIntervalSince1970)])
            }
        }
    }
    public func unembedded(allowed: [String: [String]], limit: Int, now: Date = .now) throws -> [Unembedded] {
        guard FileManager.default.fileExists(atPath: file.path), limit > 0 else { return [] }
        let pairs = allowed.flatMap { account, boxes in boxes.map { (account, $0) } }
        guard !pairs.isEmpty else { return [] }
        return try open { database in
            let filter = pairs.map { _ in "(m.account=? AND m.mailbox=?)" }.joined(separator: " OR ")
            return try database.rows("SELECT m.id,m.subject,texts.body FROM messages m JOIN texts ON texts.rowid=m.id WHERE (\(filter)) AND NOT EXISTS(SELECT 1 FROM embedded e WHERE e.message=m.id) AND NOT EXISTS(SELECT 1 FROM deferred d WHERE d.message=m.id AND d.at>?) ORDER BY m.date DESC LIMIT ?",
                                     pairs.flatMap { [SQLiteValue.text($0.0), .text($0.1)] } + [.real(now.timeIntervalSince1970 - Self.deferral), .integer(Int64(limit))])
                .map { Unembedded(row: $0[0].integer ?? 0, subject: $0[1].text ?? "", text: $0[2].text ?? "") }
        }
    }
    /// Records a message's embedding. With no parts the message is only marked as looked at: one the model has no
    /// language for is not tried again.
    public func setEmbedding(row: Int64, model: String, parts: [EmbeddedPart]) throws {
        try open { database in
            guard let account = try database.rows("SELECT account FROM messages WHERE id=?", [.integer(row)]).first?[0].text else { return }
            try database.run("BEGIN IMMEDIATE")
            do {
                try Self.forgetEmbedding(of: row, in: database)
                try database.run("INSERT INTO embedded(message,model,parts) VALUES(?,?,?)", [.integer(row), .text(model), .integer(Int64(parts.count))])
                for (number, part) in parts.enumerated() {
                    try database.run("INSERT INTO vectors(message,part,model,start,length,data) VALUES(?,?,?,?,?,?)",
                                     [.integer(row), .integer(Int64(number)), .text(model), .integer(Int64(part.start)), .integer(Int64(part.length)), .blob(Self.packed(part.vector))])
                }
                try Self.shift(account: account, model: model, by: parts.map { Self.unpacked(Self.packed($0.vector)) }, sign: 1, in: database)
                try database.run("COMMIT")
            } catch { try? database.run("ROLLBACK"); throw error }
        }
    }
    /// Removes one message's embedding, as when the message is deleted. The caller holds the transaction.
    static func forgetEmbedding(of row: Int64, in database: SQLiteDatabase) throws {
        let held = try database.rows("SELECT v.model,v.data,m.account FROM vectors v JOIN messages m ON m.id=v.message WHERE v.message=?", [.integer(row)])
        for (model, rows) in Dictionary(grouping: held, by: { $0[0].text ?? "" }) {
            guard let account = rows.first?[2].text else { continue }
            try shift(account: account, model: model, by: rows.compactMap { $0[1].blob.map(unpacked) }, sign: -1, in: database)
        }
        try database.run("DELETE FROM vectors WHERE message=?", [.integer(row)])
        try database.run("DELETE FROM embedded WHERE message=?", [.integer(row)])
        try database.run("DELETE FROM deferred WHERE message=?", [.integer(row)])
    }
    /// Removes every embedding: the owner turned search by meaning off. Returns whether there were any.
    @discardableResult public func removeEmbeddings() throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return try open { database in
            let any = (try database.rows("SELECT count(*) FROM embedded").first?[0].integer ?? 0) > 0
            guard any else { return false }
            // Dropped whole: emptying them row by row would take as long as making them did.
            for table in ["vectors", "embedded", "centres", "deferred"] { try database.run("DROP TABLE IF EXISTS \(table)") }
            try Self.createEmbeddingTables(in: database)
            return true
        }
    }
    /// Removes the embeddings of every account but those given: the owner unticked Search by Meaning for an account,
    /// and nothing of its embeddings is kept. Returns how many messages lost theirs.
    @discardableResult public func keepEmbeddings(onlyAccounts accounts: Set<String>) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try open { database in
            let held = try database.rows("SELECT DISTINCT m.account FROM embedded e JOIN messages m ON m.id=e.message").compactMap { $0[0].text }.filter { !accounts.contains($0) }
            var removed = 0
            for account in held {
                removed += Int(try database.rows("SELECT count(*) FROM embedded e JOIN messages m ON m.id=e.message WHERE m.account=?", [.text(account)]).first?[0].integer ?? 0)
                try database.run("BEGIN IMMEDIATE")
                do {
                    for table in ["vectors", "embedded", "deferred"] { try database.run("DELETE FROM \(table) WHERE message IN (SELECT id FROM messages WHERE account=?)", [.text(account)]) }
                    try database.run("DELETE FROM centres WHERE account=?", [.text(account)])
                    try database.run("COMMIT")
                } catch { try? database.run("ROLLBACK"); throw error }
            }
            return removed
        }
    }
    /// How far the embedding of an account's allowed folders has come: messages embedded, and messages in the index.
    public func embeddingProgress(account: String, mailboxes: [String]) throws -> (embedded: Int, total: Int) {
        guard !mailboxes.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return (0, 0) }
        return try open { database in
            let marks = mailboxes.map { _ in "?" }.joined(separator: ",")
            let values: [SQLiteValue] = [.text(account)] + mailboxes.map { .text($0) }
            let total = try database.rows("SELECT count(*) FROM messages WHERE account=? AND mailbox IN (\(marks))", values).first?[0].integer ?? 0
            let done = try database.rows("SELECT count(*) FROM messages m WHERE m.account=? AND m.mailbox IN (\(marks)) AND EXISTS(SELECT 1 FROM embedded e WHERE e.message=m.id)", values).first?[0].integer ?? 0
            return (Int(done), Int(total))
        }
    }

    // MARK: Searching

    /// The messages whose passages lie nearest the query's vector, best first, within the query's folders and
    /// filters. `vector` is a unit vector from the model named. Each message counts by its best passage, and that
    /// passage is what the hit shows.
    public func searchByMeaning(_ query: MailSearchQuery, model: String, vector: [Float]) throws -> [MeaningHit] {
        guard !query.mailboxes.isEmpty, !vector.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return [] }
        let limit = min(max(query.limit, 1), Self.limit)
        var filters = "m.account=? AND m.mailbox IN (\(query.mailboxes.map { _ in "?" }.joined(separator: ","))) AND v.model=?"
        var values: [SQLiteValue] = [.text(query.account)] + query.mailboxes.map { .text($0) } + [.text(model)]
        if let person = query.person?.trimmingCharacters(in: .whitespaces), !person.isEmpty {
            filters += " AND (m.sender LIKE ? ESCAPE '\\' OR m.recipients LIKE ? ESCAPE '\\')"
            values += [.text(Self.pattern(person)), .text(Self.pattern(person))]
        }
        switch query.direction { case .received: filters += " AND m.sent=0"; case .sent: filters += " AND m.sent=1"; case .both: break }
        if let since = query.since { filters += " AND m.date>=?"; values.append(.real(since.timeIntervalSince1970)) }
        if let until = query.until { filters += " AND m.date<=?"; values.append(.real(until.timeIntervalSince1970)) }
        if query.hasAttachments { filters += " AND m.attachments>0" }
        return try open { database in
            // What the account's mail has in common is taken out of both sides before they are compared.
            let width = vector.count
            var centre = [Float](repeating: 0, count: width)
            if let held = try database.rows("SELECT n,total FROM centres WHERE account=? AND model=?", [.text(query.account), .text(model)]).first,
               let count = held[0].integer, count > 20, let total = held[1].blob.map(Self.doubles), total.count == width {
                centre = total.map { Float($0 / Double(count)) }
            }
            var wanted = zip(vector, centre).map { $0 - $1 }
            let wantedLength = sqrt(wanted.reduce(0) { $0 + $1 * $1 })
            guard wantedLength > 0 else { return [] }
            wanted = wanted.map { $0 / wantedLength }
            let centreSquared = centre.reduce(0) { $0 + $1 * $1 }
            var best: [Int64: (score: Float, start: Int, length: Int)] = [:]
            // Each vector is scored where SQLite holds it and then let go (independent review of build 170, M7): an
            // account's vectors are never all in memory at once.
            let centreToWanted = zip(centre, wanted).reduce(0) { $0 + $1.0 * $1.1 }
            try database.each("SELECT v.message,v.start,v.length,v.data FROM vectors v JOIN messages m ON m.id=v.message WHERE \(filters)", values) { statement in
                guard Int(sqlite3_column_bytes(statement, 3)) == width * MemoryLayout<Int16>.size, let bytes = sqlite3_column_blob(statement, 3) else { return }
                let stored = bytes.assumingMemoryBound(to: Int16.self)
                var toWanted: Float = 0, toCentre: Float = 0, own: Float = 0
                for index in 0..<width { let value = Float(stored[index]) / 32767; toWanted += value * wanted[index]; toCentre += value * centre[index]; own += value * value }
                let length = sqrt(max(own - 2 * toCentre + centreSquared, 1e-12))
                let score = (toWanted - centreToWanted) / length
                let message = sqlite3_column_int64(statement, 0)
                if score > (best[message]?.score ?? -.infinity) { best[message] = (score, Int(sqlite3_column_int64(statement, 1)), Int(sqlite3_column_int64(statement, 2))) }
            }
            let top = best.sorted { $0.value.score > $1.value.score }.prefix(limit)
            return try top.compactMap { entry -> MeaningHit? in
                guard let row = try database.rows("SELECT m.mailbox,m.message_id,m.date,m.sender,m.subject,m.sent,m.attachments,texts.body FROM messages m JOIN texts ON texts.rowid=m.id WHERE m.id=?", [.integer(entry.key)]).first else { return nil }
                let body = row[7].text ?? ""
                let from = body.index(body.startIndex, offsetBy: min(entry.value.start, body.count))
                let to = body.index(from, offsetBy: min(entry.value.length, body.distance(from: from, to: body.endIndex)))
                return MeaningHit(hit: MailSearchHit(messageID: row[1].text ?? "", mailbox: row[0].text ?? "", date: Date(timeIntervalSince1970: row[2].real ?? 0), sender: row[3].text ?? "",
                                                     subject: row[4].text ?? "", sent: row[5].integer == 1, attachments: Int(row[6].integer ?? 0),
                                                     passage: Self.passage(String(body[from..<to]), around: [])), score: entry.value.score)
            }
        }
    }
}
