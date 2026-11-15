import XCTest
@testable import BridgeCore

/// Owner's decision, 15 November 2026: the search index is encrypted. Inside tests the key is a fixed one of their
/// own, so the owner's Keychain is never touched.
final class MailIndexEncryptionTests: XCTestCase {
    private func index() -> (MailSearchIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crypt-\(UUID().uuidString)", isDirectory: true)
        return (MailSearchIndex(bridgeDirectory: root), root)
    }
    private func message(_ id: String, _ text: String) -> IndexedMessage {
        IndexedMessage(account: "ACCOUNT-1", mailbox: "inbox", messageID: "\(id)@example.invalid", date: Date(timeIntervalSince1970: 1_794_000_000), sender: "Maya Okafor <maya@example.invalid>",
                       recipients: ["owner@example.invalid"], subject: "Venue for the spring meeting", sent: false, attachments: 0, text: text)
    }
    private func bytes(_ index: MailSearchIndex) -> Data {
        ["", "-wal", "-shm"].compactMap { try? Data(contentsOf: URL(fileURLWithPath: index.file.path + $0)) }.reduce(Data(), +)
    }

    func testNothingOfTheMailCanBeReadFromTheFiles() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        try index.add([message("venue", "We will use Harbor Hall. 来週の打ち合わせは水曜日です。 marker-7f3a")])
        var query = MailSearchQuery(account: "ACCOUNT-1", mailboxes: ["inbox"]); query.words = ["harbor hall"]
        XCTAssertEqual(try index.search(query).count, 1, "with its key the index answers")
        query.words = ["打ち合わせ"]
        XCTAssertEqual(try index.search(query).count, 1)
        let disk = bytes(index)
        XCTAssertGreaterThan(disk.count, 1000)
        for plain in ["marker-7f3a", "Harbor Hall", "maya@example.invalid", "Venue for the spring", "SQLite format 3"] {
            XCTAssertNil(disk.range(of: Data(plain.utf8)), "\(plain) is not on disk in the clear")
        }
        XCTAssertNil(disk.range(of: Data("打ち合わせ".utf8)))
    }

    func testAnIndexFromBeforeEncryptionIsReplacedAndTheKeyIsRaw() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        // A plain SQLite file in the index's place, as earlier builds left it.
        try FileManager.default.createDirectory(at: index.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var header = Data("SQLite format 3\u{0}".utf8); header.append(Data(count: 4080))
        try header.write(to: index.file)
        try Data("leftover plain text from before".utf8).write(to: URL(fileURLWithPath: index.file.path + "-wal"))
        XCTAssertEqual(try index.count(account: "ACCOUNT-1"), 0)
        try index.add([message("again", "made anew, encrypted")])
        XCTAssertEqual(try index.count(account: "ACCOUNT-1"), 1)
        XCTAssertNil(bytes(index).range(of: Data("leftover plain text".utf8)), "the plain files are gone")
        XCTAssertNil(bytes(index).range(of: Data("SQLite format 3".utf8)))
        // Raw bytes, so SQLCipher runs no key derivation at each opening.
        XCTAssertEqual(MailIndexKey.pragma(Data([0x00, 0xAB, 0x5A])), "PRAGMA key = \"x'00AB5A'\"")
        XCTAssertEqual(try MailIndexKey.current().count, 32)
    }

    func testAnotherKeyCannotOpenTheIndex() throws {
        let (index, root) = index(); defer { try? FileManager.default.removeItem(at: root) }
        try index.add([message("venue", "We will use Harbor Hall.")])
        let other = try SQLiteDatabase(index.file); defer { other.close() }
        try other.run(MailIndexKey.pragma(Data(repeating: 0x11, count: 32)))
        XCTAssertTrue(other.unreadable(), "a wrong key reads nothing")
        let none = try SQLiteDatabase(index.file); defer { none.close() }
        XCTAssertTrue(none.unreadable(), "nor does no key at all")
        XCTAssertEqual(try index.count(account: "ACCOUNT-1"), 1, "and the index is untouched by the attempts")
    }
}
