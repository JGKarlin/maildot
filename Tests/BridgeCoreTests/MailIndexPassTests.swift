import XCTest
@testable import BridgeCore

/// A folder of invented messages standing in for Mail.
private actor FakeMail: MailIndexReading {
    struct Held { let id: Int; let messageID: String; let date: Date; let sender: String; let subject: String; let text: String }
    var held: [String: [Held]] = [:]
    var cap = 500
    var refuses: Set<String> = []
    var readsAtOnce = 100
    private(set) var listings = 0
    private(set) var reads = 0
    func put(_ messages: [Held], in box: NativeMailbox) { held[box.id, default: []] += messages }
    func remove(id: Int, from box: NativeMailbox) { held[box.id]?.removeAll { $0.id == id } }
    var junk: Set<Int> = []
    func markJunk(_ id: Int) { junk.insert(id) }
    func set(cap: Int) { self.cap = cap }
    func set(readsAtOnce: Int) { self.readsAtOnce = readsAtOnce }
    func refuse(_ box: NativeMailbox, _ on: Bool) { if on { refuses.insert(box.id) } else { refuses.remove(box.id) } }
    func indexList(accountID: String, mailbox: NativeMailbox, since: Date, until: Date) async throws -> MailIndexListing {
        listings += 1
        if refuses.contains(mailbox.id) { throw BridgeFailure("The selected mailbox is unavailable or ambiguous.") }
        let found = (held[mailbox.id] ?? []).filter { $0.date >= since && $0.date < until }
        return MailIndexListing(count: found.count, entries: found.count > cap ? nil : found.map { .init(id: $0.id, messageID: $0.messageID) })
    }
    func indexRead(accountID: String, mailbox: NativeMailbox, ids: [Int]) async throws -> [MailIndexRead] {
        reads += 1
        if refuses.contains(mailbox.id) { throw BridgeFailure("The selected mailbox is unavailable or ambiguous.") }
        return ids.prefix(readsAtOnce).map { id in
            guard let found = held[mailbox.id]?.first(where: { $0.id == id }) else { return MailIndexRead(id: id, message: nil, text: "") }
            return MailIndexRead(id: id, message: NativeMailMessage(id: id, mailboxID: mailbox.id, headerID: found.messageID, subject: found.subject, sender: found.sender, receivedAt: found.date,
                                                                    isRead: true, size: 100, to: ["owner@example.invalid"], cc: [], bcc: [], attachmentCount: 0), text: found.text, leftOut: junk.contains(id))
        }
    }
}

