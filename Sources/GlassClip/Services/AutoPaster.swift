// AutoPaster.swift — 自动粘贴（设计共识的可选功能）。
//
// 原理：用户在面板回车后，GlassClip 已把内容写上剪贴板；面板随即隐藏，
// 焦点回到用户之前的应用；本模块在 HID 层合成一次 ⌘V，让目标应用
// 自己把剪贴板内容粘贴进去——GlassClip 不直接操控别的应用。
//
// 权限：合成键盘事件需要辅助功能（Accessibility）授权，
// 未授权时引导系统弹窗/设置页（设置页有完整引导流程）。

import AppKit
import ApplicationServices

/// 自动粘贴工具（无状态，全静态）。
enum AutoPaster {
    /// 当前进程是否已获辅助功能授权（设置页据此显示权限状态）。
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统授权弹窗（首次调用时系统会询问"是否允许 GlassClip 控制
    /// 你的电脑"）。
    static func promptTrust() {
        // kAXTrustedCheckOptionPrompt 的字面值：CF 全局常量，无并发安全保证，
        // 不能直接引用符号，只能按字符串传入同名 key。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 在 HID 事件层合成 ⌘V 按下-抬起。
    ///
    /// 细节：
    /// - tap 用 .cghidEventTap（最底层注入点，等效真实键盘输入）；
    /// - eventSource 用 combinedSessionState：合成事件与真实键鼠共享状态机；
    /// - down 与 up 之间 sleep 20ms：部分应用对零间隔的按下-抬起会丢键；
    /// - 必须在面板隐藏之后调用——合成事件落点是当时的前台应用，
    ///   面板不隐藏就会粘贴回面板自己。
    /// 未授权时不粘贴，直接弹授权引导（用户预期是"要粘贴"，给出路径即可）。
    static func paste() {
        guard AXIsProcessTrusted() else {
            promptTrust()
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(9) // V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}
