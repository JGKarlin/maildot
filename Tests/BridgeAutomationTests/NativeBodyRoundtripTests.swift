import XCTest
import BridgeCore
@testable import BridgeAutomation

final class NativeBodyRoundtripTests:XCTestCase {
    @MainActor func testRoundtripRestoresCompleteBodyAndRefusesReplay() async throws {
        let store=try fixtureStore(),script=RoundtripFixtureScript()
        try await NativeBodyRoundtripProbe.run(store:store,scripting:script,reader:RoundtripFixtureReader(script:script))
        let state=await script.state(); XCTAssertEqual(state.body,NativeBodyRoundtripProbe.fixture.body); XCTAssertEqual(state.writes,2)
        let result=try result(store)
        XCTAssertEqual(result["status"].string,"complete"); XCTAssertEqual(result["nativeReadbackComplete"],true)
        do { try await NativeBodyRoundtripProbe.run(store:store,scripting:script,reader:RoundtripFixtureReader(script:script)); XCTFail("Must not replay") } catch { }
        let after=await script.state(); XCTAssertEqual(after.writes,2)
    }
    @MainActor func testUnknownWriteOutcomeStopsWithoutRestoration() async throws {
        let store=try fixtureStore(),script=RoundtripFixtureScript()
        do { try await NativeBodyRoundtripProbe.run(store:store,scripting:script,reader:RoundtripFixtureReader(script:script,unknownAfterWrite:true)); XCTFail("Unknown result must stop") } catch { }
        let state=await script.state(); XCTAssertEqual(state.writes,1)
        let result=try result(store); XCTAssertEqual(result["status"].string,"failed"); XCTAssertEqual(result["restoreAttempted"],false)
    }
    @MainActor func testContextOrPendingActionChangeBeforeWritePreventsMutation() async throws {
        for pending in [false,true] {
            let store=try fixtureStore(),script=RoundtripFixtureScript()
            let reader=RoundtripFixtureReader(script:script,beforeReturn:{ try store.transaction {
                if pending { $0.operations.append(NativeOperation(contextID:NativeBodyRoundtripProbe.contextID,kind:"share")) }
                else { $0.activeContextID=nil }
            } })
            do { try await NativeBodyRoundtripProbe.run(store:store,scripting:script,reader:reader); XCTFail("Changed context must stop") } catch { }
            let state=await script.state(); XCTAssertEqual(state.writes,0)
        }
    }
    @MainActor func testUncertainRestorationIsNotRetried() async throws {
        let store=try fixtureStore(),script=RoundtripFixtureScript(failAfterRestore:true)
        do { try await NativeBodyRoundtripProbe.run(store:store,scripting:script,reader:RoundtripFixtureReader(script:script)); XCTFail("Uncertain restoration must stop") } catch { }
        let state=await script.state(); XCTAssertEqual(state.writes,2)
        let result=try result(store); XCTAssertEqual(result["stage"].string,"restore"); XCTAssertEqual(result["status"].string,"failed")
        do { try await NativeBodyRoundtripProbe.run(store:store,scripting:script,reader:RoundtripFixtureReader(script:script)); XCTFail("Must not replay") } catch { }
        let after=await script.state(); XCTAssertEqual(after.writes,2)
    }
    private func fixtureStore() throws -> BridgeStore {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        let store=BridgeStore(directory:directory)
        try store.transaction { state in
            var context=ReplyContext(id:NativeBodyRoundtripProbe.contextID,envelope:NativeBodyRoundtripProbe.fixture)
            context.snapshot=NativeBodyRoundtripProbe.fixture
            state.activeContextID=context.id; state.contexts[context.id]=context
        }
        return store
    }
    private func result(_ store:BridgeStore) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self,from:Data(contentsOf:store.directory.appendingPathComponent("SyntheticDiagnostics/body-roundtrip-\(NativeBodyRoundtripProbe.contextID).json")))
    }
    func testOnlyTheExactSharedSyntheticReplyMayBeWritten() throws {
        let visible=NativeBodyRoundtripProbe.fixture
        var context=ReplyContext(id:NativeBodyRoundtripProbe.contextID,envelope:visible)
        context.snapshot=visible
        var native=visible; native.id=1; native.attachmentCount=0; native.body=""
        XCTAssertNoThrow(try NativeBodyRoundtripProbe.validate(context:context,native:native,visible:visible))
        var changed=visible; changed.body += "Owner edit"
        XCTAssertThrowsError(try NativeBodyRoundtripProbe.validate(context:context,native:native,visible:changed))
        changed=visible; changed.bcc=["other@example.invalid"]
        XCTAssertThrowsError(try NativeBodyRoundtripProbe.validate(context:context,native:native,visible:changed))
        native.attachmentCount=1
        XCTAssertThrowsError(try NativeBodyRoundtripProbe.validate(context:context,native:native,visible:visible))
        native.attachmentCount=0; native.body="Unexpected native body"
        XCTAssertThrowsError(try NativeBodyRoundtripProbe.validate(context:context,native:native,visible:visible))
        native.body=""; context.proposal=DotProposal(body:"Real Dot work",revision:1,snapshotRevision:1)
        XCTAssertThrowsError(try NativeBodyRoundtripProbe.validate(context:context,native:native,visible:visible))
        context.proposal=nil; context.review=SendReview(draft:native)
        XCTAssertThrowsError(try NativeBodyRoundtripProbe.validate(context:context,native:native,visible:visible))
    }
    func testRestorationRequiresExactExpectedReadback() throws {
        var native=NativeBodyRoundtripProbe.fixture; native.id=1; native.attachmentCount=0; native.body=NativeBodyRoundtripProbe.marker
        var visible=NativeBodyRoundtripProbe.fixture; visible.body=NativeBodyRoundtripProbe.marker
        XCTAssertEqual(try NativeBodyRoundtripProbe.restoration(native:native,visible:visible),NativeBodyRoundtripProbe.fixture.body)
        visible.body=NativeBodyRoundtripProbe.marker+NativeBodyRoundtripProbe.fixture.body
        XCTAssertEqual(try NativeBodyRoundtripProbe.restoration(native:native,visible:visible),"")
        visible.body += "Concurrent owner edit"
        XCTAssertThrowsError(try NativeBodyRoundtripProbe.restoration(native:native,visible:visible))
        visible.body=NativeBodyRoundtripProbe.marker; native.body="Changed after write"
        XCTAssertThrowsError(try NativeBodyRoundtripProbe.restoration(native:native,visible:visible))
    }
}

