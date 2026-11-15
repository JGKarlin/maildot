import AppKit
import OSLog
import BridgeCore
import BridgeAutomation

/// Runs the work that fills Mail Dot's search index, in small steps.
///
/// Through Mail (Ask Dot review, 15 November 2026): a step asks Mail for a few messages or one listing, which takes
/// Mail and this app a moment each, so such steps are taken only while Mail is open, nothing else is waiting for
/// Mail, and neither the Ask Dot bar is showing nor one of Mail Dot's windows in use.
///
/// From Mail's own files and by meaning (owner's request, 15 November 2026): with search by meaning on and Full
/// Disk Access given, the folders are read straight from the Mail folder, and every indexed message is embedded
/// with Apple's on-device model. Neither needs Mail, so this goes on while Mail is closed. Without the access the
/// option stays on and mail is read through Mail as before.
@MainActor final class MailIndexRunner {
    static let shared=MailIndexRunner()
    private static let log=Logger(subsystem:"org.jgkarlin.MailBridge",category:"Index")
    private let automation=MailAutomation()
    private let files=MailFileSync(home:FileManager.default.homeDirectoryForCurrentUser)
    private let embedder=ContextualEmbedder()
    private var nextStep=Date.distantPast
    private var nextForget=Date.distantPast
    private var running=false
    private var working=false
    private var turn=0
    /// The folders Mail keeps files for and Mail Dot may read them from; the rest are read through Mail.
    private var onDisk:Set<String>=[]

    /// `meaningGrants` are the accounts the owner ticked Search by Meaning for; `meaning` says there is one at least.
    private struct Scope { var grants:[NativeMailGrant]; var meaningGrants:[NativeMailGrant]; var owner:Set<String>; var index:MailSearchIndex; var operations:Bool; var meaning:Bool { !meaningGrants.isEmpty } }
    private func scope() -> Scope? {
        guard let store=try? NativeMailStore.shared(),let state=try? store.read(),let settings=try? MailSettingsStore.shared().read() else { return nil }
        let grants=MailIndexPass.scope(settings:settings,native:state)
        return Scope(grants:grants,meaningGrants:grants.filter{ settings.searchByMeaning(account:$0.accountID) },owner:settings.ownerAddresses,
                     index:MailSearchIndex(bridgeDirectory:store.directory.deletingLastPathComponent()),operations:!state.operations.isEmpty || !state.setupOperations.isEmpty)
    }
    private static func allowed(_ grants:[NativeMailGrant]) -> [String:[String]] {
        Dictionary(grants.map{ ($0.accountID,$0.mailboxes.map(\.id)) },uniquingKeysWith:{ first,_ in first })
    }

