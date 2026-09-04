// StatusBarMenuTests.swift — 状态栏菜单 target 布线回归测试。
//
// 锁定的 bug：菜单构建时把所有项的 target 一律设成 AppDelegate，
// 包括 action 实现在 NSApplication 上的 Quit 项——AppDelegate 不响应
// terminate(_:)，NSMenu 弹出时逐项验证失败，Quit 永久置灰。
// 修复后 Quit 的 target 为 NSApp；本测试无头复现"菜单显示前的
// 验证过程"，锁定三个菜单项全部可点。
//
// 环境要点：xctest 进程默认没有 NSApp，而 NSMenu.update() 在没有
// app 对象时会把所有项一律 disable——必须先触碰 NSApplication.shared，
// update() 的逐项验证才与真机行为一致。

import AppKit
import XCTest
@testable import GlassClip

@MainActor
final class StatusBarMenuTests: XCTestCase {
    /// 回归测试：状态栏菜单中每个带 action 的项都必须通过显示时验证
    /// （即 enabled），否则用户看到的就是永久置灰的条目。
    func testAllStatusBarMenuItemsAreEnabledAfterValidation() {
        // xctest 进程默认没有 NSApplication；没有 app 对象时
        // NSMenu.update() 会把所有项一律 disable。
        let _ = NSApplication.shared
        let delegate = AppDelegate()
        let menu = delegate.makeStatusBarMenu()
        menu.update()

        let actionable = menu.items.filter { $0.action != nil }
        XCTAssertGreaterThanOrEqual(actionable.count, 3, "expected Show/Settings/Quit entries")
        for item in actionable {
            XCTAssertTrue(item.isEnabled, "status-bar menu item '\(item.title)' is disabled")
        }
    }

    /// 回归测试：Tahoe 自动菜单图标必须被抑制（AppDelegate.init 里的
    /// NSMenuItem.disableIcons swizzle）。若有人移除该调用，显式设置的
    /// image 将不再被吞掉，本测试变红。
    func testMenuIconsAreDisabled() {
        let _ = NSApplication.shared
        let delegate = AppDelegate() // init 内安装 swizzle
        let item = NSMenuItem(title: "Icon Probe", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        XCTAssertNil(item.image,
                     "menu icons must stay disabled app-wide (Tahoe automatic icon regression); NSMenuItem.disableIcons() call was likely removed")
        _ = delegate
    }
}
