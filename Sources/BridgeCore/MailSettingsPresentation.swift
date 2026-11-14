import Foundation

extension MailSettings {
    public func showsNativeAccessManagement(for account:NativeMailAccount,grants:[NativeMailGrant]) -> Bool {
        grants.contains { $0.accountID == account.id && $0.revokedAt == nil }
    }
    /// The newest result supersedes older attempts for the same control.
    /// Completed work remains in private history rather than cluttering settings.
    public func configurationRequests(for page:MailInventoryScope) -> [MailSettingsRequest] {
        var seen=Set<String>()
        return requests.reversed().filter { request in
            let key:String
            switch request.kind {
            case .refresh:
                let scope=request.input?.inventoryScope ?? .all
                guard page == .all || scope == .all || scope == page else { return false }
                key="refresh"
            case .activate:
                guard page != .schedules else { return false }
                key="activate:" + MailDraft.address(request.email ?? "")
            case .nativeLink:
                guard page != .schedules,let version=request.input?.nativeGrantVersion else { return false }
                key="native:" + (request.input?.nativeAccountID ?? "")
                guard nativeAccounts.contains(where:{$0.id == request.input?.nativeAccountID}),!version.isEmpty else { return false }
            case .keepConnected,.unknown:
                // Shown on the Connection page, not among account or schedule requests.
                return false
            case .linkSchedule,.changeSchedule:
                guard page != .accounts else { return false }
                key="schedule:" + (request.scheduleID ?? "")
            }
            guard seen.insert(key).inserted else { return false }
            return request.status != .confirmed
        }
    }

    public func hasUnresolvedScheduleRequest(_ scheduleID:String) -> Bool {
        requests.contains { request in
            [.linkSchedule,.changeSchedule].contains(request.kind) && request.scheduleID == scheduleID &&
                ![.confirmed,.failed].contains(request.status)
        }
    }
}
