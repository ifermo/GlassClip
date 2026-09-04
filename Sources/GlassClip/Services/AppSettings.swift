// AppSettings.swift — 用户偏好层：UserDefaults 持久化的 @Published 属性。
//
// 模式：每个偏好一个 @Published 属性 + didSet 写回 UserDefaults——
// UI 绑定（SwiftUI 读写）与持久化在同一个点上完成，无需手动 save。
// 初始化时读库给默认值；读不到（首次启动）落回设计共识的默认值。
//
// 启动登录是例外：SMAppService 的状态是系统事实而非本地偏好，
// 用计算属性实时查询（见 launchAtLogin）。

import Foundation
import ServiceManagement
import SwiftUI

/// 全局设置（进程级单例，设置页与数据层共用同一实例）。
@MainActor
final class AppSettings: ObservableObject {
    /// 共享实例。HistoryController 默认注入它；测试可传入独立实例。
    static let shared = AppSettings()

    /// UserDefaults 入口。注入参数化，测试可指向内存 suite。
    private let defaults: UserDefaults

    /// 持久化键名。每个键在写入（didSet）与读取（init）两处各用一次，
    /// 收进一处常量杜绝两边拼写漂移。
    ///
    /// 键名属于持久化契约：改值等于让既有用户的该项偏好读不回（且无迁移）。
    /// 只允许新增，禁止修改或删除既有值。
    private enum Keys {
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyCode = "hotKeyCode"
        static let historyLimit = "historyLimit"
        static let autoPaste = "autoPaste"
        static let sensitiveApps = "sensitiveApps"
    }

    /// 热键修饰键（Carbon modifier 掩码，⌥⌘V 默认）。变更即写库。
    @Published var hotKeyModifiers: Int {
        didSet { defaults.set(hotKeyModifiers, forKey: Keys.hotKeyModifiers) }
    }

    /// 热键主键码（虚拟键码）。变更即写库。
    @Published var hotKeyCode: UInt32 {
        didSet { defaults.set(Int(hotKeyCode), forKey: Keys.hotKeyCode) }
    }

    /// 历史条数上限（设计共识默认 1000，设置页约束在 200–5000）。
    @Published var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Keys.historyLimit) }
    }

    /// 自动粘贴开关（合成 ⌘V，需要辅助功能权限；设计共识默认关闭）。
    @Published var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Keys.autoPaste) }
    }

    /// 敏感应用名单（可编辑，默认 1Password/Bitwarden/KeePassXC/钥匙串）。
    @Published var sensitiveApps: [String] {
        didSet { defaults.set(sensitiveApps, forKey: Keys.sensitiveApps) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 热键默认值必须来自 HotKeyCombo.default 而不是在这里重复写字面量：
        // 录制器、设置 UI、持久化兜底三处共用同一常量，永不漂移。
        hotKeyModifiers = defaults.object(forKey: Keys.hotKeyModifiers) as? Int ?? HotKeyCombo.default.modifiers
        // 键码持久化为 Int：录制器给的是 UInt32，读写类型对称（UserDefaults
        // 存取统一走 Int），读回时再转回 UInt32。
        hotKeyCode = UInt32(defaults.object(forKey: Keys.hotKeyCode) as? Int ?? Int(HotKeyCombo.default.keyCode))
        historyLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 1000
        autoPaste = defaults.object(forKey: Keys.autoPaste) as? Bool ?? false
        sensitiveApps = defaults.stringArray(forKey: Keys.sensitiveApps) ?? SensitiveAppsFilter.defaults
    }

    /// 当前名单构建的敏感过滤器（每次捕获时调用；构建成本可忽略）。
    var sensitiveFilter: SensitiveAppsFilter {
        SensitiveAppsFilter(entries: sensitiveApps)
    }

    /// 开机自启当前状态：实时查询 SMAppService（系统事实，不落 UserDefaults）。
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 开关开机自启。失败（罕见：系统服务拒绝）仅记日志不抛出；
    /// launchAtLogin 是计算属性、无 @Published，必须手动 objectWillChange
    /// 通知 UI 刷新开关状态。
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("GlassClip launch-at-login error: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }
}
