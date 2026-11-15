import AppKit
import ApplicationServices
import OSLog
import BridgeCore
import BridgeAutomation

/// Keeps the Connection lines true and Dot listening (owner approval of the Connection mock-ups, 14 November 2026).
/// Every few seconds the background app looks at what Mail Dot needs in place, saves what it found for Settings, the
/// Mail Dot window and the banner, acts on a button pressed there, keeps Mail Dot's entry in ChatGPT's local tools
/// current, and asks Dot to listen when no worker on this Mac is taking requests.
@MainActor enum ConnectionWatch {
    private static let log=Logger(subsystem:"org.jgkarlin.MailBridge",category:"Connection")
    private static var busy=false

    static func tick() async {
        guard !busy,let bridge=try? BridgeStore.shared() else { return }
        busy=true; defer { busy=false }
        let store=MailTriageStore(bridgeDirectory:bridge.directory)
        let mailRunning=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").contains{ !$0.isTerminated }
        // Asked only while Mail is open: the question is never allowed to start Mail.
        let mailStatus:Int32?=mailRunning ? await MailAutomation().permissionStatus() : nil
        let chatGPT=chatGPTState()
        let tunnel=listening(bridge)
        let accessibility=AXIsProcessTrusted()
        // Looked at only while search by meaning is on: the look itself is what lists Mail Dot under Full Disk Access.
        let meaning=(try? MailSettingsStore(bridgeDirectory:bridge.directory).read())?.searchByMeaningAnywhere == true
        let diskAccess:Bool?=meaning ? MailFiles.access(home:FileManager.default.homeDirectoryForCurrentUser) == .granted : nil
        // One save: the findings, and the owner's button taken so that it is acted on once.
        guard let taken=try? store.transaction({ state -> (ConnectionState,ConnectionState.Request?) in
            var found=state.connection ?? ConnectionState()
            let before=found,request=found.request
            if mailStatus == 0 { found.mail = .allowed } else if mailStatus == -1743 || mailStatus == -1744 { found.mail = .notAllowed }
            found.accessibility=accessibility; found.chatGPT=chatGPT; found.tunnelConnected=tunnel; found.fullDiskAccess=diskAccess; found.request=nil
            if found != before { state.connection=found }
            return (found,request)
        }) else { return }
        // Dot works through Mail Dot's connection in the cloud. Having Dot work on this Mac instead was tried on 14
        // November 2026 and dropped (owner decision: it needs ChatGPT open the whole time, and Dot did not listen when
        // asked), so Mail Dot never asks Dot to listen and writes nothing into ChatGPT's settings.
        if let request=taken.1 { await act(on:request,mailRunning:mailRunning,mailStatus:mailStatus) }
    }

    private static func chatGPTState() -> ConnectionState.ChatGPT {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier:DotCallLauncher.chatGPTBundleID) != nil else { return .notInstalled }
        return NSRunningApplication.runningApplications(withBundleIdentifier:DotCallLauncher.chatGPTBundleID).contains{ !$0.isTerminated } ? .open : .closed
    }
    /// Dot in the cloud can be told of requests: the tunnel answers and Dot holds a live subscription to them.
    static func listening(_ bridge:BridgeStore) -> Bool {
        guard let data=try? Data(contentsOf:bridge.directory.appendingPathComponent("background-status.json")),
              let status=try? JSONSerialization.jsonObject(with:data) as? [String:Any],status["connected"] as? Bool == true,
              Date().timeIntervalSince1970-(status["updatedAt"] as? Double ?? 0) < 60,
              let state=try? bridge.read() else { return false }
        return !state.subscriptions.deliverable(for:"mail.workflow_requested").isEmpty
    }
    private static func hasAccounts(_ bridge:BridgeStore) -> Bool {
        guard let settings=try? MailSettingsStore(bridgeDirectory:bridge.directory).read(),
              let native=try? NativeMailStore(bridgeDirectory:bridge.directory).read() else { return false }
        return ((try? MailWorkflowAccount.available(settings:settings,native:native)) ?? []).isEmpty == false
    }

    private static func act(on request:ConnectionState.Request,mailRunning:Bool,mailStatus:Int32?) async {
        log.notice("button: \(request.rawValue,privacy:.public)")
        switch request {
        case .allowMail:
            // macOS asks once; after a refusal only its own Automation list can allow Mail Dot.
            guard mailRunning else { return }
            var status=mailStatus
            if status != -1743 { status=await MailAutomation().permissionStatus(requestConsent:true) }
            if status == -1743 { open(pane:"Privacy_Automation") }
        case .openAccessibility:
            // The prompt adds Mail Dot to the Accessibility list; the page is where its switch is.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
            open(pane:"Privacy_Accessibility")
        case .openChatGPT:
            guard let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:DotCallLauncher.chatGPTBundleID) else { return }
            _ = try? await NSWorkspace.shared.openApplication(at:app,configuration:NSWorkspace.OpenConfiguration())
        case .openFullDiskAccess:
            open(pane:"Privacy_AllFiles")
        case .askDotToListen:
            break   // no longer offered: Dot is not asked to work on this Mac
        }
    }
    private static func open(pane:String) {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
