import XCTest
@testable import BridgeCore

final class MailWorkflowAccountsTests:XCTestCase {
    func testOnlyObservedAvailableConnectorsAndVerifiedNativeGrantsAreListed() throws {
        var settings=MailSettings(),native=NativeMailState()
        var gmail=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
        settings.connections=[gmail]
        settings.nativeAccounts=[NativeMailAccount(id:"icloud",name:"iCloud",addresses:["owner@icloud.example.invalid"],server:"imap.mail.me.com")]
        var grant=NativeMailGrant(accountID:"icloud",mailboxes:[NativeMailbox(accountID:"icloud",path:["INBOX"])])
        native.grants=[grant]
        XCTAssertTrue(try MailWorkflowAccount.available(settings:settings,native:native).isEmpty)
        gmail.observedAt=Date(); settings.connections=[gmail]
        grant.verifiedAt=Date(); native.grants=[grant]
        XCTAssertEqual(try MailWorkflowAccount.available(settings:settings,native:native).map(\.id),["gmail:profile","mail:icloud"])
        gmail.available=false; settings.connections=[gmail]
        grant.revokedAt=Date(); native.grants=[grant]
        XCTAssertTrue(try MailWorkflowAccount.available(settings:settings,native:native).isEmpty)
    }
}
