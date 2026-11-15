import Foundation

/// What Mail lists for a stretch of time in one folder: how many messages, and for each its id in Mail and its
/// Message-ID. `entries` is nil when there are more than the listing carries; the stretch is then listed in parts.
public struct MailIndexListing: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let id: Int
        public let messageID: String
        public init(id: Int, messageID: String) { self.id = id; self.messageID = messageID }
    }
    public let count: Int
    public let entries: [Entry]?
    public init(count: Int, entries: [Entry]?) { self.count = count; self.entries = entries }
}

/// One message as the pass read it. `message` is nil when it is no longer in the folder.
public struct MailIndexRead: Sendable, Equatable {
    public let id: Int
    public let message: NativeMailMessage?
    public let text: String
    /// Mail marks the message as junk or deleted; it is not indexed.
    public let leftOut: Bool
    public init(id: Int, message: NativeMailMessage?, text: String, leftOut: Bool = false) { self.id = id; self.message = message; self.text = text; self.leftOut = leftOut }
}

/// The two reads the pass needs from Mail. Both are bounded: a listing covers one stretch of time, a read a few
/// messages and a few seconds, and returns only those it finished.
public protocol MailIndexReading: Sendable {
    func indexList(accountID: String, mailbox: NativeMailbox, since: Date, until: Date) async throws -> MailIndexListing
    func indexRead(accountID: String, mailbox: NativeMailbox, ids: [Int]) async throws -> [MailIndexRead]
}

/// The background pass that fills Mail Dot's search index (Ask Dot review, 15 November 2026). It works in small
/// steps so Mail stays responsive: each step asks Mail for one thing only, either a few messages to read or one
/// stretch of time to list. New mail comes first, then older mail, newest first, across the folders the owner
/// allowed. Sent mail never passes the extension, and mail arrives in folders the owner did not allow, so the
/// pass reads the allowed folders themselves instead of watching arrivals.
public enum MailIndexPass {
    public enum Outcome: Equatable, Sendable { case idle, read(Int), listed(Int), rested }
    /// Mail is not asked about anything earlier.
    public static let earliest = Date(timeIntervalSince1970: 315_532_800)   // 1 January 1980
    public static let upkeepInterval: TimeInterval = 120
    static let shortestSpan: TimeInterval = 60
    static let longestSpan: TimeInterval = 3_650 * 86_400

    /// Forgets what the owner no longer allows. Needs nothing from Mail, so it runs whether Mail is open or not.
    @discardableResult public static func forget(index: MailSearchIndex, grants: [NativeMailGrant]) throws -> Int {
        try index.keep(only: allowed(grants))
    }
    static func allowed(_ grants: [NativeMailGrant]) -> [String: [String]] {
        Dictionary(grants.filter { $0.revokedAt == nil }.map { ($0.accountID, $0.mailboxes.map(\.id)) }, uniquingKeysWith: { first, _ in first })
    }
    /// Why an account's mail on this Mac is not searched, or nil when it is.
    public enum Refusal: String, Sendable, Equatable {
        case switchedOff = "Mail Dot is switched off for this account, so its mail is not read or searched."
        case connector = "This account is searched through Dot's Gmail connector, not through Mail on this Mac."
        case unconfirmed = "This account's folders are being checked again. Until the check passes its mail is not searched."
        case notAllowed = "Authorize this Mail account and folders in Mail Dot's settings first."
    }
    /// The one rule every reader, tool and report goes by (independent review of build 170, M1 and M2): an account
    /// is read on this Mac only when the owner allowed folders of it, Mail confirmed them, Mail Dot is switched on
    /// for it, and Dot does not already reach it through a Gmail connector.
    public static func refusal(account id: String, settings: MailSettings, native: NativeMailState, needsConfirmed: Bool = true) -> Refusal? {
        guard let grant = native.grants.first(where: { $0.accountID == id && $0.revokedAt == nil }) else { return .notAllowed }
        guard settings.mailDot(account: "mail:" + id) else { return .switchedOff }
        if coveredByConnector(account: id, settings: settings) { return .connector }
        if needsConfirmed, grant.verifiedAt == nil { return .unconfirmed }
        return nil
    }
    /// Dot reaches the account through a Gmail connector that is connected now.
    public static func coveredByConnector(account id: String, settings: MailSettings) -> Bool {
        guard let account = settings.nativeAccounts.first(where: { $0.id == id }) else { return false }
        let addresses = Set(account.addresses.map { $0.lowercased() })
        return settings.connections.contains { $0.isLiveConnector && addresses.contains($0.email.lowercased()) }
    }
    /// What Mail Dot reads and searches: the folders of the accounts that pass the rule, without any account's junk
    /// or trash (owner's requirement, 15 November 2026).
    public static func scope(settings: MailSettings, native: NativeMailState) -> [NativeMailGrant] { grants(settings: settings, native: native, needsConfirmed: true) }
    /// What Mail Dot keeps in its index. An account whose folder check has just failed keeps what was indexed and
    /// embedded, since renaming one folder in Mail must not cost hours of work; it is only not searched meanwhile.
    public static func kept(settings: MailSettings, native: NativeMailState) -> [NativeMailGrant] { grants(settings: settings, native: native, needsConfirmed: false) }
    private static func grants(settings: MailSettings, native: NativeMailState, needsConfirmed: Bool) -> [NativeMailGrant] {
        native.grants.compactMap { grant -> NativeMailGrant? in
            guard grant.revokedAt == nil, refusal(account: grant.accountID, settings: settings, native: native, needsConfirmed: needsConfirmed) == nil else { return nil }
            var kept = grant
            kept.mailboxes = grant.mailboxes.filter { !MailFiles.isJunkOrTrash(path: $0.path) }
            return kept.mailboxes.isEmpty ? nil : kept
        }
    }

