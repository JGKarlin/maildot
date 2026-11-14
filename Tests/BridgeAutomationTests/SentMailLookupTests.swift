import XCTest
@testable import BridgeAutomation

final class SentMailLookupTests:XCTestCase {
    func testOnlyTheOwnersOwnOpeningIsKeptNotTheQuotedMail() {
        XCTAssertEqual(SentMailLookup.opening("Hi Sam,\nThursday works.\n\nOn Monday, Sam wrote:\n> Shall we meet?"),"Hi Sam,\nThursday works.")
        XCTAssertEqual(SentMailLookup.opening("田中様、\n\nお世話になっております。\n\n2026年11月11日(水) 田中のメッセージ:\n> 本文"),"田中様、\n\nお世話になっております。")
        XCTAssertLessThanOrEqual(SentMailLookup.opening(String(repeating:"a",count:2000)).count,500)
    }
}
