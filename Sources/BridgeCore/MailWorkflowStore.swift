import Foundation
import Darwin

@_silgen_name("flock") private func workflowFileLock(_ fd:Int32,_ operation:Int32)->Int32

public struct MailWorkflowState:Codable,Sendable {
    public var schemaVersion=1
    public var requests:[MailWorkflowRequest]=[]
    public var dismissedItemVersions:[MailWorkflowItemVersion]=[]
    /// Questions Dot has put to the owner outside a call. Absent from state saved by earlier builds.
    public var questions:[OwnerQuestion]=[]
    /// When a task on the Mac last waited for work through wait_for_work. Absent from state saved by earlier builds.
    public var listenerSeenAt:Date?
    /// The worker that last waited there, so that its reports on requests it holds also show it is present.
    public var listenerWorker:String?
    /// Reply requests the owner replaced with newer words while Dot was at work on them, each with its reply, so that a
    /// draft Dot then hands back for the old one is refused and Dot is sent to the new one (owner request, 24 November
    /// 2026). Absent from state saved by earlier builds.
    public var replacedReplies:[String:String]=[:]
    public init() {}
    private enum CodingKeys:String,CodingKey { case schemaVersion,requests,dismissedItemVersions,questions,listenerSeenAt,listenerWorker,replacedReplies }
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion=try values.decode(Int.self,forKey:.schemaVersion)
        requests=try values.decode([MailWorkflowRequest].self,forKey:.requests)
        dismissedItemVersions=try values.decode([MailWorkflowItemVersion].self,forKey:.dismissedItemVersions)
        questions=try values.decodeIfPresent([OwnerQuestion].self,forKey:.questions) ?? []
        listenerSeenAt=try values.decodeIfPresent(Date.self,forKey:.listenerSeenAt)
        listenerWorker=try values.decodeIfPresent(String.self,forKey:.listenerWorker)
        replacedReplies=try values.decodeIfPresent([String:String].self,forKey:.replacedReplies) ?? [:]
    }
    /// The request that now stands for a reply, when Dot names one the owner has since replaced; nil when the named
    /// request is current or was never replaced.
    public func replyReplacement(named id:String?,contextID:String) -> String? {
        guard let id,replacedReplies[id] == contextID else { return nil }
        return requests.last(where:{ $0.action == .reply && $0.contextID == contextID })?.id ?? ""
    }
    /// A listener on the Mac is waiting now: it asked for work within the last half minute.
    public func listenerActive(now:Date=Date()) -> Bool { listenerSeenAt.map{ now.timeIntervalSince($0) < 30 } ?? false }
    /// Requests the owner made themselves (a reply from the panel, Tell Dot, a call, an answer, Ask Dot) that Dot has
    /// not started yet. While one waits, no automatic request is added in front of it, and a background request Dot
    /// opens names it, so that Dot turns to the owner first (owner report, 17 November 2026: a reply asked for in the
    /// panel waited three and a half minutes while Dot handled an automatic draft check that arrived after it).
    public func ownerRequestsWaiting(now:Date=Date()) -> [MailWorkflowRequest] {
        requests.filter { request in
            !MailWorkflowRequest.backgroundActions.contains(request.action) && ![.ready,.failed].contains(request.stage)
                && request.claim == nil && now.timeIntervalSince(request.createdAt) < MailWorkflowRequest.ownerPriorityWindow
        }
    }
    // MARK: The chain (owner's choice of a batch, 18 November 2026)

    /// How long each place in a new batch waits before ChatGPT is told of that message by a notice of its own, if
    /// Dot has not been handed it by then: the pace of one message at a time, so a chain Dot does not follow costs
    /// nothing against how things were.
    public static let chainPlaceWait:TimeInterval=75
    /// After a report, Dot is expected to take the next message within this long.
    public static let chainTakeWait:TimeInterval=45
    /// While Dot works on one message, the ones behind it wait at least this long.
    public static let chainWorkWait:TimeInterval=180

    /// The messages of a batch that Dot has not been handed and ChatGPT has not been told of, oldest first.
    public func chainWaiting(now:Date=Date()) -> [MailWorkflowRequest] {
        requests.filter{ $0.chained == true && $0.action == .draftCheck && $0.stage == .pending && !$0.hasActiveClaim(now:now) && $0.event.receiptAt == nil && $0.event.attempts == 0 }
            .sorted{ $0.createdAt < $1.createdAt }
    }
    /// Puts off the notices of the waiting messages: the first by `first`, each one after it by a place more. A
    /// notice not yet sent is made afresh, so that its age is counted from now. Returns the requests put off.
    @discardableResult public mutating func deferChain(first:TimeInterval,now:Date=Date()) -> [String] {
        let waiting=chainWaiting(now:now)
        for (place,request) in waiting.enumerated() {
            guard let index=requests.firstIndex(where:{$0.id == request.id}) else { continue }
            var event=BridgeEvent()
            event.occurredAt=now
            event.nextAttemptAt=now.addingTimeInterval(first+Double(place)*Self.chainPlaceWait)
            requests[index].event=event
        }
        return waiting.map(\.id)
    }
    /// The message Dot is handed next when it has reported on one: the first still waiting.
    public func chainNext(now:Date=Date()) -> MailWorkflowRequest? { chainWaiting(now:now).first }

    /// The worker takes the request, unless another holds it. Returns whether it is this worker's now.
    @discardableResult public mutating func take(_ id:String,worker:String,now:Date=Date()) -> Bool {
        guard let index=requests.firstIndex(where:{$0.id == id}),![.ready,.failed].contains(requests[index].stage),
              !requests[index].claimed(byAnotherThan:worker,now:now) else { return false }
        requests[index].take(worker:worker,now:now)
        return true
    }
    public func validate() throws {
        guard questions.count <= OwnerQuestion.limit,Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ OwnerQuestion.normalized($0.text) == $0.text && UUID(uuidString:$0.id) != nil }) else {
            throw BridgeFailure("Mail workflow state holds invalid questions.")
        }
        guard schemaVersion == 1,requests.count <= 20,Set(requests.map(\.id)).count == requests.count,dismissedItemVersions.count <= 1000 else {
            throw BridgeFailure("Mail workflow state exceeds its limits or contains duplicate requests.")
        }
        try requests.forEach { try $0.validate() }
        for item in dismissedItemVersions {
            guard !item.id.isEmpty,item.id.utf8.count <= 512,!item.accountID.isEmpty,item.accountID.utf8.count <= 1024,
                  !item.sourceID.isEmpty,item.sourceID.utf8.count <= 1024,item.revision >= 0 else { throw BridgeFailure("Invalid retained item revision.") }
        }
    }
    public static let limit=20
    public static let abandonAfter:TimeInterval=30*60
    public mutating func enqueue(_ request:MailWorkflowRequest,allowedAccountIDs:Set<String>) throws {
        try request.validate()
        // An answer or instruction Dot has finished with has nothing left to show; it must not fill the list.
        requests.removeAll{[.answer,.instruction,.reply,.draftCheck,.ruleCleanup,.noteCleanup,.ask,.check].contains($0.action) && [.ready,.failed].contains($0.stage)}
        // A draft, reply or rule request Dot left unfinished for half an hour is abandoned: Mail Dot has
        // stopped waiting for it (a draft is offered again after 15 minutes). Kept, such requests filled the
        // list's 20 places and every later request was refused, so new mail stayed on Drafting (13 November 2026).
        let now=Date()
        requests.removeAll{[.reply,.draftCheck,.ruleCleanup,.noteCleanup,.ask,.check].contains($0.action) && ![.ready,.failed].contains($0.stage) && now.timeIntervalSince($0.createdAt) > Self.abandonAfter}
        // Still full: the oldest finished requests of any kind make room.
        while requests.count >= Self.limit,let oldest=requests.indices.filter({[.ready,.failed].contains(requests[$0].stage)}).min(by:{requests[$0].createdAt < requests[$1].createdAt}) {
            requests.remove(at:oldest)
        }
        guard Set(request.accountIDs).isSubset(of:allowedAccountIDs),!requests.contains(where:{$0.id == request.id}),requests.count < Self.limit else {
            throw BridgeFailure("Select currently linked accounts, or clear completed requests before continuing.")
        }
        if request.action.requiresItem {
            guard let id=request.itemID,let sourceID=request.sourceID,let revision=request.itemRevision,
                  request.accountIDs.count == 1,
                  isLatestKnownVersion(id:id,accountID:request.accountIDs[0],sourceID:sourceID,revision:revision) else {
                throw BridgeFailure("Refresh the list and select its current item before continuing.")
            }
        }
        requests.append(request)
    }
    /// Local report history only; this does not establish freshness at the email provider.
    public func isLatestKnownVersion(_ item:MailWorkflowItem) -> Bool {
        isLatestKnownVersion(id:item.id,accountID:item.accountID,sourceID:item.sourceID,revision:item.revision)
    }
    private func isLatestKnownVersion(id:String,accountID:String,sourceID:String,revision:Int) -> Bool {
        let candidates=(requests.flatMap(\.observedItems).map(MailWorkflowItemVersion.init)+dismissedItemVersions).filter {
            $0.id == id && $0.accountID == accountID
        }
        return !candidates.isEmpty && candidates.map(\.revision).max() == revision && Set(candidates.map(\.sourceID)) == [sourceID]
    }
    public mutating func dismiss(_ id:String) throws {
        guard let request=requests.first(where:{$0.id == id}) else { return }
        var retained=dismissedItemVersions
        for item in request.observedItems {
            if let index=retained.firstIndex(where:{$0.id == item.id && $0.accountID == item.accountID && $0.sourceID == item.sourceID}) {
                retained[index].revision=max(retained[index].revision,item.revision)
            } else { retained.append(MailWorkflowItemVersion(item)) }
        }
        guard retained.count <= 1000 else { throw BridgeFailure("The retained item history reached its prototype limit.") }
        dismissedItemVersions=retained
        requests.removeAll{$0.id == id}
    }
}

