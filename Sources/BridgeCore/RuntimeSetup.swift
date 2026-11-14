import Foundation
import Security

/// Mail Dot's connection settings, written by Mail Dot itself (release audit, 14 November 2026): a new user enters
/// their own OpenAI connection ID and key in setup, and Mail Dot writes the tunnel client's profile and its own
/// configuration for that user, naming this copy of the app wherever it lives. The key is kept in the login
/// Keychain, readable by Mail Dot and its background helper, never in a file. Installations set up by hand
/// before this keep their key file; nothing here reads or moves it.
public enum RuntimeSetup {
    public struct Paths: Sendable {
        public let runtime: URL
        public let profile: URL
        public let configuration: URL
        public let healthURLFile: URL
        public let log: URL
        public init(home: URL) {
            runtime = home.appendingPathComponent("Library/Application Support/Mail Dot/Runtime", isDirectory: true)
            profile = runtime.appendingPathComponent("profile.yaml")
            configuration = runtime.appendingPathComponent("configuration.json")
            let client = home.appendingPathComponent("Library/Application Support/tunnel-client", isDirectory: true)
            healthURLFile = client.appendingPathComponent("health/mail-dot.url")
            log = client.appendingPathComponent("logs/mail-dot.log")
        }
    }

    /// An OpenAI tunnel ID as the tunnel client accepts it: tunnel_ and 32 lowercase letters or digits, optionally
    /// after a namespace of 4 (found 14 November 2026; anything else stops the client at once).
    public static func validTunnelID(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.range(of: #"^tunnel_([a-z0-9]{4}_)?[a-z0-9]{32}$"#, options: .regularExpression) != nil
    }

    /// The tunnel client's profile (JSON, which YAML reads, written without escaped slashes: the tunnel client's YAML
    /// reader refuses "\/", found 14 November 2026). It names no key: the helper passes it from the Keychain.
    public static func profile(tunnelID: String, agentPath: String, agentArguments: [String] = [], paths: Paths) -> [String: Any] {
        [
            "config_version": 1,
            "admin_ui": ["open_browser": false],
            "control_plane": ["base_url": "https://api.openai.com", "tunnel_id": tunnelID.trimmingCharacters(in: .whitespacesAndNewlines)],
            "health": ["listen_addr": "127.0.0.1:0", "url_file": paths.healthURLFile.path],
            "log": ["file": paths.log.path, "format": "json", "level": "info"],
            "mcp": ["commands": [["channel": "main", "command": ([agentPath] + agentArguments).map { "\"" + $0 + "\"" }.joined(separator: " ")]]],
        ]
    }

    /// Writes the profile and configuration for this user, owner-only, replacing any earlier ones it wrote.
    public static func write(tunnelID: String, agentPath: String, agentArguments: [String] = [], clientPath: String? = nil, paths: Paths) throws {
        guard validTunnelID(tunnelID) else { throw BridgeFailure("Enter the connection ID OpenAI shows for your tunnel. It begins with tunnel_.") }
        guard agentPath.hasPrefix("/") else { throw BridgeFailure("Mail Dot could not find its own helper.") }
        let manager = FileManager.default
        for directory in [paths.runtime, paths.healthURLFile.deletingLastPathComponent(), paths.log.deletingLastPathComponent()] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let profileData = try JSONSerialization.data(withJSONObject: profile(tunnelID: tunnelID, agentPath: agentPath, agentArguments: agentArguments, paths: paths), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writePrivately(profileData, to: paths.profile)
        var configuration: [String: Any] = ["profilePath": paths.profile.path, "keySource": "keychain"]
        if let clientPath { configuration["clientPath"] = clientPath }
        try writePrivately(try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: paths.configuration)
    }

    /// Whether Mail Dot's settings exist for this user.
    public static func isConfigured(paths: Paths) -> Bool {
        FileManager.default.fileExists(atPath: paths.configuration.path) && FileManager.default.fileExists(atPath: paths.profile.path)
    }

    /// The connection ID in the profile, for showing in setup; nil if there is none.
    public static func tunnelID(paths: Paths) -> String? {
        guard let data = try? Data(contentsOf: paths.profile),
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (profile["control_plane"] as? [String: Any])?["tunnel_id"] as? String
    }

    static func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + "-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw BridgeFailure("Mail Dot could not save its connection settings.")
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw BridgeFailure("Mail Dot could not save its connection settings.")
        }
    }

    // MARK: The key, in the Keychain

    // The login keychain, with an access list naming Mail Dot and its background helper, so the helper reads the key
    // without a prompt. The shared data-protection keychain would need a provisioning profile, which a build signed
    // for GitHub distribution does not carry (it refused with errSecMissingEntitlement, 14 November 2026).
    public static let keyService = "org.jgkarlin.MailBridge.tunnel-key"
    public static let keyAccount = "OpenAI tunnel key"

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: keyAccount]
    }

    /// Saves the key the user entered, replacing any earlier one, readable by the programs at `trustedPaths` (Mail Dot
    /// and its background helper). It is never written to a file or logged.
    public static func storeKey(_ key: String, trustedPaths: [String], service: String = keyService) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4096 else { throw BridgeFailure("Paste the key OpenAI gave you for this tunnel.") }
        var trusted: [SecTrustedApplication] = []
        for path in trustedPaths {
            var application: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &application) == errSecSuccess, let application { trusted.append(application) }
        }
        guard trusted.count == trustedPaths.count else { throw BridgeFailure("Mail Dot could not find its own helper to give it the key.") }
        var access: SecAccess?
        guard SecAccessCreate("Mail Dot · OpenAI tunnel key" as CFString, trusted as CFArray, &access) == errSecSuccess, let access else {
            throw BridgeFailure("Mail Dot could not prepare the Keychain item.")
        }
        SecItemDelete(query(service) as CFDictionary)
        var item = query(service)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccess as String] = access
        item[kSecAttrLabel as String] = "Mail Dot · OpenAI tunnel key"
        var status = SecItemAdd(item as CFDictionary, nil)
        // An item an earlier setup saved, which this copy of Mail Dot may not delete: its value is replaced instead.
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw BridgeFailure("Mail Dot could not save the key in your Keychain (error \(status)).") }
    }

    /// Whether a key is saved, without reading it.
    public static func hasKey(service: String = keyService) -> Bool {
        var probe = query(service)
        probe[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(probe as CFDictionary, nil) == errSecSuccess
    }

    public static func deleteKey(service: String = keyService) {
        SecItemDelete(query(service) as CFDictionary)
    }
}