    /// The part that needs nothing from Mail: forgetting what is no longer allowed, reading Mail's files, embedding.
    /// Called every few seconds whether Mail is open or not. It starts the work and returns at once; all of the work
    /// is done off the main thread, a short piece at a time (independent review of build 170, M4 and M5).
    func tickLocal() {
        guard !working,let scope=scope(),let kept=keptGrants() else { return }
        // Not while the Mac is saving power or running hot.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return }
        working=true
        let now=Date()
        let forget=now >= nextForget
        if forget { nextForget=now.addingTimeInterval(30) }
        let home=FileManager.default.homeDirectoryForCurrentUser
        // Only the accounts ticked for Search by Meaning are read from Mail's files and embedded.
        let folders=scope.meaningGrants.flatMap(\.mailboxes)
        let ticked=Set(scope.meaningGrants.map(\.accountID))
        let idle=CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:~0)!)
        // A second and a half of work at a time, three while the Mac is left alone.
        let budget:TimeInterval=idle >= 120 ? 3 : 1.5
        let files=files,embedder=embedder,index=scope.index,owner=scope.owner,allowed=Self.allowed(scope.meaningGrants),keep=Self.allowed(kept),meaning=scope.meaning
        Task.detached(priority:.utility) { [weak self] in
            var forgotten=0,read=0,gone=0,embedded=0,missing:[String]=[],removedEmbeddings=false,granted=false
            let until=Date().addingTimeInterval(budget)
            // What the owner no longer allows, or switched Mail Dot off for, leaves the index within half a minute,
            // a few hundred messages at a time; what is left is then written without the space they held.
            if forget {
                while Date() < until,let count=try? index.keep(only:keep,limit:300),count > 0 { forgotten += count }
                if forgotten > 0,Date() < until { try? index.compact() }
            }
            // An account the owner unticked keeps nothing of its embeddings.
            if forget,let lost=try? index.keepEmbeddings(onlyAccounts:ticked),lost > 0 { removedEmbeddings=true; try? index.compact() }
            if meaning,!folders.isEmpty {
                granted=MailFiles.access(home:home) == .granted
                if granted {
                    missing=files.notOnDisk(folders).map(\.id)
                    let present=folders.filter{ !missing.contains($0.id) }
                    // Reading takes at most half of the time, so that embedding keeps pace with it.
                    let readUntil=Date().addingTimeInterval(max(0,until.timeIntervalSinceNow)/2)
                    while Date() < readUntil {
                        guard let outcome=try? files.step(index:index,folders:present,owner:owner) else { break }
                        if case .read(let count)=outcome { read += count } else if case .scanned(_,let left)=outcome { gone += left } else { break }
                    }
                }
                while Date() < until {
                    guard let count=try? MailEmbedding.step(index:index,embedder:embedder,allowed:allowed,batch:20),count > 0 else { break }
                    embedded += count
                }
            }
            // The few numbers Settings shows, counted here so that Settings never opens the index.
            do {
                var counts:[String:MeaningProgress.Counts]=[:]
                for (account,boxes) in allowed { if let progress=try? index.embeddingProgress(account:account,mailboxes:boxes) { counts[account]=MeaningProgress.Counts(embedded:progress.embedded,total:progress.total) } }
                MeaningProgress.publish(counts,bridgeDirectory:index.file.deletingLastPathComponent().deletingLastPathComponent())
            }
            let done=(forgotten,read,gone,embedded,missing,removedEmbeddings,granted)
            await self?.finished(done,folders:folders.map(\.id),meaning:meaning)
        }
    }
    private func finished(_ done:(forgotten:Int,read:Int,gone:Int,embedded:Int,missing:[String],removedEmbeddings:Bool,granted:Bool),folders:[String],meaning:Bool) {
        working=false
        onDisk=meaning && done.granted ? Set(folders).subtracting(done.missing) : []
        if done.forgotten > 0 { Self.log.info("forgot \(done.forgotten) messages no longer allowed") }
        if done.removedEmbeddings { Self.log.info("embeddings of an unticked account removed") }
        if done.read+done.gone+done.embedded > 0 { Self.log.info("from Mail's files: read \(done.read), gone \(done.gone); embedded \(done.embedded)") }
    }
    /// What stays in the index: an account whose folder check has just failed keeps what was indexed.
    private func keptGrants() -> [NativeMailGrant]? {
        guard let store=try? NativeMailStore.shared(),let state=try? store.read(),let settings=try? MailSettingsStore.shared().read() else { return nil }
        return MailIndexPass.kept(settings:settings,native:state)
    }

    /// The part that goes through Mail.
    func tick() async {
        guard !running,let scope=scope() else { return }
        running=true; defer { running=false }
        let now=Date()
        // Folders read from Mail's own files are left to that reader.
        let grants=scope.grants.compactMap { grant -> NativeMailGrant? in
            var kept=grant; kept.mailboxes=grant.mailboxes.filter{ !onDisk.contains($0.id) }
            return kept.mailboxes.isEmpty ? nil : kept
        }
        guard now >= nextStep,!grants.isEmpty else { return }
        // Dot's own reads and the owner's actions come first.
        guard !scope.operations,(try? BridgeStore.shared().read().operations.contains(where:{ $0.result == nil && $0.error == nil })) != true else { return }
        // Mail has been open a minute: a mailbox still loading lists nothing, and nothing is taken for deleted on that account.
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first(where:{ !$0.isTerminated }),
              now.timeIntervalSince(mail.launchDate ?? now) >= 60,
              !NSApplication.shared.isActive,!AskDotController.shared.showing else { return }
        // Not while the owner is at work in Mail: a step makes Mail answer a script, and typing there would stutter.
        let quiet=CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:~0)!)
        guard !(mail.isActive && quiet < 10) else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return }
        guard await automation.permissionStatus() == 0 else { nextStep=now.addingTimeInterval(60); return }
        let reader=NativeMailReader(operationDeadline:now.addingTimeInterval(20))
        turn += 1
        let outcome=(try? await MailIndexPass.step(reader:reader,index:scope.index,grants:grants,owner:scope.owner,turn:turn)) ?? .rested
        let idle=CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:~0)!)
        switch outcome {
        case .idle: nextStep=Date().addingTimeInterval(30)
        case .rested: nextStep=Date().addingTimeInterval(30); Self.log.info("a folder is resting after Mail refused a read")
        case .read(let count): nextStep=Date().addingTimeInterval(idle >= 120 ? 4 : 12); Self.log.info("read \(count) messages into the index")
        case .listed(let count): nextStep=Date().addingTimeInterval(idle >= 120 ? 2 : 6); if count > 0 { Self.log.info("listed \(count) messages to read") }
        }
    }
}
