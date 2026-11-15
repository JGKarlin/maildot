import XCTest
@testable import BridgeCore

/// A stand-in for the model: each known word pulls the vector towards one axis, so texts about the same thing lie
/// close together whatever their other words. Nothing here needs Apple's model.
private struct WordAxes: TextEmbedding {
    static let axes: [[String]] = [["dentist", "tooth", "cleaning", "dr."], ["rent", "landlord", "lease", "pay"], ["flight", "itinerary", "trip", "booking"], ["budget", "spending"], ["打ち合わせ", "ミーティング", "会議"]]
    var later = false
    func embed(_ text: String) -> Embedded {
        if later { return .later }
        if text.contains("ΩΩ") { return .unsupported }
        let lowered = text.lowercased()
        var vector = Self.axes.map { words in Float(words.filter { lowered.contains($0) }.count) } + [0.2]
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        vector = vector.map { $0 / length }
        return .vector(model: lowered.unicodeScalars.contains { $0.value >= 0x3040 } ? "cjk" : "latin", vector)
    }
}

final class MailEmbeddingTests: XCTestCase {
    private let account = "ACCOUNT-1"
    private func index() -> (MailSearchIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embed-\(UUID().uuidString)")
        return (MailSearchIndex(bridgeDirectory: root), root)
    }
    private func message(_ id: String, _ subject: String, _ text: String, daysAgo: Double = 1, mailbox: String = "inbox") -> IndexedMessage {
        IndexedMessage(account: account, mailbox: mailbox, messageID: "\(id)@example.invalid", date: Date(timeIntervalSince1970: 1_794_700_000 - daysAgo * 86_400), sender: "Maya Okafor <maya@example.invalid>",
                       recipients: ["owner@example.invalid"], subject: subject, sent: false, attachments: 0, text: text)
    }
    func testPassagesCoverTheTextAndEndAtSentences() {
        XCTAssertTrue(MailEmbedding.parts(of: "").isEmpty)
        XCTAssertEqual(MailEmbedding.parts(of: "Short note.").map(\.length), [11])
        let long = String(repeating: "This sentence is exactly forty chars long. ", count: 60)
        let parts = MailEmbedding.parts(of: long)
        XCTAssertEqual(parts.count, MailEmbedding.partLimit)
        XCTAssertEqual(parts.first?.start, 0)
        for (earlier, later) in zip(parts, parts.dropFirst()) { XCTAssertEqual(earlier.start + earlier.length, later.start, "passages follow one another without a gap") }
        XCTAssertTrue(parts.allSatisfy { $0.length <= 700 && $0.length >= 350 })
        XCTAssertTrue(Array(long)[parts[0].length - 1] == ".", "a passage ends where a sentence does")
        let japanese = String(repeating: "来週の打ち合わせは水曜日の午後3時から行います。", count: 40)
        XCTAssertTrue(MailEmbedding.parts(of: japanese).allSatisfy { $0.length <= 220 }, "Japanese passages are shorter: a character is about a word piece")
    }
    func testTheBacklogIsEmbeddedNewestFirstAndMeaningFindsWhatWordsDoNot() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        try index.add([message("dental", "Appointment confirmation", "This confirms your cleaning with Dr. Ito on 3 December.", daysAgo: 6),
                       message("lease", "Renewal terms", "From February you pay the landlord 1,450 each month.", daysAgo: 40),
                       message("flight", "Your itinerary", "Booking QX7RLM for the trip to San Francisco.", daysAgo: 20),
                       message("jp", "来週の打ち合わせについて", "来週の打ち合わせは水曜日の午後3時から行います。", daysAgo: 4),
                       message("odd", "ΩΩ", "ΩΩ ΩΩ", daysAgo: 2),
                       message("other", "Budget", "The budget is approved.", daysAgo: 1, mailbox: "private")] +
                      (0..<30).map { message("news\($0)", "Digest \($0)", "Markets, weather and a recipe, issue \($0).", daysAgo: 50 + Double($0)) })
        let allowed = [account: ["inbox"]]
        XCTAssertEqual(try MailEmbedding.step(index: index, embedder: WordAxes(), allowed: allowed, batch: 3), 3)
        XCTAssertEqual(try index.unembedded(allowed: allowed, limit: 1).first?.subject, "Your itinerary", "the newest three are done; the next newest waits")
        while try MailEmbedding.step(index: index, embedder: WordAxes(), allowed: allowed, batch: 10) > 0 {}
        let progress = try index.embeddingProgress(account: account, mailboxes: ["inbox"])
        XCTAssertEqual(progress.embedded, 35)
        XCTAssertEqual(progress.total, 35, "a message in a language no model covers still counts as looked at")
        XCTAssertEqual(try index.embeddingProgress(account: account, mailboxes: ["private"]).embedded, 0, "a folder not allowed is not embedded")
        // "tooth doctor" shares no word with the confirmation; its meaning does.
        var query = MailSearchQuery(account: account, mailboxes: ["inbox"]); query.words = ["tooth doctor"]
        XCTAssertTrue(try index.search(query).isEmpty)
        guard case .vector(let model, let vector) = WordAxes().embed("When do I see the tooth doctor?") else { return XCTFail() }
        let found = try index.searchByMeaning(query, model: model, vector: vector)
        XCTAssertEqual(found.first?.hit.messageID, "dental@example.invalid")
        XCTAssertTrue(found.first?.hit.passage.contains("Dr. Ito") == true, "the hit shows the passage that matched")
        guard case .vector(let japanese, let japaneseVector) = WordAxes().embed("次のミーティングはいつですか") else { return XCTFail() }
        XCTAssertEqual(try index.searchByMeaning(query, model: japanese, vector: japaneseVector).map(\.hit.messageID), ["jp@example.invalid"], "only vectors of the same model are compared")
        query.since = Date(timeIntervalSince1970: 1_794_700_000 - 3 * 86_400)
        XCTAssertTrue(try index.searchByMeaning(query, model: model, vector: vector).allSatisfy { $0.hit.messageID != "dental@example.invalid" }, "the filters hold for meaning as for words")
        // Off again: nothing of it is kept.
        XCTAssertTrue(try index.removeEmbeddings())
        XCTAssertEqual(try index.embeddingProgress(account: account, mailboxes: ["inbox"]).embedded, 0)
        XCTAssertTrue(try index.searchByMeaning(MailSearchQuery(account: account, mailboxes: ["inbox"]), model: model, vector: vector).isEmpty)
    }
    /// Independent review of build 170, M6: one message whose model is still being fetched does not hold up the rest.
    func testAMessageWhoseModelIsStillBeingFetchedWaitsWithoutHoldingUpTheOthers() throws {
        struct English: TextEmbedding {
            func embed(_ text: String) -> Embedded { text.contains("打ち合わせ") ? .later : WordAxes().embed(text) }
        }
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        try index.add([message("jp", "来週の打ち合わせについて", "来週の打ち合わせは水曜日です。", daysAgo: 1), message("lease", "Renewal terms", "You pay the landlord 1,450.", daysAgo: 2),
                       message("flight", "Your itinerary", "Booking for the trip.", daysAgo: 3)])
        let allowed = [account: ["inbox"]]
        XCTAssertEqual(try MailEmbedding.step(index: index, embedder: English(), allowed: allowed, batch: 10), 3)
        XCTAssertEqual(try index.embeddingProgress(account: account, mailboxes: ["inbox"]).embedded, 2, "the two English messages are embedded although the newest message is waiting")
        XCTAssertTrue(try index.unembedded(allowed: allowed, limit: 10).isEmpty, "the waiting message is not offered again within the hour")
        let later = Date().addingTimeInterval(MailSearchIndex.deferral + 60)
        XCTAssertEqual(try index.unembedded(allowed: allowed, limit: 10, now: later).map(\.subject), ["来週の打ち合わせについて"], "an hour later it is tried again")
        // After six tries it is marked as looked at, so the backlog's count can reach its total.
        let row = try XCTUnwrap(index.unembedded(allowed: allowed, limit: 10, now: later).first).row
        for _ in 0..<MailSearchIndex.deferralLimit { try index.deferEmbedding(row: row) }
        XCTAssertEqual(try index.embeddingProgress(account: account, mailboxes: ["inbox"]).embedded, 3)
        XCTAssertTrue(try index.unembedded(allowed: allowed, limit: 10, now: later).isEmpty)
    }
    /// Review of build 170, L4 and L5.
    func testALaterMessageBearingAnEarliersIdentifierDoesNotReplaceItAndAnEmptyIndexLeavesTheDisk() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        try index.add([message("thread", "Venue", "We will use Harbor Hall.")])
        var forged = message("thread", "Venue", "We will use Riverside Lodge."); forged.sender = "Someone Else <else@example.invalid>"
        try index.add([forged])
        XCTAssertEqual(try index.texts(account: account, mailboxes: ["inbox"], messageIDs: ["thread@example.invalid"]).first?.text, "We will use Harbor Hall.")
        var corrected = message("thread", "Venue", "We will use Harbor Hall, room 2."); corrected.sender = "maya@example.invalid"
        try index.add([corrected])
        XCTAssertEqual(try index.texts(account: account, mailboxes: ["inbox"], messageIDs: ["thread@example.invalid"]).first?.text, "We will use Harbor Hall, room 2.", "the same sender's message is still brought up to date")
        try index.add((0..<700).map { message("n\($0)", "Digest \($0)", String(repeating: "Markets and weather. ", count: 40)) })
        XCTAssertEqual(try index.keep(only: [:], limit: 300), 300, "forgetting is done a few hundred at a time")
        var left = 300
        while left > 0 { left = try index.keep(only: [:], limit: 300) }
        XCTAssertEqual(try index.count(account: account), 0)
        try index.compact()
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.file.path), "an index left empty is removed from the disk")
        try index.add([message("again", "Back", "The index is made anew when mail returns.")])
        XCTAssertEqual(try index.count(account: account), 1)
    }
    /// Review of build 170, L3 and M10.
    func testHTMLMailIsReadAsItsWordsAndASearchCountsOnlyWhenMailDotSawIt() {
        let html = "<html><head><title>x</title><style>p { color: #333; font-family: Helvetica }</style></head><body><script>track()</script><p>Tom &amp; Maya &#12354;&#x3044; meet at&nbsp;3.</p><!-- hidden --><div>Bring the &ldquo;budget&rdquo;</div></body></html>"
        let text = MailBodyText.plain(html: html)
        XCTAssertTrue(text.contains("Tom & Maya あい meet at 3."))
        XCTAssertTrue(text.contains("Bring the “budget”"))
        for unwanted in ["font-family", "track()", "hidden", "<p>", "&amp;"] { XCTAssertFalse(text.contains(unwanted), unwanted) }
        let asked = [(id: "mail:A", name: "iCloud"), (id: "mail:B", name: "Work"), (id: "gmail:g", name: "Gmail")]
        let claimed = [AskDot.Coverage(account: "mail:A", searched: true, detail: "Inbox"), AskDot.Coverage(account: "mail:B", searched: true, detail: "Inbox"), AskDot.Coverage(account: "gmail:g", searched: true, detail: "All mail")]
        let settled = AskDot.settled(claimed, asked: asked, searchedOnThisMac: ["A"])
        XCTAssertEqual(settled.map(\.observed), [true, false, nil])
        XCTAssertEqual(settled.map(\.shownAsSearched), [true, false, true], "a search of Mail that Mail Dot did not see is not shown as one; a connector account rests on Dot's word")
        XCTAssertEqual(AskDot.settled(claimed, asked: asked).map(\.shownAsSearched), [true, true, true], "with nothing observed either way, as in earlier builds, Dot's word stands")
        let at = Date()
        let records = [ToolCallRecord(at: at, method: "tools/call", tool: "native_mail_search", outcome: .ok, detail: nil, request: "R", account: "A"),
                       ToolCallRecord(at: at, method: "tools/call", tool: "native_mail_search", outcome: .refused, detail: nil, request: "R", account: "B"),
                       ToolCallRecord(at: at, method: "tools/call", tool: "native_mail_search", outcome: .ok, detail: nil, request: "other", account: "B")]
        XCTAssertEqual(ToolCallRecord.accountsSearched(for: "R", in: records), ["A"])
    }
    /// Owner's request, 15 November 2026: Search by Meaning is chosen account by account.
    func testSearchByMeaningIsChosenPerAccountAndUntickingRemovesThatAccountsEmbeddings() throws {
        var settings = MailSettings()
        settings.nativeAccounts = [NativeMailAccount(id: "A", name: "iCloud", addresses: ["a@example.invalid"], server: "imap.example.invalid"), NativeMailAccount(id: "B", name: "Work", addresses: ["b@example.invalid"], server: "imap.example.invalid")]
        XCTAssertFalse(settings.searchByMeaning(account: "A") || settings.searchByMeaningAnywhere, "off for every account until a box is ticked")
        settings.setSearchByMeaning(true, account: "A")
        XCTAssertTrue(settings.searchByMeaning(account: "A") && !settings.searchByMeaning(account: "B") && settings.searchByMeaningAnywhere)
        settings.setSearchByMeaning(false, account: "A")
        XCTAssertFalse(settings.searchByMeaningAnywhere)
        // The single switch of build 170 stood for every account; unticking one row leaves the others on.
        settings.searchByMeaningAccounts = nil; settings.searchByMeaning = true
        XCTAssertTrue(settings.searchByMeaning(account: "B"))
        settings.setSearchByMeaning(false, account: "A")
        XCTAssertEqual(settings.searchByMeaningAccounts, ["B"])
        XCTAssertNil(settings.searchByMeaning)
        let saved = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(MailSettings.self, from: saved).searchByMeaningAccounts, ["B"])

        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        var other = message("w1", "Lease", "You pay the landlord 1,450."); other.account = "B"
        try index.add([message("d1", "Appointment", "Your cleaning with Dr. Ito."), other])
        while try MailEmbedding.step(index: index, embedder: WordAxes(), allowed: [account: ["inbox"], "B": ["inbox"]]) > 0 {}
        XCTAssertEqual(try index.embeddingProgress(account: "B", mailboxes: ["inbox"]).embedded, 1)
        XCTAssertEqual(try index.keepEmbeddings(onlyAccounts: [account]), 1)
        XCTAssertEqual(try index.embeddingProgress(account: "B", mailboxes: ["inbox"]).embedded, 0, "the unticked account's embeddings are gone")
        XCTAssertEqual(try index.embeddingProgress(account: account, mailboxes: ["inbox"]).embedded, 1, "the ticked account's stay")
        XCTAssertEqual(try index.count(account: "B"), 1, "its mail stays in the word index")
        XCTAssertEqual(try index.keepEmbeddings(onlyAccounts: [account]), 0)
    }
    func testStoredVectorsKeepTheirDirectionAndWordAndMeaningResultsAreMerged() {
        let vector: [Float] = [0.6, -0.8, 0, 0.001]
        let back = MailSearchIndex.unpacked(MailSearchIndex.packed(vector))
        for (a, b) in zip(vector, back) { XCTAssertEqual(a, b, accuracy: 0.0001) }
        func hit(_ id: String) -> MailSearchHit { MailSearchHit(messageID: id, mailbox: "inbox", date: Date(), sender: "", subject: "", sent: false, attachments: 0, passage: id) }
        let merged = NativeMailTools.merged(words: [hit("a"), hit("b"), hit("c")], meaning: [hit("d"), hit("b")], limit: 3)
        XCTAssertEqual(merged.map(\.hit.messageID), ["b", "a", "d"], "found by both comes first; then the best of each")
        XCTAssertEqual(merged.map(\.by), ["both", "words", "meaning"])
    }
}

