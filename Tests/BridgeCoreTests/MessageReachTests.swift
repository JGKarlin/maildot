import XCTest
@testable import BridgeCore

/// Mail sent to a second address of a mailbox Dot reads through its Gmail connector reaches Dot with that
/// connector as its route (owner report, 17 November 2026: such mail arrived with no route and could not be read).
final class MessageReachTests: XCTestCase {
    func settings() -> MailSettings {
        var settings = MailSettings()
        var university = MailConnection(id:"work", email:"owner@uni.example.invalid", connectionID:"link")
        university.observedAt = Date()
        settings.connections = [university]
        settings.nativeAccounts = [
            NativeMailAccount(id:"UNI", name:"University", addresses:["owner@uni.example.invalid","owner@dept.uni.example.invalid"], server:"imap.gmail.com"),
            NativeMailAccount(id:"OTHER", name:"Other", addresses:["owner@other.example.invalid"], server:"imap.other.example.invalid")]
        return settings
    }

    func testMailToASecondAddressOfAConnectorMailboxUsesTheConnector() {
        let routes = MailWorkflowTools.messageReach(recipients:["Owner@Dept.Uni.example.invalid"], settings:settings(), native:NativeMailState())
        XCTAssertEqual(routes, [["route":"gmail_connector","account":"work"]])
    }

    func testMailToTheConnectorAddressItselfIsListedOnce() {
        let routes = MailWorkflowTools.messageReach(recipients:["owner@uni.example.invalid","owner@dept.uni.example.invalid"], settings:settings(), native:NativeMailState())
        XCTAssertEqual(routes, [["route":"gmail_connector","account":"work"]])
    }

    func testAnAccountWithNoConnectorAndNoFolderAccessHasNoRoute() {
        XCTAssertEqual(MailWorkflowTools.messageReach(recipients:["owner@other.example.invalid"], settings:settings(), native:NativeMailState()), [])
    }

    func testAConnectorThatIsNotLiveIsNotOffered() {
        var settings = settings(); settings.connections[0].available = false
        XCTAssertEqual(MailWorkflowTools.messageReach(recipients:["owner@dept.uni.example.invalid"], settings:settings, native:NativeMailState()), [])
    }
}
