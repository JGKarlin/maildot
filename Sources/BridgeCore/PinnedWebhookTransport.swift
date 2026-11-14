import Foundation
import PinnedHTTP

enum PinnedWebhookTransport {
    static func isPublicAddress(_ text:String) -> Bool { bridge_address_is_public(text) == 1 }

    @concurrent static func send(_ request:URLRequest) async throws -> (Data,Int) {
        guard let rawURL = request.url?.absoluteString, let body = request.httpBody,
              let id = request.value(forHTTPHeaderField:"webhook-id"),
              let timestamp = request.value(forHTTPHeaderField:"webhook-timestamp"),
              let signature = request.value(forHTTPHeaderField:"webhook-signature"),
              let subscription = request.value(forHTTPHeaderField:"X-MCP-Subscription-Id") else {
            throw BridgeFailure("Incomplete signed callback request.")
        }
        _ = try WebhookSecurity.callbackURL(rawURL)
        var response = [UInt8](repeating:0,count:4096), length = 0, status = 0
        let result = body.withUnsafeBytes { bytes in
            bridge_https_post(rawURL,bytes.bindMemory(to:UInt8.self).baseAddress,body.count,
                              id,timestamp,signature,subscription,&response,response.count,&length,&status)
        }
        guard result == 0 else { throw BridgeFailure("Callback HTTPS transfer failed (code \(result)).") }
        return (Data(response.prefix(length)),status)
    }
}