final class MeaningSearchToolTests: XCTestCase {
    func testTheToolUsesMeaningOnlyWhenTheOwnerTurnedItOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meaning-\(UUID().uuidString)", isDirectory: true); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let account = "ACCOUNT-1", inbox = NativeMailbox(accountID: account, path: ["INBOX"])
        let store = NativeMailStore(bridgeDirectory: root)
        try store.transaction { var grant = NativeMailGrant(accountID: account, mailboxes: [inbox]); grant.verifiedAt = .now; $0.grants = [grant] }
        let index = MailSearchIndex(bridgeDirectory: root)
        try index.add([IndexedMessage(account: account, mailbox: inbox.id, messageID: "dental@example.invalid", date: .now, sender: "clinic@example.invalid", recipients: [], subject: "Appointment confirmation",
                                      sent: false, attachments: 0, text: "This confirms your cleaning with Dr. Ito on 3 December.")] +
                      (0..<25).map { IndexedMessage(account: account, mailbox: inbox.id, messageID: "n\($0)@example.invalid", date: .now, sender: "digest@example.invalid", recipients: [], subject: "Digest \($0)", sent: false, attachments: 0, text: "Markets and weather.") })
        NativeMailTools.embedder = WordAxes(); defer { NativeMailTools.embedder = ContextualEmbedder() }
        while try MailEmbedding.step(index: index, embedder: WordAxes(), allowed: [account: [inbox.id]]) > 0 {}
        let arguments: [String: JSONValue] = ["account_id": .string(account), "words": ["tooth doctor"], "meaning": "When do I see the tooth doctor?"]
        var answer = try await NativeMailTools.call("native_mail_search", arguments: arguments, store: store, wake: {})
        XCTAssertEqual(answer["search_by_meaning"], "off")
        XCTAssertEqual(answer["hits"].array?.count, 0, "off by default: only words are searched")
        try MailSettingsStore(bridgeDirectory: root).transaction { $0.searchByMeaning = true }
        answer = try await NativeMailTools.call("native_mail_search", arguments: arguments, store: store, wake: {})
        XCTAssertEqual(answer["search_by_meaning"], "on")
        XCTAssertEqual(answer["hits"].array?.first?["message_id"], "dental@example.invalid")
        XCTAssertEqual(answer["hits"].array?.first?["found_by"], "meaning")
        answer = try await NativeMailTools.call("native_mail_search", arguments: ["account_id": .string(account), "meaning": "ΩΩ"], store: store, wake: {})
        XCTAssertEqual(answer["search_by_meaning"], "unavailable_for_this_language")
    }
}

