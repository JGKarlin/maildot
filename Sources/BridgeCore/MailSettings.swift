import Foundation

public struct NativeMailAccount:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var name:String
    public var addresses:[String]
    public var server:String
    /// The user's name as registered on the account in Mail ("full name"), when Mail gave it.
    public var fullName:String?
    public init(id:String,name:String,addresses:[String],server:String) { self.id=id; self.name=name; self.addresses=addresses; self.server=server }
    public var isGmail:Bool { ["imap.gmail.com","imap.googlemail.com","smtp.gmail.com","smtp.googlemail.com"].contains(server.lowercased()) || addresses.contains { $0.lowercased().hasSuffix("@gmail.com") } }
    /// An iCloud Mail account: Apple's mail servers, or an @icloud.com, @me.com or @mac.com address. Dot reaches it
    /// through ChatGPT's iCloud Mail plugin, never through AppleScript (owner decision, 15 November 2026).
    public var isICloud:Bool {
        let host=server.lowercased()
        return host == "mail.me.com" || host.hasSuffix(".mail.me.com") || addresses.contains { address in ["@icloud.com","@me.com","@mac.com"].contains { address.lowercased().hasSuffix($0) } }
    }
}

public struct MailConnection:Codable,Equatable,Identifiable,Sendable {
    /// The providers whose ChatGPT plugin Dot reads mail through: Gmail, and iCloud Mail (15 November 2026).
    public static let connectorProviders:Set<String>=["gmail","icloud"]
    /// Mail Dot's account id for the account this connection reaches.
    public var accountID:String { provider == "icloud" ? "icloud:"+id : "gmail:"+id }
    /// A connection Dot has reported and can use now.
    public var isLiveConnector:Bool { available && observedAt != nil && Self.connectorProviders.contains(provider) }
    /// The connection id inside one of Mail Dot's connector account ids, if it is one.
    public static func connectionID(inAccountID id:String) -> String? {
        if id.hasPrefix("gmail:") { return String(id.dropFirst(6)) }
        if id.hasPrefix("icloud:") { return String(id.dropFirst(7)) }
        return nil
    }
    public var id:String
    public var email:String
    public var connectionID:String
    public var provider:String = "gmail"
    public var observedAt:Date?
    public var available:Bool = true
    public init(id:String,email:String,connectionID:String) { self.id=id; self.email=email; self.connectionID=connectionID }
}

public struct MailScheduleSource:Codable,Equatable,Sendable {
    public var kind:String
    /// Provider profile ID, native Mail account ID, course/plugin ID, or personal queue ID.
    public var id:String
    public var addresses:[String]
    public var connectionID:String?
    public init(kind:String,id:String,addresses:[String],connectionID:String?=nil) { self.kind=kind; self.id=id; self.addresses=addresses; self.connectionID=connectionID }
}

public struct MailSchedule:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var title:String
    public var accountEmails:[String]
    public var cadence:String
    public var conditions:String
    public var trigger:String = "periodic"
    /// The Mac's own time zone unless the schedule names one (not one place hardcoded, for distribution).
    public var timeZone:String = TimeZone.current.identifier
    public var enabled:Bool = true
    public var observedAt:Date?
    public var nextRunAt:Date?
    public var lastAttemptAt:Date?
    public var lastSuccessAt:Date?
    public var outcome:String?
    public var available:Bool = true
    public var sources:[MailScheduleSource] = []
    public init(id:String,title:String,accountEmails:[String],cadence:String,conditions:String) {
        self.id=id; self.title=title; self.accountEmails=accountEmails; self.cadence=cadence; self.conditions=conditions
    }
    private enum CodingKeys:String,CodingKey { case id,title,accountEmails,cadence,conditions,trigger,timeZone,enabled,observedAt,nextRunAt,lastAttemptAt,lastSuccessAt,outcome,available,sources }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id); title=try c.decode(String.self,forKey:.title)
        accountEmails=try c.decode([String].self,forKey:.accountEmails); cadence=try c.decode(String.self,forKey:.cadence); conditions=try c.decode(String.self,forKey:.conditions)
        trigger=try c.decode(String.self,forKey:.trigger); timeZone=try c.decode(String.self,forKey:.timeZone); enabled=try c.decode(Bool.self,forKey:.enabled)
        observedAt=try c.decodeIfPresent(Date.self,forKey:.observedAt); nextRunAt=try c.decodeIfPresent(Date.self,forKey:.nextRunAt)
        lastAttemptAt=try c.decodeIfPresent(Date.self,forKey:.lastAttemptAt); lastSuccessAt=try c.decodeIfPresent(Date.self,forKey:.lastSuccessAt); outcome=try c.decodeIfPresent(String.self,forKey:.outcome)
        available=try c.decodeIfPresent(Bool.self,forKey:.available) ?? true
        sources=try c.decodeIfPresent([MailScheduleSource].self,forKey:.sources) ?? []
    }
}