final class MailIndexPassTests: XCTestCase {
    private let account = "ACCOUNT-1"
    private var inbox: NativeMailbox { NativeMailbox(accountID: account, path: ["INBOX"]) }
    private var sent: NativeMailbox { NativeMailbox(accountID: account, path: ["Sent Messages"]) }
    private let start = Date(timeIntervalSince1970: 1_794_000_000)   // November 2026
    private func index() -> (MailSearchIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pass-\(UUID().uuidString)")
        return (MailSearchIndex(bridgeDirectory: root), root)
    }
    private func held(_ id: Int, daysAgo: Double, _ subject: String, _ text: String, from sender: String = "Maya Okafor <maya@example.invalid>") -> FakeMail.Held {
        .init(id: id, messageID: "<m\(id)@example.invalid>", date: start.addingTimeInterval(-daysAgo * 86_400), sender: sender, subject: subject, text: text)
    }
    /// Steps until the pass has nothing to do, moving the clock a little each time. Returns the steps taken.
    @discardableResult private func run(_ mail: FakeMail, _ index: MailSearchIndex, grants: [NativeMailGrant], from time: Date, limit: Int = 400) async throws -> Int {
        var now = time, steps = 0
        while steps < limit {
            let outcome = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: ["owner@example.invalid"], now: now)
            if outcome == .idle { break }
            steps += 1; now = now.addingTimeInterval(1)
        }
        return steps
    }

    func testOlderMailComesInNewestFirstAcrossFoldersAndThePassFinishes() async throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let mail = FakeMail()
        await mail.put([held(1, daysAgo: 1, "Budget", "the quarterly budget is attached"), held(2, daysAgo: 40, "Lease", "the lease renewal for the office"),
                        held(3, daysAgo: 2_000, "Ancient", "a very old note about the lighthouse")], in: inbox)
        await mail.put([held(10, daysAgo: 3, "Re: Budget", "I approve the budget", from: "Owner <OWNER@example.invalid>")], in: sent)
        let grants = [NativeMailGrant(accountID: account, mailboxes: [inbox, sent])]
        // The first steps reach last week's mail in both folders before anything old.
        var now = start
        for _ in 0..<8 { _ = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: ["owner@example.invalid"], now: now); now = now.addingTimeInterval(1) }
        var query = MailSearchQuery(account: account, mailboxes: [inbox.id, sent.id]); query.words = ["budget"]
        XCTAssertEqual(Set(try index.search(query).map(\.messageID)), ["m1@example.invalid", "m10@example.invalid"])
        XCTAssertNotEqual(try index.progress(account: account, mailbox: inbox.id)?.complete, true)
        try await run(mail, index, grants: grants, from: now)
        XCTAssertEqual(try index.count(account: account), 4)
        XCTAssertEqual(try index.progress(account: account, mailbox: inbox.id)?.complete, true)
        XCTAssertEqual(try index.progress(account: account, mailbox: sent.id)?.complete, true)
        query.words = ["budget"]; query.direction = .sent
        XCTAssertEqual(try index.search(query).map(\.messageID), ["m10@example.invalid"], "a message from the owner's address counts as sent")
        query.words = ["lighthouse"]; query.direction = .both
        XCTAssertEqual(try index.search(query).count, 1)
    }

    func testNewMailJoinsWithinTwoMinutesAndIsNotReadTwice() async throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let mail = FakeMail()
        await mail.put([held(1, daysAgo: 1, "Budget", "the quarterly budget")], in: inbox)
        let grants = [NativeMailGrant(accountID: account, mailboxes: [inbox])]
        try await run(mail, index, grants: grants, from: start)
        let readsBefore = await mail.reads
        await mail.put([.init(id: 2, messageID: "<m2@example.invalid>", date: start.addingTimeInterval(30), sender: "Tomás Rey <tomas@example.invalid>", subject: "Tickets", text: "your tickets for the concert")], in: inbox)
        var outcome = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: [], now: start.addingTimeInterval(40))
        XCTAssertEqual(outcome, .idle, "a folder is not listed again before two minutes have passed")
        let later = start.addingTimeInterval(MailIndexPass.upkeepInterval + 500)
        outcome = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: [], now: later)
        XCTAssertEqual(outcome, .listed(1))
        outcome = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: [], now: later.addingTimeInterval(1))
        XCTAssertEqual(outcome, .read(1))
        var query = MailSearchQuery(account: account, mailboxes: [inbox.id]); query.words = ["concert"]
        XCTAssertEqual(try index.search(query).map(\.messageID), ["m2@example.invalid"])
        let readsAfter = await mail.reads
        XCTAssertEqual(readsAfter, readsBefore + 1)
        // Listing the same hour again finds nothing new.
        outcome = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: [], now: later.addingTimeInterval(MailIndexPass.upkeepInterval + 1))
        XCTAssertEqual(outcome, .listed(0))
    }

    func testADenseStretchIsListedInShorterPartsAndNothingIsLost() async throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let mail = FakeMail(); await mail.set(cap: 20)
        await mail.put((1...90).map { held($0, daysAgo: 1 + Double($0) / 20, "Note \($0)", "numbered note \($0) about the harbour") }, in: inbox)
        let grants = [NativeMailGrant(accountID: account, mailboxes: [inbox])]
        try await run(mail, index, grants: grants, from: start)
        XCTAssertEqual(try index.count(account: account), 90)
        XCTAssertEqual(try index.progress(account: account, mailbox: inbox.id)?.complete, true)
    }

    func testAMessageThatLeftTheFolderAndPartialReadsDoNotStopThePass() async throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let mail = FakeMail(); await mail.set(readsAtOnce: 2)
        await mail.put((1...7).map { held($0, daysAgo: Double($0), "Note \($0)", "numbered note \($0)") }, in: inbox)
        let grants = [NativeMailGrant(accountID: account, mailboxes: [inbox])]
        // Listed, then one message is moved away before it is read.
        _ = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: [], now: start)
        _ = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: [], now: start.addingTimeInterval(1))
        await mail.remove(id: 3, from: inbox)
        try await run(mail, index, grants: grants, from: start.addingTimeInterval(2))
        XCTAssertEqual(try index.count(account: account), 6)
        XCTAssertEqual(try index.progress(account: account, mailbox: inbox.id)?.pending, [])
    }

    func testAFolderMailRefusesRestsWhileTheOthersGoOn() async throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let mail = FakeMail()
        await mail.put([held(1, daysAgo: 1, "Budget", "the quarterly budget")], in: inbox)
        await mail.put([held(10, daysAgo: 1, "Re: Budget", "approved")], in: sent)
        await mail.refuse(inbox, true)
        let grants = [NativeMailGrant(accountID: account, mailboxes: [inbox, sent])]
        var now = start, outcomes: [MailIndexPass.Outcome] = []
        for _ in 0..<40 { outcomes.append(try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: [], now: now)); now = now.addingTimeInterval(1) }
        XCTAssertEqual(outcomes.first, .rested)
        XCTAssertEqual(try index.count(account: account), 1, "the other folder was indexed meanwhile")
        XCTAssertEqual(outcomes.last, .rested, "with one folder resting the pass is not idle")
        let listingsWhileResting = await mail.listings
        // Ten minutes later Mail answers again and the folder is taken up where it stood.
        await mail.refuse(inbox, false)
        try await run(mail, index, grants: grants, from: start.addingTimeInterval(700))
        XCTAssertEqual(try index.count(account: account), 2)
        let listingsAfter = await mail.listings
        XCTAssertGreaterThan(listingsAfter, listingsWhileResting)
    }

    func testJunkIsLeftOutAndMailDeletedFromAFolderLeavesTheIndex() async throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let mail = FakeMail()
        await mail.put([held(1, daysAgo: 1, "Budget", "the quarterly budget"), held(2, daysAgo: 2, "You won", "claim your budget prize")], in: inbox)
        await mail.markJunk(2)
        let grants = [NativeMailGrant(accountID: account, mailboxes: [inbox])]
        try await run(mail, index, grants: grants, from: start)
        XCTAssertEqual(try index.count(account: account), 1, "the message Mail marks as junk is not indexed")
        let readsOnce = await mail.reads
        // A new message arrives and the old one is deleted in Mail; the next listing of the last hour notices both.
        await mail.put([.init(id: 3, messageID: "<m3@example.invalid>", date: start.addingTimeInterval(60), sender: "Tomás Rey <tomas@example.invalid>", subject: "Tickets", text: "your tickets")], in: inbox)
        await mail.put([.init(id: 4, messageID: "<m4@example.invalid>", date: start.addingTimeInterval(90), sender: "Tomás Rey <tomas@example.invalid>", subject: "Seats", text: "your seats")], in: inbox)
        try await run(mail, index, grants: grants, from: start.addingTimeInterval(MailIndexPass.upkeepInterval + 200))
        XCTAssertEqual(try index.count(account: account), 3)
        await mail.remove(id: 4, from: inbox)
        try await run(mail, index, grants: grants, from: start.addingTimeInterval(2 * MailIndexPass.upkeepInterval + 400))
        XCTAssertEqual(try index.count(account: account), 2, "the deleted message is gone from the index")
        var query = MailSearchQuery(account: account, mailboxes: [inbox.id]); query.words = ["seats"]
        XCTAssertTrue(try index.search(query).isEmpty)
        let readsAfter = await mail.reads
        XCTAssertEqual(readsAfter, readsOnce + 1, "the junk message was not read again, nor the kept ones")
    }

    /// Independent review of build 170, H1: the check does not stop at the last hour.
    func testMailDeletedLongAfterItWasIndexedLeavesTheIndexWhenItsStretchIsCheckedAgain() async throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let mail = FakeMail()
        await mail.put([held(1, daysAgo: 1, "Budget", "the quarterly budget"), held(2, daysAgo: 9, "Lease", "the lease renewal"), held(3, daysAgo: 400, "Ancient", "a very old note")], in: inbox)
        let grants = [NativeMailGrant(accountID: account, mailboxes: [inbox])]
        // Everything is read, and the first round of checking runs to the folder's oldest mail.
        var now = start
        var turn = 0
        func steps(_ count: Int) async throws { for _ in 0..<count { _ = try await MailIndexPass.step(reader: mail, index: index, grants: grants, owner: [], now: now, turn: turn); turn += 1; now = now.addingTimeInterval(MailIndexPass.upkeepInterval + 1) } }
        // Steps come no faster than new mail is due to be listed, as with many folders: reading still gets its turn.
        try await steps(400)
        XCTAssertEqual(try index.count(account: account), 3)
        XCTAssertNotNil(try index.progress(account: account, mailbox: inbox.id)?.checkRestsUntil, "a round of checking was completed")
        // Days later the owner deletes two old messages in Mail, one of them over a year old.
        await mail.remove(id: 2, from: inbox); await mail.remove(id: 3, from: inbox)
        now = now.addingTimeInterval(MailIndexPass.checkRest + 1)
        try await steps(400)
        XCTAssertEqual(try index.count(account: account), 1, "both are gone from the index, however old")
        var query = MailSearchQuery(account: account, mailboxes: [inbox.id]); query.words = ["lease", "ancient"]
        XCTAssertTrue(try index.search(query).isEmpty)
    }

    func testWithdrawnFoldersAreForgottenWithoutMail() async throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let mail = FakeMail()
        await mail.put([held(1, daysAgo: 1, "Budget", "the quarterly budget")], in: inbox)
        await mail.put([held(10, daysAgo: 1, "Re: Budget", "approved")], in: sent)
        var grant = NativeMailGrant(accountID: account, mailboxes: [inbox, sent])
        try await run(mail, index, grants: [grant], from: start)
        XCTAssertEqual(try index.count(account: account), 2)
        grant.mailboxes = [inbox]
        XCTAssertEqual(try MailIndexPass.forget(index: index, grants: [grant]), 1)
        XCTAssertNil(try index.progress(account: account, mailbox: sent.id))
        grant.revokedAt = start
        XCTAssertEqual(try MailIndexPass.forget(index: index, grants: [grant]), 1)
        XCTAssertEqual(try index.count(account: account), 0)
        let outcome = try await MailIndexPass.step(reader: mail, index: index, grants: [grant], owner: [], now: start)
        XCTAssertEqual(outcome, .idle, "a withdrawn account is not read")
    }
}
