import XCTest
import BridgeCore
@testable import BridgeAutomation

@MainActor final class MailUIEditorTests:XCTestCase {
    /// A reply whose quoted mail holds pictures can be reviewed and sent: the live count is what the review
    /// binds, whatever the displayed snapshot said, and a different count at send breaks the review.
    func testReviewBindsTheLiveCountOfPicturesAndFiles() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        for count in [-1,0,3] {
            var expected=binding.snapshot; expected.attachmentCount=count
            let live=try await editor.prepareReview(contextID:"context",token:binding.token,expected:expected)
            XCTAssertEqual(live.attachmentCount,0)
        }
        var withPictures=binding.snapshot; withPictures.attachmentCount=3
        let review=SendReview(draft:withPictures,editorToken:binding.token)
        XCTAssertNoThrow(try review.validate(draft:withPictures,editorToken:binding.token))
        var another=withPictures; another.attachmentCount=4
        XCTAssertThrowsError(try review.validate(draft:another,editorToken:binding.token))
        var unknown=withPictures; unknown.attachmentCount = -1
        XCTAssertThrowsError(try SendReview(draft:unknown,editorToken:binding.token).validate(draft:unknown,editorToken:binding.token))
    }
    func testSendRejectsChangedReviewBeforeCallingNativeDriver() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        let live=try await editor.prepareReview(contextID:"context",token:binding.token,expected:binding.snapshot)
        let review=SendReview(draft:live,editorToken:binding.token)
        var changed=live; changed.body="Later edit"
        do {
            try await editor.send(contextID:"context",token:binding.token,expected:changed,review:review,consume:{_ in XCTFail("Must not consume")})
            XCTFail("Changed reviewed draft must refuse")
        } catch { }
        let count=await driver.sendCalls
        XCTAssertEqual(count,0)
    }
    func testReviewPreflightRequiresCurrentBindingAndExactDraft() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        let live=try await editor.prepareReview(contextID:"context",token:binding.token,expected:binding.snapshot)
        XCTAssertEqual(live.attachmentCount,0); XCTAssertEqual(live.id,-1)
        XCTAssertEqual(live.body,binding.snapshot.body)
        do { _ = try await editor.prepareReview(contextID:"context",token:"replaced",expected:binding.snapshot); XCTFail("Replaced binding must refuse") } catch { }
        await driver.change(stale:true)
        do { _ = try await editor.prepareReview(contextID:"context",token:binding.token,expected:binding.snapshot); XCTFail("Owner edit must refuse") } catch { }
        let state=await driver.state(); XCTAssertEqual(state.inserted,"")
    }
    func testAlreadyAppliedReplyRequiresFreshUnchangedReadback() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        let applied=try await editor.apply("Message\n",contextID:"context",token:binding.token,expected:binding.snapshot)
        try await editor.verifyUnchanged(contextID:"context",token:binding.token,expected:applied)
        await driver.change(stale:true)
        do {
            try await editor.verifyUnchanged(contextID:"context",token:binding.token,expected:applied)
            XCTFail("Cached application must not conceal a later Mail edit")
        } catch { }
        let state=await driver.state()
        XCTAssertEqual(state.body,"Owner edit")
    }
    func testWholeBodySelectionAllowsOnlyOneFinalStructuralLineBreak() throws {
        XCTAssertTrue(MailUIEditPolicy.completeSelection("Message\n",source:"Message\n"))
        XCTAssertTrue(MailUIEditPolicy.completeSelection("Message",source:"Message\n"))
        XCTAssertTrue(MailUIEditPolicy.completeSelection("Message\n",source:"Message\n\n"))
        XCTAssertFalse(MailUIEditPolicy.completeSelection("Message",source:"Message\n\n"))
        XCTAssertFalse(MailUIEditPolicy.completeSelection("Message",source:"Message "))
        XCTAssertFalse(MailUIEditPolicy.completeSelection("Message",source:" Message"))
        XCTAssertFalse(MailUIEditPolicy.completeSelection("",source:"Message\n"))
        XCTAssertFalse(MailUIEditPolicy.completeSelection("Repl",source:"Message\n"))
        XCTAssertFalse(MailUIEditPolicy.completeSelection("e\u{301}",source:"é\n"))
    }
    func testAuthorizationChangeDuringFocusPreventsKeyDispatch() async {
        var allowed=true,typed=false
        do {
            try await MailUIKeyDispatch.perform(identity:{},selection:{},focus:{allowed=false},authorization:{ guard allowed else { throw BridgeFailure("Proposal changed") } },post:{typed=true})
            XCTFail("Must recheck authorization at dispatch")
        } catch { }
        XCTAssertFalse(typed)
    }
    func testFocusChangeDuringIdentityDiscoveryPreventsKeyDispatch() async {
        var focused=true,typed=false
        do {
            try await MailUIKeyDispatch.perform(identity:{focused=false},selection:{},focus:{ guard focused else { throw BridgeFailure("Focus changed") } },post:{typed=true})
            XCTFail("Must check focus after identity discovery")
        } catch { }
        XCTAssertFalse(typed)
    }
    func testUnicodeSegmentationPreservesExactTextAndRejectsControlInput() throws {
        let text="Message 👩🏽‍💻\n日本語 e\u{301}\n"
        XCTAssertEqual(try MailUIEditPolicy.segments(text).joined(),text)
        XCTAssertThrowsError(try MailUIEditPolicy.segments("Wrong\tfield"))
        XCTAssertThrowsError(try MailUIEditPolicy.segments("Null\0text"))
        XCTAssertThrowsError(try MailUIEditPolicy.segments("Attachment\u{fffc}"))
        XCTAssertThrowsError(try MailUIEditPolicy.segments(String(repeating:"x",count:8193)))
    }
    func testActualVisibleReadbackIsRequiredAndKeepsNativeIDUnknown() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        let applied=try await editor.apply("Message\n",contextID:"context",token:binding.token,expected:binding.snapshot)
        XCTAssertEqual(applied.body,"Message\n\n")
        XCTAssertEqual(applied.id,-1); XCTAssertEqual(applied.attachmentCount,-1)
        let state=await driver.state(); XCTAssertEqual(state.inserted,"Message\n")
    }
    func testStaleSourceOrFailedFocusNeverTypes() async throws {
        for stale in [true,false] {
            let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
            let binding=try await editor.bind(contextID:"context",matching:fixture())
            await driver.change(stale:stale,failFocus:!stale)
            do { _ = try await editor.apply("Message",contextID:"context",token:binding.token,expected:binding.snapshot); XCTFail("Must refuse") } catch { }
            let state=await driver.state(); XCTAssertEqual(state.inserted,"")
        }
    }
    func testLostBindingAndWrongReadbackCannotReportSuccess() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        do { _ = try await editor.apply("Message",contextID:"context",token:"unknown",expected:binding.snapshot); XCTFail("Unknown binding") } catch { }
        await driver.change(badReadback:true)
        do { _ = try await editor.apply("Message",contextID:"context",token:binding.token,expected:binding.snapshot); XCTFail("Wrong result") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Inspect Mail")) }
    }
    func testFailedInsertionPutsTheOriginalReplyBackAndSaysSo() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        await driver.change(badReadback:true,canRestore:true)
        do { _ = try await editor.apply("Message",contextID:"context",token:binding.token,expected:binding.snapshot); XCTFail("Wrong result") }
        catch { XCTAssertTrue(error.localizedDescription.contains("put your original message back"),error.localizedDescription) }
        let restores=await driver.restoreCalls; XCTAssertEqual(restores,1)
        let state=await driver.state(); XCTAssertEqual(state.body,"Original\n")
    }
    func testFailedRestorationTellsTheOwnerWhereTheOriginalTextIsKept() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        await driver.change(badReadback:true)
        do { _ = try await editor.apply("Message",contextID:"context",token:binding.token,expected:binding.snapshot); XCTFail("Wrong result") }
        catch { XCTAssertTrue(error.localizedDescription.contains("under This message"),error.localizedDescription) }
    }
    func testInsertingAtTheTopTypesOnlyTheReplyAndLeavesTheQuotedMailAsItIs() async throws {
        let quoted="\n\n2026/11/11 20:00、田中 愛子 <tanaka@example.invalid>のメール:\n\n田中です。\n来週の研究会は木曜日の14時からでよろしいでしょうか。\n"
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        await driver.set(body:quoted)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        let first=try await editor.insertAtTop("木曜日の14時で問題ありません。\n",replacing:"",contextID:"context",token:binding.token,expected:binding.snapshot)
        XCTAssertEqual(first.typed,"木曜日の14時で問題ありません。","only the reply is typed")
        XCTAssertEqual(first.draft.body,"木曜日の14時で問題ありません。"+quoted,"every character of the quoted mail is where it was")
        let typedCount=await driver.state().inserted.count
        XCTAssertEqual(typedCount,first.typed.count,"nothing of the thread was typed")
        // A revision replaces the earlier reply and nothing else.
        let second=try await editor.insertAtTop("金曜日の10時はいかがでしょうか。",replacing:first.typed,contextID:"context",token:binding.token,expected:first.draft)
        XCTAssertEqual(second.draft.body,"金曜日の10時はいかがでしょうか。"+quoted)
        // If the top is no longer what Mail Dot typed, it is the owner's text and is not replaced.
        do { _ = try await editor.insertAtTop("別案",replacing:"もう無い文",contextID:"context",token:binding.token,expected:second.draft); XCTFail("Must refuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer at the top"),error.localizedDescription) }
        let body=await driver.state().body
        XCTAssertEqual(body,"金曜日の10時はいかがでしょうか。"+quoted)
    }
    func testAFailedInsertionAtTheTopSaysTheQuotedMailWasNotTouched() async throws {
        let driver=UIEditFixture(),editor=MailUIReplyEditor(driver:driver)
        let binding=try await editor.bind(contextID:"context",matching:fixture())
        await driver.change(badReadback:true)
        do { _ = try await editor.insertAtTop("Reply",replacing:"",contextID:"context",token:binding.token,expected:binding.snapshot); XCTFail("Wrong result") }
        catch { XCTAssertTrue(error.localizedDescription.contains("quoted mail was not touched"),error.localizedDescription) }
    }
    private func fixture()->MailDraft { MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Original\n",attachmentCount:-1) }
}

