import XCTest
@testable import BridgeCore

final class ScheduledMailUpdateTests:XCTestCase {
    private func fixture() throws -> (MailSettings,[MailWorkflowAccount],ScheduledMailUpdate) {
        var settings=MailSettings()
        var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link"); profile.observedAt=Date()
        settings.connections=[profile]
        var schedule=MailSchedule(id:"schedule",title:"Mail Dot · Review",accountEmails:[profile.email],cadence:"Hourly",conditions:"Report actionable mail")
        schedule.observedAt=Date(); schedule.sources=[MailScheduleSource(kind:"gmail",id:profile.id,addresses:[profile.email],connectionID:profile.connectionID)]
        settings.schedules=[schedule]; settings.linkedScheduleIDs=[schedule.id]
        let accounts=try MailWorkflowAccount.available(settings:settings,native:NativeMailState())
        let update=ScheduledMailUpdate(id:"meeting",scheduleID:schedule.id,runID:"run-1",revision:0,accountIDs:["gmail:profile"],sourceIDs:["message-1"],title:"Meeting reply needed",summary:"A meeting was proposed.",action:.decision,actionText:"Choose a time.",checkedAt:Date(),coverage:"Work calendar checked; personal calendar not checked.")
        return(settings,accounts,update)
    }
    func testScheduledReportNeedsNoMenuRequestAndDuplicateDoesNotBecomeUnread() throws {
        let (settings,accounts,update)=try fixture()
        var state=ScheduledMailUpdateState()
        XCTAssertTrue(try state.accept(update,settings:settings,accounts:accounts))
        try state.markRead(update.key,revision:0)
        XCTAssertFalse(try state.accept(update,settings:settings,accounts:accounts))
        XCTAssertFalse(state.records[0].unread)
        var revised=update; revised.revision=1; revised.runID="run-2"; revised.summary="The proposed time now works."
        XCTAssertTrue(try state.accept(revised,settings:settings,accounts:accounts))
        XCTAssertEqual(state.records.count,1); XCTAssertTrue(state.records[0].unread)
        XCTAssertThrowsError(try state.markRead(update.key,revision:0))
        XCTAssertThrowsError(try state.accept(update,settings:settings,accounts:accounts))
        revised.summary="Conflicting content at the same revision"
        XCTAssertThrowsError(try state.accept(revised,settings:settings,accounts:accounts))
    }
    func testUnlinkedScheduleRevokedAccountAndSubstitutedConnectionRefused() throws {
        let (settings,accounts,update)=try fixture()
        var state=ScheduledMailUpdateState(),unlinked=settings
        unlinked.linkedScheduleIDs=[]
        XCTAssertThrowsError(try state.accept(update,settings:unlinked,accounts:accounts))
        XCTAssertThrowsError(try state.accept(update,settings:settings,accounts:[]))
        var changed=settings; changed.schedules[0].sources[0].connectionID="another-link"
        XCTAssertThrowsError(try state.accept(update,settings:changed,accounts:accounts))
        changed=settings; changed.schedules[0].enabled=false
        XCTAssertThrowsError(try state.accept(update,settings:changed,accounts:accounts))
    }
    func testPersistentReceiptAndToolAcknowledgement() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (settings,_,update)=try fixture()
        try MailSettingsStore(bridgeDirectory:root).transaction{$0=settings}
        let result=try ScheduledMailUpdateTools.call("report_scheduled_mail_update",arguments:["update":try .encode(update)],bridgeDirectory:root)
        XCTAssertEqual(result["saved"],true)
        let duplicate=try ScheduledMailUpdateTools.call("report_scheduled_mail_update",arguments:["update":try .encode(update)],bridgeDirectory:root)
        XCTAssertEqual(duplicate["duplicate"],true)
        XCTAssertEqual(try ScheduledMailUpdateStore(bridgeDirectory:root).read().records.count,1)
        let read=try ScheduledMailUpdateTools.call("get_scheduled_mail_updates",arguments:[:],bridgeDirectory:root)
        XCTAssertEqual(read["updates"].array?.first?["update"]["summary"].string,update.summary)
        try MailSettingsStore(bridgeDirectory:root).transaction{$0.connections[0].available=false}
        let revoked=try ScheduledMailUpdateTools.call("get_scheduled_mail_updates",arguments:[:],bridgeDirectory:root)
        XCTAssertEqual(revoked["updates"].array?.count,0)
    }
    func testReadHistoryCanBeCompactedWithoutResurrectingARetry() throws {
        let (settings,accounts,original)=try fixture()
        var state=ScheduledMailUpdateState()
        try state.accept(original,settings:settings,accounts:accounts)
        try state.markRead(original.key,revision:0)
        for index in 1...200 {
            var update=original; update.id="item-\(index)"
            XCTAssertNoThrow(try state.accept(update,settings:settings,accounts:accounts))
        }
        XCTAssertEqual(state.records.count,200)
        XCTAssertFalse(state.records.contains{$0.id == original.key})
        XCTAssertFalse(try state.accept(original,settings:settings,accounts:accounts))
        XCTAssertFalse(state.records.contains{$0.id == original.key})
        var fresh=original; fresh.revision=1; fresh.summary="Fresh development"
        let read=state.records[0]
        try state.markRead(read.id,revision:read.update.revision)
        XCTAssertTrue(try state.accept(fresh,settings:settings,accounts:accounts))
        XCTAssertTrue(state.records.first{$0.id == original.key}?.unread == true)
    }
    func testPaginationIncludesLaterRevisionsAndNoReceiptOnWriteFailure() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=ScheduledMailUpdateStore(bridgeDirectory:root)
        defer {try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:store.directory.path); try? FileManager.default.removeItem(at:root)}
        let (settings,_,original)=try fixture()
        try MailSettingsStore(bridgeDirectory:root).transaction{$0=settings}
        for index in 1...21 {
            var update=original; update.id="item-\(index)"
            _=try ScheduledMailUpdateTools.call("report_scheduled_mail_update",arguments:["update":try .encode(update)],bridgeDirectory:root)
        }
        let page=try ScheduledMailUpdateTools.call("get_scheduled_mail_updates",arguments:[:],bridgeDirectory:root)
        XCTAssertEqual(page["updates"].array?.count,20); XCTAssertEqual(page["has_more"],true)
        var revised=original; revised.id="item-1"; revised.revision=1; revised.summary="Later correction"
        _=try ScheduledMailUpdateTools.call("report_scheduled_mail_update",arguments:["update":try .encode(revised)],bridgeDirectory:root)
        let next=try ScheduledMailUpdateTools.call("get_scheduled_mail_updates",arguments:["after_sequence":page["next_cursor"]],bridgeDirectory:root)
        XCTAssertEqual(next["updates"].array?.count,2)
        XCTAssertEqual(next["updates"].array?.last?["update"]["summary"].string,"Later correction")
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:store.directory.path)
        XCTAssertThrowsError(try ScheduledMailUpdateTools.call("report_scheduled_mail_update",arguments:["update":try .encode(original)],bridgeDirectory:root))
        XCTAssertEqual(try store.read().records.count,21)
    }
    func testOlderCheckAndChangedAccountCannotReplaceMatter() throws {
        let (settings,accounts,original)=try fixture()
        var state=ScheduledMailUpdateState(); try state.accept(original,settings:settings,accounts:accounts)
        var revised=original; revised.revision=1; revised.checkedAt=original.checkedAt.addingTimeInterval(-1)
        XCTAssertThrowsError(try state.accept(revised,settings:settings,accounts:accounts))
        revised=original; revised.revision=1; revised.accountIDs=["gmail:unrelated"]
        XCTAssertThrowsError(try state.accept(revised,settings:settings,accounts:accounts))
        revised=original; revised.id="ancient"; revised.checkedAt=Date().addingTimeInterval(-91*86400)
        XCTAssertThrowsError(try state.accept(revised,settings:settings,accounts:accounts))
    }
    func testScheduledReportArrivesThroughMCPWithoutWorkflowRequest() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (settings,_,update)=try fixture()
        try MailSettingsStore(bridgeDirectory:root).transaction{$0=settings}
        let router=MCPRouter(store:BridgeStore(directory:root),statelessTunnel:true)
        let input:JSONValue=["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"report_scheduled_mail_update","arguments":["update":try .encode(update)]]]
        let response=await router.response(try input.text())
        let result=try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(response).utf8))
        XCTAssertEqual(result["result"]["isError"],false)
        XCTAssertEqual(result["result"]["structuredContent"]["saved"],true)
        XCTAssertTrue(try MailWorkflowStore(bridgeDirectory:root).read().requests.isEmpty)
    }
}