public struct MailWorkflowItemVersion:Codable,Sendable {
    public let id:String
    public let accountID:String
    public let sourceID:String
    public var revision:Int
    init(_ item:MailWorkflowItem) { id=item.id; accountID=item.accountID; sourceID=item.sourceID; revision=item.revision }
}

/// Separate storage prevents an older loaded compose extension from dropping
/// workflow requests when it writes the legacy reply state.
public struct MailWorkflowStore:Sendable {
    public let directory:URL
    private let limit=2_097_152
    public init(bridgeDirectory:URL) { directory=bridgeDirectory.appendingPathComponent("Workflow",isDirectory:true) }
    public static func shared() throws -> Self { try Self(bridgeDirectory:BridgeStore.shared().directory) }
    public func read() throws -> MailWorkflowState { try locked { try load() } }
    public func transaction<T>(_ body:(inout MailWorkflowState)throws->T) throws -> T {
        try locked {
            var state=try load(); let result=try body(&state); try state.validate()
            let data=try JSONEncoder().encode(state)
            guard data.count <= limit else { throw BridgeFailure("Mail workflow state exceeds 2 MiB.") }
            let temporary=directory.appendingPathComponent("workflow-\(UUID().uuidString).tmp")
            let fd=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd >= 0 else { throw BridgeFailure("Cannot create private workflow state.") }
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at:temporary) }
            try handle.write(contentsOf:data); try handle.synchronize()
            guard Darwin.rename(temporary.path,directory.appendingPathComponent("workflow.json").path) == 0 else { throw BridgeFailure("Cannot save workflow state.") }
            return result
        }
    }
    private func load() throws -> MailWorkflowState {
        let fd=Darwin.open(directory.appendingPathComponent("workflow.json").path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return MailWorkflowState() }
            throw BridgeFailure("Cannot open workflow state.")
        }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? handle.close() }
        var info=stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size <= limit else { throw BridgeFailure("Workflow state is not a bounded regular file.") }
        var data=Data()
        while data.count <= limit {
            guard let chunk=try handle.read(upToCount:min(65_536,limit+1-data.count)),!chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw BridgeFailure("Workflow state exceeds its read limit.") }
        let state=try JSONDecoder().decode(MailWorkflowState.self,from:data); try state.validate(); return state
    }
    private func locked<T>(_ body:()throws->T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(directory.appendingPathComponent("workflow.lock").path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw BridgeFailure("Cannot open workflow lock.") }
        defer { _=workflowFileLock(fd,LOCK_UN); Darwin.close(fd) }
        guard workflowFileLock(fd,LOCK_EX) == 0 else { throw BridgeFailure("Cannot lock workflow state.") }
        return try body()
    }
}