    /// One step. `owner` holds the owner's addresses, by which a message counts as sent.
    /// `turn` counts the caller's steps. Listing for new mail has first call on every other turn only: with many
    /// folders and unhurried steps it would otherwise be due again before anything else had its turn, and no
    /// message would ever be read.
    public static func step(reader: any MailIndexReading, index: MailSearchIndex, grants: [NativeMailGrant], owner: Set<String>,
                            now: Date = .now, batch: Int = 6, turn: Int = 0) async throws -> Outcome {
        var folders: [(box: NativeMailbox, progress: MailIndexProgress)] = []
        for grant in grants where grant.revokedAt == nil {
            for box in grant.mailboxes {
                if let held = try index.progress(account: grant.accountID, mailbox: box.id) { folders.append((box, held)); continue }
                // A folder met for the first time: everything before now is still to be listed.
                let fresh = MailIndexProgress(newest: now, gaps: [.init(low: earliest, high: now)])
                try index.setProgress(fresh, account: grant.accountID, mailbox: box.id)
                folders.append((box, fresh))
            }
        }
        let awake = folders.filter { ($0.progress.restUntil ?? .distantPast) <= now }
        // 1. New mail: each folder is listed from where it was last listed, every two minutes, before anything else.
        let checkDue = awake.filter { $0.progress.complete && now.timeIntervalSince($0.progress.checkedAt ?? .distantPast) >= upkeepInterval && ($0.progress.checkRestsUntil ?? .distantPast) <= now }
        let otherWork = !checkDue.isEmpty || awake.contains { !$0.progress.pending.isEmpty || !$0.progress.gaps.isEmpty }
        if turn % 2 == 0 || !otherWork, let folder = awake.filter({ now.timeIntervalSince($0.progress.listedAt ?? .distantPast) >= upkeepInterval })
            .min(by: { ($0.progress.listedAt ?? .distantPast) < ($1.progress.listedAt ?? .distantPast) }) {
            return try await attempt(folder, index: index, now: now) { progress in
                // An hour is listed again each time: Mail may file a message a little after the time it bears.
                let since = progress.newest.addingTimeInterval(-3_600)
                let listing = try await reader.indexList(accountID: folder.box.accountID, mailbox: folder.box, since: since, until: now.addingTimeInterval(86_400))
                progress.listedAt = now
                defer { progress.newest = now }
                guard let entries = listing.entries else {
                    // More arrived than one listing carries (Mail was closed for a long while): walked like older mail.
                    progress.gaps.append(.init(low: since, high: now.addingTimeInterval(86_400), span: 86_400))
                    return .listed(0)
                }
                // What the index holds for this stretch and Mail no longer lists here was deleted or moved away.
                try index.reconcile(account: folder.box.accountID, mailbox: folder.box.id, since: since, until: now.addingTimeInterval(86_400), listed: entries.map(\.messageID))
                return .listed(try queue(entries, into: &progress, account: folder.box.accountID, index: index))
            }
        }
        // 2. Messages already listed are read, so what was found is searchable before more is looked for.
        if let folder = awake.first(where: { !$0.progress.pending.isEmpty }) {
            return try await attempt(folder, index: index, now: now) { progress in
                let wanted = Array(progress.pending.prefix(max(1, batch)))
                let reads = try await reader.indexRead(accountID: folder.box.accountID, mailbox: folder.box, ids: wanted)
                let lowered = Set(owner.map { $0.lowercased() })
                try index.exclude(account: folder.box.accountID, messageIDs: reads.filter(\.leftOut).compactMap { $0.message?.headerID }, now: now)
                try index.add(reads.compactMap { read in
                    guard let message = read.message, !read.leftOut else { return nil }
                    let sender = MailMessageIdentity.address(in: message.sender) ?? message.sender.lowercased()
                    return IndexedMessage(account: folder.box.accountID, mailbox: folder.box.id, messageID: message.headerID, date: message.receivedAt, sender: message.sender,
                                          recipients: message.to + message.cc + message.bcc, subject: message.subject, sent: lowered.contains(sender),
                                          attachments: message.attachmentCount, text: read.text)
                })
                // Mail returns those it finished in the time it had. When it finished none, the first is let go so
                // one message Mail cannot read does not hold up the rest.
                let finished = Set(reads.map(\.id)).intersection(wanted)
                let settled = finished.isEmpty ? Set(wanted.prefix(1)) : finished
                progress.pending.removeAll(where: settled.contains)
                return .read(reads.filter { $0.message != nil && !$0.leftOut }.count)
            }
        }
        // 3. Older mail: the folder whose unlisted mail is newest goes next, so every folder goes back in time together.
        if let folder = awake.filter({ !$0.progress.gaps.isEmpty }).max(by: { top($0.progress) < top($1.progress) }) {
            return try await attempt(folder, index: index, now: now) { progress in
                guard let position = progress.gaps.indices.max(by: { progress.gaps[$0].high < progress.gaps[$1].high }) else { return .idle }
                var gap = progress.gaps[position]
                let since = max(gap.low, gap.high.addingTimeInterval(-gap.span))
                let listing = try await reader.indexList(accountID: folder.box.accountID, mailbox: folder.box, since: since, until: gap.high)
                var found = 0
                if let entries = listing.entries {
                    try index.reconcile(account: folder.box.accountID, mailbox: folder.box.id, since: since, until: gap.high, listed: entries.map(\.messageID))
                    found = try queue(entries, into: &progress, account: folder.box.accountID, index: index)
                    if listing.count < 50 { gap.span = min(gap.span * 2, longestSpan) }
                    gap.high = since
                } else if gap.span > shortestSpan {
                    // Too many for one listing: the same stretch is listed again in shorter parts.
                    gap.span = max(shortestSpan, gap.span / 4)
                } else {
                    // More than a listing carries within one minute; passed over so the pass can go on.
                    gap.high = since
                }
                if gap.high <= gap.low { progress.gaps.remove(at: position) } else { progress.gaps[position] = gap }
                return .listed(found)
            }
        }
        // 4. Mail already read is checked against Mail again, one stretch at a time, without end (independent review of
        // build 170, H1): a message deleted, marked as junk or filed elsewhere long after it was indexed leaves the
        // index when its stretch comes round. A folder is gone through from now back to its oldest mail, then rests.
        if let folder = checkDue
            .min(by: { ($0.progress.checkedAt ?? .distantPast) < ($1.progress.checkedAt ?? .distantPast) }) {
            return try await attempt(folder, index: index, now: now) { progress in
                var gap = progress.check ?? .init(low: earliest, high: now.addingTimeInterval(-3_600))
                progress.checkedAt = now
                let since = max(gap.low, gap.high.addingTimeInterval(-gap.span))
                let listing = try await reader.indexList(accountID: folder.box.accountID, mailbox: folder.box, since: since, until: gap.high)
                var found = 0
                if let entries = listing.entries {
                    try index.reconcile(account: folder.box.accountID, mailbox: folder.box.id, since: since, until: gap.high, listed: entries.map(\.messageID))
                    found = try queue(entries, into: &progress, account: folder.box.accountID, index: index)
                    if listing.count < 50 { gap.span = min(gap.span * 2, longestSpan) }
                    gap.high = since
                } else if gap.span > shortestSpan {
                    gap.span = max(shortestSpan, gap.span / 4)
                } else {
                    gap.high = since
                }
                if gap.high <= gap.low { progress.check = nil; progress.checkRestsUntil = now.addingTimeInterval(checkRest) } else { progress.check = gap }
                return .listed(found)
            }
        }
        return awake.count < folders.count ? .rested : .idle
    }
    /// How long a folder rests after it has been checked through to its oldest mail.
    public static let checkRest: TimeInterval = 6 * 3_600

