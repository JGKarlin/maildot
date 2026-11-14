import Foundation
import Darwin

@_silgen_name("flock") private func compositionFileLock(_ fd:Int32,_ operation:Int32)->Int32

public enum NativeCompositionOutcome:String,Sendable {case pending,unconfirmed,created,failed}

public struct NativeCompositionOperation:Codable,Sendable,Identifiable {
    public let id:String
    public let plan:NativeCompositionPlan
    public let createdAt:Date
    public fileprivate(set) var claimedAt:Date?
    public fileprivate(set) var consumedAt:Date?
    public fileprivate(set) var draft:MailDraft?
    public fileprivate(set) var error:String?
    /// A claim proves an attempt began, not that a worker is still running.
    public var outcome:NativeCompositionOutcome {
        if draft != nil {return .created}
        if error != nil {return .failed}
        return claimedAt == nil ? .pending : .unconfirmed
    }
    fileprivate init(plan:NativeCompositionPlan) { id=UUID().uuidString; self.plan=plan; createdAt=Date() }
}

public struct NativeCompositionState:Codable,Sendable {
    public let schemaVersion:Int
    public private(set) var operations:[NativeCompositionOperation]
    public init() { schemaVersion=1; operations=[] }

    public func validate() throws {
        guard schemaVersion == 1,operations.count <= 100,
              Set(operations.map(\.id)).count == operations.count,
              Set(operations.map{ $0.plan.requestID }).count == operations.count else {
            throw BridgeFailure("Invalid or full draft-creation history.")
        }
        for op in operations {
            try op.plan.composition.validate()
            guard UUID(uuidString:op.id) != nil,UUID(uuidString:op.plan.requestID) != nil,
                  op.plan.requestRevision > 0,!op.plan.nativeAccountID.isEmpty,
                  op.plan.nativeAccountID.utf8.count <= 1024,
                  op.createdAt.timeIntervalSince1970.isFinite,
                  op.claimedAt.map({$0.timeIntervalSince1970.isFinite && $0 >= op.createdAt}) ?? true,
                  op.consumedAt.map({date in op.claimedAt.map{date.timeIntervalSince1970.isFinite && date >= $0} ?? false}) ?? true,
                  op.error.map({!$0.isEmpty && $0.utf8.count <= 8192 && op.claimedAt != nil && op.draft == nil}) ?? true else {
                throw BridgeFailure("Invalid draft-creation operation.")
            }
            if let draft=op.draft {
                guard op.consumedAt != nil else { throw BridgeFailure("Draft result has no consumed creation attempt.") }
                try op.plan.validateCreated(draft)
            }
        }
    }

    @discardableResult public mutating func enqueue(_ plan:NativeCompositionPlan) throws -> NativeCompositionOperation {
        guard operations.count < 100,!operations.contains(where:{$0.plan.requestID == plan.requestID}) else {
            throw BridgeFailure("This proposal already has a creation attempt, or creation history is full. Inspect Mail before continuing.")
        }
        let operation=NativeCompositionOperation(plan:plan)
        operations.append(operation)
        return operation
    }
    public mutating func claimNext() -> NativeCompositionOperation? {
        guard let index=operations.firstIndex(where:{$0.claimedAt == nil && $0.error == nil && $0.draft == nil}) else { return nil }
        operations[index].claimedAt=Date()
        return operations[index]
    }
    public mutating func consume(_ id:String,request:MailWorkflowRequest?,accounts:[MailWorkflowAccount],nativeAccounts:[NativeMailAccount]) throws {
        guard let index=operations.firstIndex(where:{$0.id == id}),let request,
              operations[index].claimedAt != nil,operations[index].consumedAt == nil,
              operations[index].draft == nil,operations[index].error == nil else {
            throw BridgeFailure("This creation attempt is unavailable or was already used.")
        }
        try operations[index].plan.validate(request:request,accounts:accounts,nativeAccounts:nativeAccounts)
        operations[index].consumedAt=Date()
    }
    public mutating func complete(_ id:String,draft:MailDraft) throws {
        guard let index=operations.firstIndex(where:{$0.id == id}),operations[index].consumedAt != nil,
              operations[index].draft == nil,operations[index].error == nil else {
            throw BridgeFailure("Cannot confirm this creation attempt.")
        }
        try operations[index].plan.validateCreated(draft)
        operations[index].draft=draft
    }
    public mutating func fail(_ id:String,error:String) {
        guard let index=operations.firstIndex(where:{$0.id == id}),operations[index].claimedAt != nil,
              operations[index].draft == nil,operations[index].error == nil else { return }
        operations[index].error=String((error.isEmpty ? "Creation could not be confirmed. Inspect Mail." : error).prefix(2048))
    }
    public mutating func recoverInterrupted() {
        for index in operations.indices where operations[index].claimedAt != nil && operations[index].draft == nil && operations[index].error == nil {
            operations[index].error="Mail Dot restarted during draft creation. Inspect Mail; this attempt will not be replayed."
        }
    }
}

/// Kept separate from legacy extension-written state so it cannot erase the
/// durable single-use record while an older Mail extension is still loaded.
public struct NativeCompositionStore:Sendable {
    public let directory:URL
    private let limit=2_097_152
    public init(bridgeDirectory:URL) { directory=bridgeDirectory.appendingPathComponent("Compositions",isDirectory:true) }
    public static func shared() throws -> Self { try Self(bridgeDirectory:BridgeStore.shared().directory) }
    public func read() throws -> NativeCompositionState { try locked {try load()} }
    public func transaction<T>(_ body:(inout NativeCompositionState)throws->T) throws -> T {
        try locked {
            var state=try load(); let result=try body(&state); try state.validate()
            let data=try JSONEncoder().encode(state)
            guard data.count <= limit else { throw BridgeFailure("Draft-creation history exceeds 2 MiB.") }
            let temporary=directory.appendingPathComponent("composition-\(UUID().uuidString).tmp")
            let fd=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd >= 0 else { throw BridgeFailure("Cannot create private draft-creation state.") }
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer {try? handle.close(); try? FileManager.default.removeItem(at:temporary)}
            try handle.write(contentsOf:data); try handle.synchronize()
            guard Darwin.rename(temporary.path,directory.appendingPathComponent("compositions.json").path) == 0 else { throw BridgeFailure("Cannot save draft-creation state.") }
            return result
        }
    }
    private func load() throws -> NativeCompositionState {
        let fd=Darwin.open(directory.appendingPathComponent("compositions.json").path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT {return NativeCompositionState()}
            throw BridgeFailure("Cannot open draft-creation state.")
        }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer {try? handle.close()}
        var info=stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size <= limit else { throw BridgeFailure("Draft-creation state is not a bounded regular file.") }
        var data=Data()
        while data.count <= limit {
            guard let chunk=try handle.read(upToCount:min(65_536,limit+1-data.count)),!chunk.isEmpty else {break}
            data.append(chunk)
        }
        guard data.count <= limit else { throw BridgeFailure("Draft-creation state exceeds its read limit.") }
        let state=try JSONDecoder().decode(NativeCompositionState.self,from:data); try state.validate(); return state
    }
    private func locked<T>(_ body:()throws->T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(directory.appendingPathComponent("compositions.lock").path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw BridgeFailure("Cannot open draft-creation lock.") }
        defer {_=compositionFileLock(fd,LOCK_UN); Darwin.close(fd)}
        guard compositionFileLock(fd,LOCK_EX) == 0 else { throw BridgeFailure("Cannot lock draft-creation state.") }
        return try body()
    }
}
