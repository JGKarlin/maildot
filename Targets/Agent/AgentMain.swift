import Foundation
import Darwin
import AppKit
import BridgeCore

@main struct AgentMain {
    /// Whether this helper was started by Mail Dot's own connection: the tunnel client that sits beside it. A helper
    /// started for setup offers only the two setup tools and is started by ChatGPT, so it is let through.
    static func startedByMailDot() -> Bool {
        if ConnectionSetup.enabled { return true }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getppid(), &buffer, UInt32(buffer.count)) > 0 else { return false }
        let parent = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        let beside = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("tunnel-client").path
        return parent == beside
    }
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            // The helper answers Mail Dot's own connection and nothing else (independent review of build 170, H2):
            // another program on this Mac that starts it gets no mail from it.
            #if !DEBUG
            guard startedByMailDot() else {
                try? FileHandle.standardError.write(contentsOf: Data("Mail Dot's helper answers only Mail Dot's own connection.\n".utf8))
                return
            }
            #endif
            let store: BridgeStore
            // Another store is for tests, in debug builds only (review of build 170, L1).
            #if DEBUG
            if let index = arguments.firstIndex(of:"--store"), arguments.indices.contains(index + 1) {
                store = BridgeStore(directory:URL(fileURLWithPath:arguments[index+1]))
            } else { store = try .shared() }
            #else
            store = try .shared()
            #endif
            let callLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/Logs/tool-calls.log")
            let wakeCompanion: @Sendable () async -> Void = {
                await MainActor.run {
                    let app=URL(fileURLWithPath:arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    guard app.pathExtension == "app",let url=URL(string:"mailbridge://operations") else { return }
                    let configuration=NSWorkspace.OpenConfiguration()
                    configuration.activates=false
                    NSWorkspace.shared.open([url],withApplicationAt:app,configuration:configuration,completionHandler:nil)
                }
            }
            let router = MCPRouter(store:store, statelessTunnel:true, callLogMirror:callLog, wakeCompanion: wakeCompanion)
            // The menu-bar item, its unread count and the notifications belong to the companion app. The agent
            // runs whenever the owner is logged in, so it starts the companion quietly when it starts itself.
            if !arguments.contains("--store") { await wakeCompanion() }
            let worker = Task.detached {
                let hub = EventHub(store:store,deliveryLog:callLog)
                let lease = EventPumpLease(bridgeDirectory:store.directory)
                while !Task.isCancelled {
                    try? store.transaction { $0.agentSeenAt = .now }
                    if lease.held { await hub.pump() }
                    try? await Task.sleep(for:.seconds(2))
                }
            }
            defer { worker.cancel() }
            while let line = readLine() {
                if let result = await router.response(line) {
                    try FileHandle.standardOutput.write(contentsOf:Data((result + "\n").utf8))
                }
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf:Data(("Mail Dot agent stopped: " + error.localizedDescription + "\n").utf8))
        }
    }
}