/// Apple's own model through Mail Dot's own search, on invented mail: questions reworded so that they share no
/// telling word with the message that answers them. Skipped on a Mac where macOS has not fetched the model.
final class RealModelMeaningTests: XCTestCase {
    func testRewordedQuestionsFindTheirAnswersAmongTheFirstFive() throws {
        let embedder = ContextualEmbedder()
        guard case .vector = embedder.embed("A sentence in English.") else { throw XCTSkip("Apple's embedding model is not on this Mac yet.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let index = MailSearchIndex(bridgeDirectory: root), account = "ACCOUNT-1"
        let mail: [(String, String, String)] = [
            ("dental", "Appointment confirmation", "This confirms your cleaning with Dr. Ito on 3 December at 14:30. Please arrive ten minutes early."),
            ("lease", "Lease renewal terms", "The rent for the renewed term will be 1,450 per month from 1 February. Please sign and return the attached agreement by 15 January."),
            ("venue", "Re: Spring meeting", "After comparing the three options we will use Harbor Hall. The deposit is due at the end of the month."),
            ("flight", "Your itinerary: OSA to SFO", "Booking reference QX7RLM. Departure 14 January 17:05 from Osaka Kansai, arrival 10:40 San Francisco. Seat 23A."),
            ("wifi", "Wi-Fi at the cabin", "The network is called Pinecone and the passphrase is on the fridge. The router sits behind the bookshelf if it needs a restart."),
            ("plumber", "A plumber who actually shows up", "You asked who fixed our boiler: it was Idris at Northside Heating, 555-0142. Fair price and he came the same day."),
            ("grant", "Grant application", "The foundation moved the submission date: proposals are now due 5 December, not the 12th. The page limit is unchanged."),
            ("moved", "We moved!", "Our new address is 18 Larch Lane, Apartment 4. The housewarming will be some time in the spring."),
            ("ad1", "Whitening offer this month", "Book any appointment this month and get whitening at half price."),
            ("ad2", "Fares to San Francisco from 499", "Winter fares are here. Fly to San Francisco, Seattle or Vancouver."),
            ("boiler", "Boiler inspection", "The annual boiler inspection is on the 20th between 9 and 12. No rent change is involved."),
            ("pkg", "Your parcel has shipped", "Tracking number 1Z999. Expected delivery Thursday."), ("gym", "Membership renewal", "Your gym membership renews on 1 March at 39 per month."),
            ("school", "Parent evening", "Teachers will be available from 6 pm on Tuesday in the main hall."), ("car", "Service reminder", "Your car is due for its annual service and tyre rotation next month."),
            ("jmeeting", "来週の打ち合わせについて", "来週の打ち合わせは水曜日の午後3時から、会議室Bで行います。資料は前日までに共有します。"),
            ("jdelivery", "納期のご連絡", "部品の納期は12月10日になります。遅れる場合は改めてご連絡いたします。"),
            ("jparty", "忘年会のお知らせ", "今年の忘年会は12月20日の19時から駅前の居酒屋で開催します。参加費は5,000円です。"),
            ("jrepair", "エアコン修理の日程", "修理業者が金曜日の午前中に伺います。立ち会いをお願いします。"),
            ("jbook", "ご注文の本について", "ご注文いただいた書籍は在庫切れのため、入荷は来月中旬になります。"),
            ("jinvoice", "請求書の送付", "10月分の請求書を添付いたします。お支払い期限は11月30日です。"),
        ] + (0..<40).map { ("news\($0)", "This week: issue \($0)", "Markets, weather and a recipe. Meeting rooms are in short supply across the city, a budget airline adds a route, and rents rise again.") }
          + (0..<15).map { ("jnews\($0)", "今週のニュース第\($0)号", "市場の動き、天気、そして料理のレシピ。会議室が不足し、家賃がまた上がっています。") }
        try index.add(mail.enumerated().map { number, entry in
            IndexedMessage(account: account, mailbox: "inbox", messageID: "\(entry.0)@example.invalid", date: Date(timeIntervalSince1970: 1_794_700_000 - Double(number) * 3_600), sender: "maya@example.invalid",
                           recipients: [], subject: entry.1, sent: false, attachments: 0, text: entry.2)
        })
        let started = Date()
        while try MailEmbedding.step(index: index, embedder: embedder, allowed: [account: ["inbox"]], batch: 50) > 0 {}
        let seconds = Date().timeIntervalSince(started)
        let questions: [(String, String)] = [("When do I have to see the tooth doctor?", "dental"), ("How much will I pay the landlord each month next year?", "lease"), ("Where are we holding the gathering in spring?", "venue"),
            ("What is the confirmation code for my trip to California?", "flight"), ("How do I get online at the cottage?", "wifi"), ("Who repaired the heating at Maya's place?", "plumber"),
            ("What is the new closing date for the funding proposal?", "grant"), ("Where does Maya live now?", "moved"),
            ("次のミーティングは何曜日の何時ですか。", "jmeeting"), ("注文した部品はいつ届きますか。", "jdelivery"), ("年末の飲み会はどこでやりますか。", "jparty"), ("エアコンを直す人はいつ来ますか。", "jrepair"), ("頼んだ本はいつ手に入りますか。", "jbook")]
        var places: [Int] = []
        for (question, answer) in questions {
            guard case .vector(let model, let vector) = embedder.embed(question) else { places.append(99); continue }
            var query = MailSearchQuery(account: account, mailboxes: ["inbox"]); query.limit = 25
            let found = try index.searchByMeaning(query, model: model, vector: vector).map(\.hit.messageID)
            places.append((found.firstIndex(of: "\(answer)@example.invalid") ?? 98) + 1)
        }
        print("REAL-MODEL: \(mail.count) messages embedded in \(String(format: "%.1f", seconds)) s; places of the answers \(places); in the first five: \(places.filter { $0 <= 5 }.count) of \(questions.count); first: \(places.filter { $0 == 1 }.count)")
        XCTAssertGreaterThanOrEqual(places.filter { $0 <= 5 }.count, 10)
    }
}
