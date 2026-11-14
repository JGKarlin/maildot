import Foundation
import AppKit
import BridgeCore

@main struct AgentMain {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            let store: BridgeStore
            if let index = arguments.firstIndex(of:"--store"), arguments.indices.contains(index + 1) {
                store = BridgeStore(directory:URL(fileURLWithPath:arguments[index+1]))
            } else { store = try .shared() }
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
