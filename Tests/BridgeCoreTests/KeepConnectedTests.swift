import XCTest
@testable import BridgeCore

/// Mail Dot asks Dot, without any action by the owner, to run the hourly job that renews its subscriptions.
@MainActor final class KeepConnectedTests: XCTestCase {
    func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
    func hub(_ root:URL) -> EventHub { EventHub(store:BridgeStore(directory:root),sender:{ _ in (Data(),200) }) }
    func keepConnected(_ settings:MailSettings) -> [MailSettingsRequest] { settings.requests.filter { $0.kind == .keepConnected } }

    func testKeepConnectedIsRequestedAutomaticallyAndOnlyOnce() async throws {
        let root = root(), hub = hub(root), store = MailSettingsStore(bridgeDirectory:root)
        await hub.pump(); await hub.pump()
        let requests = keepConnected(try store.read())
        XCTAssertEqual(requests.count,1)
        XCTAssertEqual(requests.first?.status,.pending)
        XCTAssertEqual(requests.first?.instruction,MailSettingsCoordinator.keepConnectedInstruction)
        XCTAssertTrue(MailSettingsCoordinator.keepConnectedInstruction.contains("Mail Dot · Keep connected"))
        XCTAssertTrue(MailSettingsCoordinator.keepConnectedInstruction.contains("bridge_status"))
    }

    func testConfirmationIsRecordedAndStopsFurtherRequests() async throws {
        let root = root(), hub = hub(root), store = MailSettingsStore(bridgeDirectory:root)
        await hub.pump()
        let pending = try XCTUnwrap(keepConnected(try store.read()).first)
        let revision = try store.read().revision
        _ = try MailSettingsTools.call("report_mail_settings",arguments:["request_id":.string(pending.id),"expected_revision":.number(Double(revision)),"outcome":"Hourly connection check is on","result_code":"verified","stage":"confirmed"],store:store)
        XCTAssertNotNil(try store.read().keepConnectedConfirmedAt)
        await hub.pump()
        XCTAssertEqual(keepConnected(try store.read()).count,1)
        XCTAssertEqual(keepConnected(try store.read()).first?.status,.confirmed)
    }

