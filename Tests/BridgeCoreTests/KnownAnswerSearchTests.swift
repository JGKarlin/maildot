import XCTest
@testable import BridgeCore

/// Known-answer questions against an invented mailbox (Ask Dot review, 15 November 2026). Each question has one
/// message that answers it and the searches Dot would plausibly make, in order: the obvious words first, then
/// alternatives. The test counts how many searches it takes for the answering message to appear among the first
/// five hits. Every name and address is invented.
final class KnownAnswerSearchTests: XCTestCase {
    private let account = "ACCOUNT-1"
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_794_700_000)   // mid-November 2026
    private var serial = 0
    private var corpus: [IndexedMessage] = []

    private func add(_ id: String, daysAgo: Double, from sender: String, _ subject: String, _ text: String, to: [String] = ["owner@example.invalid"], sent: Bool = false, attachments: Int = 0) {
        corpus.append(IndexedMessage(account: account, mailbox: sent ? "sent" : "inbox", messageID: "\(id)@example.invalid", date: now.addingTimeInterval(-daysAgo * day), sender: sender,
                                     recipients: to, subject: subject, sent: sent, attachments: attachments, text: text))
    }
    private func build() {
        let maya = "Maya Okafor <maya@example.invalid>", tomas = "Tomás Rey <tomas@example.invalid>", yuki = "佐藤 由紀 <yuki@example.invalid>"
        let owner = "Owner <owner@example.invalid>", clinic = "Harbor Dental <frontdesk@clinic.example.invalid>", landlord = "Elm Street Property <office@elm.example.invalid>"
        // The answers.
        add("dental", daysAgo: 6, from: clinic, "Appointment confirmation", "This confirms your cleaning with Dr. Ito on 3 December at 14:30. Please arrive ten minutes early.")
        add("lease", daysAgo: 40, from: landlord, "Lease renewal terms", "The rent for the renewed term will be 1,450 per month from 1 February. Please sign and return the attached agreement by 15 January.", attachments: 1)
        add("venue", daysAgo: 12, from: maya, "Re: Spring meeting", "After comparing the three options we will use Harbor Hall. The deposit is due at the end of the month.\n\nOn Nov 1, 2026, at 9:00, Owner wrote:\n> Which venue did you settle on? Riverside Lodge looked good.")
        add("budget-sent", daysAgo: 9, from: owner, "Re: Q4 budget", "I approve the revised budget of 82,000, on the condition that travel stays under 9,000.", to: ["tomas@example.invalid"], sent: true)
        add("flight", daysAgo: 20, from: "Skyline Air <no-reply@skyline.example.invalid>", "Your itinerary: OSA to SFO", "Booking reference QX7RLM. Departure 14 January 17:05 from Osaka Kansai, arrival 10:40 San Francisco. Seat 23A.")
        add("jp-meeting", daysAgo: 4, from: yuki, "来週の打ち合わせについて", "来週の打ち合わせは水曜日の午後3時から、会議室Bで行います。資料は前日までに共有します。")
        add("jp-invoice", daysAgo: 15, from: yuki, "請求書の送付", "10月分の請求書を添付いたします。お支払い期限は11月30日です。金額は税込で132,000円です。", attachments: 1)
        add("password", daysAgo: 2, from: tomas, "Wi-Fi at the cabin", "The network is called Pinecone and the passphrase is on the fridge. The router sits behind the bookshelf if it needs a restart.")
        add("recommend", daysAgo: 70, from: maya, "A plumber who actually shows up", "You asked who fixed our boiler: it was Idris at Northside Heating, 555-0142. Fair price and he came the same day.")
        add("deadline", daysAgo: 30, from: tomas, "Grant application", "The foundation moved the submission date: proposals are now due 5 December, not the 12th. The page limit is unchanged.")
        add("old-address", daysAgo: 400, from: maya, "We moved!", "Our new address is 18 Larch Lane, Apartment 4. The housewarming will be some time in the spring.")
        add("jp-short", daysAgo: 8, from: yuki, "納期のご連絡", "部品の納期は12月10日になります。遅れる場合は改めてご連絡いたします。")
        // Mail that shares words with the answers without answering.
        add("dental-ad", daysAgo: 3, from: "Bright Smiles <news@smiles.example.invalid>", "Whitening offer this month", "Book any appointment this month and get whitening at half price.")
        add("venue-q", daysAgo: 14, from: owner, "Spring meeting", "Which venue did you settle on? Riverside Lodge looked good.", to: ["maya@example.invalid"], sent: true)
        add("budget-ask", daysAgo: 10, from: tomas, "Q4 budget", "Here is the revised budget. Can you approve it by Friday? Travel is the line I am least sure of.", attachments: 1)
        add("budget-old", daysAgo: 100, from: tomas, "Q3 budget", "The third quarter closed at 77,400, slightly under plan.")
        add("flight-ad", daysAgo: 5, from: "Skyline Air <offers@skyline.example.invalid>", "Fares to San Francisco from 499", "Winter fares are here. Fly to San Francisco, Seattle or Vancouver.")
        add("lease-note", daysAgo: 45, from: landlord, "Boiler inspection", "The annual boiler inspection is on the 20th between 9 and 12. No rent change is involved.")
        add("jp-meeting-old", daysAgo: 35, from: yuki, "先月の打ち合わせの議事録", "先月の打ち合わせの議事録を共有します。次回の日程は別途ご連絡します。")
        add("jp-invoice-old", daysAgo: 46, from: yuki, "請求書の送付", "9月分の請求書を添付いたします。お支払い期限は10月31日です。", attachments: 1)
        add("grant-old", daysAgo: 60, from: tomas, "Grant application", "Proposals are due 12 December. The page limit is fifteen.")
        for index in 0..<60 {
            add("news-\(index)", daysAgo: Double(index) + 0.5, from: "Weekly Digest <digest@news.example.invalid>", "This week: issue \(index)",
                "Markets, weather and a recipe. Meeting rooms are in short supply across the city, a budget airline adds a route, and rents rise again. Issue \(index).")
        }
    }
    private struct Question {
        let asks: String
        let answer: String
        /// The searches in the order Dot would try them.
        let searches: [(words: [String], person: String?, direction: MailSearchQuery.Direction, since: Double?, attachments: Bool)]
    }
    private func search(_ words: [String], person: String? = nil, _ direction: MailSearchQuery.Direction = .both, sinceDaysAgo: Double? = nil, attachments: Bool = false)
        -> (words: [String], person: String?, direction: MailSearchQuery.Direction, since: Double?, attachments: Bool) { (words, person, direction, sinceDaysAgo, attachments) }

    func testTwelveQuestionsAreAnsweredWithinTwoSearchesAndMostWithinOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("known-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        build()
        let index = MailSearchIndex(bridgeDirectory: root)
        try index.add(corpus)
        let questions = [
            Question(asks: "When is my dentist appointment?", answer: "dental", searches: [search(["dentist", "appointment"]), search(["dental", "cleaning"])]),
            Question(asks: "What will the rent be after the renewal?", answer: "lease", searches: [search(["rent", "renewal", "lease"])]),
            Question(asks: "Which venue did Maya choose for the spring meeting?", answer: "venue", searches: [search(["venue", "spring meeting"], person: "maya", .received)]),
            Question(asks: "What did I tell Tomás about the budget?", answer: "budget-sent", searches: [search(["budget"], person: "tomas", .sent)]),
            Question(asks: "What is my booking reference for the San Francisco flight?", answer: "flight", searches: [search(["booking reference", "San Francisco", "itinerary"])]),
            Question(asks: "来週の打ち合わせはいつですか。", answer: "jp-meeting", searches: [search(["打ち合わせ", "来週"])]),
            Question(asks: "10月分の請求書の支払い期限は？", answer: "jp-invoice", searches: [search(["請求書", "10月分", "支払い期限"])]),
            Question(asks: "What is the Wi-Fi password at the cabin?", answer: "password", searches: [search(["wifi password", "cabin"]), search(["Wi-Fi", "passphrase", "network"])]),
            Question(asks: "Who was the plumber Maya recommended?", answer: "recommend", searches: [search(["plumber"], person: "maya")]),
            Question(asks: "When is the grant application due now?", answer: "deadline", searches: [search(["grant", "due", "deadline"], sinceDaysAgo: 45)]),
            Question(asks: "What is Maya's new address?", answer: "old-address", searches: [search(["new address", "moved"], person: "maya")]),
            Question(asks: "部品の納期はいつ？", answer: "jp-short", searches: [search(["納期", "部品"])]),
        ]
        var taken: [Int] = []
        for question in questions {
            var found: Int?
            for (attempt, tried) in question.searches.enumerated() {
                var query = MailSearchQuery(account: account, mailboxes: ["inbox", "sent"])
                query.words = tried.words; query.person = tried.person; query.direction = tried.direction; query.hasAttachments = tried.attachments
                if let since = tried.since { query.since = now.addingTimeInterval(-since * day) }
                let hits = try index.search(query)
                if hits.prefix(5).contains(where: { $0.messageID == "\(question.answer)@example.invalid" }) { found = attempt + 1; break }
            }
            XCTAssertNotNil(found, "not found: \(question.asks)")
            taken.append(found ?? 99)
        }
        let first = taken.filter { $0 == 1 }.count
        print("KNOWN-ANSWER: \(questions.count) questions, \(first) answered by the first search, \(taken.filter { $0 <= 2 }.count) within two; searches per question \(taken)")
        XCTAssertEqual(taken.filter { $0 <= 2 }.count, questions.count)
        XCTAssertGreaterThanOrEqual(first, 10)
    }

    func testTheAnsweringPassageIsInTheHitSoNoReadIsNeeded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("known-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        build()
        let index = MailSearchIndex(bridgeDirectory: root)
        try index.add(corpus)
        var query = MailSearchQuery(account: account, mailboxes: ["inbox", "sent"])
        query.words = ["venue", "spring meeting"]; query.person = "maya"; query.direction = .received
        let hit = try XCTUnwrap(try index.search(query).first)
        XCTAssertTrue(hit.passage.contains("Harbor Hall"))
        XCTAssertFalse(hit.passage.contains("Riverside Lodge"), "the question quoted beneath the reply is not part of the reply")
        query = MailSearchQuery(account: account, mailboxes: ["inbox", "sent"]); query.words = ["納期"]
        XCTAssertTrue(try XCTUnwrap(try index.search(query).first).passage.contains("12月10日"))
    }
}
