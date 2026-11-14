import Foundation
import Darwin

@_silgen_name("flock") private func nativeMailLock(_ descriptor:Int32,_ operation:Int32)->Int32

/// Private account grants and short-lived read results; never provider credentials.
public struct NativeMailStore:Sendable {
    public let directory:URL
    private let limit=2_097_152
    public init(bridgeDirectory:URL) { directory=bridgeDirectory.appendingPathComponent("NativeMail",isDirectory:true) }
    public static func shared() throws -> Self { try Self(bridgeDirectory:BridgeStore.shared().directory) }
    public func read() throws -> NativeMailState { try locked { try load() } }
    public func transaction<T>(_ body:(inout NativeMailState)throws->T) throws -> T {
        try locked {
            var value=try load(); let result=try body(&value); try value.validate()
            let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
            let data=try encoder.encode(value)
            guard data.count <= limit else { throw BridgeFailure("Native Mail state exceeds 2 MiB.") }
            let temporary=directory.appendingPathComponent("access-\(UUID().uuidString).tmp")
            let descriptor=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard descriptor >= 0 else { throw BridgeFailure("Cannot create private native Mail state.") }
            let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at:temporary) }
            try handle.write(contentsOf:data); try handle.synchronize()
            guard Darwin.rename(temporary.path,directory.appendingPathComponent("access.json").path) == 0 else { throw BridgeFailure("Cannot commit native Mail state.") }
            return result
        }
    }
    private func load() throws -> NativeMailState {
        let descriptor=Darwin.open(directory.appendingPathComponent("access.json").path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return NativeMailState() }
            throw BridgeFailure("Cannot open native Mail state.")
        }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true); defer { try? handle.close() }
        var info=stat()
        guard fstat(descriptor,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size <= limit else { throw BridgeFailure("Native Mail state is not a bounded regular file.") }
        var data=Data()
        while data.count <= limit {
            guard let chunk=try handle.read(upToCount:min(65_536,limit+1-data.count)),!chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw BridgeFailure("Native Mail state exceeds 2 MiB.") }
        let value=try JSONDecoder().decode(NativeMailState.self,from:data)
        try value.validate(); return value
    }
    private func locked<T>(_ body:()throws->T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor=Darwin.open(directory.appendingPathComponent("access.lock").path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard descriptor >= 0 else { throw BridgeFailure("Cannot open native Mail state lock.") }
        defer { _=nativeMailLock(descriptor,LOCK_UN); Darwin.close(descriptor) }
        guard nativeMailLock(descriptor,LOCK_EX) == 0 else { throw BridgeFailure("Cannot lock native Mail state.") }
        return try body()
    }
}
