import Foundation

enum MailSettingsTools {
    static func call(_ name:String,arguments:[String:JSONValue],store:MailSettingsStore) throws -> JSONValue {
        if name == "get_mail_settings" {
            let native=try NativeMailStore(bridgeDirectory:store.directory.deletingLastPathComponent()).read()
            return ["protocol_version":1,"settings":try .encode(store.read()),"native_access":try NativeMailTools.status(native),"response_contract":["transport":"report_mail_settings","presentation":"native_settings_controls","request_fields":["id","kind","email","scheduleID","expectedProfileID","input","answers"],"instruction":"Handle typed request kind, target and input. For keepConnected, follow the request's instruction to create or reuse the single Keep connected job for Mail Dot, which runs every six hours, then report confirmed/verified with empty connections and schedules, or failed/capabilityUnavailable. For refresh honor input.inventoryScope: accounts returns only current authenticated connector profiles; schedules returns only schedule inventory; all returns both. Complete inventory means membership in that collection. Unknown optional times must not block account verification. NativeLink with input.nativeGrantVersion refers to a native owner-granted folder scope; call native_mail_list_mailboxes for that account to verify it, then report confirmed with empty connections/schedules. Do not read messages for setup. No native grant means access is not authorized. Return enumerated stage/result_code, typed data or native form fields. Never send the owner to Dot/chat or ask them to repeat prompts. Provider/system consent stays native."],"note":"Native metadata and explicit owner requests. Imported snapshots are not live confirmation. No mailbox permission or email-send permission is granted by this tool."]
        }
        guard let requestID=arguments["request_id"]?.string,let revision=arguments["expected_revision"]?.integer,
              let outcome=arguments["outcome"]?.string,!outcome.isEmpty,outcome.utf8.count <= 1024,
              let code=arguments["result_code"]?.string else { throw BridgeFailure("A current native settings request and structured result are required.") }
        let stage=arguments["stage"]?.string ?? "confirmed"
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profiles=try decoder.decode([MailConnection].self,from:Data((try (arguments["connections"] ?? []).text()).utf8))
        let schedules=try decoder.decode([MailSchedule].self,from:Data((try (arguments["schedules"] ?? []).text()).utf8))
        let form=try decoder.decode([MailSettingsFormField].self,from:Data((try (arguments["form"] ?? []).text()).utf8))
        let validCodes=["confirmed":["verified"],"question":["needsOwnerInput"],"awaitingAuthorization":["needsGoogleConsent"],"failed":["capabilityUnavailable","failed"]]
        guard validCodes[stage]?.contains(code) == true,(stage == "question" ? !form.isEmpty : form.isEmpty) else { throw BridgeFailure("Return the result code and native form appropriate to the response stage.") }
        try store.transaction { settings in
            if stage == "confirmed" {
                var nativeGrant:NativeMailGrant?
                if let request=settings.requests.first(where:{$0.id == requestID}),request.kind == .nativeLink,let account=request.input?.nativeAccountID {
                    nativeGrant=try NativeMailStore(bridgeDirectory:store.directory.deletingLastPathComponent()).read().grants.first(where:{$0.accountID == account})
                }
                try MailSettingsCoordinator.report(requestID:requestID,expectedRevision:revision,connections:profiles,schedules:schedules,outcome:outcome,nativeGrant:nativeGrant,settings:&settings)
            } else {
                guard profiles.isEmpty,schedules.isEmpty,settings.revision == revision,
                      let index=settings.requests.firstIndex(where:{ $0.id == requestID }),
                      ![.confirmed,.failed].contains(settings.requests[index].status),
                      ["question","awaitingAuthorization","failed"].contains(stage),
                      let status=MailSettingsRequestStatus(rawValue:stage) else { throw BridgeFailure("Invalid or stale settings progress report.") }
                guard stage != "awaitingAuthorization" || settings.requests[index].kind == .activate else { throw BridgeFailure("Google authorization applies only to Gmail activation.") }
                settings.requests[index].status=status; settings.requests[index].question=nil
                settings.requests[index].resultCode=code; settings.requests[index].form=form; settings.requests[index].answers=nil
                settings.requests[index].outcome=outcome; settings.requests[index].event.reviewedAt = .now
                settings.revision += 1
            }
        }
        return ["saved":true,"request_id":.string(requestID),"revision":.number(Double(try store.read().revision))]
    }

