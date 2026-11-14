import XCTest
@testable import BridgeCore

/// Mail Dot is inactive until Dot has answered on this Mac, and again if Dot stops answering (14 November 2026).
final class DotAccessTests:XCTestCase {
    func testANewSetupWaitsForDotAndActivatesWhenItAnswers() {
        var settings=MailSettings()
        XCTAssertFalse(settings.dotActive)
        XCTAssertTrue(settings.dotCheckDue(),"Mail Dot checks on its own")
        settings.requestDotCheck()
        XCTAssertFalse(settings.dotCheckDue(),"one check at a time")
        settings.markDotCheckSent(requestID:"c1")
        settings.noteDotAnswered()
        XCTAssertTrue(settings.dotActive)
        XCTAssertNil(settings.effectiveDotAccess.checkRequestedAt)
    }
    func testAnExistingSetupThatDotAlreadyConfirmedStaysActive() {
        var settings=MailSettings(); settings.keepConnectedConfirmedAt=Date()
        XCTAssertNil(settings.dotAccess)
        XCTAssertTrue(settings.dotActive)
    }
    /// The check never locks anyone out (owner requirement): silence after Dot has answered only shows a notice.
    func testSilenceAfterDotHasAnsweredNeverMakesMailDotInactive() {
        var settings=MailSettings(); settings.noteDotAnswered()
        settings.noteDotSilent(DotAccess.silenceLimit+5)
        XCTAssertTrue(settings.dotActive,"a network failure or a sleeping Mac must not switch Mail Dot off")
        XCTAssertTrue(settings.effectiveDotAccess.quiet)
        XCTAssertFalse(settings.dotCheckDue(),"no automatic checks for an active setup")
        settings.noteDotAnswered()
        XCTAssertFalse(settings.effectiveDotAccess.quiet)
    }
    func testAnUnansweredCheckIsGivenUpAndCanBeRetried() {
        var settings=MailSettings()
        settings.requestDotCheck(); settings.markDotCheckSent(requestID:"c1",now:Date().addingTimeInterval(-MailTriageState.answerLimit-60))
        XCTAssertTrue(settings.expireDotCheck())
        XCTAssertNil(settings.effectiveDotAccess.checkRequestedAt)
        XCTAssertFalse(settings.dotCheckDue(),"the next automatic check waits its half hour")
        settings.requestDotCheck()
        XCTAssertTrue(settings.effectiveDotAccess.checking,"Check Again works at once")
    }
    func testSavedSettingsWithoutTheFieldStillLoad() throws {
        let saved=try JSONEncoder().encode(MailSettings())
        XCTAssertNil(try JSONDecoder().decode(MailSettings.self,from:saved).dotAccess)
        XCTAssertTrue(MailWorkflowTools.instructions(for:.check).contains("Ready"))
    }
}

