import XCTest
@testable import BridgeCore

final class ContextPruningTests:XCTestCase {
    private func store() -> BridgeStore {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return BridgeStore(directory:directory)
    }
    private func context(_ id:String,updated:TimeInterval,body:String="") -> ReplyContext {
        var value=ReplyContext(id:id,envelope:MailDraft(id: -1,subject:"Re: \(id)",sender:"owner@example.invalid",to:["a@example.invalid"],cc:[],bcc:[],body:body,attachmentCount:0))
        value.updatedAt=Date(timeIntervalSince1970:updated)
        return value
    }

    func testOrphanedMessagesNeverStopMailDotTheOldestAreDropped() throws {
        let store=store()
        // Reply windows whose closing Mail Dot never heard of, because Mail quit or the extension restarted.
        for index in 0..<40 { try store.transaction { $0.contexts["old\(index)"]=context("old\(index)",updated:Double(index)) } }
        let state=try store.read()
        XCTAssertEqual(state.contexts.count,BridgeStore.contextLimit)
        XCTAssertNotNil(state.contexts["old39"],"the newest is kept")
        XCTAssertNil(state.contexts["old0"],"the oldest went first")
        try store.transaction { $0.contexts["now"]=context("now",updated:1_000) }
        XCTAssertNotNil(try store.read().contexts["now"],"a new reply window always opens")
    }

    func testAMessageThatIsBusyAwaitingConfirmationOrOpenIsKept() throws {
        var state=BridgeState()
        for index in 0..<5 { state.contexts["c\(index)"]=context("c\(index)",updated:Double(index)) }
        state.operations.append(NativeOperation(contextID:"c0",kind:"apply"))
        state.contexts["c1"]?.sendConfirmation=SendConfirmation(fingerprint:"f",snapshotRevision:0)
        state.activeContextID="c2"
        state.pruneContexts(keeping:2)
        XCTAssertEqual(Set(state.contexts.keys),["c0","c1","c2"],"nothing in use is dropped, even beyond the limit")
    }

    func testLongThreadsFitBecauseOldMessagesMakeRoom() throws {
        let store=store()
        let long=String(repeating:"引用されたメールの本文です。",count:16_000) // about 224 K characters, near 700 KB in UTF-8
        XCTAssertLessThanOrEqual(long.utf16.count,MailBodyLimits.characters)
        for index in 0..<15 {
            var value=context("long\(index)",updated:Double(index),body:long)
            value.snapshot=value.envelope
            try store.transaction { $0.contexts[value.id]=value }
        }
        let state=try store.read()
        XCTAssertNotNil(state.contexts["long14"],"the newest long thread is kept")
        XCTAssertLessThan(state.contexts.count,15,"older long threads made room")
    }
}
