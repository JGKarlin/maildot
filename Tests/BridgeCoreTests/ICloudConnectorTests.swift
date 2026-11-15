import XCTest
@testable import BridgeCore

final class ICloudConnectorTests: XCTestCase {
    private let account=NativeMailAccount(id:"A1",name:"iCloud",addresses:["owner@icloud.example.invalid"],server:"p01-imap.mail.me.com")

    func testAnICloudAccountIsRecognised() {
        XCTAssertTrue(account.isICloud)
        // Recognised by Apple's mail server alone, whatever the address (no real mailbox address appears in the tests).
        XCTAssertTrue(NativeMailAccount(id:"A2",name:"Me",addresses:["owner@example.invalid"],server:"imap.mail.me.com").isICloud)
        XCTAssertFalse(NativeMailAccount(id:"A3",name:"Work",addresses:["owner@work.example.invalid"],server:"imap.work.example.invalid").isICloud)
    }

    func testAConfirmedICloudConnectorCoversTheAccountAndRoutesThroughIt() throws {
        var settings=MailSettings()
        settings.nativeAccounts=[account]
        XCTAssertFalse(MailIndexPass.coveredByConnector(account:"A1",settings:settings))
        var connection=MailConnection(id:"ic1",email:"owner@icloud.example.invalid",connectionID:"link")
        connection.provider="icloud"; connection.observedAt=Date()
        settings.connections=[connection]
        XCTAssertNoThrow(try settings.validate())
        XCTAssertTrue(MailIndexPass.coveredByConnector(account:"A1",settings:settings))
        XCTAssertEqual(connection.accountID,"icloud:ic1")
        XCTAssertEqual(MailConnection.connectionID(inAccountID:"icloud:ic1"),"ic1")
        let accounts=try MailWorkflowAccount.available(settings:settings,native:NativeMailState())
        XCTAssertEqual(accounts.map(\.id),["icloud:ic1"])
        XCTAssertEqual(accounts.first?.route,"icloud")
        XCTAssertTrue(settings.accountIDs(receiving:["owner@icloud.example.invalid"]).contains("icloud:ic1"))
    }
    func testDotConfirmsAnICloudConnectionWithoutProfileIDs() throws {
        var settings=MailSettings()
        settings.nativeAccounts=[account]
        var input=MailSettingsInput(); input.provider="icloud"
        let request=try MailSettingsCoordinator.request(.activate,email:"owner@icloud.example.invalid",instruction:"Confirm the iCloud connector.",input:input,settings:&settings)
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[],outcome:"Connected.",settings:&settings)
        XCTAssertEqual(settings.connections.map(\.provider),["icloud"])
        XCTAssertTrue(MailIndexPass.coveredByConnector(account:"A1",settings:settings))
    }
}
