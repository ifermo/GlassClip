// ConstantContractTests.swift — 字面量契约：值本身就是持久化/显示协议的一部分。
//
// 为什么单独钉这些：常量收口类重构（把散落的字面量搬进 enum/常量）最容易出的
// 事故是"搬的时候手滑改了值"，而值改了编译器完全不知道：
// - UserDefaults 键名变了 → 用户既有偏好静默丢失（读回默认值）；
// - 键码显示表变了 → 热键设置页显示的符号与实际注册的键不再对应。
// 因此这里钉的是"键名字符串本身"和"码→显示名的映射结果"，不是实现细节。

import AppKit
import Carbon.HIToolbox
import XCTest

@testable import GlassClip

/// UserDefaults 持久化键名契约。
final class PersistenceKeyContractTests: XCTestCase {
    /// 五个偏好的写入键名与读回键名必须逐一等于历史字面量，
    /// 且写路径与读路径成对（换一处忘另一处 = 偏好重启即丢）。
    @MainActor func testPreferenceKeysAreTheLegacyNames() {
        let suiteName = "com.ken.glassclip.tests.keys.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        // 全部刻意取"非默认值"：等于默认值的用例会在读写双双错位时假绿。
        settings.historyLimit = 777
        settings.autoPaste = true
        settings.hotKeyModifiers = 1234
        settings.hotKeyCode = 11
        settings.sensitiveApps = ["com.apple.Keychain"]

        XCTAssertEqual(defaults.object(forKey: "historyLimit") as? Int, 777)
        XCTAssertEqual(defaults.object(forKey: "autoPaste") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "hotKeyModifiers") as? Int, 1234)
        XCTAssertEqual(defaults.object(forKey: "hotKeyCode") as? Int, 11,
                       "键码持久化为 Int（读写类型对称），不是 UInt32")
        XCTAssertEqual(defaults.object(forKey: "sensitiveApps") as? [String], ["com.apple.Keychain"])

        // 读路径：换一个实例重新解析同一域，值必须原样回来。
        let reopened = AppSettings(defaults: defaults)
        XCTAssertEqual(reopened.historyLimit, 777)
        XCTAssertEqual(reopened.autoPaste, true)
        XCTAssertEqual(reopened.hotKeyModifiers, 1234)
        XCTAssertEqual(reopened.hotKeyCode, 11)
        XCTAssertEqual(reopened.sensitiveApps, ["com.apple.Keychain"])
    }
}

/// 虚拟键码 → 显示名映射契约（热键录制器与设置页共用）。
final class HotKeyDisplayContractTests: XCTestCase {
    /// 与 KeyCode 常量重叠的七个码位：数值一旦漂移，显示符号就与实际注册键不符。
    func testCodesSharedWithKeyConstantsKeepTheirNames() {
        XCTAssertEqual(HotKeyCombo.keyName(UInt32(KeyCode.escape)), "Esc")
        XCTAssertEqual(HotKeyCombo.keyName(UInt32(KeyCode.delete)), "Delete")
        XCTAssertEqual(HotKeyCombo.keyName(UInt32(KeyCode.space)), "Space")
        XCTAssertEqual(HotKeyCombo.keyName(UInt32(KeyCode.tab)), "Tab")
        XCTAssertEqual(HotKeyCombo.keyName(UInt32(KeyCode.return)), "Return")
        XCTAssertEqual(HotKeyCombo.keyName(UInt32(KeyCode.downArrow)), "↓")
        XCTAssertEqual(HotKeyCombo.keyName(UInt32(KeyCode.upArrow)), "↑")
    }

    /// 全部 61 个码位的显示名快照。legacy 字典逐字抄自收口前的四张手抄表
    /// （letters/digits/symbols/fKeys）：改用 Carbon 的 kVK_* 常量后，
    /// 任何一处码位与显示名对不上都会在这里变红。
    func testEveryMappedCodeKeepsItsLegacyName() {
        let legacy: [UInt32: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
            40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
            32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        XCTAssertEqual(legacy.count, 61, "快照表要覆盖四张手抄表的全部条目")
        for (code, name) in legacy.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(HotKeyCombo.keyName(code), name, "键码 \(code) 的显示名漂移")
        }
    }

    /// Carbon 有定义、但本表刻意不收录的码位必须仍走回退分支。
    /// 换用 kVK_* 时最可能的偏差是"顺手多映射几个键"——那会让原本显示
    /// "Key 30" 的键突然显示成引号，属于可观测变化。
    func testUnmappedCodesStillFallBack() {
        for code: UInt32 in [10, 24, 30, 33, 39, 41, 42, 43, 44, 47, 50] {
            XCTAssertEqual(HotKeyCombo.keyName(code), "Key \(code)", "键码 \(code) 不该被映射")
        }
        XCTAssertEqual(HotKeyCombo.keyName(999), "Key 999")
    }

    /// 修饰键拼接顺序（⌃⌥⇧⌘）与默认热键展示串（设计共识 ⌥⌘V）。
    func testModifierOrderAndDefaultComboDisplay() {
        XCTAssertEqual(HotKeyCombo.default.displayString, "⌥⌘V")
        let all = HotKeyCombo(
            modifiers: Int(controlKey) | Int(optionKey) | Int(shiftKey) | Int(cmdKey),
            keyCode: UInt32(kVK_ANSI_A)
        )
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘A")
    }
}
