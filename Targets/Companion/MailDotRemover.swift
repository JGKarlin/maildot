import SwiftUI
import AppKit
import BridgeCore

/// Removes Mail Dot from this Mac at the person's press of Remove Mail Dot… in the app's window (installer design
/// review, recommendation 8, approved by the owner on 15 November 2026). It does what the removal script did:
/// stops the helper, withdraws the extension from Mail, moves the app and what it stored to a dated folder in the
/// Trash, deletes the key from the Keychain and takes Mail Dot out of ChatGPT's settings; it also resets Mail Dot's
/// two privacy grants. It then names what remains on the person's OpenAI account, which Mail Dot cannot delete.
@MainActor enum MailDotRemover {
    /// Everything the closing state shows, read before the app's own files move.
    struct Closing {
        var title:String, remain:String, left:String, done:String, open:String
        var items:[(name:String,page:URL)]
        var icon:NSImage
        var outcome:MailDotRemoval.Outcome?
        /// Shown when other accounts use this Mac: the app in Applications is theirs too and stays.
        var appStays:String?
        /// Shown when the key could not be deleted from the Keychain.
        var keyStays:String?
    }
    static func start() {
        // Never from a run against a synthetic store, and never while Mail is open: Mail holds the extension.
        guard ProcessInfo.processInfo.environment["MAILDOT_PREVIEW_STORE"] == nil else { return }
        // Only the installed copy removes Mail Dot: a copy run from elsewhere, as in development, does nothing.
        let home=FileManager.default.homeDirectoryForCurrentUser
        let place=Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        guard place == "/Applications" || place == home.appendingPathComponent("Applications").path else { return }
        // Other accounts on this Mac share the copy in Applications; then it stays, and only this account's part goes.
        let shared=place == "/Applications" && !MailDotRemoval.otherAccounts(home:home).isEmpty
        // Mail open in this account, or, where the app itself is to go, in any account: the extension would vanish under it.
        let mailHere=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").contains(where:{ !$0.isTerminated })
        if mailHere || (!shared && Self.mailRunsAnywhere()) {
            let alert=NSAlert()
            alert.messageText=String(localized:"Quit Mail to remove Mail Dot.")
            alert.runModal()
            return
        }
        let alert=NSAlert()
        alert.alertStyle = .warning
        alert.messageText=String(localized:"Remove Mail Dot from this Mac?")
        alert.informativeText=String(localized:"The app, its Mail extension, its settings and its stored data move to the Trash. Its search index of your mail and its key in your Keychain are deleted.")
        alert.addButton(withTitle:String(localized:"Remove")).hasDestructiveAction=true
        alert.addButton(withTitle:String(localized:"Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name=SetupThroughDot.connectionName()
        var closing=Closing(title:String(localized:"Mail Dot is removed"),
                            remain:String(localized:"Four items remain on your OpenAI account, each named “\(name)”. Mail Dot cannot delete them."),
                            left:String(localized:"macOS did not let Mail Dot move these. Drag them to the Trash:"),
                            done:String(localized:"Done"),open:String(localized:"Open"),
                            items:MailDotRemoval.Remaining.allCases.map{ (label($0),$0.page) },
                            icon:NSApplication.shared.applicationIconImage,outcome:nil,
                            appStays:shared ? String(localized:"The Mail Dot app stays in Applications for the other accounts on this Mac.") : nil,keyStays:nil)
        let keyStays=String(localized:"Mail Dot could not delete its keys from your Keychain. Delete “\(RuntimeSetup.keyService)” and “\(MailIndexKey.service)” in Keychain Access.")
        Task {
            (NSApplication.shared.delegate as? CompanionDelegate)?.stopForRemoval()
            try? await Task.sleep(for:.milliseconds(600))
            if await !withdraw(appGoes:!shared) { closing.keyStays=keyStays }
            closing.outcome=try? MailDotRemoval.moveToTrash(home:home,app:shared ? nil : Bundle.main.bundleURL)
            // Pressed in the setup window, that window goes; the closing state is shown in the app's own window.
            MailDotSetupWindow.shared.close()
            MailDotAboutWindow.shared.showRemoved(closing)
        }
    }
    private static func label(_ item:MailDotRemoval.Remaining) -> String {
        switch item {
        case .tunnel: String(localized:"Tunnel")
        case .key: String(localized:"Key")
        case .plugin: String(localized:"Plugin")
        case .task: String(localized:"Hourly task")
        }
    }
    /// What changes the system outside Mail Dot's own files. Each step is one the removal script took, by the same tool.
    /// Whether a Mail is running in any account of this Mac, this one included.
    private static func mailRunsAnywhere() -> Bool {
        let tool=Process(),pipe=Pipe()
        tool.executableURL=URL(fileURLWithPath:"/bin/ps"); tool.arguments=["-axo","comm="]
        tool.standardOutput=pipe; tool.standardError=FileHandle.nullDevice
        guard (try? tool.run()) != nil else { return false }
        let text=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        tool.waitUntilExit()
        return text.split(separator:"\n").contains{ $0.hasSuffix("/Mail.app/Contents/MacOS/Mail") }
    }
    /// Returns whether the key is gone from the Keychain.
    private static func withdraw(appGoes:Bool) async -> Bool {
        let id=MailDotRemoval.identifier
        let app=Bundle.main.bundleURL
        try? await BackgroundConnection.setEnabled(false)
        await run("/bin/launchctl",["bootout","gui/\(getuid())/\(id).Runtime"])
        for name in ["MailDotRuntime","MailDotAgent","MailDotExtension"] { await run("/usr/bin/pkill",["-x",name]) }
        await run("/usr/bin/pkill",["-f",app.appendingPathComponent("Contents/Helpers/tunnel-client").path])
        await run("/usr/bin/pluginkit",["-r",app.appendingPathComponent("Contents/PlugIns/MailDotExtension.appex").path])
        if appGoes { await run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",["-u",app.path]) }
        for domain in [id,id+".MailExtension",id+".Runtime",id+".Agent"] { await run("/usr/bin/defaults",["delete",domain]) }
        // The search index's key goes with the index.
        let keyGone=RuntimeSetup.deleteKey() && MailIndexKey.delete()
        // No permission of Mail Dot's stays behind: Full Disk Access, working with Mail, Accessibility and the rest
        // (review of build 170, M8).
        await run("/usr/bin/tccutil",["reset","All",id])
        return keyGone
    }
    private static func run(_ tool:String,_ arguments:[String]) async {
        await Task.detached {
            let process=Process()
            process.executableURL=URL(fileURLWithPath:tool); process.arguments=arguments
            process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }.value
    }
}

/// What the app's window shows once Mail Dot is removed. Its texts were read beforehand: the app's files are in the Trash.
struct MailDotRemovedView:View {
    static let size=CGSize(width:420,height:430)
    let closing:MailDotRemover.Closing
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:12) {
                Image(nsImage:closing.icon).resizable().frame(width:48,height:48).accessibilityHidden(true)
                Text(verbatim:closing.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            }
            Text(verbatim:closing.remain).fixedSize(horizontal:false,vertical:true)
            VStack(spacing:8) {
                ForEach(Array(closing.items.enumerated()),id:\.offset) { _,item in
                    HStack {
                        Text(verbatim:item.name)
                        Spacer()
                        Button(closing.open) { NSWorkspace.shared.open(item.page) }.accessibilityLabel(Text(verbatim:"\(closing.open): \(item.name)"))
                    }
                }
            }
            ForEach([closing.appStays,closing.keyStays].compactMap{ $0 },id:\.self) { line in
                Label { Text(verbatim:line).fixedSize(horizontal:false,vertical:true) } icon: { Image(systemName:"info.circle") }.font(.callout).foregroundStyle(MailDotStyle.supporting)
            }
            if let left=closing.outcome?.left,!left.isEmpty {
                Label { Text(verbatim:closing.left).fixedSize(horizontal:false,vertical:true) } icon: { Image(systemName:"exclamationmark.triangle.fill") }.foregroundStyle(MailDotStyle.warningText)
                ForEach(left,id:\.self) { path in Text(verbatim:path).font(.caption).textSelection(.enabled).lineLimit(2) }
            }
            Spacer(minLength:0)
            HStack { Spacer(); Button(closing.done) { NSApplication.shared.terminate(nil) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width:Self.size.width,height:Self.size.height,alignment:.topLeading)
        .background(Color(nsColor:.windowBackgroundColor))
    }
}
