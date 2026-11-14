import XCTest
@testable import BridgeCore

/// A backup must be safe to keep and safe to restore: no secrets in it, and nothing that could make an
/// already-used approval usable again.
@MainActor final class StateBackupTests: XCTestCase {
    func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
    func populated() throws -> URL {
        let root = directory()
        try MailSettingsStore(bridgeDirectory:root).transaction { settings in
            var profile = MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link"); profile.observedAt = Date()
            settings.connections = [profile]
            var schedule = MailSchedule(id:"schedule",title:"Mail Dot · Review",accountEmails:[profile.email],cadence:"Hourly",conditions:"Report actionable mail")
            schedule.observedAt = Date()
            settings.schedules = [schedule]; settings.linkedScheduleIDs = [schedule.id]
            settings.keepConnectedConfirmedAt = Date()
            try MailSettingsCoordinator.request(.refresh,instruction:"MARKER-INSTRUCTION",settings:&settings)
        }
        try BridgeStore(directory:root).transaction { state in
            let draft = MailDraft(id:1,subject:"MARKER-SUBJECT",sender:"owner@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],body:"MARKER-BODY",attachmentCount:0)
            var context = ReplyContext(id:"message",envelope:draft)
            BridgeCoordinator.share(draft,with:&context)
            var review = SendReview(draft:draft); review.consumed = true
            context.review = review
            state.contexts["message"] = context
            state.subscriptions = [EventSubscription(id:"sub_x",callbackURL:"https://chatgpt.com/MARKER-CALLBACK",secret:"whsec_MARKERSECRET",expiresAt:Date().addingTimeInterval(3600),verifiedAt:Date())]
        }
        return root
    }

    func testBackupHoldsSettingsButNoSecretsDraftsApprovalsOrPendingRequests() throws {
        let root = try populated(), destination = directory()
        let file = try StateBackup.export(bridgeDirectory:root,to:destination,build:"0.4.1 (59)")
        let text = try String(contentsOf:file,encoding:.utf8)
        XCTAssertFalse(text.contains("MARKER"),"No instruction, subject, body, callback address or secret may be exported.")
        XCTAssertTrue(text.contains("Mail Dot · Review"))
        let mode = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue,0o600)
    }

    func testRestoreBringsBackLinksWithoutRevivingApprovalsOrDotsUnverifiedClaim() throws {
        let root = try populated(), destination = directory()
        let file = try StateBackup.export(bridgeDirectory:root,to:destination,build:"0.4.1 (59)")
        let fresh = directory()
        try BridgeStore(directory:fresh).transaction { state in
            let draft = MailDraft(id:2,subject:"Later",sender:"owner@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],body:"Later",attachmentCount:0)
            var context = ReplyContext(id:"later",envelope:draft); BridgeCoordinator.share(draft,with:&context)
            var review = SendReview(draft:draft); review.consumed = true; context.review = review
            state.contexts["later"] = context
        }
        try MailSettingsStore(bridgeDirectory:fresh).transaction { $0.linkedScheduleIDs = ["kept-before-restore"] }
        try StateBackup.restore(from:file,bridgeDirectory:fresh)
        let keptFiles = try FileManager.default.contentsOfDirectory(atPath:fresh.appendingPathComponent("Configuration").path).filter { $0.hasPrefix("settings-before-restore-") }
        XCTAssertEqual(keptFiles.count,1)
        let kept = try JSONDecoder().decode(MailSettings.self,from:Data(contentsOf:fresh.appendingPathComponent("Configuration").appendingPathComponent(keptFiles[0])))
        XCTAssertEqual(kept.linkedScheduleIDs,["kept-before-restore"])
        let settings = try MailSettingsStore(bridgeDirectory:fresh).read()
        XCTAssertEqual(settings.linkedScheduleIDs,["schedule"])
        XCTAssertEqual(settings.connections.map(\.email),["owner@example.invalid"])
        XCTAssertTrue(settings.requests.isEmpty)
        XCTAssertNil(settings.keepConnectedConfirmedAt)
        // The live reply state is not part of a backup, so a used approval stays used.
        XCTAssertEqual(try BridgeStore(directory:fresh).read().contexts["later"]?.review?.consumed,true)
        XCTAssertNil(try BridgeStore(directory:fresh).read().contexts["message"])
    }

    func testSettingsWrittenByANewerBuildStillLoad() throws {
        let root = directory()
        try MailSettingsStore(bridgeDirectory:root).transaction { try MailSettingsCoordinator.request(.refresh,instruction:"Read actual settings",settings:&$0) }
        let file = root.appendingPathComponent("Configuration/settings.json")
        let text = try String(contentsOf:file,encoding:.utf8).replacingOccurrences(of:"\"kind\":\"refresh\"",with:"\"kind\":\"somethingFromTheFuture\"")
        try text.write(to:file,atomically:true,encoding:.utf8)
        let settings = try MailSettingsStore(bridgeDirectory:root).read()
        XCTAssertEqual(settings.requests.first?.kind,.unknown)
        XCTAssertTrue(settings.configurationRequests(for:.all).isEmpty)
    }
}
