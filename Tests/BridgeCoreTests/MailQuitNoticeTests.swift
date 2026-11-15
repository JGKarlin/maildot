import XCTest
@testable import BridgeCore

final class MailQuitNoticeTests: XCTestCase {
    func testMailsRefusalLineIsRecognised() {
        // The line Mail wrote on 15 November 2026 when the Dock's Quit was turned down with the Mail Dot window open.
        let line="2026-11-15 15:34:42.751 Df Mail[82536:1efbec] [com.apple.AppKit:Application] Failed responder chain validation for terminate: action. Canceling termination."
        XCTAssertTrue(MailQuitNotice.isRefusal(line))
    }
    func testOtherLinesAreIgnored() {
        XCTAssertFalse(MailQuitNotice.isRefusal(#"Filtering the log data using "process == "Mail" AND composedMessage CONTAINS "Canceling termination"""#))
        XCTAssertFalse(MailQuitNotice.isRefusal("2026-11-15 15:54:23.689 Df Mail[92666:1fe9d8] [com.apple.AppKit:Application] App termination approved"))
        XCTAssertFalse(MailQuitNotice.isRefusal("2026-11-15 15:34:42.751 Df Notes[1:2] [com.apple.AppKit:Application] Canceling termination."))
    }
    func testAClickOnAnotherMailWindowClosesTheMailDotWindow() {
        let mailWindow=OutsideClick.Target(owner:100,layer:0,onStandardMailWindow:true)
        XCTAssertTrue(OutsideClick.closes(mailWindow,mail:100,mailDotWindowOpen:true))
        XCTAssertFalse(OutsideClick.closes(mailWindow,mail:100,mailDotWindowOpen:false))
        // Another app, a menu, and the Mail Dot dialog or its popovers leave it open.
        XCTAssertFalse(OutsideClick.closes(.init(owner:200,layer:0,onStandardMailWindow:false),mail:100,mailDotWindowOpen:true))
        XCTAssertFalse(OutsideClick.closes(.init(owner:100,layer:101,onStandardMailWindow:true),mail:100,mailDotWindowOpen:true))
        XCTAssertFalse(OutsideClick.closes(.init(owner:100,layer:0,onStandardMailWindow:false),mail:100,mailDotWindowOpen:true))
        XCTAssertEqual(OutsideClick.flipped(CGPoint(x:10,y:100),mainScreenHeight:900),CGPoint(x:10,y:800))
    }
}