final class RuntimeSetupTests: XCTestCase {
    func testConnectionIDsAreCheckedAndSettingsWrittenPrivately() throws {
        XCTAssertTrue(RuntimeSetup.validTunnelID("tunnel_"+String(repeating:"0",count:32)))
        XCTAssertTrue(RuntimeSetup.validTunnelID("tunnel_ab12_"+String(repeating:"f",count:32)))
        XCTAssertFalse(RuntimeSetup.validTunnelID("tunnel_abc-123_X"),"the tunnel client refuses it")
        XCTAssertFalse(RuntimeSetup.validTunnelID("abc"))
        XCTAssertFalse(RuntimeSetup.validTunnelID("tunnel_"))
        XCTAssertFalse(RuntimeSetup.validTunnelID("tunnel_a b"))
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("runtime-setup-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:home) }
        let paths=RuntimeSetup.Paths(home:home)
        XCTAssertFalse(RuntimeSetup.isConfigured(paths:paths))
        XCTAssertThrowsError(try RuntimeSetup.write(tunnelID:"nope",agentPath:"/Applications/Mail Dot.app/Contents/Helpers/MailDotAgent",paths:paths))
        try RuntimeSetup.write(tunnelID:" tunnel_"+String(repeating:"a",count:32)+" ",agentPath:"/Applications/Mail Dot.app/Contents/Helpers/MailDotAgent",paths:paths)
        XCTAssertTrue(RuntimeSetup.isConfigured(paths:paths))
        XCTAssertEqual(RuntimeSetup.tunnelID(paths:paths),"tunnel_"+String(repeating:"a",count:32))
        for url in [paths.profile,paths.configuration] {
            let mode=(try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(mode & 0o077,0,"owner only")
        }
        let profile=try JSONSerialization.jsonObject(with:Data(contentsOf:paths.profile)) as! [String:Any]
        XCTAssertNil((profile["control_plane"] as? [String:Any])?["api_key"],"the key is never in the profile")
        XCTAssertEqual(((profile["mcp"] as? [String:Any])?["commands"] as? [[String:Any]])?.first?["command"] as? String,"\"/Applications/Mail Dot.app/Contents/Helpers/MailDotAgent\"")
        let configuration=try JSONSerialization.jsonObject(with:Data(contentsOf:paths.configuration)) as! [String:Any]
        XCTAssertEqual(configuration["keySource"] as? String,"keychain"); XCTAssertNil(configuration["credentialPath"])
    }
}

final class WaitForWorkTests: XCTestCase {
    func testTheCallIsHeldUntilARequestWaitsAndHandsEachOverOnce() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("wait-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        // Nothing waits: it gives up at the (shortest allowed) timeout.
        let idle=try await MailWorkflowTools.waitForWork(arguments:["timeout_seconds":5],bridgeDirectory:root)
        XCTAssertEqual(idle["work"],false)
        // A request arriving while the call is held is handed over, and not a second time.
        let request=try MailWorkflowRequest(action:.check,accountIDs:["gmail:a@example.invalid"])
        Task.detached {
            try? await Task.sleep(for:.seconds(1))
            try? MailWorkflowStore(bridgeDirectory:root).transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:a@example.invalid"]) }
        }
        let found=try await MailWorkflowTools.waitForWork(arguments:["timeout_seconds":20],bridgeDirectory:root)
        XCTAssertEqual(found["work"],true)
        XCTAssertEqual(found["requests"].array?.first?["id"].string,request.id)
        XCTAssertEqual(found["requests"].array?.first?["action"].string,"check")
        let again=try await MailWorkflowTools.waitForWork(arguments:["timeout_seconds":5],bridgeDirectory:root)
        XCTAssertEqual(again["work"],false,"a request already handed over is not handed over again at once")
    }
}

/// One worker per request (release review, 14 November 2026): a listener on the Mac and Dot in the cloud both
/// answered one request in the trial, each paying to read it.
final class RequestClaimTests: XCTestCase {
    private func bridge() throws -> (URL,MailWorkflowStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("claim-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try MailSettingsStore(bridgeDirectory:root).transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        return (root,MailWorkflowStore(bridgeDirectory:root))
    }
    private func enqueue(_ action:MailWorkflowAction,_ store:MailWorkflowStore) throws -> MailWorkflowRequest {
        let request=try MailWorkflowRequest(action:action,accountIDs:["gmail:profile"])
        try store.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        return request
    }
    func testTheWorkerThatTakesARequestKeepsItAndAnotherIsRefused() async throws {
        let (root,store)=try bridge(); defer { try? FileManager.default.removeItem(at:root) }
        let request=try enqueue(.check,store)
        let found=try await MailWorkflowTools.waitForWork(arguments:["timeout_seconds":5],bridgeDirectory:root,worker:"mac")
        XCTAssertEqual(found["requests"].array?.first?["id"].string,request.id)
        // Another worker sees it marked in the index, cannot read it and cannot report on it.
        let index=try MailWorkflowTools.call("get_mail_workflow",arguments:[:],bridgeDirectory:root,worker:"cloud")
        XCTAssertEqual(index["requests"].array?.first?["handled_by_another_session"],true)
        XCTAssertThrowsError(try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root,worker:"cloud"))
        let report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Ready",items:[])
        XCTAssertThrowsError(try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root,worker:"cloud"))
        XCTAssertEqual(try store.read().requests[0].revision,0)
        // The worker that took it reads it, without the claim shown, and reports.
        let read=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root,worker:"mac")
        XCTAssertNil(read["request"].object?["claim"])
        XCTAssertNil(try MailWorkflowTools.call("get_mail_workflow",arguments:[:],bridgeDirectory:root,worker:"mac")["requests"].array?.first?.object?["handled_by_another_session"])
        _ = try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root,worker:"mac")
        XCTAssertEqual(try store.read().requests[0].stage,.ready)
        // Finished work is open to read by anyone again.
        XCTAssertNoThrow(try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root,worker:"cloud"))
    }
    func testReadingARequestTakesItAndAnAbandonedOneIsFreeAfterTenMinutes() throws {
        let (root,store)=try bridge(); defer { try? FileManager.default.removeItem(at:root) }
        let request=try enqueue(.check,store)
        _ = try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root,worker:"cloud")
        XCTAssertEqual(try store.read().requests[0].claim?.worker,"cloud")
        var state=try store.read()
        XCTAssertFalse(state.take(request.id,worker:"mac"))
        XCTAssertTrue(state.requests[0].claimed(byAnotherThan:"mac"))
        let later=Date().addingTimeInterval(MailWorkflowRequest.claimLease+1)
        XCTAssertFalse(state.requests[0].claimed(byAnotherThan:"mac",now:later))
        XCTAssertTrue(state.take(request.id,worker:"mac",now:later))
        XCTAssertEqual(state.requests[0].claim?.worker,"mac")
    }
    func testWaitingReturnsOnlyTheKindsAskedForAndMarksAListener() async throws {
        let (root,store)=try bridge(); defer { try? FileManager.default.removeItem(at:root) }
        let check=try enqueue(.check,store)
        XCTAssertFalse(try store.read().listenerActive())
        let none=try await MailWorkflowTools.waitForWork(arguments:["timeout_seconds":5,"actions":["ask"]],bridgeDirectory:root,worker:"mac")
        XCTAssertEqual(none["work"],false,"a check is not handed to a listener that asked only for questions")
        XCTAssertNil(try store.read().requests[0].claim)
        XCTAssertTrue(try store.read().listenerActive())
        let some=try await MailWorkflowTools.waitForWork(arguments:["timeout_seconds":5,"actions":["ask","check"]],bridgeDirectory:root,worker:"mac")
        XCTAssertEqual(some["requests"].array?.first?["id"].string,check.id)
        do {
            _ = try await MailWorkflowTools.waitForWork(arguments:["timeout_seconds":5,"actions":["everything"]],bridgeDirectory:root,worker:"mac")
            XCTFail("an unknown kind is refused")
        } catch {}
    }
    func testStateSavedByEarlierBuildsStillReads() throws {
        let old=#"{"schemaVersion":1,"requests":[],"dismissedItemVersions":[],"questions":[]}"#
        let state=try JSONDecoder().decode(MailWorkflowState.self,from:Data(old.utf8))
        XCTAssertNil(state.listenerSeenAt); XCTAssertFalse(state.listenerActive())
    }
    func testOnlyOneHelperSendsNotices() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("lease-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var first:EventPumpLease?=EventPumpLease(bridgeDirectory:root)
        let second=EventPumpLease(bridgeDirectory:root)
        XCTAssertTrue(try XCTUnwrap(first).held); XCTAssertTrue(try XCTUnwrap(first).held)
        XCTAssertFalse(second.held)
        first=nil   // the first helper ends: the next to ask sends the notices
        XCTAssertTrue(second.held)
    }
}