public enum MailSettingsRequestKind:String,Codable,Sendable {
    case refresh,activate,linkSchedule,changeSchedule,nativeLink,keepConnected
    /// A kind written by a newer build. Such a request is kept and ignored, so that an older build can
    /// still read the settings after a rollback.
    case unknown
    public init(from decoder:Decoder) throws {
        self=Self(rawValue:try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}
public enum MailSettingsRequestStatus:String,Codable,Sendable { case pending,awaitingAuthorization,question,confirmed,failed }
public enum MailInventoryScope:String,Codable,Sendable { case accounts,schedules,all }
public struct MailSettingsInput:Codable,Equatable,Sendable {
    public var nativeAccountID:String?
    public var nativeGrantVersion:String?
    public var cadence:String?
    public var conditions:String?
    public var enabled:Bool?
    public var completeInventory:Bool?
    public var inventoryScope:MailInventoryScope?
    public var verificationRequestedAt:Date?
    /// For an activation: the plugin asked for, "gmail" or "icloud". Absent means Gmail, as before 15 November 2026.
    public var provider:String?
    public init() {}
}
public struct MailSettingsFormField:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var label:String
    public var kind:String
    public var options:[String]
    public var required:Bool
    public init(id:String,label:String,kind:String,options:[String],required:Bool) { self.id=id; self.label=label; self.kind=kind; self.options=options; self.required=required }
    public func validate() throws {
        guard !id.isEmpty,id.utf8.count <= 64,!label.isEmpty,label.utf8.count <= 512,
              ["text","selection","confirmation"].contains(kind),options.count <= 8,
              Set(options).count == options.count,options.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              (kind != "selection" || !options.isEmpty),(kind != "text" || options.isEmpty),
              (kind != "confirmation" || options == ["yes","no"]) else { throw BridgeFailure("Invalid native setup form field.") }
    }
}
public struct MailSettingsRequest:Codable,Identifiable,Sendable {
    public var id = UUID().uuidString
    public var kind:MailSettingsRequestKind
    public var email:String?
    public var scheduleID:String?
    public var expectedProfileID:String?
    public var protocolVersion:Int? = 1
    public var input:MailSettingsInput?
    public var form:[MailSettingsFormField]?
    public var answers:[String:String]?
    public var resultCode:String?
    public var instruction:String
    public var createdAt = Date()
    public var status:MailSettingsRequestStatus = .pending
    public var question:String?
    public var outcome:String?
    public var event = BridgeEvent()
    public init(kind:MailSettingsRequestKind,email:String?,scheduleID:String?,instruction:String) {
        self.kind=kind; self.email=email; self.scheduleID=scheduleID; self.instruction=instruction
    }
}

public struct MailSettings:Codable,Sendable {
    public var schemaVersion = 1
    public var revision = 0
    public var nativeAccounts:[NativeMailAccount] = []
    public var connections:[MailConnection] = []
    public var schedules:[MailSchedule] = []
    public var linkedScheduleIDs:[String] = []
    public var requests:[MailSettingsRequest] = []
    public var lastDotSync:Date?
    public var lastAccountsSync:Date?
    public var lastSchedulesSync:Date?
    /// When Dot confirmed that its Keep connected job renewing Mail Dot's subscriptions exists.
    public var keepConnectedConfirmedAt:Date?
    /// How many keep-connected requests in a row Dot has left unanswered.
    public var keepConnectedUnanswered:Int?
    public var source = "Waiting for Dot"
    /// The layout of the Mail Dot window, chosen in Settings (owner request, 13 November 2026). Absent means Briefing.
    public var windowLayout:MailDotWindowLayout?
    /// Whether pressing Send in the reply panel first asks the owner to confirm (owner request, 17 November 2026).
    /// Absent means yes, the default. With it off, the panel's Send sends at once; a send Dot drafted by voice still
    /// needs the owner's confirmation on the Mac.
    public var confirmBeforeSending:Bool?
    public var confirmsPanelSends:Bool { confirmBeforeSending ?? true }
    /// The owner's choice in Settings: mail of the accounts read on this Mac can also be found by its meaning, from
    /// embeddings made and kept on this Mac (15 November 2026). Absent or false means off, which is the default.
    public var searchByMeaning:Bool?
    /// The accounts in Mail for which the owner ticked Search by Meaning, by their identifiers in Mail (owner's
    /// request, 15 November 2026: one choice per account, in the row of the account). Absent means none, unless the
    /// single switch of build 170 was on, which then stands for every account until a row is ticked or unticked.
    public var searchByMeaningAccounts:[String]?
    public func searchByMeaning(account id:String) -> Bool {
        if let chosen=searchByMeaningAccounts { return chosen.contains(id) }
        return searchByMeaning == true
    }
    /// Whether it is on for any account: Mail Dot then looks whether it may read the Mail folder.
    public var searchByMeaningAnywhere:Bool { searchByMeaningAccounts.map{ !$0.isEmpty } ?? (searchByMeaning == true) }
    public mutating func setSearchByMeaning(_ on:Bool,account id:String) {
        var chosen=Set(searchByMeaningAccounts ?? (searchByMeaning == true ? nativeAccounts.map(\.id) : []))
        if on { chosen.insert(id) } else { chosen.remove(id) }
        searchByMeaningAccounts=chosen.sorted(); searchByMeaning=nil
    }
    /// The owner's choice, made in Mail: Dot writes draft replies on its own during its scheduled reviews,
    /// for important mail that needs a reply. Absent or false means it does not. Such a draft is only ever
    /// shown to the owner; nothing enters a message, and nothing is sent, without the owner's press.
    /// Build 82's single switch; no longer used, kept so that saved settings still load.
    public var automaticDrafts:Bool?
    public var automaticDraftsChangedAt:Date?
    /// The accounts on which the owner switched automatic replies off. Every other account has them on:
    /// the owner's default (12 November 2026).
    public var automaticRepliesOff:[String]?
    public func automaticReplies(account id:String) -> Bool { !(automaticRepliesOff ?? []).contains(id) }
    /// When Automatic replies last went on for each account. Only mail that arrives after it is offered to
    /// Dot for an automatic draft (the owner's rule, 12 November 2026): turning the switch on never reaches
    /// back to older mail.
    public var automaticRepliesSince:[String:Date]?
    public mutating func setAutomaticReplies(_ on:Bool,account id:String,now:Date=Date()) {
        var off=Set(automaticRepliesOff ?? [])
        var since=automaticRepliesSince ?? [:]
        if on { if off.contains(id) || since[id] == nil { since[id]=now }; off.remove(id) } else { off.insert(id); since[id]=nil }
        automaticRepliesOff=off.isEmpty ? nil : off.sorted()
        automaticRepliesSince=since.isEmpty ? nil : since
    }
    /// The accounts on which the owner switched Mail Dot off: Mail Dot leaves them alone. Their arriving
    /// mail is not checked, Dot is not given them to read or draft for, and their Automatic replies do
    /// nothing. Every other account has Mail Dot on (12 November 2026).
    public var mailDotOff:[String]?
    public func mailDot(account id:String) -> Bool { !(mailDotOff ?? []).contains(id) }
    /// Whether Mail Dot works on mail sent to these addresses: unless every account that receives it is off.
    public func mailDot(forRecipients addresses:[String]) -> Bool {
        let ids=accountIDs(receiving:addresses)
        return ids.isEmpty || ids.contains(where:mailDot(account:))
    }
    public mutating func setMailDot(_ on:Bool,account id:String,now:Date=Date()) {
        var off=Set(mailDotOff ?? [])
        let wasOff=off.contains(id)
        if on { off.remove(id) } else { off.insert(id) }
        mailDotOff=off.isEmpty ? nil : off.sorted()
        // Back on: Automatic replies count from now, so mail that came while it was off is never drafted.
        if on,wasOff,automaticReplies(account:id) { var since=automaticRepliesSince ?? [:]; since[id]=now; automaticRepliesSince=since }
    }
    /// Every account Mail Dot knows, by its account id.
    public var knownAccountIDs:[String] { connections.map(\.accountID)+nativeAccounts.map{"mail:"+$0.id} }
    /// Gives each account whose Automatic replies are on, by default and never switched, its starting time:
    /// now. Returns whether anything changed.
    @discardableResult public mutating func stampAutomaticReplies(now:Date=Date()) -> Bool {
        var since=automaticRepliesSince ?? [:]
        let missing=knownAccountIDs.filter{automaticReplies(account:$0) && since[$0] == nil}
        guard !missing.isEmpty else { return false }
        for id in missing { since[id]=now }
        automaticRepliesSince=since
        return true
    }
    /// From when mail sent to these addresses may be drafted automatically: the latest start among the
    /// accounts that receive it, or, when no known account receives it, the earliest start of any. Nil while
    /// no start is recorded.
    public func automaticRepliesStart(forRecipients addresses:[String]) -> Date? {
        let since=automaticRepliesSince ?? [:]
        let ids=accountIDs(receiving:addresses)
        if ids.isEmpty { return since.values.min() }
        let starts=ids.map{since[$0]}
        guard starts.allSatisfy({$0 != nil}) else { return nil }
        return starts.compactMap{$0}.max()
    }
    /// The owner's rules for how Dot drafts replies, edited in Mail Dot's settings. Absent until the owner
    /// first changes them; until then the starter rules are in force. See `DraftingRules`.
    public var draftingRules:[DraftingRule]?
    /// The owner's notes on how Dot writes to particular people, by their address in lower case (owner request,
    /// 14 November 2026): "formal Japanese", "keep it brief". They go to Dot with the drafting rules.
    public var senderNotes:[String:SenderNote]?
    /// Whether Dot answers on this Mac (see DotAccess). Absent in settings saved before it.
    public var dotAccess:DotAccess?
    /// The owner's names as messages write them, if the owner set them; otherwise they come from the
    /// accounts' registered names (effectiveOwnerNames).
    public var ownerNames:[String]?
    /// The Mac user's full name, recorded by the companion; the extension cannot ask for it itself.
    public var macUserFullName:String?
    /// The accounts, by Mail Dot's account id, that receive mail at each of these addresses.
    public func accountIDs(receiving addresses:[String]) -> Set<String> {
        let wanted=Set(addresses.map{$0.lowercased()})
        var ids=Set<String>()
        for connection in connections where wanted.contains(connection.email.lowercased()) { ids.insert(connection.accountID) }
        for account in nativeAccounts where account.addresses.contains(where:{wanted.contains($0.lowercased())}) { ids.insert("mail:"+account.id) }
        return ids
    }
    /// Whether Dot drafts automatically for a message sent to these addresses: on, unless an account that
    /// receives it has automatic replies switched off.
    public func automaticReplies(forRecipients addresses:[String]) -> Bool {
        accountIDs(receiving:addresses).allSatisfy{automaticReplies(account:$0) && mailDot(account:$0)}
    }
    public init() {}

