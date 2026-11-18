import AppKit
import BridgeCore
import Sparkle
import os

/// Mail Dot's automatic updates (owner's approval, 18 November 2026). Sparkle reads the signed update list on GitHub
/// once a day, downloads a newer build in the background and verifies its signature and Developer ID. It never shows
/// a window or a notification of its own: this class is its whole interface. Checking cannot be turned off.
///
/// An update is installed only once Mail has quit, because replacing the extension under a running Mail has crashed
/// Mail (13 November 2026): when Mail quits, or at once when the owner presses Install Now while Mail is closed.
@MainActor final class MailDotUpdater: NSObject, ObservableObject {
    static let shared = MailDotUpdater()
    private static let log = Logger(subsystem: "org.jgkarlin.MailBridge", category: "update")
    nonisolated static let mailBundleID = "com.apple.mail"

    /// The version that is downloaded, verified and waiting for Mail to quit.
    @Published private(set) var readyVersion: String?
    /// True while a check the owner asked for is running.
    @Published private(set) var checking = false
    @Published private(set) var lastCheck: Date?

    private var updater: SPUUpdater?
    /// Sparkle's two ways of being told to install: the silent path's block, or the answer to its ready question.
    private var installNowBlock: (() -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    /// The update Sparkle asked about on its interactive path, named once it is downloaded.
    private var foundItem: SUAppcastItem?
    private var started = false

    var runningVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var mailRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID).isEmpty }

    func start() {
        guard !started else { return }
        started = true
        finishInstalledUpdate()
        // Only the installed copy updates itself; a build run from a project folder is never replaced.
        guard Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications" else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        // Always on, and never asked about: the owner's decision.
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        updater.updateCheckInterval = 86_400
        updater.sendsSystemProfile = false
        do { try updater.start(); self.updater = updater }
        catch { Self.log.error("updater did not start: \(error.localizedDescription, privacy: .public)") }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.mailBundleID else { return }
            MainActor.assumeIsolated { MailDotUpdater.shared.mailQuit() }
        }
    }

    /// The About window's Check for Updates. It takes the same quiet path as the daily check.
    func checkNow() {
        guard let updater, !checking else { return }
        checking = true
        updater.checkForUpdatesInBackground()
    }

    /// The About window's Install Now, offered only while Mail is closed.
    func installNow() {
        guard !Self.mailRunning else { return }
        install()
    }

    private func mailQuit() {
        guard readyVersion != nil else { return }
        // Mail may take a moment to let go of the extension after its process ends.
        Task { try? await Task.sleep(for: .seconds(3)); if !Self.mailRunning { install() } }
    }

    private static let reopenKey = "ReopenWindowAfterUpdate"
    private static let installingKey = "UpdateInstallStartedAt"
    /// True when this launch is Sparkle starting the new copy after an install Mail Dot began within the last minutes.
    static var relaunchedAfterUpdate: Bool {
        guard let started = UserDefaults.standard.object(forKey: installingKey) as? Date else { return false }
        UserDefaults.standard.removeObject(forKey: installingKey)
        return Date().timeIntervalSince(started) < 600
    }
    static func takeReopenWindow() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: reopenKey) }
        return UserDefaults.standard.bool(forKey: reopenKey)
    }

    private func install() {
        guard installNowBlock != nil || installReply != nil else { return }
        UserDefaults.standard.set(Date(), forKey: Self.installingKey)
        UserDefaults.standard.set(MailDotAboutWindow.shared.isOpen, forKey: Self.reopenKey)
        if let block = installNowBlock { installNowBlock = nil; Self.log.notice("installing \(self.readyVersion ?? "-", privacy: .public)"); block() }
        else if let reply = installReply { installReply = nil; Self.log.notice("installing \(self.readyVersion ?? "-", privacy: .public)"); reply(.install) }
    }

    private func ready(_ item: SUAppcastItem) {
        readyVersion = item.displayVersionString
        publish()
        // Mail already closed when the download finished: Install Now is shown, and the next quit of Mail also installs.
    }

    private func publish() {
        guard let directory = try? BridgeStore.shared().directory else { return }
        try? UpdateStatus(readyVersion: readyVersion, checkedAt: lastCheck).write(bridgeDirectory: directory)
    }

    /// The first launch of a new build: the steps the installer's postinstall takes, so that an update installed by
    /// Sparkle leaves Mail Dot exactly as the installer would. The extension is registered again, the background helper
    /// starts from the new copy, and the waiting record is cleared.
    private func finishInstalledUpdate() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let key = "LastLaunchedBuild"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(build, forKey: key)
        if let directory = try? BridgeStore.shared().directory {
            let status = UpdateStatus.read(bridgeDirectory: directory)
            if status.readyVersion != nil, status.waiting(runningVersion: runningVersion) == nil {
                try? UpdateStatus(readyVersion: nil, checkedAt: status.checkedAt).write(bridgeDirectory: directory)
            }
        }
        guard let previous, previous != build else { return }
        Self.log.notice("first launch of build \(build, privacy: .public) after \(previous, privacy: .public)")
        let appex = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/MailDotExtension.appex").path
        Self.run("/usr/bin/pluginkit", ["-a", appex])
        Self.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/org.jgkarlin.MailBridge.Runtime"])
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run(); process.waitUntilExit()
    }
}

extension MailDotUpdater: SPUUpdaterDelegate {
    /// The silent path: the update is downloaded and verified, and Sparkle would install it when Mail Dot quits.
    /// Mail Dot rarely quits, so it keeps the block and installs when Mail quits instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNowBlock = immediateInstallHandler
        ready(item)
        return true
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        checking = false
        lastCheck = .now
        publish()
    }
}

/// Sparkle's interface, answered without showing anything. Each question gets the answer the owner chose once for all:
/// check automatically, download automatically, send no system profile, install when Mail has quit.
extension MailDotUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Reached only when the silent path cannot be taken. Download it; installing waits for Mail to quit.
        foundItem = appcastItem
        if state.stage == .notDownloaded { reply(.install) }
        else { installReply = reply; ready(appcastItem) }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        Logger(subsystem: "org.jgkarlin.MailBridge", category: "update").error("update failed: \(error.localizedDescription, privacy: .public)")
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        if let item = foundItem { ready(item) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {
        checking = false
    }
}
