// SensitiveApps.swift — 敏感应用过滤（隐私设计共识的落地）。
//
// 来自密码管理器等敏感应用的拷贝不进历史（防止密码留在剪贴板历史里）。
// 过滤名单默认含 1Password / Bitwarden / KeePassXC / 钥匙串访问，
// 用户可在设置里编辑（AppSettings 持久化）。
//
// 匹配语义：大小写不敏感 + 首尾空白剔除；条目既匹配 bundleID 也匹配
// 显示名——bundleID 精确但普通用户不会填，显示名好填但有重名风险，
// 两条路都通才覆盖"自己输 1Password"和"自己输 com.1password..."两类输入。

import Foundation

/// 敏感应用名单及其匹配逻辑（值类型，Sendable，可在任意线程使用）。
struct SensitiveAppsFilter: Sendable {
    /// 归一化后的名单（已小写化、去首尾空白、去空串）。
    let entries: Set<String>

    /// 从原始名单构建；归一化在构建期一次完成，匹配期零成本。
    init(entries: [String]) {
        self.entries = Set(entries.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// 默认名单（设计共识）：主流密码管理器 + 系统钥匙串。
    static let defaults = ["1Password", "Bitwarden", "KeePassXC", "Keychain Access"]

    /// 判断某来源应用是否命中敏感名单。
    ///
    /// - Parameter app: 来源归因；nil（未知来源）不算敏感——无法归因时
    ///   宁可记录也不误伤（密码管理器场景总有可归因的前台应用）。
    /// - Returns: bundleID 或显示名任一命中即 true。
    func isSensitive(_ app: AppSource?) -> Bool {
        guard let app else { return false }
        if let bundleID = app.bundleID?.lowercased(), entries.contains(bundleID) { return true }
        if let name = app.name?.lowercased(), entries.contains(name) { return true }
        return false
    }
}