private actor RoundtripFixtureScript:NativeBodyProbeScripting {
    var draft:MailDraft
    var writes=0
    let failAfterRestore:Bool
    init(failAfterRestore:Bool=false) { self.failAfterRestore=failAfterRestore; draft=NativeBodyRoundtripProbe.fixture; draft.id=1; draft.attachmentCount=0; draft.body="" }
    func connect(_ envelope:MailDraft) -> MailDraft { draft }
    func snapshot(id:Int)->MailDraft { draft }
    func apply(_ text:String,to expected:MailDraft) throws -> MailDraft {
        guard draft.fingerprint == expected.fingerprint else { throw BridgeFailure("Conflict") }
        draft.body=text; writes += 1
        if failAfterRestore && writes == 2 { throw BridgeFailure("Unknown restoration outcome") }
        return draft
    }
    func send(_ expected:MailDraft) throws -> Bool { throw BridgeFailure("Synthetic diagnostic must never send") }
    func state()->(body:String,writes:Int) { (draft.body,writes) }
}
private struct RoundtripFixtureReader:MailReplyReading {
    let script:RoundtripFixtureScript
    var unknownAfterWrite=false
    var beforeReturn:(@Sendable () throws -> Void)?
    func capture(matching expected:MailDraft,native:MailDraft?) async throws -> MailDraft {
        try beforeReturn?()
        let state=await script.state()
        var visible=NativeBodyRoundtripProbe.fixture
        if state.writes > 0 { visible.body=unknownAfterWrite ? "Unexpected body" : state.body }
        return visible
    }
}
