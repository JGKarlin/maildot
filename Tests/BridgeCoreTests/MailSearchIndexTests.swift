import XCTest
@testable import BridgeCore

/// Mail Dot's own search index (Ask Dot review, 15 November 2026).
final class MailSearchIndexTests: XCTestCase {
    private func index() -> (MailSearchIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
        return (MailSearchIndex(bridgeDirectory: root), root)
    }
    private func message(_ id: String, _ subject: String, _ text: String, from sender: String = "Maya Okafor <maya@example.invalid>", to: [String] = ["owner@example.invalid"],
                         daysAgo: Double = 1, sent: Bool = false, attachments: Int = 0, mailbox: String = "inbox", account: String = "acct") -> IndexedMessage {
        IndexedMessage(account: account, mailbox: mailbox, messageID: id, date: Date().addingTimeInterval(-daysAgo * 86400), sender: sender, recipients: to, subject: subject, sent: sent, attachments: attachments, text: text)
    }
    private func query(_ words: [String], mailboxes: [String] = ["inbox", "sent"]) -> MailSearchQuery {
        var query = MailSearchQuery(account: "acct", mailboxes: mailboxes); query.words = words; return query
    }

    func testWordsAreFoundInEnglishAndJapaneseAndRankedByTheMatch() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        try index.add([
            message("<a@example.invalid>", "Revised workshop budget", "The revised budget moves travel from 420,000 to 360,000 yen and adds interpreting."),
            message("b@example.invalid", "Lunch on Friday?", "Are you free for lunch on Friday at noon?", from: "Sam Lee <sam@example.invalid>"),
            message("c@example.invalid", "木曜日の会議について", "木曜日の会議は14時から第二会議室で行います。予算の資料をお持ちください。", from: "田中 <tanaka@example.invalid>"),
        ])
        XCTAssertEqual(try index.search(query(["budget"])).map(\.messageID), ["a@example.invalid"], "the angle brackets are not part of the identity")
        XCTAssertEqual(try index.search(query(["BUDGET"])).count, 1, "case does not matter")
        XCTAssertEqual(try index.search(query(["第二会議室"])).map(\.messageID), ["c@example.invalid"])
        XCTAssertEqual(try index.search(query(["会議"])).map(\.messageID), ["c@example.invalid"], "a two-character word is found too")
        XCTAssertEqual(Set(try index.search(query(["lunch", "予算の資料"])).map(\.messageID)), ["b@example.invalid", "c@example.invalid"], "any of the words")
        XCTAssertTrue(try index.search(query(["nothing-like-this"])).isEmpty)
        let hit = try XCTUnwrap(index.search(query(["interpreting"])).first)
        XCTAssertTrue(hit.passage.contains("interpreting")); XCTAssertEqual(hit.subject, "Revised workshop budget"); XCTAssertEqual(hit.sender, "Maya Okafor <maya@example.invalid>")
    }

    func testFiltersNarrowAndOnlyAllowedFoldersAnswer() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        try index.add([
            message("old@example.invalid", "Venue", "Harbor Hall is booked for the workshop.", daysAgo: 200),
            message("new@example.invalid", "Venue again", "Harbor Hall confirmed the workshop booking.", daysAgo: 2, attachments: 1),
            message("mine@example.invalid", "Re: Venue", "I prefer Harbor Hall for the workshop.", from: "owner@example.invalid", to: ["Priya Nair <priya@example.invalid>"], daysAgo: 1, sent: true, mailbox: "sent"),
            message("other@example.invalid", "Venue", "Harbor Hall workshop notes.", account: "another"),
        ])
        var q = query(["workshop"])
        XCTAssertEqual(try index.search(q).count, 3, "another account's mail never answers")
        q.direction = .sent; XCTAssertEqual(try index.search(q).map(\.messageID), ["mine@example.invalid"])
        q.direction = .received; q.since = Date().addingTimeInterval(-30 * 86400)
        XCTAssertEqual(try index.search(q).map(\.messageID), ["new@example.invalid"])
        q = query(["workshop"]); q.hasAttachments = true
        XCTAssertEqual(try index.search(q).map(\.messageID), ["new@example.invalid"])
        q = query(["workshop"]); q.person = "priya"
        XCTAssertEqual(try index.search(q).map(\.messageID), ["mine@example.invalid"], "a person is the sender or a recipient")
        XCTAssertEqual(try index.search(query(["workshop"], mailboxes: ["inbox"])).count, 2, "a folder no longer allowed does not answer")
        XCTAssertTrue(try index.search(query(["workshop"], mailboxes: [])).isEmpty)
        // No words: the filters alone, newest first.
        q = query([]); q.person = "maya"
        XCTAssertEqual(try index.search(q).map(\.messageID), ["new@example.invalid", "old@example.invalid"])
    }

    func testAMessageIsHeldOnceAndWithdrawnFoldersLeaveNothing() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        try index.add([message("a@example.invalid", "First", "first wording of the plan")])
        try index.add([message("<a@example.invalid>", "First", "second wording of the plan")])
        XCTAssertEqual(try index.count(account: "acct"), 1)
        XCTAssertTrue(try index.search(query(["first wording"])).isEmpty)
        XCTAssertEqual(try index.search(query(["second wording"])).count, 1)
        try index.add([message("s@example.invalid", "Sent one", "a sent message about the plan", mailbox: "sent")])
        var progress = MailIndexProgress(newest: Date(timeIntervalSince1970: 2_000), gaps: [.init(low: Date(timeIntervalSince1970: 0), high: Date(timeIntervalSince1970: 2_000))])
        progress.pending = [7, 9]
        try index.setProgress(progress, account: "acct", mailbox: "sent")
        XCTAssertEqual(try index.progress(account: "acct", mailbox: "sent"), progress)
        XCTAssertEqual(try index.missing(account: "acct", messageIDs: ["<a@example.invalid>", "s@example.invalid", "new@example.invalid", ""]), ["new@example.invalid"])
        XCTAssertEqual(try index.keep(only: ["acct": ["inbox"]]), 1)
        XCTAssertEqual(try index.count(account: "acct"), 1)
        XCTAssertNil(try index.progress(account: "acct", mailbox: "sent"), "its progress is forgotten with it")
        XCTAssertEqual(try index.keep(only: [:]), 1)
        XCTAssertEqual(try index.count(account: "acct"), 0)
        XCTAssertTrue(try index.search(query(["plan"])).isEmpty)
    }

    func testOnlyAMessagesOwnWordsAreKeptAndTextsComeBackByIdentity() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        let reply = "Thursday works for me.\n\nOn Nov 10, 2026, at 9:00, Maya Okafor <maya@example.invalid> wrote:\n> Could we meet on zebra day?\n> Regards"
        XCTAssertEqual(MailSearchIndex.withoutQuotedHistory(reply), "Thursday works for me.")
        XCTAssertEqual(MailSearchIndex.withoutQuotedHistory("了解です。\n\n2026年11月10日(火) 9:00 田中 <tanaka@example.invalid>:\n> 木曜日はいかがですか"), "了解です。")
        XCTAssertEqual(MailSearchIndex.withoutQuotedHistory("Note: see below.\n> quoted\nStill mine"), "Note: see below.\nStill mine")
        try index.add([message("r@example.invalid", "Re: Meeting", reply), message("q@example.invalid", "Other", "other text")])
        XCTAssertTrue(try index.search(query(["zebra"])).isEmpty, "quoted history is not this message's text")
        let texts = try index.texts(account: "acct", mailboxes: ["inbox"], messageIDs: ["<q@example.invalid>", "r@example.invalid", "missing@example.invalid"])
        XCTAssertEqual(texts.map(\.messageID), ["q@example.invalid", "r@example.invalid"]); XCTAssertEqual(texts[1].text, "Thursday works for me.")
        XCTAssertTrue(try index.texts(account: "acct", mailboxes: ["sent"], messageIDs: ["q@example.invalid"]).isEmpty)
        // A long text yields a passage around the word, not its beginning.
        let long = String(repeating: "filler words here. ", count: 80) + "The keyword pomegranate appears late. " + String(repeating: "more filler. ", count: 80)
        let passage = MailSearchIndex.passage(long, around: ["pomegranate"])
        XCTAssertTrue(passage.contains("pomegranate")); XCTAssertLessThan(passage.count, 310); XCTAssertTrue(passage.hasPrefix("…"))
    }
}

