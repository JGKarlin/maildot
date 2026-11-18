import Foundation

/// What Mail Dot's updater last found, written by the app for its own About window and for Mail Dot's settings in Mail,
/// which runs in the extension and cannot ask the app directly (owner's approval of automatic updates, 18 November 2026).
/// An update is downloaded and checked in the background and installed only after Mail quits, because replacing the
/// extension under a running Mail has crashed it.
public struct UpdateStatus: Codable, Equatable, Sendable {
    /// The version an update is ready to install, as people see it (for example 0.4.212); nil when up to date.
    public var readyVersion: String?
    /// When the updater last finished a check, found or not.
    public var checkedAt: Date?
    public init(readyVersion: String? = nil, checkedAt: Date? = nil) { self.readyVersion = readyVersion; self.checkedAt = checkedAt }

    public static let fileName = "update-status.json"
    public static func url(bridgeDirectory: URL) -> URL { bridgeDirectory.appendingPathComponent(fileName) }
    public static func read(bridgeDirectory: URL) -> UpdateStatus {
        guard let data = try? Data(contentsOf: url(bridgeDirectory: bridgeDirectory)),
              let status = try? JSONDecoder.iso.decode(UpdateStatus.self, from: data) else { return UpdateStatus() }
        return status
    }
    public func write(bridgeDirectory: URL) throws {
        try JSONEncoder.iso.encode(self).write(to: Self.url(bridgeDirectory: bridgeDirectory), options: .atomic)
    }
    /// An update the running build already is, or is newer than, is not waiting any more: after an install the new
    /// build clears the record on its first launch, and a stale record must not show a line until then.
    public func waiting(runningVersion: String) -> String? {
        guard let readyVersion, readyVersion.compare(runningVersion, options: .numeric) == .orderedDescending else { return nil }
        return readyVersion
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
private extension JSONEncoder {
    static var iso: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}