    private static func top(_ progress: MailIndexProgress) -> Date { progress.gaps.map(\.high).max() ?? .distantPast }

    /// Queues the listed messages the index does not hold yet; returns how many.
    private static func queue(_ entries: [MailIndexListing.Entry], into progress: inout MailIndexProgress, account: String, index: MailSearchIndex) throws -> Int {
        let absent = try index.missing(account: account, messageIDs: entries.map(\.messageID))
        let waiting = Set(progress.pending)
        let fresh = entries.filter { entry in MailSearchIndex.key(entry.messageID).map(absent.contains) == true && !waiting.contains(entry.id) }.map(\.id)
        progress.pending += fresh
        return fresh.count
    }

    /// Runs one piece of work for a folder and saves where it stands. When Mail refuses, the folder rests for ten
    /// minutes and the others go on: a renamed folder or one slow listing must not stop the whole pass.
    private static func attempt(_ folder: (box: NativeMailbox, progress: MailIndexProgress), index: MailSearchIndex, now: Date,
                                _ work: (inout MailIndexProgress) async throws -> Outcome) async throws -> Outcome {
        var progress = folder.progress
        do {
            let outcome = try await work(&progress)
            progress.restUntil = nil
            try index.setProgress(progress, account: folder.box.accountID, mailbox: folder.box.id)
            return outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var rested = folder.progress
            rested.restUntil = now.addingTimeInterval(600)
            try index.setProgress(rested, account: folder.box.accountID, mailbox: folder.box.id)
            return .rested
        }
    }
}