/// The two tools Dot reaches the index through.
final class MailSearchToolTests: XCTestCase {
    private func bridge() throws -> (URL, NativeMailStore, String, NativeMailbox, NativeMailbox) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("searchtool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NativeMailStore(bridgeDirectory: root)
        let inbox = NativeMailbox(accountID: "acct", path: ["INBOX"]), archive = NativeMailbox(accountID: "acct", path: ["Archive"])
        try store.transaction { var grant = NativeMailGrant(accountID: "acct", mailboxes: [inbox]); grant.verifiedAt = .now; $0.grants = [grant] }
        let index = MailSearchIndex(bridgeDirectory: root)
        try index.add([
            IndexedMessage(account: "acct", mailbox: inbox.id, messageID: "one@example.invalid", date: Date().addingTimeInterval(-86400), sender: "Priya Nair <priya@example.invalid>", recipients: ["owner@example.invalid"], subject: "Revised budget", sent: false, attachments: 1, text: "The revised budget adds interpreting."),
            IndexedMessage(account: "acct", mailbox: archive.id, messageID: "two@example.invalid", date: Date().addingTimeInterval(-86400), sender: "Priya Nair <priya@example.invalid>", recipients: ["owner@example.invalid"], subject: "Old budget", sent: false, attachments: 0, text: "The old budget, kept in a folder not allowed."),
        ])
        return (root, store, "acct", inbox, archive)
    }
    func testSearchAnswersOnlyFromAllowedFoldersAndSaysWhetherTheIndexIsComplete() async throws {
        let (root, store, account, inbox, archive) = try bridge(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NativeMailTools.call("native_mail_search", arguments: ["account_id": .string(account), "words": ["budget"]], store: store, wake: {})
        XCTAssertEqual(result["hits"].array?.map { $0["message_id"].string }, ["one@example.invalid"], "the folder the owner did not allow never answers")
        XCTAssertEqual(result["hits"].array?.first?["mailbox"].string, inbox.name)
        XCTAssertTrue(result["hits"].array?.first?["passage"].string?.contains("interpreting") == true)
        XCTAssertEqual(result["index_complete"], false); XCTAssertEqual(result["folders_still_being_indexed"].array?.count, 1)
        try MailSearchIndex(bridgeDirectory: root).setProgress(MailIndexProgress(newest: .now, gaps: []), account: account, mailbox: inbox.id)
        let later = try await NativeMailTools.call("native_mail_search", arguments: ["account_id": .string(account), "person": "priya", "has_attachments": true], store: store, wake: {})
        XCTAssertEqual(later["index_complete"], true); XCTAssertEqual(later["hits"].array?.count, 1)
        for arguments: [String: JSONValue] in [["account_id": .string(account)], ["account_id": .string(account), "words": ["budget"], "mailbox_ids": [.string(archive.id)]], ["account_id": "another", "words": ["budget"]]] {
            do { _ = try await NativeMailTools.call("native_mail_search", arguments: arguments, store: store, wake: {}); XCTFail("refused") } catch {}
        }
    }
    func testUpToFiveFoundMessagesAreReadInOneCall() async throws {
        let (root, store, account, _, _) = try bridge(); defer { try? FileManager.default.removeItem(at: root) }
        let read = try await NativeMailTools.call("native_mail_read_found", arguments: ["account_id": .string(account), "message_ids": ["<one@example.invalid>", "two@example.invalid", "none@example.invalid"]], store: store, wake: {})
        XCTAssertEqual(read["messages"].array?.map { $0["message_id"].string }, ["one@example.invalid"])
        XCTAssertEqual(read["messages"].array?.first?["text"].string, "The revised budget adds interpreting.")
        XCTAssertEqual(read["messages"].array?.first?["textTruncated"], false)
        XCTAssertEqual(read["not_found"].array?.count, 2, "one is in a folder not allowed, one does not exist")
        let six: [JSONValue] = (0..<6).map { .string("m\($0)@example.invalid") }
        do { _ = try await NativeMailTools.call("native_mail_read_found", arguments: ["account_id": .string(account), "message_ids": .array(six)], store: store, wake: {}); XCTFail("refused") } catch {}
    }
    /// Independent review of build 170, M1, M2 and L6: one rule for the index, the tools and the reach list.
    func testAnAccountSwitchedOffUnconfirmedOrReachedThroughAConnectorIsNotSearched() async throws {
        let (root, store, account, inbox, _) = try bridge(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = MailSettingsStore(bridgeDirectory: root)
        func search() async throws -> JSONValue { try await NativeMailTools.call("native_mail_search", arguments: ["account_id": .string(account), "words": ["budget"]], store: store, wake: {}) }
        func refused(_ expected: MailIndexPass.Refusal, _ call: () async throws -> JSONValue) async {
            do { _ = try await call(); XCTFail("refused: \(expected)") } catch { XCTAssertEqual((error as? BridgeFailure)?.message, expected.rawValue) }
        }
        var answer = try await search()
        XCTAssertEqual(answer["hits"].array?.count, 1)
        // Switched off: every tool refuses, and the account is not even listed.
        try settings.transaction { $0.setMailDot(false, account: "mail:" + account) }
        await refused(.switchedOff) { try await search() }
        await refused(.switchedOff) { try await NativeMailTools.call("native_mail_list_mailboxes", arguments: ["account_id": .string(account)], store: store, wake: {}) }
        answer = try await NativeMailTools.call("native_mail_status", arguments: [:], store: store, wake: {})
        XCTAssertEqual(answer["accounts"].array?.count, 0)
        XCTAssertTrue(MailIndexPass.kept(settings: try settings.read(), native: try store.read()).isEmpty, "its part of the index goes")
        try settings.transaction { $0.setMailDot(true, account: "mail:" + account) }
        // A folder check that failed: not searched, but what was indexed is kept.
        try store.transaction { $0.grants[0].verifiedAt = nil }
        await refused(.unconfirmed) { try await search() }
        XCTAssertTrue(MailIndexPass.scope(settings: try settings.read(), native: try store.read()).isEmpty)
        XCTAssertEqual(MailIndexPass.kept(settings: try settings.read(), native: try store.read()).map(\.accountID), [account])
        try store.transaction { $0.grants[0].verifiedAt = .now }
        // The same mailbox reached through a Gmail connector: searched there, and not indexed here.
        try settings.transaction {
            $0.nativeAccounts = [NativeMailAccount(id: account, name: "Personal", addresses: ["Owner@gmail.example.invalid"], server: "imap.example.invalid")]
            var connection = MailConnection(id: "g", email: "owner@gmail.example.invalid", connectionID: "link"); connection.observedAt = .now
            $0.connections = [connection]
        }
        await refused(.connector) { try await search() }
        XCTAssertTrue(MailIndexPass.kept(settings: try settings.read(), native: try store.read()).isEmpty)
        let reach = try MailWorkflowTools.reach(for: ["mail:" + account], labels: [], bridgeDirectory: root)
        XCTAssertEqual(reach.first?["route"], "gmail_connector")
        XCTAssertEqual(reach.first?["gmail_account"], "Owner@gmail.example.invalid")
        try settings.transaction { $0.connections[0].available = false }
        answer = try await search()
        XCTAssertEqual(answer["hits"].array?.count, 1, "with the connector gone the account is read on this Mac again")
        // A junk folder the owner allowed is left out of the scope, and out of what must be complete.
        let junk = NativeMailbox(accountID: account, path: ["Junk"])
        try store.transaction { $0.grants[0].mailboxes = [inbox, junk] }
        XCTAssertEqual(MailIndexPass.scope(settings: try settings.read(), native: try store.read()).first?.mailboxes, [inbox])
        try MailSearchIndex(bridgeDirectory: root).setProgress(MailIndexProgress(newest: .now, gaps: []), account: account, mailbox: inbox.id)
        answer = try await search()
        XCTAssertEqual(answer["index_complete"], true)
    }
}