    public func validate() throws {
        guard schemaVersion == 1, revision >= 0, nativeAccounts.count <= 100, connections.count <= 100,
              schedules.count <= 100, requests.count <= 30, linkedScheduleIDs.count <= 100 else { throw BridgeFailure("Mail settings exceed the prototype limits.") }
        if let rules=draftingRules {
            guard rules.count <= DraftingRules.limit,Set(rules.map(\.id)).count == rules.count,
                  rules.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 64 && !$0.text.isEmpty && $0.text.count <= DraftingRules.textLimit && !$0.text.contains("\n") }) else { throw BridgeFailure("Invalid drafting rules.") }
        }
        func ids(_ values:[String]) -> Bool { Set(values).count == values.count && values.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 } }
        guard ids(nativeAccounts.map(\.id)), ids(connections.map(\.id)), ids(schedules.map(\.id)), ids(requests.map(\.id)),ids(linkedScheduleIDs) else { throw BridgeFailure("Mail settings contain duplicate or invalid identifiers.") }
        for item in connections {
            guard !item.email.isEmpty, item.email.utf8.count <= 320, !item.connectionID.isEmpty, item.connectionID.utf8.count <= 512,
                  ["gmail","outlook","icloud"].contains(item.provider) else { throw BridgeFailure("Invalid connected email profile.") }
        }
        guard Set(connections.map { $0.provider + ":" + MailDraft.address($0.email) }).count == connections.count else { throw BridgeFailure("Conflicting profile IDs for the same email account require explicit reconciliation.") }
        for item in nativeAccounts {
            guard item.name.utf8.count <= 512, item.server.utf8.count <= 512, item.addresses.count <= 30,
                  item.addresses.allSatisfy({ $0.utf8.count <= 320 }) else { throw BridgeFailure("Invalid Mail account metadata.") }
        }
        for item in schedules {
            guard !item.title.isEmpty,item.title.utf8.count <= 512,item.accountEmails.count <= 30,
                  item.accountEmails.allSatisfy({ $0.utf8.count <= 320 }),item.conditions.utf8.count <= 16384,
                  item.cadence.utf8.count <= 2048,TimeZone(identifier:item.timeZone) != nil,
                  ["periodic","event"].contains(item.trigger) else { throw BridgeFailure("Invalid schedule metadata.") }
            guard item.sources.count <= 32,ids(item.sources.map { $0.kind + ":" + $0.id }),
                  item.sources.allSatisfy({ source in
                      ["gmail","outlook","mail","course","mailDotQueue"].contains(source.kind) && !source.id.isEmpty && source.id.utf8.count <= 512 && source.addresses.count <= 30 && source.addresses.allSatisfy { $0.utf8.count <= 320 } && (source.connectionID?.utf8.count ?? 0) <= 512 && (!["gmail","outlook"].contains(source.kind) || !(source.connectionID ?? "").isEmpty)
                  }) else { throw BridgeFailure("Invalid schedule source references.") }
        }
        guard requests.allSatisfy({ $0.instruction.utf8.count <= 16384 && ($0.question?.utf8.count ?? 0) <= 16384 && ($0.outcome?.utf8.count ?? 0) <= 16384 }) else { throw BridgeFailure("Settings request exceeds its limit.") }
        for request in requests {
            guard (request.input?.cadence?.utf8.count ?? 0) <= 2048,(request.input?.conditions?.utf8.count ?? 0) <= 16384,
                  (request.input?.nativeAccountID?.utf8.count ?? 0) <= 512,(request.form?.count ?? 0) <= 8,
                  (request.answers?.count ?? 0) <= 8,request.answers?.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= 4096 }) ?? true else { throw BridgeFailure("Setup form exceeds its limits.") }
            guard Set((request.form ?? []).map(\.id)).count == (request.form?.count ?? 0) else { throw BridgeFailure("Duplicate setup form fields.") }
            try request.form?.forEach { try $0.validate() }
            if let version=request.input?.nativeGrantVersion {
                guard version.utf8.count <= 36,UUID(uuidString:version) != nil else { throw BridgeFailure("Invalid native permission version.") }
            }
        }
    }
}

