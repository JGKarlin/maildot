import Foundation
import Darwin

/// A backup of what the owner set up: connected accounts, schedules and their links, and received scheduled
/// updates. It deliberately leaves out everything that must not outlive its moment or leave the Mac:
/// subscriptions and their signing secrets, shared replies and their text, send approvals, queued actions,
/// pending requests, and mailbox grants (restoring a grant would re-grant access the owner may have removed).
public enum StateBackup {
    public struct Archive:Codable,Sendable {
        public var format=1
        public var createdAt:Date
        public var build:String
        public var settings:MailSettings
        public var updates:ScheduledMailUpdateState
    }

    /// Writes one private file into an existing folder the owner named, and returns it.
    public static func export(bridgeDirectory:URL,to destination:URL,build:String,now:Date = .now) throws -> URL {
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:destination.path,isDirectory:&isDirectory),isDirectory.boolValue else {
            throw BridgeFailure("Choose an existing folder for the backup.")
        }
        var settings=try MailSettingsStore(bridgeDirectory:bridgeDirectory).read()
        settings.requests=[]
        let archive=Archive(createdAt:now,build:build,settings:settings,updates:try ScheduledMailUpdateStore(bridgeDirectory:bridgeDirectory).read())
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        let data=try encoder.encode(archive)
        let stamp=now.ISO8601Format().replacingOccurrences(of:":",with:"")
        let file=destination.appendingPathComponent("MailDot-backup-\(stamp).json")
        let fd=Darwin.open(file.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw BridgeFailure("Cannot create the backup file. A backup with this time may already exist.") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? handle.close() }
        try handle.write(contentsOf:data); try handle.synchronize()
        return file
    }

    /// Restores accounts, schedules and links. Received updates are restored only into an empty store, so
    /// newer receipts are never overwritten. Dot's earlier statement that its renewal job exists is not
    /// restored; it must be shown again by evidence.
    public static func restore(from file:URL,bridgeDirectory:URL) throws {
        let data=try Data(contentsOf:file)
        guard data.count <= 4_194_304 else { throw BridgeFailure("This file is too large to be a Mail Dot backup.") }
        let archive=try JSONDecoder().decode(Archive.self,from:data)
        guard archive.format == 1 else { throw BridgeFailure("This backup was made by a newer Mail Dot.") }
        try archive.settings.validate(); try archive.updates.validate()
        let settingsStore=MailSettingsStore(bridgeDirectory:bridgeDirectory)
        // The settings about to be replaced are kept beside the live ones, so a mistaken restore can be undone.
        let replaced=try settingsStore.read()
        let stamp=Date().ISO8601Format().replacingOccurrences(of:":",with:"")
        let kept=settingsStore.directory.appendingPathComponent("settings-before-restore-\(stamp).json")
        let fd=Darwin.open(kept.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw BridgeFailure("Cannot keep the current settings before restoring, so nothing was restored.") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        try handle.write(contentsOf:JSONEncoder().encode(replaced)); try handle.synchronize(); try handle.close()
        try settingsStore.transaction { current in
            var restored=archive.settings
            restored.requests=[]; restored.keepConnectedConfirmedAt=nil; restored.keepConnectedUnanswered=0
            restored.revision=max(current.revision,archive.settings.revision)+1
            current=restored
        }
        let updates=ScheduledMailUpdateStore(bridgeDirectory:bridgeDirectory)
        if try updates.read().sequence == 0 { try updates.transaction { $0=archive.updates } }
    }
}
