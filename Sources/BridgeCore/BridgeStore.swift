import Foundation
import Darwin
import Security

// Qualifying Darwin.flock selects the imported C struct rather than the function.
@_silgen_name("flock") private func lockFileDescriptor(_ descriptor: Int32, _ operation: Int32) -> Int32

public struct BridgeStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    /// The app group named in this process's own signature: the builder's team prefix and this suffix, so the
    /// source names no one developer's team (release audit, 14 November 2026). An unsigned run, such as the
    /// package tests, has no signature to read and uses the bare suffix.
    public static let groupSuffix = "org.jgkarlin.MailBridge"
    public static let groupID: String = signedAppGroup() ?? groupSuffix
    static func signedAppGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String] else { return nil }
        return groups.first { $0.hasSuffix("." + groupSuffix) }
    }

    public static func shared() throws -> BridgeStore {
        #if DEBUG
        // Development builds can be pointed at a synthetic store, so the interface can be rendered and
        // inspected without touching the owner's real data. Release builds have no such override.
        if let path = ProcessInfo.processInfo.environment["MAILDOT_PREVIEW_STORE"], !path.isEmpty {
            return BridgeStore(directory: URL(fileURLWithPath: path, isDirectory: true))
        }
        #endif
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw BridgeFailure("Mail Dot cannot access its shared container. Open the signed companion app first.")
        }
        return BridgeStore(directory: group.appendingPathComponent("BridgeState", isDirectory: true))
    }

    /// At most this many messages are kept; the least recently used beyond it are dropped.
    public static let contextLimit = 20
    public static let sizeLimit = 8_388_608
    public func read() throws -> BridgeState { try locked { try load() } }
    public func transaction<T>(_ body: (inout BridgeState) throws -> T) throws -> T {
        try locked {
            var state = try load()
            let result = try body(&state)
            state.audit = Array(state.audit.suffix(100))
            let finished = state.operations.filter { $0.result != nil || $0.error != nil }.suffix(60).map(\.id)
            let retained = Set(finished)
            state.operations.removeAll { ($0.result != nil || $0.error != nil) && !retained.contains($0.id) }
            // Messages a reply window registered are forgotten when the window closes, but not when Mail quits
            // or the extension restarts. Old ones are dropped here, oldest first, so they can never fill the
            // store and stop Mail Dot (seen 12 November 2026, after a day of reinstalls).
            state.pruneContexts(keeping: Self.contextLimit)
            guard state.operations.count <= 100, state.subscriptions.count <= 10 else {
                throw BridgeFailure("Mail Dot has too many unfinished actions. Wait a moment and try again.")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(state)
            while data.count > Self.sizeLimit, state.pruneContexts(keeping: max(1, state.contexts.count - 1)) { data = try encoder.encode(state) }
            guard data.count <= Self.sizeLimit else { throw BridgeFailure("This message is too long for Mail Dot to keep. Nothing was changed.") }
            let temporary = directory.appendingPathComponent("state-\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw BridgeFailure("Cannot create private state file.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard Darwin.rename(temporary.path, directory.appendingPathComponent("state.json").path) == 0 else {
                throw BridgeFailure("Cannot commit shared state.")
            }
            return result
        }
    }

    private func load() throws -> BridgeState {
        let url = directory.appendingPathComponent("state.json")
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return BridgeState() }
            throw BridgeFailure("Cannot inspect shared state.")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= Self.sizeLimit else {
            throw BridgeFailure("Shared state is not a bounded regular file.")
        }
        let state = try JSONDecoder().decode(BridgeState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1 else { throw BridgeFailure("Unsupported shared-state version. Existing data was preserved.") }
        return state
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.appendingPathComponent("state.lock").path,
                                     O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BridgeFailure("Cannot lock shared state.") }
        defer { _ = lockFileDescriptor(descriptor, LOCK_UN); Darwin.close(descriptor) }
        guard lockFileDescriptor(descriptor, LOCK_EX) == 0 else { throw BridgeFailure("Shared-state lock failed.") }
        return try body()
    }
}