final class OnMacSetupTests: XCTestCase {
    private let agent="/Applications/Mail Dot.app/Contents/Helpers/MailDotAgent"
    func testTheEntryIsAddedWithoutTouchingTheRestOfTheFile() throws {
        XCTAssertEqual(CodexRegistration.registering(agentPath:agent,in:nil),"[mcp_servers.maildot]\ncommand = \"\(agent)\"\n")
        let existing="model = \"x\"\n\n[mcp_servers.other]\ncommand = \"a\"\n"
        let added=try XCTUnwrap(CodexRegistration.registering(agentPath:agent,in:existing))
        XCTAssertTrue(added.hasPrefix(existing))
        XCTAssertEqual(CodexRegistration.registeredPath(in:added),agent)
        XCTAssertNil(CodexRegistration.registering(agentPath:agent,in:added),"an entry already naming this helper is left alone")
        XCTAssertNil(CodexRegistration.registeredPath(in:existing))
    }
    func testAnEntryNamingAnotherCopyIsCorrectedInPlace() throws {
        let old="[mcp_servers.maildot]\ncommand = \"/Users/someone/Old/Mail Dot.app/Contents/Helpers/MailDotAgent\"\nstartup_timeout_sec = 20\n\n[profiles.p]\ncommand = \"keep\"\n"
        let fixed=try XCTUnwrap(CodexRegistration.registering(agentPath:agent,in:old))
        XCTAssertEqual(CodexRegistration.registeredPath(in:fixed),agent)
        XCTAssertTrue(fixed.contains("startup_timeout_sec = 20"))
        XCTAssertTrue(fixed.hasSuffix("[profiles.p]\ncommand = \"keep\"\n"),"another table's command is not Mail Dot's")
        XCTAssertEqual(fixed.components(separatedBy:"\n").count,old.components(separatedBy:"\n").count)
    }
    func testAPathWithQuotesSurvivesTheRoundTrip() throws {
        let odd="/Users/a \"b\"/Mail Dot.app/Contents/Helpers/MailDotAgent"
        let written=try XCTUnwrap(CodexRegistration.registering(agentPath:odd,in:""))
        XCTAssertEqual(CodexRegistration.registeredPath(in:written),odd)
    }
    func testDotIsAskedToListenAtWideningIntervalsAndThenLeftAlone() {
        var input=ListenerWatch.Input(); let now=input.now
        input.canReachDot=true
        XCTAssertEqual(ListenerWatch.step(input),.askDotToListen,"no listener has ever been seen")
        input.lastAskedAt=now.addingTimeInterval(-300); input.asks=1
        XCTAssertEqual(ListenerWatch.step(input),.nothing,"asked five minutes ago")
        input.lastAskedAt=now.addingTimeInterval(-700)
        XCTAssertEqual(ListenerWatch.step(input),.askDotToListen)
        input.asks=2
        XCTAssertEqual(ListenerWatch.step(input),.nothing,"the second wait is twenty minutes")
        input.asks=3; input.lastAskedAt=now.addingTimeInterval(-86400)
        XCTAssertEqual(ListenerWatch.step(input),.nothing,"after three asks Mail Dot stops asking by itself")
        input.canReachDot=false; input.asks=0; input.lastAskedAt=nil
        XCTAssertEqual(ListenerWatch.step(input),.nothing,"ChatGPT is closed")
    }
    func testAWorkerThatAsksOrReportsCountsAsListening() {
        var input=ListenerWatch.Input(); let now=input.now
        input.canReachDot=true; input.canStartTask=true; input.oldestWaiting=now.addingTimeInterval(-600)
        input.listenerSeenAt=now.addingTimeInterval(-20)
        XCTAssertTrue(ListenerWatch.listening(input)); XCTAssertEqual(ListenerWatch.step(input),.nothing)
        // Drafting a reply takes minutes, during which the listener asks for no work; its reports show it is there.
        input.listenerSeenAt=now.addingTimeInterval(-400); input.lastClaimAt=now.addingTimeInterval(-60)
        XCTAssertTrue(ListenerWatch.listening(input))
        input.lastClaimAt=now.addingTimeInterval(-400)
        XCTAssertFalse(ListenerWatch.listening(input))
        XCTAssertEqual(ListenerWatch.step(input),.startTask,"a request has waited ten minutes with no worker")
        input.oldestWaiting=now.addingTimeInterval(-30)
        XCTAssertEqual(ListenerWatch.step(input),.askDotToListen,"a request made half a minute ago is given time")
        input.canStartTask=false; input.oldestWaiting=now.addingTimeInterval(-600)
        XCTAssertEqual(ListenerWatch.step(input),.askDotToListen)
    }
}

