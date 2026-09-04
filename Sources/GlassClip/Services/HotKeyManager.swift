// HotKeyManager.swift — 全局热键：组合模型 + Carbon 注册管理。
//
// 为什么用 Carbon 的 RegisterEventHotKey：这是不引第三方库就能注册
// "系统级"热键（任何应用前台都响应）的官方途径，SwiftUI/.zero 依赖
// 共识下的标准选择。Carbon.HIToolbox 的事件部分至今仍是受支持 API。
//
// 结构：HotKeyCombo 是纯值（可比较、可持久化、可显示），
// HotKeyManager 是注册生命周期（重复注册即换键，先注销后注册）。

import Carbon.HIToolbox
import Foundation

// MARK: - 组合键模型

/// 一个全局热键组合：修饰键掩码 + 主键码。
struct HotKeyCombo: Sendable, Equatable {
    /// Carbon 修饰键掩码（cmdKey/optionKey/shiftKey/controlKey 位或）。
    var modifiers: Int
    /// 主键的虚拟键码（硬件布局相关，与 keyboardViewer 显示一致）。
    var keyCode: UInt32

    /// 默认热键 ⌥⌘V（设计共识）。热键设置的"恢复默认"也用它，
    /// 与 AppSettings 的持久化兜底共用同一常量。
    static let `default` = HotKeyCombo(modifiers: Int(cmdKey) | Int(optionKey), keyCode: UInt32(kVK_ANSI_V))

    /// UI 展示串：修饰键符号按 ⌃⌥⇧⌘ 固定顺序拼接，再接主键名
    /// （如 "⌥⌘V"）。顺序与 macOS 菜单栏惯例一致。
    var displayString: String {
        var result = ""
        if modifiers & Int(controlKey) != 0 { result += "⌃" }
        if modifiers & Int(optionKey) != 0 { result += "⌥" }
        if modifiers & Int(shiftKey) != 0 { result += "⇧" }
        if modifiers & Int(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(keyCode)
        return result
    }

    /// 键码 → 显示名总表。构建为类型常量：`displayString` 会在列表渲染中
    /// 反复求值，每次重建 61 项字典是不必要的开销（同 ClipboardCapture.entities）。
    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Escape): "Esc", UInt32(kVK_Delete): "Delete",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓", UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up", UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    /// 虚拟键码 → 显示名。查表覆盖字母/数字/常用符号/F1-F12；
    /// 未收录的键码回退为 "Key <code>"（录制器允许，显示不至空白）。
    ///
    /// 键位一律取 Carbon 的 kVK_* 常量：本项目别处（默认热键、注册调用）
    /// 用的就是同一套常量，重复抄写数字只会引入抄错的风险。
    /// 注意这些常量名是 **ANSI 布局的物理位置**（kVK_ANSI_A 即左上角那颗
    /// 字母键），非 US 布局下显示名与实际字符可能不符——已登记的已知缺陷。
    static func keyName(_ keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }
}

// MARK: - 注册管理

/// 全局热键的注册/注销与回调分发。
@MainActor
final class HotKeyManager {
    /// 已注册热键的系统引用（注销时需要）。
    private var hotKeyRef: EventHotKeyRef?
    /// 已安装的事件处理器引用（注销时需要）。
    private var eventHandler: EventHandlerRef?

    /// 热键按下回调（主线程）。由 PanelController 接管：切换面板显隐。
    var onHotKey: (@MainActor () -> Void)?

    /// 自家热键的签名 'GLCL'（FourCharCode）：系统会把所有热键事件投给
    /// 处理器，靠签名过滤出本应用注册的那颗键。
    private static let signature: FourCharCode = {
        let chars = Array("GLCL".utf8)
        return FourCharCode(chars[0]) << 24 | FourCharCode(chars[1]) << 16 | FourCharCode(chars[2]) << 8 | FourCharCode(chars[3])
    }()

    /// C 函数指针形式的处理器（Carbon API 要求）。
    ///
    /// 约束与要点：
    /// - 闭包不能捕获上下文 → 上下文经 userData 指针传入，
    ///   Unmanaged.takeUnretainedValue 取回 manager（不转移所有权，
    ///   manager 由上层持有）；
    /// - Carbon 事件回调运行在主线程（应用事件目标挂在主 RunLoop），
    ///   用 MainActor.assumeIsolated 桥回 Swift 隔离世界；
    /// - 只响应签名匹配的事件，其余一律放行（返回 noErr）。
    private static let handler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        if hotKeyID.signature == signature {
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                manager.onHotKey?()
            }
        }
        return noErr
    }

    /// 注册组合键。重复调用 = 换键（设置页录制新热键后调用），
    /// 先注销旧注册再装新的，不会累积多个处理器。
    ///
    /// 失败静默（返回值不抛）：注册失败的表现是"热键不响应"，
    /// 不至于影响应用其余功能。
    func register(_ combo: HotKeyCombo) {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(target, Self.handler, 1, &eventType, selfRef, &eventHandler)
        guard status == noErr else { return }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(combo.keyCode, UInt32(combo.modifiers), id, target, 0, &ref)
        hotKeyRef = ref
    }

    /// 注销热键与处理器；幂等（未注册时调用无害）。
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