public enum MailSettingsCoordinator {
    /// The whole job, stated once here so that Dot receives it through the native settings channel
    /// and the owner never has to paste instructions.
    /// The job's title is the one setup gives it ("Mail Dot (<Mac account>) · Keep connected"); a job set up earlier by
    /// hand under the older title is reused, never duplicated.
    public static var keepConnectedInstruction:String { "Keep Mail Dot connected. Mail Dot needs one scheduled job that runs \(DotHandlers.keepConnectedSchedule). If a job titled \(DotHandlers.keepConnectedTitle()) or \(DotHandlers.legacyKeepConnectedTitle) already exists, reuse it under its own title, correct its schedule and instructions, and never create a second; otherwise create it with the title \(DotHandlers.keepConnectedTitle()). When it is set up, run it once now, so that Mail Dot sees it work; its schedule continues after. Its instructions are exactly: \(DotHandlers.keepConnectedPrompt) When renewing, subscribe with queue_id personal and ttlMs set to requested_lifetime_ms, reusing the existing handler for that event (Mail Dot · Configuration for mail.settings_requested, Mail Dot · Mail menu for mail.workflow_requested) and never creating a duplicate. When the job exists and is enabled, report confirmed/verified with empty connections and schedules. If you cannot create scheduled jobs in this run, report failed/capabilityUnavailable." }
    public static let keepConnectedRetry:TimeInterval = 6*3600