/// The approved Connection design (14 November 2026): what the lines, the banner and the window line are decided from.
final class ConnectionTests: XCTestCase {
    private func access(confirmed:Bool,unanswered:Int=0) -> DotAccess {
        var access=DotAccess(); if confirmed { access.confirmedAt=Date(); access.lastAnsweredAt=Date() }; access.unanswered=unanswered; return access
    }
    func testDotIsAvailableWhileAWorkerListensOrTheTunnelIsConnected() {
        var connection=ConnectionState(); connection.chatGPT = .open
        XCTAssertEqual(DotAvailability(access:access(confirmed:false),connection:connection,listening:true),.available)
        XCTAssertEqual(DotAvailability(access:access(confirmed:true),connection:connection,listening:false),.notConnected)
        connection.chatGPT = .closed
        XCTAssertEqual(DotAvailability(access:access(confirmed:true),connection:connection,listening:false),.notConnected,"whether ChatGPT is open is not the reason")
        connection.tunnelConnected=true
        XCTAssertEqual(DotAvailability(access:access(confirmed:true),connection:connection,listening:false),.available,"Dot works in the cloud with ChatGPT closed")
        XCTAssertEqual(DotAvailability(access:access(confirmed:true),connection:connection,listening:false),.available,"Dot in the cloud answers through the tunnel")
        XCTAssertEqual(DotAvailability(access:access(confirmed:false),connection:connection,listening:false),.notYetAnswered)
        let quiet=access(confirmed:true,unanswered:DotAccess.silenceLimit)
        XCTAssertEqual(DotAvailability(access:quiet,connection:connection,listening:false),.silent(since:quiet.lastAnsweredAt))
        XCTAssertEqual(DotAvailability(access:access(confirmed:true),connection:nil,listening:false),.available,"no findings saved yet: judged as before")
    }
    func testTheBannerSaysUnavailableOnlyWhereDotIsWaitedFor() {
        XCTAssertEqual(MailDotBanner.drafting.shown(.notConnected),.dotUnavailable)
        XCTAssertEqual(MailDotBanner.drafting.shown(.available),.drafting)
        XCTAssertEqual(MailDotBanner.draftReady.shown(.notConnected),.draftReady,"a draft already made is still ready")
        XCTAssertEqual(MailDotBanner.noReplyNeeded.shown(.notYetAnswered),.dotUnavailable)
        XCTAssertEqual(MailDotBanner.dotUnavailable.title,"💤 Dot unavailable")
    }
    func testOnlyTheListenersOwnWorkShowsItIsPresent() throws {
        var state=MailWorkflowState(); let now=Date()
        try state.enqueue(MailWorkflowRequest(action:.check,accountIDs:["gmail:a"]),allowedAccountIDs:["gmail:a"])
        XCTAssertFalse(state.workerListening(now:now))
        XCTAssertNotNil(state.oldestWaiting(now:now))
        // Dot in the cloud takes the request: no listener is on this Mac for that.
        XCTAssertTrue(state.take(state.requests[0].id,worker:"cloud",now:now))
        XCTAssertFalse(state.workerListening(now:now))
        XCTAssertNil(state.oldestWaiting(now:now),"a request a worker holds is not waiting")
        // A listener that waited ten minutes ago and reported a minute ago is still there.
        state.listenerSeenAt=now.addingTimeInterval(-600); state.listenerWorker="cloud"
        XCTAssertTrue(state.workerListening(now:now))
        XCTAssertFalse(state.workerListening(now:now.addingTimeInterval(ListenerWatch.gone+1)))
    }
    func testTheFirstThreeLinesDecideWhetherDotCanBeAsked() {
        var connection=ConnectionState()
        XCTAssertFalse(connection.canReachDot)
        connection.mail = .allowed; connection.accessibility=true; connection.chatGPT = .open
        XCTAssertTrue(connection.canReachDot)
        connection.chatGPT = .closed
        XCTAssertFalse(connection.canReachDot)
        var other=connection; other.asks=2; other.request = .askDotToListen
        XCTAssertTrue(connection.sameFindings(as:other))
        other.accessibility=false
        XCTAssertFalse(connection.sameFindings(as:other))
        XCTAssertFalse(connection.asking())
        connection.askedToListenAt=Date().addingTimeInterval(-30)
        XCTAssertTrue(connection.asking())
    }
}

