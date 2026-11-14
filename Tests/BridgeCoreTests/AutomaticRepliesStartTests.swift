import XCTest
@testable import BridgeCore

final class AutomaticRepliesStartTests:XCTestCase {
    private func settings() -> MailSettings {
        var value=MailSettings()
        value.nativeAccounts=[NativeMailAccount(id:"icloud",name:"iCloud",addresses:["owner@icloud.example.invalid"],server:"imap.example.invalid")]
        value.connections=[MailConnection(id:"g1",email:"owner@gmail.example.invalid",connectionID:"c1")]
        return value
    }

    func testAnAccountOnByDefaultStartsCountingWhenFirstSeen() {
        var value=settings()
        XCTAssertNil(value.automaticRepliesStart(forRecipients:["owner@icloud.example.invalid"]),"nothing is drafted before a start is recorded")
        let seen=Date(timeIntervalSince1970:1_000_000)
        XCTAssertTrue(value.stampAutomaticReplies(now:seen))
        XCTAssertFalse(value.stampAutomaticReplies(now:seen.addingTimeInterval(60)),"stamped once")
        XCTAssertEqual(value.automaticRepliesStart(forRecipients:["owner@icloud.example.invalid"]),seen)
    }

    func testTurningTheSwitchOnStartsFromThatMomentAndOffClearsIt() {
        var value=settings()
        let first=Date(timeIntervalSince1970:1_000_000),later=first.addingTimeInterval(3600)
        value.stampAutomaticReplies(now:first)
        value.setAutomaticReplies(false,account:"mail:icloud",now:first.addingTimeInterval(10))
        XCTAssertNil(value.automaticRepliesSince?["mail:icloud"])
        XCTAssertFalse(value.stampAutomaticReplies(now:later),"an account switched off is not stamped")
        value.setAutomaticReplies(true,account:"mail:icloud",now:later)
        XCTAssertEqual(value.automaticRepliesStart(forRecipients:["owner@icloud.example.invalid"]),later,"mail before this moment is never drafted automatically")
        value.setAutomaticReplies(true,account:"mail:icloud",now:later.addingTimeInterval(99))
        XCTAssertEqual(value.automaticRepliesSince?["mail:icloud"],later,"switching on what is already on changes nothing")
    }

    func testMailToSeveralAccountsCountsFromTheLatestStart() {
        var value=settings()
        let early=Date(timeIntervalSince1970:1_000_000),late=early.addingTimeInterval(500)
        value.stampAutomaticReplies(now:early)
        value.setAutomaticReplies(false,account:"gmail:g1"); value.setAutomaticReplies(true,account:"gmail:g1",now:late)
        XCTAssertEqual(value.automaticRepliesStart(forRecipients:["owner@icloud.example.invalid","owner@gmail.example.invalid"]),late)
        XCTAssertEqual(value.automaticRepliesStart(forRecipients:["someone@else.example.invalid"]),early,"an unknown account uses the earliest start")
    }

    func testOlderMailIsHeldWithItsReasonAndCanStillBeAskedAbout() throws {
        var state=MailTriageState()
        let entry=MailTriageEntry(messageID:"<old@example.invalid>",sender:"a@example.invalid",senderName:nil,subject:"Old",receivedAt:Date(),
                                  verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)
        state.record(entry)
        state.hold(entry.id,older:true)
        let held=try XCTUnwrap(state.entries.first{$0.id == entry.id})
        XCTAssertEqual(held.outcome,.held)
        XCTAssertEqual(held.stateLine,"Not offered: it arrived before automatic replies were turned on.")
        try state.ask(entry.id)
        XCTAssertEqual(state.entries.first{$0.id == entry.id}?.outcome,.pending,"Ask Dot still works")
    }

    func testSettingsSavedBeforeTheStartTimesStillLoad() throws {
        var old=try XCTUnwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(settings())) as? [String:Any])
        old.removeValue(forKey:"automaticRepliesSince")
        let loaded=try JSONDecoder().decode(MailSettings.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertNil(loaded.automaticRepliesSince)
    }

    func testMailDotOffLeavesTheAccountAloneAndBackOnStartsAutomaticRepliesAfresh() throws {
        var value=settings()
        let first=Date(timeIntervalSince1970:1_000_000),later=first.addingTimeInterval(7200)
        value.stampAutomaticReplies(now:first)
        value.setMailDot(false,account:"mail:icloud")
        XCTAssertFalse(value.mailDot(forRecipients:["owner@icloud.example.invalid"]))
        XCTAssertTrue(value.mailDot(forRecipients:["owner@icloud.example.invalid","owner@gmail.example.invalid"]),"another receiving account still has it on")
        XCTAssertFalse(value.automaticReplies(forRecipients:["owner@icloud.example.invalid"]),"Automatic replies do nothing while Mail Dot is off")
        var native=NativeMailState()
        try NativeMailCoordinator.authorize(accountID:"icloud",mailboxes:[NativeMailbox(accountID:"icloud",path:["Inbox"])],state:&native)
        native.grants[0].verifiedAt=first
        XCTAssertFalse(try MailWorkflowAccount.available(settings:value,native:native).contains{$0.id == "mail:icloud"},"Dot is not given the account")
        value.setMailDot(true,account:"mail:icloud",now:later)
        XCTAssertTrue(try MailWorkflowAccount.available(settings:value,native:native).contains{$0.id == "mail:icloud"})
        XCTAssertEqual(value.automaticRepliesStart(forRecipients:["owner@icloud.example.invalid"]),later,"mail that came while it was off is never drafted")
        XCTAssertNil(value.mailDotOff)
        try value.validate()
    }
}