    func testConfirmationMustNotCarryAccountOrScheduleInventory() async throws {
        let root = root(), hub = hub(root), store = MailSettingsStore(bridgeDirectory:root)
        await hub.pump()
        let pending = try XCTUnwrap(keepConnected(try store.read()).first)
        var settings = try store.read()
        let profile = MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:pending.id,expectedRevision:settings.revision,connections:[profile],schedules:[],outcome:"On",settings:&settings))
        XCTAssertNil(settings.keepConnectedConfirmedAt)
    }

    func testFailedRequestIsRetriedOnlyAfterSixHours() async throws {
        let root = root(), hub = hub(root), store = MailSettingsStore(bridgeDirectory:root)
        await hub.pump()
        let first = try XCTUnwrap(keepConnected(try store.read()).first)
        _ = try MailSettingsTools.call("report_mail_settings",arguments:["request_id":.string(first.id),"expected_revision":.number(Double(try store.read().revision)),"outcome":"Scheduled jobs are unavailable in this run","result_code":"capabilityUnavailable","stage":"failed"],store:store)
        await hub.pump()
        XCTAssertEqual(keepConnected(try store.read()).filter { $0.status == .pending }.count,0)
        try store.transaction { settings in
            for index in settings.requests.indices where settings.requests[index].id == first.id {
                settings.requests[index].createdAt = Date().addingTimeInterval(-7*3600)
            }
        }
        await hub.pump(); await hub.pump()
        XCTAssertEqual(keepConnected(try store.read()).filter { $0.status == .pending }.count,1)
    }

    func testRequestDotNeverAnsweredIsMarkedAndAskedAgain() async throws {
        let root = root(), hub = hub(root), store = MailSettingsStore(bridgeDirectory:root)
        await hub.pump()
        let first = try XCTUnwrap(keepConnected(try store.read()).first)
        try store.transaction { settings in
            for index in settings.requests.indices where settings.requests[index].id == first.id {
                settings.requests[index].createdAt = Date().addingTimeInterval(-2*3600)
            }
        }
        await hub.pump(); await hub.pump()
        let requests = keepConnected(try store.read())
        XCTAssertEqual(requests.first { $0.id == first.id }?.status,.failed)
        XCTAssertEqual(requests.first { $0.id == first.id }?.resultCode,"noAnswer")
        XCTAssertEqual(requests.filter { $0.status == .pending }.count,1)
    }

    func testRequestWhoseDeliveryGaveUpIsAskedAgainAtOnce() async throws {
        let root = root(), hub = hub(root), store = MailSettingsStore(bridgeDirectory:root)
        await hub.pump()
        let first = try XCTUnwrap(keepConnected(try store.read()).first)
        try store.transaction { settings in
            for index in settings.requests.indices where settings.requests[index].id == first.id { settings.requests[index].event.attempts = 8 }
        }
        await hub.pump()
        let requests = keepConnected(try store.read())
        XCTAssertEqual(requests.first { $0.id == first.id }?.status,.failed)
        XCTAssertEqual(requests.filter { $0.status == .pending }.count,1)
    }

    func testUnansweredRequestsBackOffAndThenStop() throws {
        var settings = MailSettings()
        var now = Date(timeIntervalSince1970:1_800_000_000)
        var asked = 0
        // Simulate Dot never answering for four days, checking every five minutes.
        for _ in 0..<(4*24*12) {
            let before = settings.requests.filter { $0.kind == .keepConnected }.count
            _ = try MailSettingsCoordinator.ensureKeepConnected(settings:&settings,now:now)
            asked += settings.requests.filter { $0.kind == .keepConnected }.count - before
            if let index = settings.requests.indices.last, settings.requests[index].kind == .keepConnected, settings.requests[index].createdAt > now { settings.requests[index].createdAt = now }
            now.addTimeInterval(300)
        }
        XCTAssertEqual(asked,MailSettingsCoordinator.keepConnectedMaximumUnanswered)
        XCTAssertEqual(settings.keepConnectedUnanswered,MailSettingsCoordinator.keepConnectedMaximumUnanswered)
        XCTAssertTrue(MailSettingsCoordinator.keepConnectedStopped(settings))
        MailSettingsCoordinator.retryKeepConnected(settings:&settings)
        XCTAssertFalse(MailSettingsCoordinator.keepConnectedStopped(settings))
        XCTAssertTrue(try MailSettingsCoordinator.ensureKeepConnected(settings:&settings,now:now))
    }

    func testConfirmationWithNoEvidenceForADayIsWithdrawnAndAskedAgain() throws {
        var settings = MailSettings()
        let confirmed = Date(timeIntervalSince1970:1_800_000_000)
        settings.keepConnectedConfirmedAt = confirmed
        // Dot's own claim is not evidence. With a recent check on record the confirmation stands.
        XCTAssertFalse(try MailSettingsCoordinator.ensureKeepConnected(settings:&settings,lastStatusCheck:confirmed.addingTimeInterval(29*3600),now:confirmed.addingTimeInterval(30*3600)))
        XCTAssertNotNil(settings.keepConnectedConfirmedAt)
        // With none for more than a day it is withdrawn and the job is requested again.
        XCTAssertTrue(try MailSettingsCoordinator.ensureKeepConnected(settings:&settings,lastStatusCheck:confirmed.addingTimeInterval(3600),now:confirmed.addingTimeInterval(30*3600)))
        XCTAssertNil(settings.keepConnectedConfirmedAt)
        XCTAssertEqual(settings.requests.filter { $0.kind == .keepConnected && $0.status == .pending }.count,1)
    }

    func testRenewalHealthRestsOnEvidenceHeldByTheMac() {
        let now = Date(timeIntervalSince1970:1_800_000_000)
        XCTAssertEqual(RenewalHealth.evaluate(lastStatusCheck:now.addingTimeInterval(-1800),allSubscriptionsLive:true,now:now),.working(lastCheck:now.addingTimeInterval(-1800)))
        XCTAssertEqual(RenewalHealth.evaluate(lastStatusCheck:now.addingTimeInterval(-3*3600),allSubscriptionsLive:true,now:now),.notChecking(since:now.addingTimeInterval(-3*3600)))
        XCTAssertEqual(RenewalHealth.evaluate(lastStatusCheck:nil,allSubscriptionsLive:true,now:now),.notChecking(since:nil))
        XCTAssertEqual(RenewalHealth.evaluate(lastStatusCheck:now.addingTimeInterval(-600),allSubscriptionsLive:false,now:now),.lapsed(lastCheck:now.addingTimeInterval(-600)))
    }

    func testKeepConnectedRequestStaysOffTheAccountAndSchedulePages() async throws {
        let root = root(), hub = hub(root), store = MailSettingsStore(bridgeDirectory:root)
        await hub.pump()
        let settings = try store.read()
        XCTAssertTrue(settings.configurationRequests(for:.accounts).isEmpty)
        XCTAssertTrue(settings.configurationRequests(for:.schedules).isEmpty)
        XCTAssertTrue(settings.configurationRequests(for:.all).isEmpty)
    }

    func testDeliveryLogShowsARequestWaitingAndThenDelivered() async throws {
        let root = root(), log = root.appendingPathComponent("Logs/tool-calls.log")
        let secret = "whsec_" + Data(repeating:7,count:32).base64EncodedString()
        let hub = EventHub(store:BridgeStore(directory:root),sender:{ request in
            let body = try JSONDecoder().decode(JSONValue.self,from:request.httpBody!)
            if body["type"] == "verification" { return (Data(try JSONValue.object(["challenge":body["challenge"]]).text().utf8),200) }
            return (Data(),200)
        },deliveryLog:log)
        await hub.pump(); await hub.pump()
        func eventLines() throws -> [String] { try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map(String.init).filter { $0.contains(" event mail.settings_requested") } }
        var lines = try eventLines()
        XCTAssertEqual(lines.count,1)
        XCTAssertTrue(lines[0].hasSuffix(" event mail.settings_requested waiting subscription=none"),lines[0])
        _ = try await hub.subscribe(["name":"mail.settings_requested","arguments":["queue_id":"personal"],"delivery":["mode":"webhook","url":"https://chatgpt.com/settings","secret":.string(secret)],"ttlMs":120000])
        await hub.pump()
        lines = try eventLines()
        XCTAssertEqual(lines.count,2)
        let all = try String(contentsOf:log,encoding:.utf8)
        XCTAssertTrue(all.contains(" state reply=missing settings=missing menu=missing keepConnected=pending"),all)
        XCTAssertTrue(all.contains(" state reply=missing settings=active menu=missing keepConnected=pending"),all)
        XCTAssertTrue(lines[1].hasSuffix(" event mail.settings_requested status=200 subscription=active"),lines[1])
    }

    func testSettingsContractTellsDotHowToHandleTheRequest() throws {
        let store = MailSettingsStore(bridgeDirectory:root())
        let contract = try MailSettingsTools.call("get_mail_settings",arguments:[:],store:store)["response_contract"]["instruction"].string
        XCTAssertTrue(try XCTUnwrap(contract).contains("keepConnected"))
    }
}
