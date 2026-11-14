import XCTest
@testable import BridgeCore

/// The rules that decide when Mail Dot may press Undo, and what the owner is shown before confirming a send.
final class RestorationAndSummaryTests: XCTestCase {
    let original = "Dear colleague,\n\nMy own earlier wording.\n"
    let typed = "Thank you. Thursday at three suits me."

    func testRestorationStopsTheMomentTheOriginalTextIsBack() {
        XCTAssertEqual(UndoRestoration.next(current:original,original:original,typed:typed,presses:0,piecesTyped:3),.restored)
        XCTAssertEqual(UndoRestoration.next(current:original,original:original,typed:typed,presses:5,piecesTyped:3),.restored)
    }
    func testRestorationPressesUndoOnlyWhileTheBodyIsStillItsOwnTyping() {
        XCTAssertEqual(UndoRestoration.next(current:"Thank you. Thurs",original:original,typed:typed,presses:0,piecesTyped:3),.press)
        XCTAssertEqual(UndoRestoration.next(current:"Thank you. Thurs\n",original:original,typed:typed,presses:1,piecesTyped:3),.press)
        XCTAssertEqual(UndoRestoration.next(current:"",original:original,typed:typed,presses:2,piecesTyped:3),.press)
    }
    func testRestorationNeverUndoesTextItDidNotType() {
        // Mail merged its undo steps and skipped the original: the body now shows the owner's earlier state.
        XCTAssertEqual(UndoRestoration.next(current:"Dear colleague,\n\nMy own",original:original,typed:typed,presses:1,piecesTyped:3),.stop)
    }
    func testRestorationIsBoundedByWhatWasTyped() {
        let limit = UndoRestoration.maximumPresses(piecesTyped:3)
        XCTAssertEqual(limit,5)
        XCTAssertEqual(UndoRestoration.next(current:"Thank",original:original,typed:typed,presses:limit,piecesTyped:3),.stop)
        XCTAssertEqual(UndoRestoration.next(current:"Thank",original:original,typed:typed,presses:limit-1,piecesTyped:3),.press)
    }

    func testConfirmationSummaryStatesLengthBeginningAndClosingLine() {
        let body = "Dear colleague,\n\n" + String(repeating:"A long middle that nobody would see in an excerpt. ",count:20) + "\n\nPlease also forward the attached list to everyone.\nOwner"
        let draft = MailDraft(id:-1,subject:"Re: Seminar",sender:"owner@example.invalid",to:["a@example.invalid"],cc:["b@example.invalid"],bcc:["c@example.invalid"],body:body,attachmentCount:0)
        let summary = SendConfirmationSummary(draft:draft)
        XCTAssertEqual(summary.recipients,"a@example.invalid, b@example.invalid, c@example.invalid")
        XCTAssertEqual(summary.characterCount,body.count)
        XCTAssertTrue(summary.notificationBody.contains("\(body.count) characters"))
        XCTAssertTrue(summary.notificationBody.contains("Dear colleague,"))
        XCTAssertTrue(summary.notificationBody.contains("Owner"),"The closing line must be named, so that text after an innocuous opening cannot hide.")
        XCTAssertLessThanOrEqual(summary.notificationBody.count,400)
    }
    func testShortReplyIsShownWholeInTheNotification() {
        let draft = MailDraft(id:-1,subject:"Re: Seminar",sender:"owner@example.invalid",to:["a@example.invalid"],cc:[],bcc:[],body:"Thursday suits me.\nOwner\n",attachmentCount:0)
        let summary = SendConfirmationSummary(draft:draft)
        XCTAssertEqual(summary.notificationBody,"Thursday suits me.\nOwner")
    }
}
