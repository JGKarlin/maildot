import Foundation

/// Keeps Mail Dot's index in step with Mail's own files, folder by folder, when the owner has given Full Disk
/// Access for search by meaning. It needs nothing from Mail, so it works whether Mail is open or not. Each step is
/// small: either one folder is looked through for files that are new or gone, or a few new files are read.
/// A folder Mail keeps no directory for on this Mac is reported, and is then read through Mail as before.
public final class MailFileSync: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable { case idle, scanned(new: Int, gone: Int), read(Int) }
    private let home: URL
    private let lock = NSLock()
    private var waiting: [String: [(local: Int, file: URL)]] = [:]
    private var scannedAt: [String: Date] = [:]
    private var settled: Set<String> = []
    private var missing: Set<String> = []
    /// How often a folder is looked through again.
    public var interval: TimeInterval = 300
    public init(home: URL) { self.home = home }

    /// The folders of these that Mail keeps no directory for; they stay with the reader that goes through Mail.
    public func notOnDisk(_ folders: [NativeMailbox]) -> [NativeMailbox] {
        lock.lock(); defer { lock.unlock() }
        return folders.filter { missing.contains($0.id) || MailFiles.folder(home: home, accountID: $0.accountID, path: $0.path) == nil }
    }

    /// How often a file that could not be read is tried before it is left out: Mail may have been writing it.
    static let readAttempts = 3
    private var attempts: [String: Int] = [:]
    private var lastRead: String?
    private var scannedLast = false

    public func step(index: MailSearchIndex, folders: [NativeMailbox], owner: Set<String>, now: Date = .now, batch: Int = 40) throws -> Outcome {
        lock.lock(); defer { lock.unlock() }
        let lowered = Set(owner.map { $0.lowercased() })
        // 1. A folder due to be looked through is looked through first (independent review of build 170, M5): mail
        // that arrived or was deleted is noticed within the interval however long the backlog of unread files is.
        // Looking and reading take turns when both are waiting, so neither can keep the other out however the steps fall.
        let due = folders.filter { !missing.contains($0.id) && now.timeIntervalSince(scannedAt[$0.id] ?? .distantPast) >= interval }
        let readingWaits = folders.contains { !(waiting[$0.id] ?? []).isEmpty }
        if !(scannedLast && readingWaits), let folder = due.min(by: { (scannedAt[$0.id] ?? .distantPast) < (scannedAt[$1.id] ?? .distantPast) }) {
            scannedLast = true
            scannedAt[folder.id] = now
            guard let directory = MailFiles.folder(home: home, accountID: folder.accountID, path: folder.path) else { missing.insert(folder.id); return .scanned(new: 0, gone: 0) }
            let onDisk = MailFiles.messageFiles(in: directory, home: home)
            let known = try index.knownFiles(account: folder.accountID, mailbox: folder.id)
            let gone = known.subtracting(onDisk.keys)
            try index.drop(account: folder.accountID, mailbox: folder.id, files: Array(gone))
            // Mail numbers messages as they arrive, so the highest numbers are the newest mail.
            let new = onDisk.filter { !known.contains($0.key) }.sorted { $0.key > $1.key }.map { (local: $0.key, file: $0.value) }
            waiting[folder.id] = new
            if new.isEmpty { try finish(folder, index: index, now: now) }
            return .scanned(new: new.count, gone: gone.count)
        }
        // 2. Files found are read, newest first, the folders taking turns.
        scannedLast = false
        let queued = folders.filter { !(waiting[$0.id] ?? []).isEmpty }
        guard !queued.isEmpty else { return .idle }
        let next = lastRead.flatMap { last in queued.firstIndex { $0.id == last } }.map { (queued.index(after: $0)) % queued.count } ?? 0
        let folder = queued[next]; lastRead = folder.id
        var queue = waiting[folder.id] ?? []
        let taken = Array(queue.prefix(max(1, batch))); queue.removeFirst(taken.count); waiting[folder.id] = queue
        var read: [(local: Int, message: IndexedMessage?)] = []
        for entry in taken {
            let key = folder.id + "/" + String(entry.local)
            guard let message = MailFiles.read(entry.file, home: home) else {
                // Not a message Mail Dot could read. It is not recorded, so the next look through the folder offers
                // it again; only after three tries is it left out (review of build 170, L2).
                attempts[key, default: 0] += 1
                if attempts[key, default: 0] >= Self.readAttempts { attempts[key] = nil; read.append((entry.local, nil)) }
                continue
            }
            attempts[key] = nil
            guard !message.deleted, !message.junk else { read.append((entry.local, nil)); continue }
            let address = MailMessageIdentity.address(in: message.sender) ?? message.sender.lowercased()
            // A message without a Message-ID is known by its folder and its number in Mail.
            let identity = message.messageID ?? "no-message-id-\(folder.id.suffix(12))-\(entry.local)@mail-dot.invalid"
            read.append((entry.local, IndexedMessage(account: folder.accountID, mailbox: folder.id, messageID: identity, date: message.date, sender: message.sender, recipients: message.recipients,
                                                     subject: message.subject, sent: lowered.contains(address), attachments: message.attachments, text: message.text)))
        }
        try index.take(account: folder.accountID, mailbox: folder.id, files: read, now: now)
        if queue.isEmpty { try finish(folder, index: index, now: now) }
        return .read(read.filter { $0.message != nil }.count)
    }
    /// A folder whose files are all taken in is complete: the reader that goes through Mail has nothing left to do there.
    private func finish(_ folder: NativeMailbox, index: MailSearchIndex, now: Date) throws {
        try index.settle(account: folder.accountID, mailbox: folder.id, now: now)
        let complete = try index.progress(account: folder.accountID, mailbox: folder.id)?.complete == true
        guard !settled.contains(folder.id) || !complete else { return }
        settled.insert(folder.id)
        var progress = MailIndexProgress(newest: now, gaps: [])
        progress.listedAt = now
        try index.setProgress(progress, account: folder.accountID, mailbox: folder.id)
    }
}
