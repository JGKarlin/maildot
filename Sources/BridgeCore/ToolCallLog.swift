import Foundation
import Darwin

@_silgen_name("flock") private func callLogLock(_ fd:Int32,_ operation:Int32)->Int32

/// One MCP request as the agent saw it: when it arrived, which method or tool it named, and how it ended.
/// It never holds arguments, results or correspondence, so the log can be read without exposing mail.
public struct ToolCallRecord:Codable,Sendable,Equatable {
    public enum Outcome:String,Codable,Sendable {case ok,refused,failed}
    public let at:Date
    public let method:String
    public let tool:String?
    public let outcome:Outcome
    /// A refusal's fixed wording, kept only for tools whose refusals contain no caller-supplied text.
    public let detail:String?
    public init(at:Date,method:String,tool:String?,outcome:Outcome,detail:String?) {
        self.at=at; self.method=method; self.tool=tool; self.outcome=outcome; self.detail=detail
    }
}

/// A bounded, private record of recent calls, newest last. It answers whether Dot called and whether it was refused.
public struct ToolCallLogStore:Sendable {
    public static let limit=500
    private static let byteLimit=1_048_576
    public let directory:URL
    public init(bridgeDirectory:URL) {directory=bridgeDirectory.appendingPathComponent("CallLog",isDirectory:true)}

    public func read() throws -> [ToolCallRecord] {try locked{try load()}}

    public func append(_ record:ToolCallRecord) throws {
        try locked {
            let records=Array((try load()+[record]).suffix(Self.limit))
            let data=try JSONEncoder().encode(records)
            guard data.count <= Self.byteLimit else {throw BridgeFailure("The call log exceeds its size limit.")}
            let temporary=directory.appendingPathComponent("calls-\(UUID().uuidString).tmp")
            let fd=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd >= 0 else {throw BridgeFailure("Cannot save the call log.")}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer {try? handle.close(); try? FileManager.default.removeItem(at:temporary)}
            try handle.write(contentsOf:data); try handle.synchronize()
            guard Darwin.rename(temporary.path,directory.appendingPathComponent("calls.json").path) == 0 else {
                throw BridgeFailure("Cannot commit the call log.")
            }
        }
    }

    /// Appends one line per call to a private text file. Best effort: a failure here is ignored.
    public static func mirror(_ record:ToolCallRecord,to file:URL) {
        appendLine("\(record.at.ISO8601Format()) \(record.method) \(record.tool ?? "-") \(record.outcome.rawValue) \(record.detail ?? "-")",to:file)
    }
    /// Appends one line to a private text file. The caller supplies only fixed, content-free wording.
    public static func appendLine(_ text:String,to file:URL) {
        try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var info=stat()
        if lstat(file.path,&info) == 0,info.st_size > byteLimit {
            _ = Darwin.rename(file.path,file.deletingPathExtension().appendingPathExtension("old.log").path)
        }
        let fd=Darwin.open(file.path,O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else {return}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer {try? handle.close()}
        try? handle.write(contentsOf:Data((text+"\n").utf8))
    }

    private func load() throws -> [ToolCallRecord] {
        let fd=Darwin.open(directory.appendingPathComponent("calls.json").path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        if fd < 0 {if errno == ENOENT {return []}; throw BridgeFailure("Cannot read the call log.")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer {try? handle.close()}
        var info=stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size <= Self.byteLimit else {
            throw BridgeFailure("The call log is not a bounded regular file.")
        }
        let data=try handle.readToEnd() ?? Data()
        return try JSONDecoder().decode([ToolCallRecord].self,from:data)
    }

    private func locked<T>(_ body:()throws->T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(directory.appendingPathComponent("calls.lock").path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else {throw BridgeFailure("Cannot open the call-log lock.")}
        defer {_=callLogLock(fd,LOCK_UN); Darwin.close(fd)}
        guard callLogLock(fd,LOCK_EX) == 0 else {throw BridgeFailure("Cannot lock the call log.")}
        return try body()
    }
}
