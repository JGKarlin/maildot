import XCTest
@testable import BridgeCore

final class SettingsProtocolTests:XCTestCase {
    func testNonGmailNativeGrantKeepsManagementWithMatchingCloudConnection() throws {
        let account=NativeMailAccount(id:"native",name:"Work",addresses:["owner@example.com"],server:"outlook.office365.com")
        var cloud=MailConnection(id:"cloud",email:"owner@example.com",connectionID:"link"); cloud.provider="outlook"
        var settings=MailSettings(); settings.nativeAccounts=[account]; settings.connections=[cloud]
        let grant=NativeMailGrant(accountID:account.id,mailboxes:[NativeMailbox(accountID:account.id,path:["Inbox"])])
        XCTAssertTrue(settings.showsNativeAccessManagement(for:account,grants:[grant]))
    }
    func testAnotherScheduleChangeCannotRaceAnUnresolvedOwnerRequest() throws {
        var settings=MailSettings()
        settings.schedules=[MailSchedule(id:"job",title:"Review",accountEmails:[],cadence:"Hourly",conditions:"Keep")]
        _ = try MailSettingsCoordinator.request(.changeSchedule,scheduleID:"job",instruction:"Daily",settings:&settings)
        XCTAssertThrowsError(try MailSettingsCoordinator.request(.linkSchedule,scheduleID:"job",instruction:"Add prefix",settings:&settings))
        XCTAssertEqual(settings.requests.count,1)
    }
    func testNativeConfigurationShowsCurrentUnresolvedWorkWithoutOldFailures() throws {
        var settings=MailSettings()
        _ = try MailSettingsCoordinator.request(.refresh,instruction:"Old combined refresh",settings:&settings)
        settings.requests[0].status = .failed
        var input=MailSettingsInput(); input.inventoryScope = .accounts
        _ = try MailSettingsCoordinator.request(.refresh,instruction:"Current account verification",input:input,settings:&settings)
        settings.requests[1].status = .confirmed
        XCTAssertTrue(settings.configurationRequests(for:.accounts).isEmpty)
        XCTAssertEqual(settings.configurationRequests(for:.schedules).count,1)
    }
    func testAccountRefreshCannotEraseOrRewriteSchedules() throws {
        var settings=MailSettings()
        settings.schedules=[MailSchedule(id:"job",title:"Keep",accountEmails:[],cadence:"Hourly",conditions:"No sending")]
        var input=MailSettingsInput(); input.inventoryScope = .accounts
        let request=try MailSettingsCoordinator.request(.refresh,instruction:"Refresh accounts only",input:input,settings:&settings)
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[settings.schedules[0]],outcome:"Wrong collection",settings:&settings))
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[MailConnection(id:"profile",email:"owner@example.com",connectionID:"link")],schedules:[],outcome:"Accounts verified",settings:&settings)
        XCTAssertEqual(settings.schedules.first?.available,true)
        XCTAssertNotNil(settings.lastAccountsSync)
        XCTAssertNil(settings.lastSchedulesSync)
    }
    func testScheduleRequestCarriesTypedValuesWithoutParsingProse() throws {
        var settings=MailSettings()
        settings.schedules=[MailSchedule(id:"job",title:"Review",accountEmails:[],cadence:"Hourly",conditions:"Keep")]
        var input=MailSettingsInput(); input.cadence="Every two hours"; input.conditions="No sending"; input.enabled=false
        let request=try MailSettingsCoordinator.request(.changeSchedule,scheduleID:"job",instruction:"Owner changed settings",input:input,settings:&settings)
        XCTAssertEqual(request.protocolVersion,1)
        XCTAssertEqual(request.input?.cadence,"Every two hours")
        XCTAssertEqual(request.input?.enabled,false)
    }
    func testStructuredFormRejectsInventedChoicesAndStaleQuestions() throws {
        var settings=MailSettings()
        let request=try MailSettingsCoordinator.request(.activate,email:"owner@example.com",instruction:"Connect",settings:&settings)
        let field=MailSettingsFormField(id:"scope",label:"Coverage",kind:"selection",options:["Inbox","All mail"],required:true)
        settings.requests[0].form=[field]; settings.requests[0].status = .question
        XCTAssertThrowsError(try MailSettingsCoordinator.answer(requestID:request.id,form:[field],answers:["scope":"Send all"],settings:&settings))
        try MailSettingsCoordinator.answer(requestID:request.id,form:[field],answers:["scope":"Inbox"],settings:&settings)
        XCTAssertEqual(settings.requests[0].answers,["scope":"Inbox"])
        XCTAssertEqual(settings.requests[0].status,.pending)
        XCTAssertFalse(settings.requests[0].instruction.contains("Owner response:"))
        XCTAssertThrowsError(try MailSettingsCoordinator.answer(requestID:request.id,form:[field],answers:["scope":"Inbox"],settings:&settings))
    }
}
