import XCTest
@testable import BridgeCore

final class UpdateStatusTests: XCTestCase {
    /// The line shows only while a newer build waits; once installed, the record no longer counts.
    func testOnlyANewerVersionIsWaiting() {
        XCTAssertEqual(UpdateStatus(readyVersion:"0.4.212").waiting(runningVersion:"0.4.211"),"0.4.212")
        XCTAssertEqual(UpdateStatus(readyVersion:"0.4.1000").waiting(runningVersion:"0.4.999"),"0.4.1000","compared as numbers")
        XCTAssertNil(UpdateStatus(readyVersion:"0.4.212").waiting(runningVersion:"0.4.212"))
        XCTAssertNil(UpdateStatus(readyVersion:"0.4.211").waiting(runningVersion:"0.4.212"))
        XCTAssertNil(UpdateStatus().waiting(runningVersion:"0.4.212"))
    }

    func testRoundTripsThroughTheSharedFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        XCTAssertEqual(UpdateStatus.read(bridgeDirectory:directory), UpdateStatus(), "no file reads as up to date")
        let checked = Date(timeIntervalSince1970:1_800_000_000)
        try UpdateStatus(readyVersion:"0.4.212", checkedAt:checked).write(bridgeDirectory:directory)
        XCTAssertEqual(UpdateStatus.read(bridgeDirectory:directory), UpdateStatus(readyVersion:"0.4.212", checkedAt:checked))
    }
}
