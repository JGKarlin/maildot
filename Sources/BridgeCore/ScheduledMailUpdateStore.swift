import Foundation
import Darwin

@_silgen_name("flock") private func scheduledUpdateLock(_ fd:Int32,_ operation:Int32)->Int32

public struct ScheduledMailUpdateStore:Sendable {
    public let directory:URL
    private let limit=2_097_152
    public init(bridgeDirectory:URL) {directory=bridgeDirectory.appendingPathComponent("ScheduledUpdates",isDirectory:true)}
    public func read() throws -> ScheduledMailUpdateState {try locked{try load()}}
    public func transaction<T>(_ body:(inout ScheduledMailUpdateState)throws->T) throws -> T {
        try locked {
            var state=try load(); let result=try body(&state); try state.validate()
            let data=try JSONEncoder().encode(state)
            guard data.count <= limit else {throw BridgeFailure("Scheduled updates exceed 2 MiB; nothing was acknowledged.")}
            let temporary=directory.appendingPathComponent("updates-\(UUID().uuidString).tmp")
            let fd=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd >= 0 else {throw BridgeFailure("Cannot save scheduled updates.")}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer {try? handle.close(); try? FileManager.default.removeItem(at:temporary)}
            try handle.write(contentsOf:data); try handle.synchronize()
            guard Darwin.rename(temporary.path,directory.appendingPathComponent("updates.json").path) == 0 else {throw BridgeFailure("Cannot commit scheduled update receipt.")}
            return result
        }
    }
    private func load() throws -> ScheduledMailUpdateState {
        let fd=Darwin.open(directory.appendingPathComponent("updates.json").path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        if fd < 0 {if errno == ENOENT {return ScheduledMailUpdateState()}; throw BridgeFailure("Cannot read scheduled updates.")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer {try? handle.close()}
        var info=stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size <= limit else {throw BridgeFailure("Scheduled updates are not a bounded regular file.")}
        var data=Data()
        while data.count <= limit {
            guard let chunk=try handle.read(upToCount:min(65_536,limit+1-data.count)),!chunk.isEmpty else {break}
            data.append(chunk)
        }
        guard data.count <= limit else {throw BridgeFailure("Scheduled updates exceed the read limit.")}
        let state=try JSONDecoder().decode(ScheduledMailUpdateState.self,from:data); try state.validate(); return state
    }
    private func locked<T>(_ body:()throws->T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(directory.appendingPathComponent("updates.lock").path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else {throw BridgeFailure("Cannot open scheduled-update lock.")}
        defer {_=scheduledUpdateLock(fd,LOCK_UN); Darwin.close(fd)}
        guard scheduledUpdateLock(fd,LOCK_EX) == 0 else {throw BridgeFailure("Cannot lock scheduled updates.")}
        return try body()
    }
}
