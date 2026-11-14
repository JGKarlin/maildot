import XCTest
@testable import BridgeCore

/// Explicitly enabled acceptance checks. Ordinary test runs never access real Mail.
@MainActor final class NativeMailLiveTests:XCTestCase {
    private let fixtureTitle="Mail Dot native read test - UNSENT"
    private func liveBridge() throws -> BridgeStore {
        guard ProcessInfo.processInfo.environment["MAIL_DOT_LIVE_NATIVE_TESTS"] == "1" else {
            throw XCTSkip("Live native Mail acceptance is explicitly opt-in.")
        }
        let directory=FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(BridgeStore.groupID)/BridgeState",isDirectory:true)
        guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("state.json").path) else {
            throw BridgeFailure("Start the installed Mail Dot companion before running live acceptance.")
        }
        return BridgeStore(directory:directory)
    }
    func testLiveOwnerScopeAndSyntheticDraftReading() async throws {
        let bridge=try liveBridge()
        let native=try NativeMailStore(bridgeDirectory:bridge.directory).read()
        let settings=try MailSettingsStore(bridgeDirectory:bridge.directory).read()
        let candidates=native.grants.filter { grant in
            grant.revokedAt == nil && grant.mailboxes.contains(where:{$0.path == ["Drafts"]}) &&
                settings.nativeAccounts.contains(where:{$0.id == grant.accountID && $0.addresses.contains(where:{$0.lowercased().hasSuffix("@icloud.com")})})
        }
        guard candidates.count == 1,let grant=candidates.first,
              let drafts=grant.mailboxes.first(where:{$0.path == ["Drafts"]}) else {
            throw BridgeFailure("Live acceptance requires one owner-authorized iCloud Drafts folder. No permission was changed.")
        }
        let router=MCPRouter(store:bridge,statelessTunnel:true)
        let status=try await call(router,"native_mail_status",[:])
        guard status["companion_available"] == true else { throw BridgeFailure("The installed Mail Dot companion is not available.") }
        let folders=try await call(router,"native_mail_list_mailboxes",["account_id":.string(grant.accountID)])
        XCTAssertEqual(folders["mailboxes"].array?.count,grant.mailboxes.count)
        XCTAssertEqual(folders["server_freshness_verified"],false)

        if let other=settings.nativeAccounts.first(where:{ account in account.id != grant.accountID && !native.grants.contains(where:{$0.accountID == account.id && $0.revokedAt == nil}) }) {
            let denied=try await response(router,"native_mail_list_mailboxes",["account_id":.string(other.id)])
            XCTAssertEqual(denied["result"]["isError"],true)
        }
        let forbidden=NativeMailbox(accountID:grant.accountID,path:["Junk"])
        guard !grant.mailboxes.contains(where:{$0.id == forbidden.id}) else {
            throw BridgeFailure("The Junk denial fixture is now authorized; no broader read was attempted.")
        }
        let denied=try await response(router,"native_mail_list_messages",["account_id":.string(grant.accountID),"mailbox_id":.string(forbidden.id)])
        XCTAssertEqual(denied["result"]["isError"],true)

        let since=Date().addingTimeInterval(-3600).ISO8601Format()
        let until=Date().addingTimeInterval(60).ISO8601Format()
        let arguments:JSONValue=["account_id":.string(grant.accountID),"mailbox_id":.string(drafts.id),"since":.string(since),"until":.string(until),"limit":50]
        let before=try fixture(in:await call(router,"native_mail_list_messages",arguments))
        guard let id=before["id"].integer,let fingerprint=before["fingerprint"].string else {
            throw BridgeFailure("Synthetic draft identity was incomplete; no body was requested.")
        }
        XCTAssertEqual(before["attachmentCount"].integer,0)
        let body=try await call(router,"native_mail_read_message",["account_id":.string(grant.accountID),"mailbox_id":.string(drafts.id),"message_id":.number(Double(id)),"expected_fingerprint":.string(fingerprint)])
        guard let text=body["text"].string else { throw BridgeFailure("Synthetic draft returned no text.") }
        XCTAssertTrue(text.contains("Fixture identifier: native-mail-read-20261109."))
        XCTAssertTrue(text.contains("Meeting: Thursday at 14:00."))
        XCTAssertTrue(text.contains("State: synthetic unsent test; no delivery intended."))
        XCTAssertEqual(body["attachmentContentsIncluded"],false)
        let after=try fixture(in:await call(router,"native_mail_list_messages",arguments))
        XCTAssertEqual(after["id"].integer,id)
        XCTAssertEqual(after["isRead"],before["isRead"])
        XCTAssertEqual(after["fingerprint"].string,fingerprint)
        XCTAssertFalse(try NativeMailStore(bridgeDirectory:bridge.directory).read().operations.contains(where:{$0.accountID == grant.accountID && $0.result != nil}))
    }
    private func fixture(in page:JSONValue) throws -> JSONValue {
        let matches=(page["messages"].array ?? []).filter { $0["subject"].string == fixtureTitle }
        guard matches.count == 1,let match=matches.first else {
            throw BridgeFailure("Exactly one saved synthetic draft was not found. No message body was requested.")
        }
        return match
    }
    private func call(_ router:MCPRouter,_ name:String,_ arguments:JSONValue) async throws -> JSONValue {
        let value=try await response(router,name,arguments)
        guard value["result"]["isError"] == false else {
            throw BridgeFailure(value["result"]["content"].array?.first?["text"].string ?? "Native acceptance request failed.")
        }
        return value["result"]["structuredContent"]
    }
    private func response(_ router:MCPRouter,_ name:String,_ arguments:JSONValue) async throws -> JSONValue {
        let request:JSONValue=["jsonrpc":"2.0","id":.string(UUID().uuidString),"method":"tools/call","params":["name":.string(name),"arguments":arguments]]
        guard let raw=await router.response(try request.text()) else { throw BridgeFailure("Native acceptance returned no protocol response.") }
        return try JSONDecoder().decode(JSONValue.self,from:Data(raw.utf8))
    }
}
