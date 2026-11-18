import Foundation
import CryptoKit

public actor EventHub {
    /// The events Mail Dot sends. `mail.reply_context_changed` was a third until 17 November 2026: every message
    /// opened in Mail Dot has carried the owner's request since build 78, which reaches Dot as a workflow request,
    /// so that event had not been sent since 12 November while its subscription and handler were still renewed.
    public static let eventNames = ["mail.settings_requested","mail.workflow_requested"]
    public static let retiredEventName = "mail.reply_context_changed"
    /// How long a subscription whose renewal is late may still be tried. ChatGPT renews on its own schedule and
    /// cannot reach a Mac that is asleep or off, so a missed renewal must not disable Mail Dot by itself.
    public static let renewalGrace: TimeInterval = 86_400
    /// What Dot's Keep connected run is told about renewal. ChatGPT renews an existing handler's subscription by
    /// itself, and Dot's subscribe tool always creates a new handler (18 November 2026: renewing two expiring
    /// subscriptions made two duplicates), so Dot acts only for an event with nothing left to deliver on.
    public static let renewalInstruction = "ChatGPT renews the subscription of each existing Mail Dot handler by itself; do not renew it. Never call a subscribe tool for an event that already has a Mail Dot handler, enabled or paused, because that creates a duplicate handler. renewal_needed is true only when an event's state is missing: it has had no subscription to deliver on for a day. For each missing event only: if its Mail Dot handler exists but is paused, enable it; if it exists and is enabled, create nothing and tell the owner once that Mail Dot's handler for that event has stopped renewing; if it does not exist, create exactly one handler for it, subscribed with queue_id personal and ttlMs set to requested_lifetime_ms."
    /// A request that reached nobody within this time is closed, so that it cannot arrive hours later
    /// when the owner has moved on.
    public static let undeliveredLimit: TimeInterval = 900
    public static let undeliveredMessage = "Dot could not be reached within 15 minutes, so this request was not delivered. Ask again."
    static func undelivered(_ event: BridgeEvent, now: Date = .now) -> Bool {
        event.receipts.isEmpty && now.timeIntervalSince(event.occurredAt) > undeliveredLimit
    }
    /// The longest lifetime this server grants; Dot is asked to request it.
    public static let longestLifetimeMs = 86_400_000
    /// The shortest lifetime granted, and the one granted when none is asked for. ChatGPT asked for an hour or for
    /// nothing, every one of 587 grants up to 17 November 2026 was an hour, and it renewed 70 to 98 times a day.
    /// OpenAI's Events page lets a server enforce a minimum "to prevent excessive refresh requests".
    public static let shortestLifetimeMs = 86_400_000
    private let shortestLifetimeMs: Int
    private let store: BridgeStore
    private let sender: @Sendable (URLRequest) async throws -> (Data,Int)
    private let deliveryLog: URL?
    private var notedWaiting: Set<String> = []
    public init(store: BridgeStore, sender: (@Sendable (URLRequest) async throws -> (Data,Int))? = nil, deliveryLog: URL? = nil,
                shortestLifetimeMs: Int = EventHub.shortestLifetimeMs) {
        self.store = store; self.deliveryLog = deliveryLog; self.shortestLifetimeMs = shortestLifetimeMs
        self.sender = sender ?? { try await PinnedWebhookTransport.send($0) }
    }

    public func subscribe(_ params: JSONValue) async throws -> JSONValue {
        if params["name"].string == Self.retiredEventName {
            note("subscribe refused \(Self.retiredEventName): retired")
            throw BridgeFailure("Mail Dot no longer sends mail.reply_context_changed. Unsubscribe from it and delete its handler; do not subscribe to it again.")
        }
        guard let eventName=params["name"].string,Self.eventNames.contains(eventName), params["arguments"] == ["queue_id":"personal"],
              params["delivery"]["mode"] == "webhook", let rawURL = params["delivery"]["url"].string,
              let secret = params["delivery"]["secret"].string else { throw BridgeFailure("Invalid Mail Dot event subscription.") }
        let url: URL
        do { url = try WebhookSecurity.callbackURL(rawURL) }
        catch {
            // If ChatGPT ever calls back on a domain that is not allowed, the log must say so plainly.
            note("subscribe refused \(eventName): callback address not on an allowed domain")
            throw error
        }
        let prefix = eventName == "mail.workflow_requested" ? "sub_workflow_" : (eventName == "mail.settings_requested" ? "sub_settings_" : "sub_")
        let id = prefix + SHA256.hash(data:Data((rawURL + "|" + eventName + "|personal").utf8)).map { String(format:"%02x",$0) }.joined()
        let challenge = UUID().uuidString + UUID().uuidString
        let body = try JSONValue.object(["type":"verification", "challenge":.string(challenge)]).text()
        let data:Data, status:Int
        do { (data,status) = try await post(Data(body.utf8), id:"verification_" + UUID().uuidString, url:url, secret:secret, subscriptionID:id) }
        catch { throw CallbackEndpointFailure(reason:"connection_failed") }
        guard (200..<300).contains(status), data.count <= 4096,
              let reply = try? JSONDecoder().decode(JSONValue.self, from:data), let echoed = reply["challenge"].string,
              WebhookSecurity.sameChallenge(challenge, echoed) else { throw CallbackEndpointFailure(reason:"challenge_failed") }
        let requested = params["ttlMs"].integer
        let lifetime = Double(max(shortestLifetimeMs, 60_000, min(requested ?? Self.longestLifetimeMs, Self.longestLifetimeMs))) / 1000
        var subscription = EventSubscription(id:id, callbackURL:rawURL, secret:secret,
                                             expiresAt:Date().addingTimeInterval(lifetime), verifiedAt:.now)
        subscription.eventName=eventName
        try store.transaction { state in
            let now = Date()
            // A verified renewal replaces its own earlier record, anything it supersedes for this event,
            // and anything too long overdue to be tried again. Stale records therefore cannot accumulate.
            state.subscriptions.removeAll {
                $0.id == id || $0.expiresAt <= now.addingTimeInterval(-Self.renewalGrace)
                    || ($0.resolvedEventName == eventName && $0.expiresAt <= now)
            }
            state.subscriptions.append(subscription)
        }
        // Which official domain ChatGPT calls back on, so that domains it never uses can later be dropped.
        let family = WebhookSecurity.callbackDomain(of: url) ?? "-"
        note("subscribed \(eventName) host=\(family) lifetime=\(Int(lifetime))s asked=\(requested.map { "\($0 / 1000)s" } ?? "none")")
        return ["id":.string(id), "refreshBefore":.string(subscription.expiresAt.ISO8601Format()), "cursor":nil, "truncated":false]
    }

    public func unsubscribe(_ params: JSONValue) throws -> JSONValue {
        guard let eventName=params["name"].string,(Self.eventNames+[Self.retiredEventName]).contains(eventName), params["arguments"] == ["queue_id":"personal"],
              let rawURL = params["delivery"]["url"].string else { throw BridgeFailure("Invalid unsubscribe request.") }
        try store.transaction { $0.subscriptions.removeAll { $0.callbackURL == rawURL && $0.resolvedEventName == eventName } }
        return [:]
    }

    public func pump() async {
        do {
            let state = try store.read()
            // A message opened in Mail Dot reaches Dot as the owner's own request (a workflow request, which carries
            // the message). The older "message shared" event is retired: it had not been sent since 12 November 2026,
            // because every message has carried an owner request since build 78. Its record is closed, never sent.
            let unsent = state.contexts.values.filter { ($0.event?.attempts ?? 8) < 8 }.map { ($0.id, $0.event!.id) }
            if !unsent.isEmpty {
                try? store.transaction { state in
                    for (contextID, eventID) in unsent where state.contexts[contextID]?.event?.id == eventID {
                        state.contexts[contextID]?.event?.attempts = 8
                        state.contexts[contextID]?.event?.lastError = nil
                    }
                }
            }
            if state.subscriptions.contains(where: { $0.resolvedEventName == Self.retiredEventName }) {
                try? store.transaction { $0.subscriptions.removeAll { $0.resolvedEventName == Self.retiredEventName } }
            }
            await pumpSettings(subscriptions:state.subscriptions)
            await pumpWorkflow(subscriptions:state.subscriptions)
        } catch { /* Storage failures remain visible when the native panel reads the store. */ }
    }

    /// A request ChatGPT confirmed receiving but no session started within this long is announced again, once
    /// (owner report, 16 November 2026: two drafts waited an hour on events Dot did not act on). It was three times at
    /// 90 seconds until 17 November: that made 79 events for 32 requests in a day, each one more turn in the single
    /// conversation every request waits in, and the waits of 4 to 14 minutes went on regardless.
    static let unreadRedelivery:TimeInterval=300
    static let unreadRedeliveries=1

    private func pumpWorkflow(subscriptions:[EventSubscription]) async {
        let workflow=MailWorkflowStore(bridgeDirectory:store.directory)
        try? workflow.transaction { state in
            for index in state.requests.indices {
                let request=state.requests[index]
                guard ![.ready,.failed].contains(request.stage),request.event.reviewedAt == nil,!request.hasActiveClaim(),
                      let received=request.event.receiptAt,Date().timeIntervalSince(received) > Self.unreadRedelivery,
                      (request.redeliveries ?? 0) < Self.unreadRedeliveries else { continue }
                state.requests[index].event=BridgeEvent()
                state.requests[index].redeliveries=(request.redeliveries ?? 0)+1
            }
        }
        guard let state=try? workflow.read() else { return }
        for request in state.requests where ![.ready,.failed].contains(request.stage) && request.needsEventDelivery && request.event.nextAttemptAt <= .now && request.event.attempts < 8 {
            // A worker already has it; or a listener on the Mac is waiting and is given twenty seconds to take it
            // before Dot in the cloud is told (release review, 14 November 2026: two workers answered one request).
            if request.hasActiveClaim() { continue }
            if state.listenerActive(),!request.opensCall,Date().timeIntervalSince(request.createdAt) < 20 { continue }
            let event=request.event
            if Self.undelivered(event) {
                try? workflow.transaction { state in
                    guard let index=state.requests.firstIndex(where:{$0.id == request.id && $0.event.id == event.id}) else { return }
                    state.requests[index].event.attempts=8; state.requests[index].event.lastError=Self.undeliveredMessage
                }
                continue
            }
            let menuTargets=subscriptions.deliverable(for:"mail.workflow_requested")
            if menuTargets.isEmpty { noteWaiting("mail.workflow_requested",eventID:event.id) }
            for subscription in menuTargets where event.receipts[subscription.id] == nil {
                do {
                    let available=try MailWorkflowAccount.available(settings:MailSettingsStore(bridgeDirectory:store.directory).read(),native:NativeMailStore(bridgeDirectory:store.directory).read())
                    guard Set(request.accountIDs).isSubset(of:Set(available.map(\.id))),
                          try workflow.read().requests.contains(where:{$0.id == request.id && $0.event.id == event.id && ![.ready,.failed].contains($0.stage)}) else { continue }
                    let payload:JSONValue=["eventId":.string(event.id),"name":"mail.workflow_requested","timestamp":.string(event.occurredAt.ISO8601Format()),"data":["request_id":.string(request.id),"request_revision":.number(Double(request.revision))],"cursor":nil]
                    guard let status=try await deliver(payload,eventID:event.id,to:subscription) else { continue }
                    try updateWorkflowReceipt(workflow,requestID:request.id,eventID:event.id,subscriptionID:subscription.id,status:status)
                } catch {
                    try? updateWorkflowReceipt(workflow,requestID:request.id,eventID:event.id,subscriptionID:subscription.id,status:0)
                }
            }
        }
    }
    private func updateWorkflowReceipt(_ workflow:MailWorkflowStore,requestID:String,eventID:String,subscriptionID:String,status:Int) throws {
        try workflow.transaction { state in
            guard let index=state.requests.firstIndex(where:{$0.id == requestID && $0.event.id == eventID}) else { return }
            if (200..<300).contains(status) {
                state.requests[index].event.receiptAt = .now
                state.requests[index].event.receipts[subscriptionID] = .now
                state.requests[index].event.lastError=nil
            } else {
                state.requests[index].event.attempts += 1
                state.requests[index].event.lastError="Workflow delivery was not confirmed."
                state.requests[index].event.nextAttemptAt=Date().addingTimeInterval(pow(2,Double(state.requests[index].event.attempts)))
                if status == 410 || status == 413 { state.requests[index].event.attempts=8 }
            }
        }
    }
    private func pumpSettings(subscriptions:[EventSubscription]) async {
        let settingsStore=MailSettingsStore(bridgeDirectory:store.directory)
        // Renewal must not depend on the owner remembering to ask for it: request Dot's Keep connected job unprompted.
        let lastCheck=(try? ToolCallLogStore(bridgeDirectory:store.directory).read())?.last(where:{ $0.tool == "bridge_status" && $0.outcome == .ok })?.at
        if var trial=try? settingsStore.read(),(try? MailSettingsCoordinator.ensureKeepConnected(settings:&trial,lastStatusCheck:lastCheck)) == true {
            _ = try? settingsStore.transaction { try MailSettingsCoordinator.ensureKeepConnected(settings:&$0,lastStatusCheck:lastCheck) }
        }
        guard let settings=try? settingsStore.read() else { return }
        noteState(subscriptions:subscriptions,settings:settings)
        for request in settings.requests where request.kind != .unknown && ![.confirmed,.failed].contains(request.status) && request.event.nextAttemptAt <= .now && request.event.attempts < 8 {
            let event=request.event
            if Self.undelivered(event) {
                try? settingsStore.transaction { settings in
                    guard let index=settings.requests.firstIndex(where:{ $0.id == request.id && $0.event.id == event.id }) else { return }
                    settings.requests[index].event.attempts=8; settings.requests[index].event.lastError=Self.undeliveredMessage
                }
                continue
            }
            let settingsTargets=subscriptions.deliverable(for:"mail.settings_requested")
            if settingsTargets.isEmpty { noteWaiting("mail.settings_requested",eventID:event.id) }
            for subscription in settingsTargets where event.receipts[subscription.id] == nil {
                let payload:JSONValue=["eventId":.string(event.id),"name":"mail.settings_requested","timestamp":.string(event.occurredAt.ISO8601Format()),"data":["request_id":.string(request.id),"configuration_revision":.number(Double(settings.revision))],"cursor":nil]
                do {
                    guard let status=try await deliver(payload,eventID:event.id,to:subscription) else { continue }
                    try updateSettingsReceipt(settingsStore,request:request,subscription:subscription,status:status)
                } catch { try? updateSettingsReceipt(settingsStore,request:request,subscription:subscription,status:0) }
            }
        }
    }
    private func updateSettingsReceipt(_ store:MailSettingsStore,request:MailSettingsRequest,subscription:EventSubscription,status:Int) throws {
        try store.transaction { settings in
            guard let index=settings.requests.firstIndex(where:{ $0.id == request.id && $0.event.id == request.event.id }) else { return }
            if (200..<300).contains(status) {
                settings.requests[index].event.receiptAt = .now
                settings.requests[index].event.receipts[subscription.id] = .now
                settings.requests[index].event.lastError=nil
            } else {
                settings.requests[index].event.attempts += 1
                settings.requests[index].event.lastError=status == 0 ? "Settings callback unavailable." : "Settings callback returned HTTP \(status)."
                settings.requests[index].event.nextAttemptAt=Date().addingTimeInterval(pow(2,Double(request.event.attempts+1)))
                if status == 410 || status == 413 { settings.requests[index].event.attempts=8 }
            }
        }
    }

    /// Sends one event and returns the endpoint's status. Returns nil when a subscription whose renewal is
    /// overdue was refused by its endpoint: that subscription is then removed, and the event is left exactly
    /// as it was so that it reaches Dot once a renewed subscription arrives.
    private func deliver(_ payload: JSONValue, eventID: String, to subscription: EventSubscription) async throws -> Int? {
        let url = try WebhookSecurity.callbackURL(subscription.callbackURL)
        let name = Self.eventNames.first { $0 == payload["name"].string } ?? "-"
        let renewal = subscription.expiresAt > .now ? "active" : "overdue"
        let status: Int
        do { (_, status) = try await post(Data(payload.text().utf8), id:eventID, url:url, secret:subscription.secret, subscriptionID:subscription.id) }
        catch { note("\(name) status=unreachable subscription=\(renewal)"); throw error }
        note("\(name) status=\(status) subscription=\(renewal)")
        // Only "not found" and "gone" mean the endpoint no longer exists. A rate limit or any other refusal
        // is temporary and must not cost the subscription.
        if subscription.expiresAt <= .now, [404,410].contains(status) {
            try store.transaction { state in state.subscriptions.removeAll { $0.id == subscription.id } }
            return nil
        }
        return status
    }

    /// Diagnostic lines about event delivery: the event's fixed name, the endpoint's status and whether the
    /// subscription was live. Never the payload, the callback address or the secret.
    private func note(_ text: String) {
        guard let deliveryLog else { return }
        ToolCallLogStore.appendLine("\(Date().ISO8601Format()) event \(text)", to: deliveryLog)
    }
    private var lastNotedState = ""
    /// One line whenever the overall picture changes: each subscription's health and where the
    /// keep-connected request stands. It lets renewal be diagnosed without access to the private store.
    private func noteState(subscriptions: [EventSubscription], settings: MailSettings) {
        guard deliveryLog != nil else { return }
        func health(_ name: String) -> String {
            if subscriptions.contains(where: { $0.resolvedEventName == name && $0.expiresAt > .now }) { return "active" }
            return subscriptions.deliverable(for: name).isEmpty ? "missing" : "overdue"
        }
        let keep: String
        if settings.keepConnectedConfirmedAt != nil { keep = "confirmed" }
        else if let request = settings.requests.last(where: { $0.kind == .keepConnected }) {
            keep = request.status == .failed ? "failed(\(request.resultCode == "noAnswer" ? "noAnswer" : "refused"))"
                : "pending(delivered=\(request.event.receiptAt == nil ? "no" : "yes"),attempts=\(request.event.attempts))"
        } else { keep = "none" }
        let summary = "state settings=\(health("mail.settings_requested")) menu=\(health("mail.workflow_requested")) keepConnected=\(keep)"
        guard summary != lastNotedState else { return }
        lastNotedState = summary
        ToolCallLogStore.appendLine("\(Date().ISO8601Format()) \(summary)", to: deliveryLog!)
    }
    private func noteWaiting(_ name: String, eventID: String) {
        guard notedWaiting.insert(eventID).inserted else { return }
        if notedWaiting.count > 500 { notedWaiting = [eventID] }
        note("\(name) waiting subscription=none")
    }

    private func post(_ body: Data, id: String, url: URL, secret: String, subscriptionID: String) async throws -> (Data,Int) {
        guard body.count <= 262_144, let host = url.host else { throw BridgeFailure("Invalid callback payload.") }
        _ = host
        let timestamp = Int(Date().timeIntervalSince1970)
        var request = URLRequest(url:url)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField:"Content-Type")
        request.setValue(id, forHTTPHeaderField:"webhook-id")
        request.setValue(String(timestamp), forHTTPHeaderField:"webhook-timestamp")
        request.setValue(try WebhookSecurity.signature(id:id,timestamp:timestamp,body:body,secret:secret), forHTTPHeaderField:"webhook-signature")
        request.setValue(subscriptionID, forHTTPHeaderField:"X-MCP-Subscription-Id")
        return try await sender(request)
    }
}
extension Array where Element == EventSubscription {
    /// Where an event of this name should be sent now. A live subscription always wins. With none, the most
    /// recently verified subscription overdue by less than the grace period stands in, and its endpoint's
    /// answer decides whether it is still alive.
    public func deliverable(for eventName: String, now: Date = .now) -> [EventSubscription] {
        let named = filter { $0.resolvedEventName == eventName }
        // One event goes to one subscription. Two live records for the same event would make Dot act twice.
        if let live = named.filter({ $0.expiresAt > now }).max(by: { $0.verifiedAt < $1.verifiedAt }) { return [live] }
        let overdue = named.filter { $0.expiresAt > now.addingTimeInterval(-EventHub.renewalGrace) }
        return overdue.max { $0.verifiedAt < $1.verifiedAt }.map { [$0] } ?? []
    }
}

struct CallbackEndpointFailure: Error {
    let reason:String
}

/// Only one helper sends Dot's notices (release review, 14 November 2026): every helper a task on the Mac starts
/// would otherwise send them too, and they went out twice. The first process to take this lock keeps it for its
/// life; when it ends, the next to ask gets it.
@_silgen_name("flock") private func lockDescriptor(_ descriptor:Int32,_ operation:Int32) -> Int32
public final class EventPumpLease:@unchecked Sendable {
    private let path:String
    private var descriptor:Int32 = -1
    private let guardLock=NSLock()
    public init(bridgeDirectory:URL) { path=bridgeDirectory.appendingPathComponent("events.lock").path }
    deinit { if descriptor >= 0 { close(descriptor) } }
    /// Whether this process is the one that sends notices; asks for the lock if it does not hold it yet.
    public var held:Bool {
        guardLock.lock(); defer { guardLock.unlock() }
        if descriptor >= 0 { return true }
        let opened=open(path,O_RDWR|O_CREAT|O_CLOEXEC,0o600)
        guard opened >= 0 else { return false }
        if lockDescriptor(opened,LOCK_EX|LOCK_NB) == 0 { descriptor=opened; return true }
        close(opened)
        return false
    }
}
