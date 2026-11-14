import Foundation
import Darwin

@_silgen_name("flock") private func settingsFileLock(_ fd:Int32,_ operation:Int32) -> Int32

/// Separate from reply state: older reply helpers/extensions cannot erase settings.
public struct MailSettingsStore:Sendable {
    public let directory:URL
    public init(bridgeDirectory:URL) { directory=bridgeDirectory.appendingPathComponent("Configuration",isDirectory:true) }
    public static func shared() throws -> Self { try Self(bridgeDirectory:BridgeStore.shared().directory) }
    public func read() throws -> MailSettings { try locked { try load() } }
    public func transaction<T>(_ body:(inout MailSettings)throws -> T) throws -> T {
        try locked {
            var settings=try load(); let result=try body(&settings); try settings.validate()
            let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
            let data=try encoder.encode(settings)
            guard data.count <= 1_048_576 else { throw BridgeFailure("Mail settings exceed 1 MiB.") }
            let temporary=directory.appendingPathComponent("settings-\(UUID().uuidString).tmp")
            let fd=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd >= 0 else { throw BridgeFailure("Cannot create private settings file.") }
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at:temporary) }
            try handle.write(contentsOf:data); try handle.synchronize()
            guard Darwin.rename(temporary.path,directory.appendingPathComponent("settings.json").path) == 0 else { throw BridgeFailure("Cannot commit Mail settings.") }
            return result
        }
    }
    private func load() throws -> MailSettings {
        let url=directory.appendingPathComponent("settings.json"); var info=stat()
        if lstat(url.path,&info) != 0 {
            if errno == ENOENT { return MailSettings() }
            throw BridgeFailure("Cannot inspect Mail settings.")
        }
        guard info.st_mode & S_IFMT == S_IFREG,info.st_size <= 1_048_576 else { throw BridgeFailure("Settings are not a bounded regular file.") }
        let settings=try JSONDecoder().decode(MailSettings.self,from:Data(contentsOf:url)); try settings.validate(); return settings
    }
    private func locked<T>(_ body:()throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(directory.appendingPathComponent("settings.lock").path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw BridgeFailure("Cannot open settings lock.") }
        defer { _=settingsFileLock(fd,LOCK_UN); Darwin.close(fd) }
        guard settingsFileLock(fd,LOCK_EX) == 0 else { throw BridgeFailure("Cannot lock Mail settings.") }
        return try body()
    }
}
