// SettingsWindowTests.swift — 设置窗口回归测试（回归背景：macOS 26 坑）。
//
// 锁定的 bug：accessory（LSUIElement）+ 仅 Settings scene 的应用里，
// SwiftUI 私有 showSettingsWindow: 静默 no-op（sendAction 返回 true
// 但永不建窗，先 NSApp.activate 也无效）。现实现由 AppDelegate 自持
// NSWindow，这两个用例保证：
// 1. 窗口必须真实可见（不是"调用没报错"而是"窗口真的在屏上"）；
// 2. 重复打开复用同一实例（不叠窗、不丢已改状态）。
//
// 模式：直接实例化 AppDelegate（不走真实启动流程），调
// openSettingsWindow 后在 runloop 上等一拍再断言。

import AppKit
import XCTest
@testable import GlassClip

@MainActor
final class SettingsWindowTests: XCTestCase {
    /// 设置窗口必须真实可见并保持——防御 macOS 26 上 accessory 应用中
    /// SwiftUI showSettingsWindow: 的静默 no-op（自持窗口方案的动因）。
    func testOpenSettingsWindowShowsVisibleWindow() async throws {
        let delegate = AppDelegate()
        defer { delegate.closeSettingsWindowForTesting() }

        delegate.openSettingsWindow()
        // 建窗与上屏发生在 runloop 上，给一拍时间。
        try await Task.sleep(nanoseconds: 300_000_000)

        let window = try XCTUnwrap(delegate.settingsWindowForTesting, "settings window was never created")
        XCTAssertTrue(window.isVisible, "settings window must be visible after openSettingsWindow()")
        XCTAssertEqual(window.title, "GlassClip Settings")
    }

    /// 重复打开必须复用同一窗口实例（isReleasedWhenClosed = false 的意义）：
    /// 防止"每次点设置叠一个新窗"与窗口状态丢失回归。
    func testSettingsWindowIsReusedNotDuplicated() async throws {
        let delegate = AppDelegate()
        defer { delegate.closeSettingsWindowForTesting() }

        delegate.openSettingsWindow()
        let first = try XCTUnwrap(delegate.settingsWindowForTesting)
        delegate.openSettingsWindow()
        let second = try XCTUnwrap(delegate.settingsWindowForTesting)

        XCTAssertTrue(first === second, "opening settings twice must reuse one window")
    }
}