    /// True until Dot has confirmed the job, unless a request is already waiting or one failed recently.
    public static func needsKeepConnectedRequest(_ settings:MailSettings,now:Date = .now) -> Bool {
        guard settings.keepConnectedConfirmedAt == nil else { return false }
        let earlier=settings.requests.filter { $0.kind == .keepConnected }
        if earlier.contains(where:{ ![.confirmed,.failed].contains($0.status) }) { return false }
        // A refusal reported by Dot waits before the next attempt. A request Dot never answered does not.
        if let failed=earlier.filter({ $0.status == .failed && $0.resultCode != "noAnswer" }).map(\.createdAt).max(),now.timeIntervalSince(failed) < keepConnectedRetry { return false }
        // Unanswered requests back off (at once, then 1, 2, 4 and 8 hours) and stop after a fixed number,
        // so a Dot that never answers is not asked without end.
        let unanswered=settings.keepConnectedUnanswered ?? 0
        guard unanswered < keepConnectedMaximumUnanswered else { return false }
        if unanswered >= 2,let last=earlier.filter({ $0.resultCode == "noAnswer" }).map(\.createdAt).max(),
           now.timeIntervalSince(last) < keepConnectedAnswerLimit + 3600*pow(2,Double(unanswered-2)) { return false }
        return true
    }
    public static let keepConnectedMaximumUnanswered = 6
    /// The cycle has stopped: Dot left the maximum number of requests unanswered.
    public static func keepConnectedStopped(_ settings:MailSettings) -> Bool {
        settings.keepConnectedConfirmedAt == nil && (settings.keepConnectedUnanswered ?? 0) >= keepConnectedMaximumUnanswered
    }
    /// The owner asks to try again after the cycle stopped.
    public static func retryKeepConnected(settings:inout MailSettings) {
        settings.keepConnectedUnanswered=0; settings.revision += 1
    }
    /// A confirmation with no supporting check for this long is treated as void.
    public static let keepConnectedEvidenceLimit:TimeInterval = 26*3600
    public static let keepConnectedAnswerLimit:TimeInterval = 3600
    /// Closes a keep-connected request that can no longer succeed: its delivery gave up, or Dot has not
    /// answered within the limit. Without this, one lost request would block renewal for good.
    @discardableResult public static func expireUnansweredKeepConnected(settings:inout MailSettings,now:Date = .now) -> Bool {
        var changed=false
        for index in settings.requests.indices where settings.requests[index].kind == .keepConnected && ![.confirmed,.failed].contains(settings.requests[index].status) {
            let request=settings.requests[index]
            guard request.event.attempts >= 8 || now.timeIntervalSince(request.createdAt) > keepConnectedAnswerLimit else { continue }
            settings.requests[index].status = .failed; settings.requests[index].resultCode="noAnswer"
            settings.requests[index].outcome="Dot did not answer. Mail Dot will ask again."
            settings.keepConnectedUnanswered=(settings.keepConnectedUnanswered ?? 0)+1
            changed=true
        }
        if changed { settings.revision += 1 }
        return changed
    }
    @discardableResult public static func ensureKeepConnected(settings:inout MailSettings,lastStatusCheck:Date? = nil,now:Date = .now) throws -> Bool {
        var expired=expireUnansweredKeepConnected(settings:&settings,now:now)
        // Dot's report that the job exists is a claim. If no check by Dot has reached this Mac for more
        // than a day since, the job is presumed gone and is requested again.
        if let confirmed=settings.keepConnectedConfirmedAt,now.timeIntervalSince(confirmed) > keepConnectedEvidenceLimit,
           now.timeIntervalSince(lastStatusCheck ?? confirmed) > keepConnectedEvidenceLimit {
            settings.keepConnectedConfirmedAt=nil; settings.keepConnectedUnanswered=0; settings.revision += 1; expired=true
        }
        guard needsKeepConnectedRequest(settings,now:now) else { return expired }
        try request(.keepConnected,instruction:keepConnectedInstruction,settings:&settings)
        return true
    }

    @discardableResult public static func request(_ kind:MailSettingsRequestKind,email:String? = nil,scheduleID:String? = nil,instruction:String,input:MailSettingsInput?=nil,settings:inout MailSettings) throws -> MailSettingsRequest {
        guard !instruction.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, instruction.utf8.count <= 16384 else { throw BridgeFailure("Describe the account or schedule request.") }
        if kind == .activate || kind == .nativeLink {
            guard let email,!email.isEmpty,email.utf8.count <= 320 else { throw BridgeFailure("Select the intended email account.") }
        }
        if kind == .linkSchedule || kind == .changeSchedule {
            guard let scheduleID,settings.schedules.contains(where:{ $0.id == scheduleID && $0.available }) else { throw BridgeFailure("Refresh the existing schedule before changing it. It is absent from the latest inventory.") }
            guard !settings.hasUnresolvedScheduleRequest(scheduleID) else { throw BridgeFailure("Wait for this schedule's current configuration request to finish before submitting another change.") }
        }
        var updated = settings
        if updated.requests.count >= 25 { updated.requests.removeAll { [.confirmed,.failed].contains($0.status) } }
        guard updated.requests.count < 30 else { throw BridgeFailure("Resolve outstanding settings requests first.") }
        var request = MailSettingsRequest(kind:kind,email:email,scheduleID:scheduleID,instruction:instruction)
        request.input=input ?? MailSettingsInput()
        if kind == .refresh {
            request.input?.completeInventory=true
            if request.input?.inventoryScope == nil { request.input?.inventoryScope = .all }
        }
        if kind == .nativeLink,let email {
            let accounts=settings.nativeAccounts.filter { $0.addresses.map(MailDraft.address).contains(MailDraft.address(email)) }
            if let selected=request.input?.nativeAccountID {
                guard accounts.contains(where:{$0.id == selected}) else { throw BridgeFailure("The native account does not match the displayed email address.") }
            } else if accounts.count == 1 { request.input?.nativeAccountID=accounts[0].id }
        }
        if kind == .activate,let email { request.expectedProfileID=settings.connections.first(where:{ MailConnection.connectorProviders.contains($0.provider) && MailDraft.address($0.email) == MailDraft.address(email) })?.id }
        updated.requests.append(request); updated.revision += 1
        try updated.validate(); settings = updated
        return request
    }

