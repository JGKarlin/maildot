import SwiftUI
import AppKit
import ApplicationServices
import BridgeCore
import BridgeAutomation

/// Mail Dot's setup, shown once after installation when someone opens the app and Mail Dot has no connection yet
/// (owner request, 14 November 2026: an installer he can test, which explains each step and has Dot do the hard part).
/// Each line checks itself; a button appears only while that line needs the person. When macOS will not ask again
/// because of an earlier "no", the button opens the exact page of System Settings instead of doing nothing.
@MainActor final class MailDotSetupWindow {
    static let shared=MailDotSetupWindow()
    private var window:NSWindow?
    /// Whether Mail Dot already has a connection on this Mac; setup is then not shown.
    nonisolated static var needed:Bool { !RuntimeSetup.isConfigured(paths:RuntimeSetup.Paths(home:FileManager.default.homeDirectoryForCurrentUser)) }
    func show() {
        if window == nil {
            let made=NSWindow(contentRect:NSRect(origin:.zero,size:MailDotSetupView.size),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
            made.titlebarAppearsTransparent=true; made.titleVisibility = .hidden
            made.contentView=NSHostingView(rootView:MailDotSetupView())
            made.isReleasedWhenClosed=false; made.center()
            window=made
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}

/// What setup found on this Mac, looked at every two seconds.
struct SetupFindings:Equatable {
    var extensionOn=false
    var mail:Int32?          // nil while Mail is closed
    var accessibility=false
    var chatGPT=ConnectionState.ChatGPT.closed
    var connected=false
    var reports:[SetupThroughDot.Report]=[]
    var asked=false
    var mailAllowed:Bool { mail == 0 }
    var ready:Bool { accessibility && chatGPT == .open }

    @MainActor static func look(asked:Bool) async -> SetupFindings {
        var found=SetupFindings(asked:asked)
        found.extensionOn=await MailExtensionStatus.isOn()
        if NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").contains(where:{ !$0.isTerminated }) {
            found.mail=await MailAutomation().permissionStatus()
        }
        found.accessibility=AXIsProcessTrusted()
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier:DotCallLauncher.chatGPTBundleID) == nil { found.chatGPT = .notInstalled }
        else if NSRunningApplication.runningApplications(withBundleIdentifier:DotCallLauncher.chatGPTBundleID).contains(where:{ !$0.isTerminated }) { found.chatGPT = .open }
        if let bridge=try? BridgeStore.shared().directory {
            found.reports=SetupThroughDot.reports(in:bridge)
            if let data=try? Data(contentsOf:bridge.appendingPathComponent("background-status.json")),
               let status=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                found.connected=status["connected"] as? Bool == true && !MailDotSetupWindow.needed
            }
        }
        return found
    }
}

