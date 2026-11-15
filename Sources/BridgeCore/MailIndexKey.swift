import Foundation
import Security

/// The key that encrypts Mail Dot's search index (owner's decision, 15 November 2026: "Encrypt."; SQLCipher approved
/// the same day). A random 256-bit key, made on this Mac the first time the index is opened and kept in the login
/// Keychain with an access list naming Mail Dot and its helper, the two programs that open the index. It is never
/// written to a file, logged or shown. Without it the index file is unreadable; if it is lost, the index is made again
/// from Mail.
public enum MailIndexKey {
    public static let service = "org.jgkarlin.MailBridge.index-key"
    static let account = "Search index key"
    static let label = "Mail Dot · search index key"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Data?

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// The key, made and saved the first time. Programs that open the index at the same moment end with the same key:
    /// the one saved first is the one every program reads.
    static func current() throws -> Data {
        #if DEBUG
        // Tests never touch the owner's Keychain: inside XCTest the index uses a fixed key of its own.
        if NSClassFromString("XCTestCase") != nil { return Data(repeating: 0x5A, count: 32) }
        #endif
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let found = try read() { cached = found; return found }
        var fresh = Data(count: 32)
        let made = fresh.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard made == errSecSuccess else { throw BridgeFailure("Mail Dot could not make a key for its search index.") }
        var item = query()
        item[kSecValueData as String] = fresh
        item[kSecAttrLabel as String] = label
        if let access = access() { item[kSecAttrAccess as String] = access }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let saved = try read() { cached = saved; return saved }
        guard status == errSecSuccess else { throw BridgeFailure("Mail Dot could not save the key of its search index in your Keychain (error \(status)).") }
        cached = fresh
        return fresh
    }
    private static func read() throws -> Data? {
        var search = query()
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: AnyObject?
        let status = SecItemCopyMatching(search as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, data.count == 32 else {
            // Locked or refused: the index waits. It is never made again for want of a readable key.
            throw BridgeFailure("Mail Dot could not read the key of its search index from your Keychain (error \(status)).")
        }
        return data
    }
    /// Mail Dot and its helper, by the copy that is running: the app that holds this program.
    private static func access() -> SecAccess? {
        var url = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        while url.pathComponents.count > 1, url.pathExtension != "app" { url.deleteLastPathComponent() }
        guard url.pathExtension == "app" else { return nil }
        var trusted: [SecTrustedApplication] = []
        for path in [url.path, url.appendingPathComponent("Contents/Helpers/MailDotAgent").path] {
            var application: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &application) == errSecSuccess, let application { trusted.append(application) }
        }
        var access: SecAccess?
        guard !trusted.isEmpty, SecAccessCreate(label as CFString, trusted as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
    /// The key as SQLCipher takes it: raw bytes, so no key derivation runs at each opening.
    static func pragma(_ key: Data) -> String { "PRAGMA key = \"x'" + key.map { String(format: "%02X", $0) }.joined() + "'\"" }
    /// Removing Mail Dot deletes the key with the index. True when no key is left.
    @discardableResult public static func delete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        SecItemDelete(query() as CFDictionary)
        var probe = query(); probe[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(probe as CFDictionary, nil) == errSecItemNotFound
    }
}