/// The setup step Dot uses to hand Mail Dot its connection (owner approval, 14 November 2026).
final class ConnectionSetupTests: XCTestCase {
    func testTheSetupStepIsOfferedOnlyByAHelperStartedForSetup() async throws {
        XCTAssertFalse(ConnectionSetup.enabled,"tests run without MAILDOT_SETUP_MODE, as the helper the tunnel runs does")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let router=MCPRouter(store:BridgeStore(directory:root),statelessTunnel:true)
        let answer=await router.response(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let line=try XCTUnwrap(answer)
        let listed=try JSONDecoder().decode(JSONValue.self,from:Data(line.utf8))
        XCTAssertNotNil(listed["result"]["tools"].array)
        XCTAssertFalse(listed["result"]["tools"].array?.contains{ $0["name"].string == ConnectionSetup.toolName } ?? true)
    }
    func testATestOfSetupWritesElsewhereAndTheProfileNamesTheHelpersArguments() throws {
        let target=ConnectionSetup.Target.current(["MAILDOT_SETUP_HOME":"/tmp/maildot-setup-test","MAILDOT_SETUP_STORE":"/tmp/maildot-setup-test/store"])
        XCTAssertTrue(target.test)
        XCTAssertTrue(target.paths.runtime.path.hasPrefix("/tmp/maildot-setup-test/"))
        XCTAssertNotEqual(target.keyService,RuntimeSetup.keyService,"a test never touches the real Keychain item")
        let profile=RuntimeSetup.profile(tunnelID:"tunnel_abc",agentPath:"/A b/MailDotAgent",agentArguments:target.agentArguments,paths:target.paths)
        XCTAssertEqual(((profile["mcp"] as? [String:Any])?["commands"] as? [[String:Any]])?.first?["command"] as? String,"\"/A b/MailDotAgent\" \"--store\" \"/tmp/maildot-setup-test/store\"")
        // Written as the tunnel client's YAML reader accepts it: no escaped slashes.
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("setup-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let paths=RuntimeSetup.Paths(home:folder)
        try RuntimeSetup.write(tunnelID:"tunnel_"+String(repeating:"a",count:32),agentPath:"/A b/MailDotAgent",agentArguments:["--store","/s"],clientPath:"/c/tunnel-client",paths:paths)
        for file in [paths.profile,paths.configuration] { XCTAssertFalse(try String(contentsOf:file,encoding:.utf8).contains("\\/"),file.lastPathComponent) }
        let real=ConnectionSetup.Target.current([:])
        XCTAssertFalse(real.test); XCTAssertEqual(real.keyService,RuntimeSetup.keyService); XCTAssertTrue(real.agentArguments.isEmpty)
    }
    func testABadTunnelIDOrAnEmptyKeyIsRefusedBeforeAnythingIsSaved() async {
        let target=ConnectionSetup.Target.current(["MAILDOT_SETUP_HOME":"/tmp/maildot-setup-refused"])
        let valid=JSONValue.string("tunnel_"+String(repeating:"a",count:32))
        let cases:[[String:JSONValue]]=[["tunnel_id":"nope","api_key":"x"],["tunnel_id":"tunnel_abc","api_key":"x"],["tunnel_id":valid,"api_key":"  "]]
        for arguments in cases {
            do { _ = try await ConnectionSetup.run(arguments:arguments,agent:URL(fileURLWithPath:"/nonexistent/MailDotAgent"),target:target); XCTFail("refused") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:"/tmp/maildot-setup-refused"))
    }
}

final class SetupProgressTests: XCTestCase {
    func testProgressIsKeptInOrderAndAKeyNeverIs() throws {
        let store=FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:store) }
        _ = try ConnectionSetup.recordProgress(arguments:["step":"started"],store:store)
        _ = try ConnectionSetup.recordProgress(arguments:["step":"blocked","note":"key is sk-abcdefghijklmnop"],store:store)
        XCTAssertThrowsError(try ConnectionSetup.recordProgress(arguments:["step":"anything"],store:store))
        let saved=try JSONDecoder().decode([[String:String]].self,from:Data(contentsOf:store.appendingPathComponent("setup-progress.json")))
        XCTAssertEqual(saved.map{$0["step"]},["started","blocked"])
        XCTAssertFalse(saved[1]["note"]?.contains("sk-") ?? true)
    }
}

