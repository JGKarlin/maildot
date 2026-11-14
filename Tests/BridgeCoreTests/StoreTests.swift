import XCTest
@testable import BridgeCore

final class StoreTests: XCTestCase {
    func store() throws -> BridgeStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BridgeStore(directory: url)
    }

    func testTransactionsPersistAcrossStoreInstances() throws {
        let first = try store()
        try first.transaction { $0.activeContextID = "session-a" }
        let second = BridgeStore(directory: first.directory)
        XCTAssertEqual(try second.read().activeContextID, "session-a")
    }

    func testThrownTransactionDoesNotCommit() throws {
        let value = try store()
        try value.transaction { $0.activeContextID = "before" }
        XCTAssertThrowsError(try value.transaction { state in
            state.activeContextID = "after"
            throw BridgeFailure("stop")
        })
        XCTAssertEqual(try value.read().activeContextID, "before")
    }

    func testCorruptStateIsNotSilentlyReset() throws {
        let value = try store()
        try value.transaction { $0.activeContextID = "before" }
        let url = value.directory.appendingPathComponent("state.json")
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try value.transaction { $0.activeContextID = "after" })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "invalid")
    }

    func testConcurrentStoresDoNotLoseWrites() throws {
        let value = try store()
        let failures = MutexBox()
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            do { try value.transaction { $0.audit.append("entry-\(index)") } }
            catch { failures.add(error.localizedDescription) }
        }
        XCTAssertEqual(failures.values, [])
        XCTAssertEqual(try value.read().audit.count, 30)
    }

    func testFinishedOperationsAreBoundedWithoutDroppingUncertainActions() throws {
        let value = try store()
        for _ in 0..<110 {
            try value.transaction { state in
                var operation = NativeOperation(contextID:"test",kind:"share")
                operation.result = "done"; state.operations.append(operation)
            }
        }
        try value.transaction { state in
            var uncertain = NativeOperation(contextID:"test",kind:"send")
            uncertain.claimedAt = .now; state.operations.insert(uncertain,at:0)
        }
        XCTAssertLessThanOrEqual(try value.read().operations.count,61)
        XCTAssertEqual(try value.read().operations.first?.kind,"send")
    }
}

// The lock protects every access; this helper is only for concurrent test diagnostics.
private final class MutexBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}