    static let catalog:[JSONValue] = {
        let string:JSONValue=["type":"string"]
        let formField:JSONValue=["type":"object","properties":["id":string,"label":string,"kind":["type":"string","enum":["text","selection","confirmation"]],"options":["type":"array","maxItems":8,"items":string],"required":["type":"boolean"]],"required":["id","label","kind","options","required"],"additionalProperties":false]
        let profile:JSONValue=["type":"object","properties":["id":string,"email":string,"connectionID":string,"provider":["type":"string","enum":["gmail","outlook","icloud"]],"available":["type":"boolean"]],"required":["id","email","connectionID","provider","available"],"additionalProperties":false]
        let source:JSONValue=["type":"object","properties":["kind":["type":"string","enum":["gmail","outlook","mail","course","mailDotQueue"]],"id":string,"addresses":["type":"array","maxItems":30,"items":string],"connectionID":string],"required":["kind","id","addresses"],"additionalProperties":false]
        let schedule:JSONValue=["type":"object","properties":["id":string,"title":string,"accountEmails":["type":"array","items":string],"sources":["type":"array","maxItems":32,"items":source],"cadence":string,"conditions":string,"trigger":["type":"string","enum":["periodic","event"]],"timeZone":string,"enabled":["type":"boolean"],"nextRunAt":string,"lastAttemptAt":string,"lastSuccessAt":string,"outcome":string],"required":["id","title","accountEmails","sources","cadence","conditions","trigger","timeZone","enabled"],"additionalProperties":false]
        func tool(_ name:String,_ description:String,_ properties:[String:JSONValue],_ required:[String],readOnly:Bool)->JSONValue {
            ["name":.string(name),"description":.string(description),"inputSchema":["type":"object","properties":.object(properties),"required":.array(required.map(JSONValue.string)),"additionalProperties":false],"annotations":["readOnlyHint":.bool(readOnly),"destructiveHint":false,"openWorldHint":false,"idempotentHint":.bool(readOnly)]]
        }
        return [
            tool("get_mail_settings","Read Mail Dot's accounts, canonical schedule IDs, cached Dot-reported settings and explicit native owner requests. This reads no mailbox bodies and grants no account access. Use the real connector profile tools and ChatGPT schedule tools to reread actual state; preserve source routes and unrelated jobs. For a confirmed refresh provide a COMPLETE email schedule/profile inventory: missing items become unavailable. If full readback is unavailable, report a question/failure. Schedule sources use kind plus stable profile/native-account/course ID (personal for mailDotQueue), addresses including aliases, and current connectionID for Gmail/Outlook. Reconnection preserves stable profile ID.",[:],[],readOnly:true),
            tool("report_mail_settings","Return structured setup results for an explicit native owner request. First read get_mail_settings. stage/result_code pairs: confirmed/verified; question/needsOwnerInput with form fields; awaitingAuthorization/needsGoogleConsent; failed/capabilityUnavailable or failed. Native controls render forms; do not send the owner to Dot/chat or ask them to repeat requests. form text fields have empty options; selection has bounded choices; confirmation uses options yes,no. outcome is a brief display label (max1024 bytes), not a chat response. Confirm only actual profile/schedule readback with stable IDs and preserved sources. Activation returns only matching Gmail profile; schedule changes only the requested existing job. ISO8601 times omitted if unknown. No mailbox permission or sending is granted.",["request_id":string,"expected_revision":["type":"integer","minimum":0],"stage":["type":"string","enum":["confirmed","question","awaitingAuthorization","failed"]],"result_code":["type":"string","enum":["verified","needsOwnerInput","needsGoogleConsent","capabilityUnavailable","failed"]],"form":["type":"array","maxItems":8,"items":formField],"connections":["type":"array","maxItems":100,"items":profile],"schedules":["type":"array","maxItems":100,"items":schedule],"outcome":string],["request_id","expected_revision","stage","result_code","connections","schedules","outcome"],readOnly:false)
        ]
    }()
    static let eventDefinition:JSONValue=["name":"mail.settings_requested","description":"The owner requested account/schedule reconciliation or a change in native Mail Dot settings. Read the request and current revision with get_mail_settings. Facts only; unrelated mailbox and send actions are not authorized.","delivery":["webhook"],"inputSchema":["type":"object","properties":["queue_id":["type":"string","enum":["personal"]]],"required":["queue_id"],"additionalProperties":false],"payloadSchema":["type":"object","properties":["request_id":["type":"string"],"configuration_revision":["type":"integer"]],"required":["request_id","configuration_revision"],"additionalProperties":false]]
}
