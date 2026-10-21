import Foundation

nonisolated struct LocalSharingStatus: Equatable, Sendable {
    enum Availability: Sendable { case checking, enabled, disabled, unknown }
    enum AccountAccess: Sendable { case allowed, denied, unrestricted, unknown }
    var availability: Availability = .checking
    var account: AccountAccess = .unknown
    var responding = false

    var title: String {
        switch availability {
        case .checking: "正在检测"
        case .disabled: "未开启"
        case .unknown: "无法确认"
        case .enabled: account == .denied ? "需要授权" : "已开启"
        }
    }
    var detail: String {
        switch availability {
        case .checking: return "正在读取本机服务与账户访问状态。"
        case .disabled: return "请在系统共享设置中开启，并允许当前账户访问。"
        case .unknown: return "系统状态读取受限或服务未响应，请在共享设置中确认。"
        case .enabled: break
        }
        if account == .denied { return "服务已开启，当前账户不在系统允许访问列表中。" }
        let access: String
        switch account {
        case .allowed: access = "系统访问列表已允许当前账户。"
        case .unrestricted: access = "系统未设置单独的账户访问限制。"
        case .unknown: access = "当前账户的访问权限仍需在共享设置中确认。"
        case .denied: access = ""
        }
        return (responding ? "已检测到本机服务响应。" : "系统已开启，服务响应尚未确认。") + access
    }

    static func resolve(configured: Bool?, responding: Bool, account: AccountAccess) -> Self {
        // A valid protocol greeting proves a service responds; a failed connection does not prove it is disabled.
        let availability: Availability = responding || configured == true ? .enabled : (configured == false ? .disabled : .unknown)
        return Self(availability: availability, account: account, responding: responding)
    }
}

nonisolated struct LocalSharingSnapshot: Sendable {
    var ssh = LocalSharingStatus()
    var screenSharing = LocalSharingStatus()
}
