import XCTest
@testable import BridgeCore

/// Mail's files are read only from a made-up Mail folder here; every name and address is invented.
final class MailFilesTests: XCTestCase {
    private let account = "11111111-2222-3333-4444-555555555555"
    private var inbox: NativeMailbox { NativeMailbox(accountID: account, path: ["INBOX"]) }
    private var projects: NativeMailbox { NativeMailbox(accountID: account, path: ["Work", "Projects"]) }
    private func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mailfiles-\(UUID().uuidString)", isDirectory: true) }
    private func messages(_ home: URL, _ box: NativeMailbox, _ shard: String = "0/1") -> URL {
        var folder = home.appendingPathComponent("Library/Mail/V10/\(account)", isDirectory: true)
        for part in box.path { folder = folder.appendingPathComponent(part + ".mbox", isDirectory: true) }
        return folder.appendingPathComponent("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/Data/\(shard)/Messages", isDirectory: true)
    }
    @discardableResult private func write(_ home: URL, _ box: NativeMailbox, _ number: Int, id: String, subject: String, body: String, from: String = "Maya Okafor <maya@example.invalid>",
                                          flags: Int = 0, received: Int = 1_794_000_000, partial: Bool = false, shard: String = "0/1") throws -> URL {
        let folder = messages(home, box, shard)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = "From: \(from)\r\nTo: Owner <owner@example.invalid>, Tomás Rey <tomas@example.invalid>\r\nCc: lists@example.invalid\r\nSubject: \(subject)\r\nMessage-ID: <\(id)@example.invalid>\r\nDate: Sat, 14 Nov 2026 10:00:00 +0000\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n"
        let notes = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>date-received</key><integer>\(received)</integer><key>flags</key><integer>\(flags)</integer></dict></plist>\n"
        let file = folder.appendingPathComponent("\(number)\(partial ? ".partial" : "").emlx")
        try Data("\(raw.utf8.count)\n\(raw)\(notes)".utf8).write(to: file)
        return file
    }

