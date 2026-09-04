// StatusBarIconTests.swift — 状态栏图标资产与模板属性回归测试。
//
// 锁定的行为：状态栏用与 App 图标同源的模板图（StatusBarIcon.png，
// 从 Resources/AppIcon.png 派生，位图已入库）。
// 三个关键属性必须同时成立：
// 1. 资源随 target 打包（Bundle.module 可寻址）——防 Package.swift 的
//    resources 声明被移除或资源文件被改名后静默退回 SF Symbol；
// 2. 按 18pt 呈现（36×36 px 位图的 @2x 尺寸）；
// 3. isTemplate = true——否则亮/暗菜单栏不会自动反转，暗色下黑描边不可见。
//
// 环境要点：xctest 下 Bundle.module 指向被测 executable target 的资源
// bundle；加载走 NSImage(contentsOf:)，不需要 NSApplication。

import AppKit
import XCTest
@testable import GlassClip

@MainActor
final class StatusBarIconTests: XCTestCase {
    /// 回归测试：状态栏模板图可加载、尺寸 18pt、模板属性开启。
    func testStatusBarTemplateImageLoadsAsTemplatedAt18pt() {
        let image = AppDelegate.statusBarTemplateImage()
        XCTAssertNotNil(image,
                        "Bundle.module 找不到 StatusBarIcon.png——检查 Package.swift 的 resources 声明或文件名")
        XCTAssertEqual(image?.size.width, 18, "status bar icon must render at 18pt")
        XCTAssertEqual(image?.size.height, 18, "status bar icon must render at 18pt")
        XCTAssertEqual(image?.isTemplate, true,
                       "status bar icon must be a template image so it adapts to menu bar appearance")
    }
}
