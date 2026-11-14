import XCTest
@testable import BridgeCore

final class MailSettingsTests:XCTestCase {
    func testNativeSetupRecheckCannotReuseAnEarlierProbe() throws {
        let now=Date()
        var settings=MailSettings()
        settings.nativeAccounts=[NativeMailAccount(id:"native",name:"iCloud",addresses:["owner@example.invalid"],server:"imap.mail.me.com")]
        var grant=NativeMailGrant(accountID:"native",mailboxes:[NativeMailbox(accountID:"native",path:["Inbox"])])
        var input=MailSettingsInput(); input.nativeAccountID="native"; input.nativeGrantVersion=grant.version; input.verificationRequestedAt=now.addingTimeInterval(-10)
        let request=try MailSettingsCoordinator.request(.nativeLink,email:"owner@example.invalid",instruction:"Recheck unchanged folder scope",input:input,settings:&settings)
        settings.requests[0].createdAt=now.addingTimeInterval(-60)
        grant.verifiedAt=now.addingTimeInterval(-30)
        var stale=settings
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:stale.revision,connections:[],schedules:[],outcome:"Verified",nativeGrant:grant,settings:&stale))
        XCTAssertEqual(stale.requests[0].status,.pending)
        grant.verifiedAt=now
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[],outcome:"Fresh probe verified",nativeGrant:grant,settings:&settings)
        XCTAssertEqual(settings.requests[0].status,.confirmed)
    }
    func testNativeLinkRequiresOwnerGrantVersionAndFreshNativeProbe() throws {
        var settings=MailSettings(),native=NativeMailState()
        settings.nativeAccounts=[NativeMailAccount(id:"native-one",name:"iCloud",addresses:["owner@example.com"],server:"imap.mail.me.com")]
        let box=NativeMailbox(accountID:"native-one",path:["Inbox"])
        try NativeMailCoordinator.authorize(accountID:"native-one",mailboxes:[box],state:&native)
        var input=MailSettingsInput(); input.nativeAccountID="native-one"; input.nativeGrantVersion=native.grants[0].version
        let request=try MailSettingsCoordinator.request(.nativeLink,email:"owner@example.com",instruction:"Verify selected native folders",input:input,settings:&settings)
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[],outcome:"Connected",nativeGrant:native.grants[0],settings:&settings))
        let probe=try NativeMailCoordinator.enqueue(accountID:"native-one",mailboxID:nil,kind:.probeMailboxes,query:NativeMailQuery(),state:&native)
        _ = try NativeMailCoordinator.claim(probe.id,state:&native)
        try NativeMailCoordinator.complete(probe.id,result:["mailboxes":try .encode([box])],state:&native)
        var wrong=native.grants[0]; wrong.version=UUID().uuidString
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[],outcome:"Connected",nativeGrant:wrong,settings:&settings))
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[],outcome:"Selected folders verified",nativeGrant:native.grants[0],settings:&settings)
        XCTAssertEqual(settings.requests[0].status,.confirmed)
        XCTAssertTrue(settings.connections.isEmpty)
    }
    func testRefreshMarksAbsentScheduleUnavailableAndPreservesSuccessfulCoverage() throws {
        var settings=MailSettings()
        var retained=MailSchedule(id:"retained",title:"Review",accountEmails:[],cadence:"Hourly",conditions:"No sending")
        retained.lastSuccessAt=Date(timeIntervalSince1970:1000)
        settings.schedules=[retained,MailSchedule(id:"deleted",title:"Old",accountEmails:[],cadence:"Hourly",conditions:"No sending")]
        let request=try MailSettingsCoordinator.request(.refresh,instruction:"Complete inventory",settings:&settings)
        retained.lastSuccessAt=nil
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[retained],outcome:"Current inventory",settings:&settings)
        XCTAssertEqual(settings.schedules.first(where:{$0.id == "retained"})?.lastSuccessAt,Date(timeIntervalSince1970:1000))
        XCTAssertEqual(settings.schedules.first(where:{$0.id == "deleted"})?.available,false)
        XCTAssertThrowsError(try MailSettingsCoordinator.request(.changeSchedule,scheduleID:"deleted",instruction:"Daily",settings:&settings))
    }
    func testReconnectPreservesProfileIdentityAndRejectsCollisions() throws {
        var settings=MailSettings()
        settings.connections=[MailConnection(id:"owner-id",email:"owner@example.com",connectionID:"old-link"),MailConnection(id:"other-id",email:"other@example.com",connectionID:"other-link")]
        let request=try MailSettingsCoordinator.request(.activate,email:"owner@example.com",instruction:"Reconnect",settings:&settings)
        for id in ["other-id","invented-id"] {
            XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[MailConnection(id:id,email:"owner@example.com",connectionID:"new-link")],schedules:[],outcome:"Reconnected",settings:&settings))
        }
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[MailConnection(id:"owner-id",email:"owner@example.com",connectionID:"new-link")],schedules:[],outcome:"Reconnected",settings:&settings)
        XCTAssertEqual(settings.connections.count,2)
        XCTAssertEqual(settings.connections.first(where:{$0.id == "owner-id"})?.connectionID,"new-link")
    }
    func testRefreshRejectsDuplicateEmailProfileIdentity() throws {
        var settings=MailSettings()
        let request=try MailSettingsCoordinator.request(.refresh,instruction:"Refresh",settings:&settings)
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[MailConnection(id:"one",email:"owner@example.com",connectionID:"a"),MailConnection(id:"two",email:"OWNER@example.com",connectionID:"b")],schedules:[],outcome:"Refreshed",settings:&settings))
    }
    func testScheduleAdoptionCannotSwitchItsSourceConnection() throws {
        var settings=MailSettings()
        var schedule=MailSchedule(id:"job",title:"Review",accountEmails:["owner@example.com"],cadence:"Hourly",conditions:"No sending")
        schedule.sources=[MailScheduleSource(kind:"gmail",id:"profile",addresses:["owner@example.com"],connectionID:"link")]
        settings.schedules=[schedule]
        let request=try MailSettingsCoordinator.request(.linkSchedule,scheduleID:"job",instruction:"Prefix",settings:&settings)
        schedule.title="Mail Dot · Review"; schedule.sources[0].connectionID="different-link"
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[schedule],outcome:"Linked",settings:&settings))
    }
    func testActivationCannotSmuggleScheduleChanges() throws {
        var settings=MailSettings()
        let request=try MailSettingsCoordinator.request(.activate,email:"owner@example.com",instruction:"Activate",settings:&settings)
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[MailConnection(id:"profile",email:"owner@example.com",connectionID:"link")],schedules:[MailSchedule(id:"foreign",title:"Other",accountEmails:[],cadence:"Daily",conditions:"Changed")],outcome:"Connected",settings:&settings))
        XCTAssertTrue(settings.schedules.isEmpty)
    }
    func testScheduleAdoptionCannotAlterExistingCoverage() throws {
        var settings=MailSettings()
        let original=MailSchedule(id:"job",title:"Review",accountEmails:["owner@example.com"],cadence:"Hourly",conditions:"Quiet nights; no sending")
        settings.schedules=[original]
        let request=try MailSettingsCoordinator.request(.linkSchedule,scheduleID:"job",instruction:"Add prefix only",settings:&settings)
        var changed=original; changed.title="Mail Dot · Review"; changed.cadence="Daily"
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[changed],outcome:"Linked",settings:&settings))
        XCTAssertEqual(settings.schedules.first?.cadence,"Hourly")
    }
    func testScheduleChangeCannotMoveAccountScope() throws {
        var settings=MailSettings()
        let original=MailSchedule(id:"job",title:"Review",accountEmails:["owner@example.com"],cadence:"Hourly",conditions:"No sending")
        settings.schedules=[original]
        let request=try MailSettingsCoordinator.request(.changeSchedule,scheduleID:"job",instruction:"Daily",settings:&settings)
        var changed=original; changed.accountEmails=["other@example.com"]
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[changed],outcome:"Changed",settings:&settings))
    }
    func testWrongGoogleAccountCannotConfirmActivation() throws {
        var settings = MailSettings()
        let request = try MailSettingsCoordinator.request(.activate,email:"wanted@example.com",instruction:"Connect this Gmail account",settings:&settings)
        let wrong = MailConnection(id:"other-profile",email:"other@example.com",connectionID:"other-link")
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[wrong],schedules:[],outcome:"Connected",settings:&settings))
        XCTAssertTrue(settings.connections.isEmpty)
        XCTAssertEqual(settings.requests.first?.status,.pending)
    }
    func testMatchingProfileAndStableScheduleIdentityArePreserved() throws {
        var settings = MailSettings()
        let request = try MailSettingsCoordinator.request(.refresh,instruction:"Read current accounts and schedules",settings:&settings)
        let profile = MailConnection(id:"profile-stable",email:"owner@example.com",connectionID:"link-one")
        var schedule = MailSchedule(id:"job-stable",title:"Email check",accountEmails:["owner@example.com"],cadence:"Hourly",conditions:"No sending")
        schedule.sources=[MailScheduleSource(kind:"gmail",id:profile.id,addresses:[profile.email],connectionID:profile.connectionID)]
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[profile],schedules:[schedule],outcome:"Read back",settings:&settings)
        let link = try MailSettingsCoordinator.request(.linkSchedule,scheduleID: schedule.id,instruction:"Prefix the existing job, preserving all other settings",settings:&settings)
        var renamed = schedule; renamed.title = "Mail Dot · Email check"
        try MailSettingsCoordinator.report(requestID:link.id,expectedRevision:settings.revision,connections:[],schedules:[renamed],outcome:"Renamed and reread",settings:&settings)
        XCTAssertEqual(settings.schedules.first?.id,"job-stable")
        XCTAssertEqual(settings.linkedScheduleIDs,["job-stable"])
        XCTAssertEqual(settings.connections.first?.id,"profile-stable")
    }
    func testStaleAndForeignReportsDoNotMutateConfiguration() throws {
        var settings = MailSettings()
        let request = try MailSettingsCoordinator.request(.refresh,instruction:"Refresh",settings:&settings)
        let revision = settings.revision
        _ = try MailSettingsCoordinator.request(.refresh,instruction:"Refresh again",settings:&settings)
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:revision,connections:[],schedules:[],outcome:"Stale",settings:&settings))
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:UUID().uuidString,expectedRevision:settings.revision,connections:[],schedules:[],outcome:"Foreign",settings:&settings))
        XCTAssertNil(settings.lastDotSync)
    }
    func testScheduleChangeCannotReplaceAnotherJob() throws {
        var settings = MailSettings()
        settings.schedules = [MailSchedule(id:"one",title:"One",accountEmails:[],cadence:"Hourly",conditions:"Keep"),MailSchedule(id:"two",title:"Two",accountEmails:[],cadence:"Daily",conditions:"Untouched")]
        let request = try MailSettingsCoordinator.request(.changeSchedule,scheduleID:"one",instruction:"Check every two hours",settings:&settings)
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[settings.schedules[1]],outcome:"Wrong target",settings:&settings))
        XCTAssertEqual(settings.schedules[1].conditions,"Untouched")
    }
    func testSettingsSurviveLegacyReplyStoreWritesAndRejectedOversizeUpdate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = MailSettingsStore(bridgeDirectory:directory)
        try store.transaction { $0.connections = [MailConnection(id:"profile",email:"owner@example.com",connectionID:"link")] }
        try BridgeStore(directory:directory).transaction { $0.audit.append("legacy message writer") }
        XCTAssertEqual(try store.read().connections.count,1)
        XCTAssertThrowsError(try store.transaction { $0.connections = Array(repeating:MailConnection(id:"same",email:"a@example.com",connectionID:"link"),count:101) })
        XCTAssertEqual(try store.read().connections.count,1)
        let permissions = try FileManager.default.attributesOfItem(atPath:store.directory.appendingPathComponent("settings.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions,0o600)
    }
}