    func testAMessageFileIsReadWithMailsOwnNotes() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let file = try write(home, inbox, 101, id: "venue", subject: "Spring meeting", body: "We will use Harbor Hall.", flags: (2 << 10) | 1, received: 1_794_000_500)
        let message = try XCTUnwrap(MailFiles.read(file, home: home))
        XCTAssertEqual(message.messageID, "venue@example.invalid")
        XCTAssertEqual(message.sender, "Maya Okafor <maya@example.invalid>")
        XCTAssertEqual(message.recipients, ["owner@example.invalid", "tomas@example.invalid", "lists@example.invalid"])
        XCTAssertEqual(message.subject, "Spring meeting")
        XCTAssertEqual(message.date, Date(timeIntervalSince1970: 1_794_000_500), "the time Mail received it, not the time it was written")
        XCTAssertEqual(message.attachments, 2)
        XCTAssertFalse(message.deleted || message.junk)
        XCTAssertTrue(message.text.contains("Harbor Hall"))
        let junk = try XCTUnwrap(MailFiles.read(try write(home, inbox, 102, id: "offer", subject: "Offer", body: "Win big.", flags: 1 << 24), home: home))
        XCTAssertTrue(junk.junk)
        let deleted = try XCTUnwrap(MailFiles.read(try write(home, inbox, 103, id: "old", subject: "Old", body: "Gone.", flags: 1 << 1), home: home))
        XCTAssertTrue(deleted.deleted)
        try Data("not a message".utf8).write(to: messages(home, inbox).appendingPathComponent("104.emlx"))
        XCTAssertNil(MailFiles.read(messages(home, inbox).appendingPathComponent("104.emlx"), home: home))
    }
    /// Review of build 170, M5 and L2.
    func testNewMailIsNoticedDuringABacklogAndAnUnreadableFileIsTriedAgainBeforeItIsLeftOut() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let index = MailSearchIndex(bridgeDirectory: home.appendingPathComponent("bridge"))
        for number in 1...30 { try write(home, projects, number, id: "p\(number)", subject: "Project \(number)", body: "note \(number)") }
        try write(home, inbox, 500, id: "first", subject: "First", body: "the first inbox message")
        // A message without a Message-ID, and a file Mail has not finished writing.
        let folder = messages(home, inbox)
        let bare = "From: Maya Okafor <maya@example.invalid>\r\nSubject: No identifier\r\n\r\nA note sent without an identifier.\r\n"
        try Data("\(bare.utf8.count)\n\(bare)".utf8).write(to: folder.appendingPathComponent("501.emlx"))
        try Data("12".utf8).write(to: folder.appendingPathComponent("502.emlx"))
        let sync = MailFileSync(home: home); sync.interval = 100
        var now = Date(timeIntervalSince1970: 1_794_100_000)
        // Both folders are looked through, then reading goes a few files at a time, the folders taking turns.
        for _ in 0..<4 { now = now.addingTimeInterval(1); _ = try sync.step(index: index, folders: [projects, inbox], owner: [], now: now, batch: 5) }
        var query = MailSearchQuery(account: account, mailboxes: [inbox.id, projects.id]); query.words = ["inbox message", "identifier"]
        XCTAssertEqual(Set(try index.search(query).map(\.subject)), ["First", "No identifier"], "the inbox is read while the larger folder's backlog is still waiting")
        XCTAssertLessThan(try index.count(account: account), 32)
        // New mail arrives while the backlog is still being read: the next look through the folder is not kept waiting.
        try write(home, inbox, 510, id: "arrived", subject: "Arrived", body: "arrived during the backlog")
        now = now.addingTimeInterval(101)
        for _ in 0..<4 { now = now.addingTimeInterval(1); _ = try sync.step(index: index, folders: [projects, inbox], owner: [], now: now, batch: 5) }
        query.words = ["arrived during"]
        XCTAssertEqual(try index.search(query).count, 1)
        XCTAssertLessThan(try index.count(account: account), 33, "and the backlog was not finished first")
        // The half-written file is offered again at each look, and left out only after three tries.
        XCTAssertFalse(try index.knownFiles(account: account, mailbox: inbox.id).contains(502))
        for _ in 0..<40 { now = now.addingTimeInterval(60); _ = try sync.step(index: index, folders: [projects, inbox], owner: [], now: now, batch: 50) }
        XCTAssertTrue(try index.knownFiles(account: account, mailbox: inbox.id).contains(502))
        XCTAssertEqual(try index.count(account: account), 33)
    }
    func testOnlyTheMailFolderIsEverReadAndFoldersInsideAFolderAreTheirOwn() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        try write(home, inbox, 101, id: "a", subject: "A", body: "a")
        try write(home, inbox, 250, id: "b", subject: "B", body: "b", partial: true, shard: "2")
        try write(home, projects, 300, id: "c", subject: "C", body: "c")
        try write(home, NativeMailbox(accountID: account, path: ["Work"]), 400, id: "d", subject: "D", body: "d")
        XCTAssertEqual(MailFiles.access(home: home), .granted)
        XCTAssertEqual(MailFiles.access(home: home.appendingPathComponent("nobody")), .absent)
        let inboxFolder = try XCTUnwrap(MailFiles.folder(home: home, accountID: account, path: ["INBOX"]))
        XCTAssertEqual(Set(MailFiles.messageFiles(in: inboxFolder, home: home).keys), [101, 250])
        let work = try XCTUnwrap(MailFiles.folder(home: home, accountID: account, path: ["Work"]))
        XCTAssertEqual(Set(MailFiles.messageFiles(in: work, home: home).keys), [400], "Projects inside Work is a folder of its own")
        XCTAssertEqual(Set(MailFiles.messageFiles(in: try XCTUnwrap(MailFiles.folder(home: home, accountID: account, path: ["Work", "Projects"])), home: home).keys), [300])
        XCTAssertNil(MailFiles.folder(home: home, accountID: account, path: ["Nowhere"]))
        XCTAssertNil(MailFiles.folder(home: home, accountID: "../../etc", path: ["INBOX"]))
        XCTAssertNil(MailFiles.folder(home: home, accountID: account, path: ["../.."]))
        // A file outside the Mail folder is not read, whatever it holds, nor one reached through a link out of it.
        let outside = home.appendingPathComponent("Documents/9.emlx")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: messages(home, inbox).appendingPathComponent("101.emlx"), to: outside)
        XCTAssertNil(MailFiles.read(outside, home: home))
        try FileManager.default.createSymbolicLink(at: messages(home, inbox).appendingPathComponent("999.emlx"), withDestinationURL: outside)
        XCTAssertNil(MailFiles.read(messages(home, inbox).appendingPathComponent("999.emlx"), home: home))
        XCTAssertTrue(MailFiles.messageFiles(in: home.appendingPathComponent("Documents"), home: home).isEmpty)
        XCTAssertTrue(MailFiles.isJunkOrTrash(path: ["Junk"]) && MailFiles.isJunkOrTrash(path: ["[Gmail]", "Spam"]) && MailFiles.isJunkOrTrash(path: ["Deleted Messages"]) && MailFiles.isJunkOrTrash(path: ["ゴミ箱"]))
        XCTAssertTrue(MailFiles.isJunkOrTrash(path: ["Trash", "Old"]), "a folder inside Trash is trash")
        XCTAssertFalse(MailFiles.isJunkOrTrash(path: ["INBOX"]) || MailFiles.isJunkOrTrash(path: ["Sent Messages"]) || MailFiles.isJunkOrTrash(path: ["Bin"]) || MailFiles.isJunkOrTrash(path: ["Deleted"]),
                       "a name an ordinary folder might bear leaves nothing out")
    }
    func testTheIndexFollowsTheFiles() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let index = MailSearchIndex(bridgeDirectory: home.appendingPathComponent("bridge"))
        try write(home, inbox, 101, id: "venue", subject: "Spring meeting", body: "We will use Harbor Hall.")
        try write(home, inbox, 102, id: "offer", subject: "Offer", body: "Win a harbor cruise.", flags: 1 << 24)
        try write(home, inbox, 103, id: "sent", subject: "Re: Spring meeting", body: "Harbor Hall is fine.", from: "Owner <OWNER@example.invalid>")
        try write(home, projects, 300, id: "venue", subject: "Spring meeting", body: "We will use Harbor Hall.")
        let nowhere = NativeMailbox(accountID: account, path: ["Archive"])
        let sync = MailFileSync(home: home)
        XCTAssertEqual(sync.notOnDisk([inbox, projects, nowhere]), [nowhere])
        var now = Date(timeIntervalSince1970: 1_794_100_000)
        func run() throws { for _ in 0..<20 { now = now.addingTimeInterval(1); if try sync.step(index: index, folders: [inbox, projects], owner: ["owner@example.invalid"], now: now) == .idle { break } } }
        try run()
        XCTAssertEqual(try index.count(account: account), 2, "junk is left out, and the message filed in two folders is held once")
        var query = MailSearchQuery(account: account, mailboxes: [inbox.id, projects.id]); query.words = ["harbor"]
        XCTAssertEqual(Set(try index.search(query).map(\.messageID)), ["venue@example.invalid", "sent@example.invalid"])
        query.direction = .sent
        XCTAssertEqual(try index.search(query).map(\.messageID), ["sent@example.invalid"])
        XCTAssertEqual(try index.progress(account: account, mailbox: inbox.id)?.complete, true)
        // An embedding goes when its message is deleted, and stays while the message lives on in another folder.
        try index.setEmbedding(row: try XCTUnwrap(index.unembedded(allowed: [account: [inbox.id, projects.id]], limit: 10).first { $0.subject == "Spring meeting" }).row, model: "m", parts: [.init(start: 0, length: 5, vector: [1, 0])])
        try FileManager.default.removeItem(at: messages(home, inbox).appendingPathComponent("101.emlx"))
        try FileManager.default.removeItem(at: messages(home, inbox).appendingPathComponent("103.emlx"))
        try write(home, inbox, 110, id: "new", subject: "Tickets", body: "Your tickets for the harbor concert.")
        now = now.addingTimeInterval(sync.interval + 1)
        try run()
        query.direction = .both
        XCTAssertEqual(Set(try index.search(query).map(\.messageID)), ["venue@example.invalid", "new@example.invalid"], "the copy in Projects keeps the message; the deleted reply is gone")
        XCTAssertEqual(try index.embeddingProgress(account: account, mailboxes: [inbox.id, projects.id]).embedded, 1)
        try FileManager.default.removeItem(at: messages(home, projects).appendingPathComponent("300.emlx"))
        now = now.addingTimeInterval(sync.interval + 1)
        try run()
        XCTAssertEqual(try index.search(query).map(\.messageID), ["new@example.invalid"])
        XCTAssertEqual(try index.embeddingProgress(account: account, mailboxes: [inbox.id, projects.id]).embedded, 0, "its embedding went with it")
    }
    func testMailReadEarlierThroughMailIsKeptWithoutBeingReadTwiceAndLeavesWhenItsFileIsGone() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let index = MailSearchIndex(bridgeDirectory: home.appendingPathComponent("bridge"))
        func held(_ id: String) -> IndexedMessage { IndexedMessage(account: account, mailbox: inbox.id, messageID: id, date: Date(timeIntervalSince1970: 1_794_000_000), sender: "maya@example.invalid", recipients: [], subject: id, sent: false, attachments: 0, text: "as read through Mail") }
        try index.add([held("kept@example.invalid"), held("deleted@example.invalid")])
        let row = try XCTUnwrap(index.unembedded(allowed: [account: [inbox.id]], limit: 10).first { $0.subject == "kept@example.invalid" }).row
        try index.setEmbedding(row: row, model: "m", parts: [.init(start: 0, length: 4, vector: [0, 1])])
        try write(home, inbox, 7, id: "kept", subject: "Kept", body: "as Mail's file has it")
        let sync = MailFileSync(home: home)
        var now = Date(timeIntervalSince1970: 1_794_100_000)
        for _ in 0..<10 { now = now.addingTimeInterval(1); if try sync.step(index: index, folders: [inbox], owner: [], now: now) == .idle { break } }
        XCTAssertEqual(try index.count(account: account), 1)
        XCTAssertEqual(try index.embeddingProgress(account: account, mailboxes: [inbox.id]).embedded, 1, "the message was already held, so its embedding stands")
        XCTAssertEqual(try index.texts(account: account, mailboxes: [inbox.id], messageIDs: ["kept@example.invalid"]).first?.text, "as read through Mail")
        XCTAssertTrue(try index.texts(account: account, mailboxes: [inbox.id], messageIDs: ["deleted@example.invalid"]).isEmpty)
        // A folder the owner stops allowing takes its files' bookkeeping and embeddings with it.
        XCTAssertEqual(try index.keep(only: [:]), 1)
        XCTAssertTrue(try index.knownFiles(account: account, mailbox: inbox.id).isEmpty)
        XCTAssertFalse(try index.removeEmbeddings())
    }
}