private actor UIEditFixture:MailUIEditingDriver {
    var subjectSet:String?
    func setSubject(_ subject:String,contextID:String,token:String) async throws { subjectSet=subject }
    func attachFiles(_ urls:[URL],contextID:String,token:String,expected:MailDraft) async throws -> MailDraft { expected }
    let token=UUID().uuidString
    var sendCalls=0
    func send(contextID:String,token:String,expected:MailDraft,review:SendReview,consume:@Sendable (MailDraft) throws -> Void) throws {
        sendCalls += 1
        throw BridgeFailure("This editing fixture cannot send mail.")
    }
    var draft=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Original\n",attachmentCount:-1)
    var inserted="",selected=false,failFocus=false,badReadback=false,canRestore=false,restoreCalls=0
    var remainder="",selectedTop:String?
    func selectTop(contextID:String,token:String,expected:MailDraft,replacing previous:String) throws {
        guard token == self.token,draft.fingerprint == expected.fingerprint,!failFocus,draft.body.hasPrefix(previous) else { throw BridgeFailure("Stale source or focus") }
        selected=true; inserted=""; selectedTop=previous; remainder=String(draft.body.dropFirst(previous.count))
    }
    func set(body:String) { draft.body=body }
    func requestSave(contextID:String,token:String) -> Bool { true }
    func restoreOriginal(contextID:String,token:String) -> Bool {
        restoreCalls += 1
        guard canRestore else { return false }
        draft.body="Original\n"; return true
    }
    func bind(contextID:String,matching envelope:MailDraft) throws -> MailUIReplyBinding { MailUIReplyBinding(token:token,snapshot:draft) }
    func selectBody(contextID:String,token:String,expected:MailDraft) throws {
        guard token == self.token,draft.fingerprint == expected.fingerprint,!failFocus else { throw BridgeFailure("Stale source or focus") }
        selected=true; inserted=""; remainder=""; selectedTop=nil
    }
    func insert(_ text:String,contextID:String,token:String,authorize:@Sendable () throws -> Void) throws { try authorize(); guard selected else { throw BridgeFailure("No selection") }; inserted += text }
    func readback(contextID:String,token:String,matching envelope:MailDraft) throws -> MailDraft {
        if selected { draft.body=badReadback ? "Incorrect result" : selectedTop == nil ? inserted+"\n" : inserted+remainder; selected=false }
        return draft
    }
    func state()->(inserted:String,body:String) { (inserted,draft.body) }
    func reviewSnapshot(contextID:String,token:String,expected:MailDraft) throws -> MailDraft {
        guard token == self.token else { throw BridgeFailure("Lost binding") }
        var result=draft; result.attachmentCount=0; return result
    }
    func change(stale:Bool=false,failFocus:Bool=false,badReadback:Bool=false,canRestore:Bool=false) { if stale { draft.body="Owner edit" }; self.failFocus=failFocus; self.badReadback=badReadback; self.canRestore=canRestore }
}