    public static func answer(requestID:String,form:[MailSettingsFormField],answers:[String:String],settings:inout MailSettings) throws {
        guard let index=settings.requests.firstIndex(where:{ $0.id == requestID }),settings.requests[index].status == .question,
              settings.requests[index].form == form,!form.isEmpty,Set(answers.keys).isSubset(of:Set(form.map(\.id))) else { throw BridgeFailure("The setup form changed. Review its current fields.") }
        for field in form {
            try field.validate()
            let value=(answers[field.id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard value.utf8.count <= 4096,(!field.required || !value.isEmpty),
                  field.kind == "text" || value.isEmpty || field.options.contains(value) else { throw BridgeFailure("Complete the required setup fields using the available choices.") }
        }
        var updated=settings
        updated.requests[index].answers=answers; updated.requests[index].status = .pending
        updated.requests[index].question=nil; updated.requests[index].outcome=nil; updated.requests[index].resultCode=nil
        updated.requests[index].event=BridgeEvent(); updated.revision += 1
        try updated.validate(); settings=updated
    }

    public static func report(requestID:String,expectedRevision:Int,connections:[MailConnection],schedules:[MailSchedule],outcome:String,nativeGrant:NativeMailGrant?=nil,settings:inout MailSettings) throws {
        guard settings.revision == expectedRevision,let index = settings.requests.firstIndex(where:{ $0.id == requestID }),
              ![.confirmed,.failed].contains(settings.requests[index].status) else { throw BridgeFailure("Settings request changed. Read the current configuration first.") }
        let request = settings.requests[index]
        let scope=request.input?.inventoryScope ?? .all
        if request.kind == .refresh {
            guard (scope != .accounts || schedules.isEmpty),(scope != .schedules || connections.isEmpty) else { throw BridgeFailure("Return only the account or schedule inventory requested by this settings page.") }
        }
        if request.kind == .nativeLink {
            guard connections.isEmpty,schedules.isEmpty,let nativeGrant,nativeGrant.revokedAt == nil,
                  nativeGrant.accountID == request.input?.nativeAccountID,nativeGrant.version == request.input?.nativeGrantVersion,
                  let verified=nativeGrant.verifiedAt,verified >= max(request.createdAt,request.input?.verificationRequestedAt ?? request.createdAt) else { throw BridgeFailure("Native setup needs the owner's matching account/folder permission and a fresh successful mailbox probe. Dot cannot grant access.") }
            var native=NativeMailState(); native.grants=[nativeGrant]; try native.validate()
        }
        if request.kind == .keepConnected {
            guard connections.isEmpty,schedules.isEmpty else { throw BridgeFailure("Confirming the connection job must not carry account or schedule inventory.") }
        }
        // iCloud's connector shows Dot the signed-in address but no stable profile or connection id, so Dot confirms it
        // without a profile and Mail Dot records the connection for the address asked about (15 November 2026).
        var connections=connections
        if request.kind == .activate,request.input?.provider == "icloud",let email=request.email {
            guard schedules.isEmpty,connections.allSatisfy({ $0.provider == "icloud" && MailDraft.address($0.email) == MailDraft.address(email) }) else {
                throw BridgeFailure("Confirm only the iCloud Mail connection for the address asked about.")
            }
            if connections.isEmpty {
                var made=MailConnection(id:"icloud-"+MailDraft.address(email),email:email,connectionID:"icloud-connector")
                made.provider="icloud"
                connections=[made]
            }
        } else if request.kind == .activate {
            guard schedules.isEmpty,connections.count == 1,let email=request.email,connections.contains(where:{ MailDraft.address($0.email) == MailDraft.address(email) && $0.available && MailConnection.connectorProviders.contains($0.provider) }) else { throw BridgeFailure("Return only the authenticated Gmail profile matching the requested email account.") }
            if let expected=request.expectedProfileID { guard connections[0].id == expected else { throw BridgeFailure("Reconnection must preserve the account's stable provider profile ID.") } }
        }
        for profile in connections {
            guard !settings.connections.contains(where:{ ($0.id == profile.id && ($0.provider != profile.provider || MailDraft.address($0.email) != MailDraft.address(profile.email))) || ($0.provider == profile.provider && MailDraft.address($0.email) == MailDraft.address(profile.email) && $0.id != profile.id) }) else { throw BridgeFailure("Profile identity conflicts with the existing account. Ask the owner to reconcile it explicitly.") }
        }
        if request.kind == .linkSchedule || request.kind == .changeSchedule {
            guard schedules.count == 1, let target=schedules.first,target.id == request.scheduleID,connections.isEmpty else { throw BridgeFailure("Readback must refer only to the requested existing schedule.") }
            guard let original=settings.schedules.first(where:{ $0.id == target.id }),
                  Set(original.accountEmails.map(MailDraft.address)) == Set(target.accountEmails.map(MailDraft.address)),
                  original.trigger == target.trigger,original.timeZone == target.timeZone,
                  !original.sources.isEmpty,original.sources.sorted(by:{$0.id < $1.id}) == target.sources.sorted(by:{$0.id < $1.id}) else { throw BridgeFailure("Preserve the existing account scope, source connection, trigger type and timezone. Refresh actual source references before changing a schedule.") }
            if request.kind == .linkSchedule {
                let title=original.title.hasPrefix("Mail Dot · ") ? original.title : "Mail Dot · " + original.title
                guard target.title == title,target.cadence == original.cadence,target.conditions == original.conditions,target.enabled == original.enabled else { throw BridgeFailure("Linking changes only the existing schedule's title prefix; preserve coverage and conditions.") }
            }
        }
        var updated=settings
        var report=MailSettings(); report.connections=connections; report.schedules=schedules; try report.validate()
        if request.kind == .refresh {
            if scope != .schedules { for i in updated.connections.indices { updated.connections[i].available = false } }
            if scope != .accounts { for i in updated.schedules.indices { updated.schedules[i].available = false; updated.schedules[i].nextRunAt=nil } }
        }
        for var profile in connections {
            profile.observedAt = .now
            updated.connections.removeAll { $0.id == profile.id }; updated.connections.append(profile)
        }
        for var schedule in schedules {
            if let old=updated.schedules.first(where:{ $0.id == schedule.id }) {
                schedule.lastSuccessAt=[old.lastSuccessAt,schedule.lastSuccessAt].compactMap { $0 }.max()
                schedule.lastAttemptAt=[old.lastAttemptAt,schedule.lastAttemptAt].compactMap { $0 }.max()
            }
            schedule.available=true
            schedule.observedAt = .now
            updated.schedules.removeAll { $0.id == schedule.id }; updated.schedules.append(schedule)
        }
        if request.kind == .linkSchedule,let id=request.scheduleID,!updated.linkedScheduleIDs.contains(id) { updated.linkedScheduleIDs.append(id) }
        updated.requests[index].status = .confirmed; updated.requests[index].outcome = outcome
        updated.requests[index].resultCode="verified"; updated.requests[index].form=nil
        updated.requests[index].question = nil; updated.requests[index].event.reviewedAt = .now
        updated.lastDotSync = .now; updated.source = "Dot-reported readback"; updated.revision += 1
        if request.kind == .keepConnected { updated.keepConnectedConfirmedAt = .now; updated.keepConnectedUnanswered = 0 }
        if request.kind == .activate || (request.kind == .refresh && scope != .schedules) { updated.lastAccountsSync = .now }
        if [.linkSchedule,.changeSchedule].contains(request.kind) || (request.kind == .refresh && scope != .accounts) { updated.lastSchedulesSync = .now }
        try updated.validate(); settings=updated
    }
}

/// The three layouts of the Mail Dot window opened from a message's banner.
public enum MailDotWindowLayout:String,Codable,Sendable,CaseIterable {
    /// One column; what needs the owner comes first. The default.
    case briefing
    /// The thread as a timeline, ending at the owner's next step.
    case storyline
    /// Two panes in a wider window; each decision is a row.
    case ledger
}

/// How Dot is to write to one correspondent: the owner's notes, each one instruction (owner decision, 14 November 2026:
/// several entries like the drafting rules, each edited or deleted on its own, and polished by Dot).
public struct SenderNote:Codable,Sendable,Equatable {
    public struct Item:Codable,Sendable,Equatable,Identifiable {
        public var id:String
        public var text:String
        /// Waiting for Dot's polish; the owner's words stand, and are used, until Dot's replace them.
        public var polishing:Bool?
        public init(id:String=UUID().uuidString,text:String,polishing:Bool?=nil) { self.id=id; self.text=text; self.polishing=polishing }
    }
    public var items:[Item]
    /// The correspondent's name, for showing the notes.
    public var name:String?
    /// When the notes waiting for polish were sent to Dot; nil while none are out.
    public var polishAskedAt:Date?
    public init(items:[Item],name:String?) { self.items=items; self.name=name }
    /// One note's length (raised from 300, owner's OK, 16 November 2026).
    public static let textLimit=600
    /// People with notes, and notes for one person.
    public static let limit=100
    public static let perPerson=10
    /// Notes saved before 14 November 2026 were one text each: it becomes the first entry.
    private enum CodingKeys:String,CodingKey { case items,text,name,polishAskedAt }
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        let legacy=try values.decodeIfPresent(String.self,forKey:.text)
        items=try values.decodeIfPresent([Item].self,forKey:.items) ?? legacy.map{ [Item(id:"legacy",text:$0)] } ?? []
        name=try values.decodeIfPresent(String.self,forKey:.name)
        polishAskedAt=try values.decodeIfPresent(Date.self,forKey:.polishAskedAt)
    }
    public func encode(to encoder:Encoder) throws {
        var values=encoder.container(keyedBy:CodingKeys.self)
        try values.encode(items,forKey:.items)
        try values.encodeIfPresent(name,forKey:.name)
        try values.encodeIfPresent(polishAskedAt,forKey:.polishAskedAt)
    }
    public var waitingForPolish:[Item] { items.filter{ $0.polishing == true } }
}
extension MailSettings {
    /// The people with notes, in a steady order: by name, then address.
    public var senderNoteList:[(address:String,note:SenderNote)] {
        (senderNotes ?? [:]).filter{ !$0.value.items.isEmpty }.map{($0.key,$0.value)}.sorted{ ($0.note.name ?? $0.address).localizedCaseInsensitiveCompare($1.note.name ?? $1.address) == .orderedAscending }
    }
    public func senderNote(for address:String) -> SenderNote? { senderNotes?[SenderNotes.key(address)] }
    /// A new note for this person, waiting for Dot's polish.
    public mutating func addSenderNote(_ text:String,for address:String,name:String?) throws {
        let key=try SenderNotes.checkedKey(address)
        let words=try SenderNotes.cleaned(text)
        var notes=senderNotes ?? [:]
        var note=notes[key] ?? SenderNote(items:[],name:name)
        guard notes[key] != nil || notes.count < SenderNote.limit else { throw BridgeFailure("Mail Dot keeps notes for at most \(SenderNote.limit) people. Remove some first.") }
        guard note.items.count < SenderNote.perPerson else { throw BridgeFailure("Mail Dot keeps at most \(SenderNote.perPerson) notes for one person. Delete one first.") }
        note.items.append(.init(text:words,polishing:true)); note.name=name ?? note.name
        notes[key]=note; senderNotes=notes
    }
    public mutating func updateSenderNote(_ id:String,text:String,for address:String) throws {
        let key=SenderNotes.key(address)
        let words=try SenderNotes.cleaned(text)
        guard var note=senderNotes?[key],let index=note.items.firstIndex(where:{$0.id == id}) else { throw BridgeFailure("That note is no longer listed.") }
        guard note.items[index].text != words else { return }
        note.items[index].text=words; note.items[index].polishing=true
        senderNotes?[key]=note
    }
    public mutating func removeSenderNote(_ id:String,for address:String) {
        let key=SenderNotes.key(address)
        guard var note=senderNotes?[key] else { return }
        note.items.removeAll{$0.id == id}
        if note.items.isEmpty { senderNotes?.removeValue(forKey:key) } else { senderNotes?[key]=note }
        if senderNotes?.isEmpty == true { senderNotes=nil }
    }
    /// The notes for this person went to Dot to polish.
    public mutating func markNotesPolishAsked(for address:String,now:Date=Date()) { senderNotes?[SenderNotes.key(address)]?.polishAskedAt=now }
    /// Dot's polished wording replaces the owner's for each note still waiting; anything else (a refusal, a failure, an
    /// answer that cannot be read) leaves the owner's words. Either way the notes stop waiting.
    public mutating func applyPolishedNotes(for address:String,answer:String?) {
        let key=SenderNotes.key(address)
        guard var note=senderNotes?[key] else { return }
        let polished=answer.map(SenderNotes.parse) ?? [:]
        for index in note.items.indices where note.items[index].polishing == true {
            if let text=polished[note.items[index].id],let clean=try? SenderNotes.cleaned(text) { note.items[index].text=clean }
            note.items[index].polishing=nil
        }
        note.polishAskedAt=nil
        senderNotes?[key]=note
    }
    /// Notes Dot did not polish within the answer limit keep the owner's words.
    @discardableResult public mutating func expireNotePolish(now:Date=Date()) -> Int {
        var count=0
        for (key,note) in senderNotes ?? [:] where note.polishAskedAt.map({ now.timeIntervalSince($0) > MailTriageState.answerLimit }) == true {
            applyPolishedNotes(for:key,answer:nil); count += 1
        }
        return count
    }
    /// The notes for the people a draft is written to, as Dot is told them, or nil when there are none. Only those
    /// people's notes go with a request (owner decision, 14 November 2026), never everyone's.
    public func senderNotesInstruction(for addresses:[String]) -> String? {
        let wanted=Set(addresses.map(SenderNotes.key))
        let list=senderNoteList.filter{ wanted.contains($0.address) }
        guard !list.isEmpty else { return nil }
        return "The owner's notes on writing to particular people; apply each to every reply you draft to that address: "
            + list.map{ "\($0.address): \($0.note.items.map{ $0.text.replacingOccurrences(of:"\n",with:" ") }.joined(separator:" / "))" }.joined(separator:"; ")+"."
    }
}

public enum SenderNotes {
    /// The bare address, lowercased; a display name ("Name <address>") is dropped.
    public static func key(_ address:String) -> String {
        var value=address
        if let open=value.lastIndex(of:"<"),let close=value.lastIndex(of:">"),open < close { value=String(value[value.index(after:open)..<close]) }
        return value.trimmingCharacters(in:.whitespaces).lowercased()
    }
    static func checkedKey(_ address:String) throws -> String {
        let value=key(address)
        guard value.contains("@") else { throw BridgeFailure("That sender has no address to keep notes for.") }
        return value
    }
    /// One line, trimmed; throws if empty or too long.
    public static func cleaned(_ text:String) throws -> String {
        let line=text.components(separatedBy:.newlines).map{ $0.trimmingCharacters(in:.whitespaces) }.filter{ !$0.isEmpty }.joined(separator:" ")
        guard !line.isEmpty,line.count <= SenderNote.textLimit else { throw BridgeFailure("Write a note of at most \(SenderNote.textLimit) characters.") }
        return line
    }
    /// Dot's answer: a JSON array of {"id","text"}, found anywhere in its summary.
    static func parse(_ answer:String) -> [String:String] {
        guard let start=answer.firstIndex(of:"["),let end=answer.lastIndex(of:"]"),start < end,
              let items=try? JSONSerialization.jsonObject(with:Data(answer[start...end].utf8)) as? [[String:Any]] else { return [:] }
        var result:[String:String]=[:]
        for item in items { if let id=item["id"] as? String,let text=item["text"] as? String { result[id]=text } }
        return result
    }
    public static let polishInstructions="For action noteCleanup, person gives a correspondent's address and name, and notes lists the owner's notes, typed on their Mac, on how you should write to that person, each with id and text. Rewrite each note as one clear, concise drafting instruction that keeps exactly the owner's meaning, in the language they typed it, stated as the owner would state it (for example: Address him as Dr. Hartman). Correct spelling and grammar; add nothing they did not say; do not merge, split or drop notes. Report this request ready with summary set to a JSON array alone, one object per note with its id unchanged: [{\"id\":\"…\",\"text\":\"…\"}], each text at most 300 characters. If person.available is false, report failed."
}
