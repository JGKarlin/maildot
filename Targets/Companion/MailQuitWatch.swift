import AppKit
import BridgeCore
import os

/// Lets Mail quit while a Mail Dot window is open. Mail shows that window as a modal dialog, and macOS refuses a quit
/// sent to Mail from outside (the Dock's Quit, Restart, Shut Down, Log Out) while one is open. Mail writes one line to
/// the system log each time it refuses; on that line Mail Dot closes the Mail Dot window by its own close button and
/// sends the quit to Mail once more (owner's OK, 15 November 2026). Only Mail's own lines about turning a quit down are read.
@MainActor final class MailQuitWatch {
    static let shared=MailQuitWatch()
    private static let log=Logger(subsystem:"org.jgkarlin.MailBridge",category:"quit")
    private var stream:Process?
    private var lastResend=Date.distantPast
    private var started=false

    func start() {
        guard !started else { return }
        started=true
        watch()
        // Restart, Shut Down and Log Out: the windows are asked to close before the system asks Mail to quit.
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willPowerOffNotification,object:nil,queue:.main) { _ in
            MainActor.assumeIsolated { _ = MailDotWindowCloser.closeAll() }
        }
    }

    private func watch() {
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/log")
        process.arguments=["stream","--style","compact","--level","default","--predicate",
                           #"process == "Mail" AND subsystem == "com.apple.AppKit" AND category == "Application" AND eventMessage CONTAINS "\#(MailQuitNotice.refusalLine)""#]
        let pipe=Pipe()
        process.standardOutput=pipe
        process.standardError=FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler={ handle in
            let data=handle.availableData
            guard !data.isEmpty,MailQuitNotice.isRefusal(String(decoding:data,as:UTF8.self)) else { return }
            Task { @MainActor in MailQuitWatch.shared.refused() }
        }
        // The stream ends only if something stops it; it is started again after a pause.
        process.terminationHandler={ _ in
            Task { @MainActor in
                try? await Task.sleep(for:.seconds(15))
                MailQuitWatch.shared.watch()
            }
        }
        do { try process.run(); stream=process }
        catch { Self.log.error("could not watch for refused quits: \(error.localizedDescription,privacy:.public)") }
    }

    private func refused() {
        // A refusal of the quit sent from here is not answered again, so the two never go back and forth.
        guard Date().timeIntervalSince(lastResend) > 15 else { return }
        lastResend=Date()
        Task {
            // Only a refusal the Mail Dot window caused is answered: with no such window, Mail had another reason.
            guard MailDotWindowCloser.open() > 0 else { return }
            Self.log.info("Mail turned a quit down with the Mail Dot window open; closing it and quitting Mail again")
            guard await MailDotWindowCloser.closeAndWait() else { Self.log.error("the Mail Dot window did not close"); return }
            try? await Task.sleep(for:.milliseconds(400))
            // The ordinary quit: Mail still asks about its own unsaved drafts.
            for mail in NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail") { mail.terminate() }
        }
    }
}
