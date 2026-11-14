import XCTest
import BridgeCore
@testable import BridgeAutomation

@MainActor final class MailReplyActionsTests:XCTestCase {
    func testOmittedVisibleQuotePreventsApplyReviewAndSend() async throws {
        let expected=fixture(body:"")
        let script=ActionFixtureScript(draft:expected)
        let visible=ActionFixtureReader(body:"Visible quotation")
        let actions=MailReplyActions(scripting:script,reader:visible)
        do { _ = try await actions.apply("Replacement",to:expected); XCTFail("Omitted quotation must reject apply") } catch { }
        do { _ = try await actions.checkedSnapshot(expected); XCTFail("Omitted quotation must reject review") } catch { }
        do { _ = try await actions.send(expected); XCTFail("Omitted quotation must reject send") } catch { }
        let state=await script.state()
        XCTAssertEqual(state.draft.body,"")
        XCTAssertFalse(state.sent)
    }
    func testVisibleRecipientChangePreventsActionDespiteUnchangedScript() async throws {
        let expected=fixture(body:"Reviewed")
        let script=ActionFixtureScript(draft:expected)
        let actions=MailReplyActions(scripting:script,reader:ActionFixtureReader(body:"Reviewed",extraBcc:"other@example.invalid"))
        do { _ = try await actions.send(expected); XCTFail("Visible recipients must match") } catch { }
        let state=await script.state(); XCTAssertFalse(state.sent)
    }
    func testAppliedBodyMustMatchTheCompleteVisibleResult() async throws {
        let expected=fixture(body:"Original")
        let script=ActionFixtureScript(draft:expected)
        let actions=MailReplyActions(scripting:script,reader:ActionFixtureReader(body:nil,appendAfterWrite:"\nOpaque quotation"))
        do { _ = try await actions.apply("Replacement",to:expected); XCTFail("Partial native write is not success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Inspect Mail")) }
        let state=await script.state(); XCTAssertFalse(state.sent)
    }
    func testCompleteNativeAgreementAllowsApplyAndCheckedReadback() async throws {
        let expected=fixture(body:"Original")
        let script=ActionFixtureScript(draft:expected)
        let actions=MailReplyActions(scripting:script,reader:ActionFixtureReader(body:nil))
        let applied=try await actions.apply("Replacement",to:expected)
        XCTAssertEqual(applied.body,"Replacement")
        let reviewed=try await actions.checkedSnapshot(applied)
        XCTAssertEqual(reviewed.fingerprint,applied.fingerprint)
        let state=await script.state(); XCTAssertFalse(state.sent)
    }
    func testNativeChangeDuringVisibleCapturePreventsAction() async throws {
        let expected=fixture(body:"Original")
        let script=ActionFixtureScript(draft:expected)
        let actions=MailReplyActions(scripting:script,reader:ActionFixtureReader(body:nil,beforeReturn:{ _ = try await script.apply("Owner edit",to:expected) }))
        do { _ = try await actions.apply("Replacement",to:expected); XCTFail("Changed native record must reject action") } catch { }
        let state=await script.state(); XCTAssertEqual(state.draft.body,"Owner edit"); XCTAssertFalse(state.sent)
    }
    private func fixture(body:String)->MailDraft { MailDraft(id:1,subject:"Synthetic",sender:"owner@example.invalid",to:["owner@example.invalid"],cc:[],bcc:[],body:body,attachmentCount:0) }
}

private actor ActionFixtureScript:MailReplyScripting {
    var draft:MailDraft
    var sent=false
    init(draft:MailDraft) { self.draft=draft }
    func snapshot(id:Int) throws -> MailDraft { draft }
    func apply(_ text:String,to expected:MailDraft) throws -> MailDraft {
        guard draft.fingerprint == expected.fingerprint else { throw BridgeFailure("Conflict") }
        draft.body=text; return draft
    }
    func send(_ expected:MailDraft) throws -> Bool {
        guard draft.fingerprint == expected.fingerprint else { throw BridgeFailure("Conflict") }
        sent=true; return true
    }
    func state()->(draft:MailDraft,sent:Bool) { (draft,sent) }
}

private struct ActionFixtureReader:MailReplyReading {
    let body:String?
    var extraBcc:String?
    var appendAfterWrite=""
    var beforeReturn:(@Sendable () async throws -> Void)?
    func capture(matching expected:MailDraft,native:MailDraft?) async throws -> MailDraft {
        try await beforeReturn?()
        var visible=expected
        visible.body=body ?? ((native?.body ?? expected.body) + (native?.body == "Replacement" ? appendAfterWrite : ""))
        if let extraBcc { visible.bcc.append(extraBcc) }
        if let native { return try ReplyCapturePolicy.reconcile(native:native,visible:visible) }
        return try ReplyCapturePolicy.validate(visible,matching:expected)
    }
}
