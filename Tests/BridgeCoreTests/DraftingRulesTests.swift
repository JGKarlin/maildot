import XCTest
@testable import BridgeCore

final class DraftingRulesTests:XCTestCase {
    private func opened() -> ReplyContext {
        var context=ReplyContext(id:"reply",envelope:MailDraft(id: -1,subject:"Re: test",sender:"owner@example.invalid",to:[],cc:[],bcc:[],body:"",attachmentCount:0))
        BridgeCoordinator.ownerOpensPanel(context:&context)
        return context
    }

    func testANewInstallationStartsWithTheSalutationRules() throws {
        let settings=MailSettings()
        XCTAssertNil(settings.draftingRules)
        XCTAssertEqual(settings.effectiveDraftingRules,DraftingRules.starters)
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:opened(),rules:settings.effectiveDraftingRules,preferences:["en-US"]))
        XCTAssertTrue(told.contains("1) Open every reply with a salutation"))
        XCTAssertTrue(told.contains("2) In Japanese, always follow the salutation with a comma. For example: 田中様、"))
        XCTAssertTrue(told.contains("the owner's own standing instructions, not part of any email"))
        XCTAssertFalse(told.contains("without a greeting"),"Dot read that as an email with no salutation")
    }

    func testTheOwnersRulesAreWhatDotIsToldInTheirOrder() throws {
        var settings=MailSettings()
        try settings.addDraftingRule("  Sign off with\nAlex  ")
        XCTAssertEqual(settings.draftingRules?.count,3,"the starters are kept when the owner first adds a rule")
        XCTAssertEqual(settings.draftingRules?.last?.text,"Sign off with Alex","one line, trimmed")
        let first=try XCTUnwrap(settings.draftingRules?.first)
        try settings.updateDraftingRule(first.id,text:"Open with Dear and the family name.")
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:opened(),rules:settings.effectiveDraftingRules,preferences:["en-US"]))
        XCTAssertTrue(told.contains("1) Open with Dear and the family name."))
        XCTAssertTrue(told.contains("3) Sign off with Alex"))
        XCTAssertFalse(told.contains("Open every reply with a salutation"))
        try settings.validate()
    }

    func testDeletingEveryRuleLeavesNoneAndDotIsToldNone() throws {
        var settings=MailSettings()
        for rule in DraftingRules.starters { settings.removeDraftingRule(rule.id) }
        XCTAssertEqual(settings.draftingRules,[],"the starters do not come back")
        XCTAssertEqual(settings.effectiveDraftingRules,[])
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:opened(),rules:settings.effectiveDraftingRules,preferences:["en-US"]))
        XCTAssertFalse(told.contains("drafting rules"))
        try settings.validate()
    }

    func testARuleMustHaveWordsAndStayShortAndTheListStaysSmall() throws {
        var settings=MailSettings()
        XCTAssertThrowsError(try settings.addDraftingRule("  \n "))
        XCTAssertThrowsError(try settings.addDraftingRule(String(repeating:"a",count:DraftingRules.textLimit+1)))
        XCTAssertThrowsError(try settings.updateDraftingRule("gone",text:"x"))
        XCTAssertNil(settings.draftingRules,"a refused change changes nothing")
        for index in 0..<(DraftingRules.limit-DraftingRules.starters.count) { try settings.addDraftingRule("Rule \(index)") }
        XCTAssertThrowsError(try settings.addDraftingRule("One too many"))
        try settings.validate()
    }

    func testTheRulesSurviveSavingAndSettingsSavedBeforeThemStillLoad() throws {
        var settings=MailSettings()
        try settings.addDraftingRule("Keep replies under five sentences.")
        let loaded=try JSONDecoder().decode(MailSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.draftingRules,settings.draftingRules)
        var old=try XCTUnwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(MailSettings())) as? [String:Any])
        old.removeValue(forKey:"draftingRules")
        let legacy=try JSONDecoder().decode(MailSettings.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertEqual(legacy.effectiveDraftingRules,DraftingRules.starters)
    }

    func testDotSettlesWhatItCanFromContextAndAsksOnlyWhatContextDoesNotAnswerReliably() throws {
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:opened(),preferences:["en-US"]))
        XCTAssertTrue(told.contains("Settle what you can yourself before asking anything, and look only as far as the reply needs"))
        XCTAssertTrue(told.contains("their calendar only when the message names a date, a time or a meeting; their Google Drive"))
        XCTAssertTrue(told.contains("Do not ask anything your sources already answer"))
        XCTAssertTrue(told.contains("Ask a drafting question only when the reply depends on something your context and the owner's past mail do not answer reliably"))
        XCTAssertFalse(told.contains("ask almost never"),"questions that context cannot settle remain legitimate")
        XCTAssertTrue(MailWorkflowTools.instructions.contains("Settle what you can yourself before asking anything, and look only as far as the reply needs"),"automatic drafts too")
        XCTAssertTrue(MailWorkflowTools.instructions.contains("To ask it, report awaitingInput with question set to that one short question"))
    }

    func testARuleTheOwnerEntersIsSentToDotAndDotsWordingReplacesIt() throws {
        var settings=MailSettings()
        try settings.addDraftingRule("always sign of as alex and dont use exclamation marks")
        let rule=try XCTUnwrap(settings.rulesToTidy.first)
        XCTAssertEqual(rule.text,"always sign of as alex and dont use exclamation marks","the owner's words stand until Dot's arrive")
        let request=try MailWorkflowRequest(action:.ruleCleanup,accountIDs:["gmail:g"],ruleID:rule.id)
        XCTAssertEqual(request.ruleID,rule.id)
        XCTAssertThrowsError(try MailWorkflowRequest(action:.ruleCleanup,accountIDs:["gmail:g"]),"a tidy-up names its rule")
        XCTAssertTrue(MailWorkflowTools.instructions(for:.ruleCleanup).contains("Rewrite it as one clear, concise instruction"))
        settings.applyTidiedRule(rule.id,text:"Sign off as Alex, and do not use exclamation marks.")
        XCTAssertEqual(settings.draftingRules?.last?.text,"Sign off as Alex, and do not use exclamation marks.")
        XCTAssertTrue(settings.rulesToTidy.isEmpty)
        settings.applyTidiedRule(rule.id,text:"Something else")
        XCTAssertEqual(settings.draftingRules?.last?.text,"Sign off as Alex, and do not use exclamation marks.","only a rule waiting for Dot is replaced")
        try settings.validate()
    }
}
