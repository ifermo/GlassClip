// KeyCodes.swift — 虚拟键码常量（本项目实际用到的那几个）。
//
// 面板键盘导航（PanelRootView）与热键录制器（HotKeyRecorder）都要判断
// "按的是哪个键"。两处都用 NSEvent.keyCode（UInt16），所以这里统一成
// UInt16 常量、只收录用到的键，省去逐处转换。
//
// 热键显示名表（HotKeyCombo.keyName）走的是另一套：那里对齐 Carbon 注册
// 用的 UInt32，直接取 kVK_* 常量，不再抄第二份数字。
//
// 注意：虚拟键码是"键盘上的物理位置"，与当前键盘布局解耦
// （如 53 永远是左上角的 Esc），这正是全局热键/键盘导航需要的语义。

import Carbon.HIToolbox

/// 虚拟键码常量（值为 kVK_* 的裸值）。
enum KeyCode {
    static let escape: UInt16 = UInt16(kVK_Escape)
    static let delete: UInt16 = UInt16(kVK_Delete)
    static let space: UInt16 = UInt16(kVK_Space)
    static let tab: UInt16 = UInt16(kVK_Tab)
    static let `return`: UInt16 = UInt16(kVK_Return)
    static let downArrow: UInt16 = UInt16(kVK_DownArrow)
    static let upArrow: UInt16 = UInt16(kVK_UpArrow)
}
