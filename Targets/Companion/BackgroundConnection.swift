import Foundation
import ServiceManagement
import BridgeCore
import UserNotifications

@MainActor enum BackgroundConnection {
    static var service:SMAppService { .agent(plistName:"org.jgkarlin.MailBridge.Runtime.plist") }
    private static var lastError=""
    private static var lastProbe=Date.distantPast
    private static let runtime=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/Runtime")
    /// The local health check must not follow a redirect to some other server and count its answer.
    private static let session=URLSession(configuration:.ephemeral,delegate:NoRedirects(),delegateQueue:nil)

    static func publishStatus() async {
        guard Date().timeIntervalSince(lastProbe) >= 5,let root=try? BridgeStore.shared().directory else { return }
        lastProbe = .now
        var connected=false
        if let text=try? String(contentsOf:runtime.appendingPathComponent("health.url"),encoding:.utf8),
           let base=URL(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
           base.scheme == "http",base.host == "127.0.0.1",base.user == nil,base.password == nil,base.query == nil,base.fragment == nil,
           base.path.isEmpty || base.path == "/",let port=base.port,port > 1023 {
            var request=URLRequest(url:base.appendingPathComponent("readyz")); request.timeoutInterval=2
            if let (_,response)=try? await session.data(for:request) { connected=(response as? HTTPURLResponse)?.statusCode == 200 }
        }
        let problem=runtimeProblem() ?? tunnelProblem()
        if problem == "configuration" || problem == "moved" { await reregisterIfStartedElsewhere() }
        var value:[String:Any] = ["enabled":service.status == .enabled || service.status == .requiresApproval,"needsApproval":service.status == .requiresApproval,
                                  "connected":connected && problem == nil,"error":lastError,"updatedAt":Date().timeIntervalSince1970]
        if let problem { value["problem"]=problem }
        switch await notificationAuthorization() {
        case UNAuthorizationStatus.authorized.rawValue,UNAuthorizationStatus.provisional.rawValue: value["notifications"]="allowed"
        case UNAuthorizationStatus.denied.rawValue: value["notifications"]="off"
        default: value["notifications"]="notAsked"
        }
        if let data=try? JSONSerialization.data(withJSONObject:value) { try? data.write(to:root.appendingPathComponent("background-status.json"),options:.atomic) }
    }

    /// Why the background helper could not start, as it recorded it within the last quarter of an hour.
    private static func runtimeProblem() -> String? {
        guard let data=try? Data(contentsOf:runtime.appendingPathComponent("runtime-status.json")),
              let status=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let problem=status["problem"] as? String,["configuration","permissions","moved","launch","key"].contains(problem),
              Date().timeIntervalSince1970-(status["at"] as? Double ?? 0) < 900 else { return nil }
        return problem
    }

    /// The local readiness check answers even when OpenAI refuses the tunnel's key, so the tunnel client's
    /// own log is consulted: a refusal in the last minute means Dot cannot reach this Mac.
    private static func tunnelProblem() -> String? {
        guard let configuration=try? Data(contentsOf:runtime.appendingPathComponent("configuration.json")),
              let paths=try? JSONSerialization.jsonObject(with:configuration) as? [String:Any],let profilePath=paths["profilePath"] as? String,
              let profileData=try? Data(contentsOf:URL(fileURLWithPath:profilePath)),
              let profile=try? JSONSerialization.jsonObject(with:profileData) as? [String:Any],
              let logPath=(profile["log"] as? [String:Any])?["file"] as? String,
              let handle=try? FileHandle(forReadingFrom:URL(fileURLWithPath:logPath)) else { return nil }
        defer { try? handle.close() }
        let size=(try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset:size > 16_384 ? size-16_384 : 0)
        guard let tail=try? handle.readToEnd(),let text=String(data:tail,encoding:.utf8) else { return nil }
        let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        for line in text.split(separator:"\n").reversed() {
            guard let entry=try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],
                  let message=entry["msg"] as? String,let stamp=entry["time"] as? String,let time=formatter.date(from:stamp) else { continue }
            guard Date().timeIntervalSince(time) < 60 else { return nil }
            if message.hasPrefix("poll failed"),let error=entry["error"] as? String {
                // Judge by the HTTP status the client reports, not by its wording.
                if let match=error.range(of:#"status (\d{3})"#,options:.regularExpression),
                   let code=Int(error[match].dropFirst(7)),code == 401 || code == 403 { return "keyRefused" }
                return "unreachable"
            }
        }
        return nil
    }

    /// Whether macOS lets Mail Dot show notifications, as the raw authorization status.
    static func notificationAuthorization() async -> Int {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning:$0.authorizationStatus.rawValue) }
        }
    }

    /// The private tunnel profile names the Mail Dot agent by absolute path. If the app was moved, that path
    /// leads nowhere and the connection cannot start. When, and only when, the named program no longer exists
    /// and this app's own agent does, the profile is pointed at this app. Nothing else in it is touched.
    @discardableResult static func repairAgentPathIfMoved() -> Bool {
        guard let agent=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MailDotAgent").path as String?,
              FileManager.default.isExecutableFile(atPath:agent),
              let configuration=try? Data(contentsOf:runtime.appendingPathComponent("configuration.json")),
              let paths=try? JSONSerialization.jsonObject(with:configuration) as? [String:Any],let profilePath=paths["profilePath"] as? String,
              let data=try? Data(contentsOf:URL(fileURLWithPath:profilePath)),
              var profile=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              var mcp=profile["mcp"] as? [String:Any],var commands=mcp["commands"] as? [[String:Any]],!commands.isEmpty,
              let command=commands[0]["command"] as? String else { return false }
        let named=command.trimmingCharacters(in:CharacterSet(charactersIn:"\" "))
        guard named.hasPrefix("/"),named != agent,!FileManager.default.isExecutableFile(atPath:named) else { return false }
        commands[0]["command"]="\""+agent+"\""
        mcp["commands"]=commands; profile["mcp"]=mcp
        guard let updated=try? JSONSerialization.data(withJSONObject:profile,options:[.prettyPrinted,.sortedKeys]) else { return false }
        let temporary=profilePath+".repair-"+UUID().uuidString
        guard FileManager.default.createFile(atPath:temporary,contents:updated,attributes:[.posixPermissions:0o600]),
              rename(temporary,profilePath) == 0 else { return false }
        return true
    }

    private static var lastReregistration=Date.distantPast

    /// macOS remembers where the background helper lives when it is registered, and after an update it can go on
    /// starting the helper of an earlier copy (one moved to the Trash, say). That helper refuses to hand the key
    /// to this copy's agent and stops. When the helper reports it was started from somewhere other than this app,
    /// and this app's agent is the one the connection names, the service is registered again from here, which
    /// points macOS at this copy. At most once every ten minutes, so a real fault never becomes a loop.
    static func reregisterIfStartedElsewhere(now:Date = .now) async {
        guard now.timeIntervalSince(lastReregistration) >= 600,service.status == .enabled,
              let data=try? Data(contentsOf:runtime.appendingPathComponent("runtime-status.json")),
              let status=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
        let mine=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MailDotRuntime").resolvingSymlinksInPath().path
        let from=status["from"] as? String
        // A helper from before this record carried its origin says nothing of where it ran; one retry settles it.
        guard from == nil || URL(fileURLWithPath:from!).resolvingSymlinksInPath().path != mine else { return }
        repairAgentPathIfMoved()
        guard let named=namedAgent(),
              URL(fileURLWithPath:named).resolvingSymlinksInPath().path == Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MailDotAgent").resolvingSymlinksInPath().path else { return }
        lastReregistration=now
        do {
            try await service.unregister()
            try service.register()
            try? FileManager.default.removeItem(at:runtime.appendingPathComponent("runtime-status.json"))
            lastError=""
        } catch { lastError=error.localizedDescription }
        lastProbe = .distantPast
    }

    /// The agent program the private tunnel profile names, by absolute path.
    private static func namedAgent() -> String? {
        guard let configuration=try? Data(contentsOf:runtime.appendingPathComponent("configuration.json")),
              let paths=try? JSONSerialization.jsonObject(with:configuration) as? [String:Any],let profilePath=paths["profilePath"] as? String,
              let data=try? Data(contentsOf:URL(fileURLWithPath:profilePath)),
              let profile=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let command=((profile["mcp"] as? [String:Any])?["commands"] as? [[String:Any]])?.first?["command"] as? String else { return nil }
        let trimmed=command.trimmingCharacters(in:.whitespaces)
        let agent=trimmed.hasPrefix("\"") ? String(trimmed.dropFirst().prefix{ $0 != "\"" }) : String(trimmed.prefix{ $0 != " " })
        return agent.hasPrefix("/") ? agent : nil
    }

    static func setEnabled(_ enabled:Bool) async throws {
        do {
            if enabled { repairAgentPathIfMoved() }
            if enabled { try service.register() }
            else { try await service.unregister() }
            lastError=""
        } catch { lastError=error.localizedDescription; lastProbe = .distantPast; throw error }
        lastProbe = .distantPast
    }
}

private final class NoRedirects:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest) async -> URLRequest? { nil }
}
