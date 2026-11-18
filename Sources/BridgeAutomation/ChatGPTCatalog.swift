import Foundation
import BridgeCore

/// Reads the names of ChatGPT's controls, in every language, from the ChatGPT app on this Mac (see ChatGPTLabels).
/// Only ChatGPT's own program files are read: its archive of interface files, of which the translation tables are a
/// part. Nothing of the user's is in them. The result is kept in Mail Dot's own folder and read again only when the
/// ChatGPT app has changed.
public enum ChatGPTCatalog {
    private struct Saved: Codable { var stamp: String; var labels: ChatGPTLabels }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: Saved?

    /// The names for this copy of ChatGPT; the English ones alone when its files cannot be read.
    public static func labels(app: URL, cache: URL? = defaultCache) -> ChatGPTLabels {
        let archive = app.appendingPathComponent("Contents/Resources/app.asar")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path),
              let size = attributes[.size] as? Int, let changed = attributes[.modificationDate] as? Date else { return .english }
        let stamp = "\(size)-\(Int(changed.timeIntervalSince1970))"
        lock.lock(); let current = held; lock.unlock()
        if let current, current.stamp == stamp { return current.labels }
        if let cache, let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.stamp == stamp {
            lock.lock(); held = saved; lock.unlock()
            return saved.labels
        }
        let labels = reading(archive)
        let saved = Saved(stamp: stamp, labels: labels)
        lock.lock(); held = saved; lock.unlock()
        if let cache, let data = try? JSONEncoder().encode(saved) {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: cache, options: .atomic)
        }
        return labels
    }
    public static var defaultCache: URL? {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/chatgpt-labels.json")
    }

    /// The archive's large interface scripts: the translation tables are among them, one a language, each a few
    /// megabytes. The archive begins with a list of its files and where each lies. One file is held at a time.
    static func reading(_ archive: URL) -> ChatGPTLabels {
        var labels = ChatGPTLabels.english
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return labels }
        defer { try? handle.close() }
        func number(at offset: UInt64) -> Int? {
            guard (try? handle.seek(toOffset: offset)) != nil, let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return nil }
            return Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        }
        guard let headerSize = number(at: 4), let listLength = number(at: 12), listLength > 0, listLength < 64_000_000,
              (try? handle.seek(toOffset: 16)) != nil, let list = try? handle.read(upToCount: listLength),
              let root = try? JSONSerialization.jsonObject(with: list) as? [String: Any] else { return labels }
        let base = UInt64(8 + headerSize)
        var places: [(offset: UInt64, size: Int)] = []
        func walk(_ folder: [String: Any], _ path: String) {
            for (name, value) in folder["files"] as? [String: Any] ?? [:] {
                guard let entry = value as? [String: Any] else { continue }
                if entry["files"] != nil { walk(entry, path + name + "/"); continue }
                guard path.hasPrefix("webview/assets/"), name.hasSuffix(".js"), entry["unpacked"] == nil,
                      let size = entry["size"] as? Int, size >= 1_000_000, size <= 32_000_000,
                      let offset = (entry["offset"] as? String).flatMap(UInt64.init) else { continue }
                places.append((offset, size))
            }
        }
        walk(root, "")
        for place in places.prefix(600) {
            guard (try? handle.seek(toOffset: base + place.offset)) != nil, let data = try? handle.read(upToCount: place.size) else { continue }
            labels.add(table: data)
        }
        return labels.settled()
    }
}
