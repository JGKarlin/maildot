import XCTest
@testable import BridgeAutomation

/// Owner's report, 18 November 2026: a reply reopened from Drafts could not be read, because Mail had no window, or
/// more than one, titled with its subject, and Mail Dot asked him to close windows.
final class ComposeWindowChoiceTests: XCTestCase {
    private typealias C = ComposeWindowChoice.Candidate
    private func choose(_ windows: [C], _ subject: String, compose: Set<Int> = [], asked: inout Int) -> Int? {
        var count = 0
        let chosen = ComposeWindowChoice.choose(windows, subject: subject) { count += 1; return compose.contains($0) }
        asked = count
        return chosen
    }

    func testOneWindowWithTheSubjectIsTakenWithoutLookingFurther() {
        var asked = 0
        let windows = [C(title: "Inbox", isMain: true, isBound: false), C(title: "Re: Congratulations!", isMain: false, isBound: false)]
        XCTAssertEqual(choose(windows, "Re: Congratulations!", asked: &asked), 1)
        XCTAssertEqual(asked, 0, "the title settles it")
    }

    func testTwoWindowsWithTheSameTitleAreToldApartByTheSendButton() {
        var asked = 0
        // The message being answered is open in a window of its own, with the same title as the reply.
        let windows = [C(title: "All Drafts", isMain: false, isBound: false), C(title: "Re: Congratulations!", isMain: false, isBound: false), C(title: "Re: Congratulations!", isMain: true, isBound: false)]
        XCTAssertEqual(choose(windows, "Re: Congratulations!", compose: [2], asked: &asked), 2)
        XCTAssertEqual(asked, 2, "only the two with the title are looked at")
    }

    func testTwoDraftsWithTheSameSubjectTheOneInFrontIsTaken() {
        var asked = 0
        let windows = [C(title: "Re: Congratulations!", isMain: false, isBound: false), C(title: "Re: Congratulations!", isMain: true, isBound: false)]
        XCTAssertEqual(choose(windows, "Re: Congratulations!", compose: [0, 1], asked: &asked), 1, "where the owner opened the Mail Dot panel")
        let neither = [C(title: "Re: Congratulations!", isMain: false, isBound: false), C(title: "Re: Congratulations!", isMain: false, isBound: false)]
        XCTAssertNil(choose(neither, "Re: Congratulations!", compose: [0, 1], asked: &asked), "never a guess between two")
    }

    func testNoWindowWithTheSubjectTheOneMessageBeingWrittenIsTaken() {
        var asked = 0
        let windows = [C(title: "All Drafts", isMain: true, isBound: false), C(title: "Congratulations", isMain: false, isBound: false)]
        XCTAssertEqual(choose(windows, "Re: Congratulations!", compose: [1], asked: &asked), 1)
        XCTAssertNil(choose(windows, "Re: Congratulations!", compose: [], asked: &asked), "a viewer is never taken for the message")
    }

    func testTheWindowBoundBeforeIsKeptWhateverItsTitleNow() {
        var asked = 0
        let windows = [C(title: "Re: Congratulations!", isMain: true, isBound: false), C(title: "A new subject", isMain: false, isBound: true)]
        XCTAssertEqual(choose(windows, "Re: Congratulations!", asked: &asked), 1)
        XCTAssertEqual(asked, 0)
    }

    func testANewMessageWithoutASubjectIsTheWindowInFront() {
        var asked = 0
        let windows = [C(title: "Inbox", isMain: false, isBound: false), C(title: "New Message", isMain: true, isBound: false)]
        XCTAssertEqual(choose(windows, "", asked: &asked), 1)
    }
}
