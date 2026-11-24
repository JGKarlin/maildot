import XCTest
@testable import BridgeCore

/// Ask Dot keeps the owner's filters between openings and restarts, and Reset forgets them (owner request, 24 November 2026).
final class AskDotRememberedFiltersTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AskDotRememberedFiltersTests." + UUID().uuidString
        let made = UserDefaults(suiteName: name)!
        made.removePersistentDomain(forName: name)
        return made
    }

    func testFiltersLeftAreTheFiltersFoundNextTime() {
        let store = defaults()
        var filters = AskDot.RememberedFilters()
        filters.accounts = ["gmail:g1"]; filters.period = .custom
        filters.customFrom = Date(timeIntervalSince1970: 1_790_000_000); filters.customTo = Date(timeIntervalSince1970: 1_790_500_000)
        filters.direction = .received; filters.person = "Aiko"; filters.attachmentsOnly = true
        filters.save(to: store)
        XCTAssertEqual(AskDot.RememberedFilters.load(from: store), filters)
    }

    func testResetForgetsTheKeptFilters() {
        let store = defaults()
        var filters = AskDot.RememberedFilters()
        filters.direction = .sent
        filters.save(to: store)
        XCTAssertNotNil(AskDot.RememberedFilters.load(from: store))
        AskDot.RememberedFilters().save(to: store)
        XCTAssertNil(AskDot.RememberedFilters.load(from: store), "filters that narrow nothing are not kept")
        XCTAssertNil(store.data(forKey: AskDot.RememberedFilters.key))
    }

    func testABlankPersonNarrowsNothing() {
        var filters = AskDot.RememberedFilters()
        filters.person = "   "
        XCTAssertTrue(filters.isEmpty)
    }

    func testUnreadableFiltersAreNone() {
        let store = defaults()
        store.set(Data("not filters".utf8), forKey: AskDot.RememberedFilters.key)
        XCTAssertNil(AskDot.RememberedFilters.load(from: store))
    }
}