struct MailDotSetupView:View {
    static let size=CGSize(width:560,height:680)
    /// For rendering previews: findings given instead of looked up.
    var fixed:SetupFindings?
    @State private var found=SetupFindings()
    @State private var asked=false
    @State private var note:String?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:12) {
                Image(nsImage:NSApplication.shared.applicationIconImage).resizable().frame(width:48,height:48).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2) {
                    Text("Set Up Mail Dot").font(.title2.weight(.semibold))
                    Text("Five steps. Mail Dot checks each one itself.").foregroundStyle(.secondary)
                }
            }
            step(1,"Switch Mail Dot on in Mail",
                 "In Mail, open Settings, choose Extensions, and tick Mail Dot. Apple lets only you do this.",
                 done:found.extensionOn,button:found.extensionOn ? nil : ("Open Mail",{ MailExtensionStatus.openMail() }))
            step(2,"Allow Mail Dot to work with Mail",
                 "So Mail Dot can read the messages you choose and place Dot's drafts. Mail must be open for macOS to ask.",
                 done:found.mailAllowed,button:found.mailAllowed ? nil : (found.mail == nil ? ("Open Mail",{ MailExtensionStatus.openMail() }) : ("Allow…",{ allowMail() })))
            step(3,"Switch on Accessibility for Mail Dot",
                 "So Mail Dot can write to Dot in the ChatGPT app and start a call with Dot.",
                 done:found.accessibility,button:found.accessibility ? nil : ("Open Settings…",{ openAccessibility() }))
            step(4,"Open ChatGPT",
                 found.chatGPT == .notInstalled ? "Install the ChatGPT app and sign in with a plan that includes Dot." : "Signed in with a plan that includes Dot.",
                 done:found.chatGPT == .open,button:found.chatGPT == .closed ? ("Open ChatGPT",{ openChatGPT() }) : nil)
            step(5,"Connect Mail Dot to Dot",
                 "Mail Dot reaches Dot through a private connection on your OpenAI account. Dot sets it up: it creates the connection and a key that can only run it, hands the key to Mail Dot, which keeps it in your Keychain, and adds Mail Dot to ChatGPT. You may be asked to sign in to OpenAI, to let ChatGPT use this computer, and to approve Mail Dot's tools in ChatGPT. Dot reads none of your mail during this step.",
                 done:found.connected,button:found.connected || !found.ready ? nil : (asked ? "Ask Dot Again" : "Ask Dot to Connect",{ connect() }))
            if !found.reports.isEmpty {
                VStack(alignment:.leading,spacing:4) {
                    ForEach(Array(found.reports.suffix(6).enumerated()),id:\.offset) { _,report in
                        Text(verbatim:"\(Self.stepName(report.step))\(report.note.isEmpty ? "" : ": "+report.note)")
                            .font(.callout).foregroundStyle(report.step == "blocked" ? Color.orange : Color.secondary).lineLimit(2)
                    }
                }.padding(.leading,40)
            }
            if let note { Text(note).font(.callout).foregroundStyle(.orange).padding(.leading,40) }
            Spacer(minLength:0)
            if found.connected {
                HStack { Spacer(); Text("Mail Dot is connected to Dot.").fontWeight(.semibold); Button("Open Mail") { MailExtensionStatus.openMail() }.buttonStyle(.borderedProminent) }
            }
        }
        .padding(24)
        .frame(width:Self.size.width,height:Self.size.height,alignment:.topLeading)
        .background(Color(nsColor:.windowBackgroundColor))
        .tint(MailDotStyle.tint)
        .task {
            if let fixed { found=fixed; return }
            while !Task.isCancelled {
                let fresh=await SetupFindings.look(asked:asked)
                if fresh != found { found=fresh }
                // Setup is over: the setup tools come out of ChatGPT's settings again.
                if fresh.connected { SetupCodexEntry.remove() }
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }
    private func step(_ number:Int,_ title:LocalizedStringKey,_ detail:LocalizedStringKey,done:Bool,button:(LocalizedStringKey,() -> Void)?) -> some View {
        HStack(alignment:.top,spacing:12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.primary.opacity(0.08)).frame(width:28,height:28)
                if done { Image(systemName:"checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                else { Text(verbatim:"\(number)").font(.callout.weight(.semibold)) }
            }.accessibilityHidden(true)
            VStack(alignment:.leading,spacing:4) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:8)
            if let button { Button(button.0,action:button.1).controlSize(.regular).fixedSize() }
        }
    }
    static func stepName(_ step:String) -> String {
        switch step {
        case "started": String(localized:"Dot started")
        case "tunnel_created": String(localized:"Connection created")
        case "key_created": String(localized:"Key created")
        case "connection_saved": String(localized:"Key handed to Mail Dot")
        case "plugin_added": String(localized:"Mail Dot added to ChatGPT")
        case "done": String(localized:"Done")
        default: String(localized:"Dot is stuck")
        }
    }

    // MARK: Actions

    /// macOS asks once. After an earlier "no" it will not ask again, so its Automation page is opened instead.
    private func allowMail() {
        Task {
            let status=await MailAutomation().permissionStatus(requestConsent:true)
            if status == -1743 { Self.open(pane:"Privacy_Automation") }
        }
    }
    /// The prompt adds Mail Dot to the Accessibility list; the switch is on that page of System Settings.
    private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
        Self.open(pane:"Privacy_Accessibility")
    }
    private func openChatGPT() {
        guard let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:DotCallLauncher.chatGPTBundleID) else { return }
        NSWorkspace.shared.openApplication(at:app,configuration:NSWorkspace.OpenConfiguration(),completionHandler:nil)
    }
    static func open(pane:String) {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    /// Starts Mail Dot's connection helper, lists Mail Dot's helper in ChatGPT's settings for setup, and writes
    /// Dot the request.
    private func connect() {
        note=nil
        Task {
            do { try await BackgroundConnection.setEnabled(true) }
            catch { note=String(localized:"macOS did not allow Mail Dot's background item. Allow it in System Settings, General, Login Items."); Self.openLoginItems(); return }
            guard SetupCodexEntry.add() else { note=String(localized:"Mail Dot could not add itself to ChatGPT's settings."); return }
            asked=true
            if let refusal=await DotCallLauncher.say(SetupThroughDot.request(name:SetupThroughDot.connectionName())) { note=refusal.rawValue }
        }
    }
    static func openLoginItems() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

/// Mail Dot's entry in ChatGPT's local-tools settings during setup.
enum SetupCodexEntry {
    static var file:URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml") }
    static var agent:String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MailDotAgent").path }
    @discardableResult static func add() -> Bool {
        let folder=file.deletingLastPathComponent()
        let contents=try? String(contentsOf:file,encoding:.utf8)
        if contents == nil,FileManager.default.fileExists(atPath:file.path) { return false }
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try Data(SetupThroughDot.registering(agentPath:agent,in:contents).utf8).write(to:file,options:.atomic)
            return true
        } catch { return false }
    }
    static func remove() {
        guard let contents=try? String(contentsOf:file,encoding:.utf8),SetupThroughDot.isRegistered(in:contents) else { return }
        try? Data((SetupThroughDot.removing(in:contents)+"\n").utf8).write(to:file,options:.atomic)
    }
}