final class SetupThroughDotTests: XCTestCase {
    func testSetupEntryReplacesEarlierOnesAndRemovalLeavesTheRestAlone() {
        let other="model = \"x\"\n\n[mcp_servers.other]\ncommand = \"a\"\n"
        let old=other+"\n[mcp_servers.maildot]\ncommand = \"/old\"\n\n[mcp_servers.maildot.env]\nA = \"1\"\n\n[profiles.p]\nx = 1\n"
        let written=SetupThroughDot.registering(agentPath:"/Applications/Mail Dot.app/Contents/Helpers/MailDotAgent",in:old)
        XCTAssertEqual(written.components(separatedBy:"[mcp_servers.maildot]").count,2,"one Mail Dot entry")
        XCTAssertTrue(written.contains("MAILDOT_SETUP_MODE = \"1\""))
        XCTAssertFalse(written.contains("/old")); XCTAssertTrue(written.contains("[profiles.p]")); XCTAssertTrue(written.hasPrefix(other))
        let removed=SetupThroughDot.removing(in:written)
        XCTAssertFalse(SetupThroughDot.isRegistered(in:removed))
        XCTAssertTrue(removed.contains("[mcp_servers.other]")); XCTAssertTrue(removed.contains("[profiles.p]"))
        XCTAssertEqual(SetupThroughDot.registering(agentPath:"/a",in:nil).hasPrefix("[mcp_servers.maildot]"),true)
    }
    func testTheRequestNamesTheToolsTheHelperOffers() {
        let request=SetupThroughDot.request(name:SetupThroughDot.connectionName(user:"tester"))
        XCTAssertTrue(request.contains(ConnectionSetup.toolName))
        XCTAssertTrue(request.contains(ConnectionSetup.progressToolName))
        for step in ["started","tunnel_created","key_created","connection_saved","plugin_added","done","blocked"] { XCTAssertTrue(request.contains(step),step) }
        XCTAssertTrue(request.contains("\"Mail Dot (tester)\"")); XCTAssertTrue(request.contains("\"Mail Dot (tester) · Keep connected\""))
        XCTAssertTrue(request.contains("including ones named just \"Mail Dot\""),"another account's connection is left alone")
    }
}

