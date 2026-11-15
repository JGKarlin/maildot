import SwiftUI
import AppKit

/// The app's one window (owner decision, 14 November 2026), as other Mail extensions' apps have: shown only when
/// someone opens the app, never at login. The icon and name, whether the extension is on in Mail, and the version,
/// credit and links. Settings live in Mail only; the background connection has no face here.
@MainActor final class MailDotAboutWindow {
    static let shared=MailDotAboutWindow()
    private var window:NSWindow?
    func show() {
        if window == nil {
            let made=NSWindow(contentRect:NSRect(origin:.zero,size:MailDotAboutView.size),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
            made.titlebarAppearsTransparent=true; made.titleVisibility = .hidden
            made.contentView=NSHostingView(rootView:MailDotAboutView())
            made.isReleasedWhenClosed=false; made.center()
            window=made
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
    /// After removal the window shows what remains on the person's OpenAI account; closing it ends Mail Dot.
    func showRemoved(_ closing:MailDotRemover.Closing) {
        if window == nil { show() }
        guard let window else { return }
        window.contentView=NSHostingView(rootView:MailDotRemovedView(closing:closing))
        window.setContentSize(NSSize(width:MailDotRemovedView.size.width,height:MailDotRemovedView.size.height))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}

struct MailDotAboutView:View {
    static let size=CGSize(width:360,height:380)
    @State private var extensionOn:Bool?
    var body:some View {
        VStack(spacing:14) {
            Image(nsImage:NSApplication.shared.applicationIconImage).resizable().frame(width:96,height:96).accessibilityHidden(true)
            Text("Mail Dot").font(.title.weight(.semibold))
            HStack(spacing:8) {
                Circle().fill(extensionOn == true ? Color.green : (extensionOn == false ? MailDotStyle.warningText : Color.secondary.opacity(0.4))).frame(width:9,height:9)
                Text(extensionOn == true ? LocalizedStringKey("Extension on in Mail") : (extensionOn == false ? LocalizedStringKey("Extension off in Mail") : LocalizedStringKey("Checking…"))).foregroundStyle(MailDotStyle.supporting)
            }
            if extensionOn == false {
                Button("Open Mail") { MailExtensionStatus.openMail() }.buttonStyle(.borderedProminent)
            }
            Spacer(minLength:0)
            Button("Remove Mail Dot…") { MailDotRemover.start() }.controlSize(.small)
            Divider()
            MailDotCredits().frame(maxWidth:.infinity,alignment:.center).multilineTextAlignment(.center)
        }
        .padding(.horizontal,24).padding(.top,34).padding(.bottom,20)
        .frame(width:Self.size.width,height:Self.size.height)
        .background(Color(nsColor:.windowBackgroundColor))
        .tint(MailDotStyle.tint)
        .task { while !Task.isCancelled { let on=await MailExtensionStatus.isOn(); if on != extensionOn { extensionOn=on }; try? await Task.sleep(for:.seconds(2)) } }
    }
}

/// Whether Mail Dot's extension is switched on, as macOS records it for Mail.
enum MailExtensionStatus {
    static let identifier="org.jgkarlin.MailBridge.MailExtension"
    static func isOn() async -> Bool {
        await Task.detached {
            let tool=Process(); let pipe=Pipe()
            tool.executableURL=URL(fileURLWithPath:"/usr/bin/pluginkit"); tool.arguments=["-m","-i",identifier]
            tool.standardOutput=pipe; tool.standardError=FileHandle.nullDevice
            guard (try? tool.run()) != nil else { return false }
            tool.waitUntilExit()
            let text=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
            return text.split(separator:"\n").contains { $0.trimmingCharacters(in:.whitespaces).hasPrefix("+") }
        }.value
    }
    /// Opens Mail, at the person's press; Extensions is a tab of Mail's Settings. Mail Dot never starts Mail by itself.
    @MainActor static func openMail() {
        guard let mail=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.mail") else { return }
        NSWorkspace.shared.openApplication(at:mail,configuration:NSWorkspace.OpenConfiguration(),completionHandler:nil)
    }
}
