import XCTest
@testable import BridgeCore

/// Outlook accounts go through ChatGPT's Outlook Email connector, as Gmail and iCloud do (owner decision, 26 November 2026).
final class OutlookConnectorTests: XCTestCase {
    private let address="owner@outlook.example.invalid"

    func testOutlookAccountsAreRecognisedByMicrosoftsServers() {
        XCTAssertTrue(NativeMailAccount(id:"A",name:"Work",addresses:["owner@work.example.invalid"],server:"outlook.office365.com").isOutlook)
        XCTAssertTrue(NativeMailAccount(id:"B",name:"Home",addresses:["owner@example.invalid"],server:"imap-mail.outlook.com").isOutlook)
        XCTAssertFalse(NativeMailAccount(id:"C",name:"Uni",addresses:["owner@uni.example.invalid"],server:"mail.uni.example.invalid").isOutlook)
        XCTAssertFalse(NativeMailAccount(id:"D",name:"iCloud",addresses:["owner@example.invalid"],server:"imap.mail.me.com").isOutlook)
    }

    func testDotConfirmsTheOutlookProfileAndDotIsToldItsRoute() throws {
        var settings=MailSettings()
        var input=MailSettingsInput(); input.provider="outlook"
        let request=try MailSettingsCoordinator.request(.activate,email:address,instruction:"Connect Outlook.",input:input,settings:&settings)
        var profile=MailConnection(id:"ms1",email:address,connectionID:"link-ms"); profile.provider="outlook"
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[profile],schedules:[],outcome:"Connected.",settings:&settings)
        let connection=try XCTUnwrap(settings.connections.first)
        XCTAssertTrue(connection.isLiveConnector)
        XCTAssertEqual(connection.accountID,"outlook:ms1")
        XCTAssertEqual(connection.route,"outlook_connector")
        XCTAssertEqual(MailConnection.connectionID(inAccountID:"outlook:ms1"),"ms1")
        let reach=MailWorkflowTools.messageReach(recipients:[address],settings:settings,native:NativeMailState())
        XCTAssertEqual(reach,[.object(["route":"outlook_connector","account":"ms1"])])
    }

    func testAGmailProfileDoesNotAnswerAnOutlookRequest() throws {
        var settings=MailSettings()
        var input=MailSettingsInput(); input.provider="outlook"
        let request=try MailSettingsCoordinator.request(.activate,email:address,instruction:"Connect Outlook.",input:input,settings:&settings)
        let wrong=MailConnection(id:"g1",email:address,connectionID:"link-g")
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[wrong],schedules:[],outcome:"",settings:&settings))
    }

    func testOutlookCalendarIsOfferedForEachOutlookAccount() throws {
        var settings=MailSettings()
        let offers=settings.calendarOffers(gmail:[],iCloud:[],outlook:[address])
        XCTAssertEqual(offers.map(\.provider),[.outlook])
        var input=MailSettingsInput(); input.provider=MailCalendarConnection.Provider.outlook.activation
        XCTAssertEqual(input.provider,"outlookCalendar")
        let request=try MailSettingsCoordinator.request(.activate,email:address,instruction:"Confirm Outlook Calendar.",input:input,settings:&settings)
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[],outcome:"Connected.",settings:&settings)
        XCTAssertEqual(settings.calendarState(.outlook,email:address),.connected)
        XCTAssertTrue(settings.connections.isEmpty)
    }
}
