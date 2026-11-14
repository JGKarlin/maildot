import Foundation
import CryptoKit

public enum WebhookSecurity {
    public static func signature(id: String, timestamp: Int, body: Data, secret: String) throws -> String {
        guard secret.hasPrefix("whsec_"), let key = Data(base64Encoded: String(secret.dropFirst(6))), (24...64).contains(key.count) else {
            throw BridgeFailure("Invalid callback signing secret.")
        }
        var message = Data("\(id).\(timestamp).".utf8)
        message.append(body)
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data:key))
        return "v1," + Data(digest).base64EncodedString()
    }

    /// The domains ChatGPT may be called back on. ChatGPT was observed on November 11, 2026 to use
    /// openai.com; chatgpt.com is its other first-party domain. oaiusercontent.com, which serves content
    /// supplied by users, was allowed earlier and is not.
    public static let allowedCallbackDomains = ["openai.com", "chatgpt.com"]
    public static func callbackDomain(of url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return allowedCallbackDomains.first { host == $0 || host.hasSuffix("." + $0) }
    }

    public static func callbackURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 4096, let url = URL(string:raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443, callbackDomain(of: url) != nil else {
            throw BridgeFailure("This prototype accepts HTTPS callback URLs on official OpenAI domains only.")
        }
        return url
    }

    public static func sameChallenge(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count,b.count) {
            difference |= Int((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0))
        }
        return difference == 0
    }
}
