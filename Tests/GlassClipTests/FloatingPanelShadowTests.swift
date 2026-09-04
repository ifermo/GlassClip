// FloatingPanelShadowTests.swift — 面板阴影回归（背景：黑色线框 bug）。
//
// 锁定的 bug：borderless + backgroundColor=.clear 的面板仍会收到 AppKit
// 按"窗口矩形边界"生成的原生阴影——服务器不认 NSGlassEffectView 的
// cornerRadius 裁切，表现为紧贴玻璃边缘的一圈黑色硬线框（四边+四角，
// 带 alpha 17–33% 的深色贴边带；debug/ 截图回路逐像素对比证实：关阴影
// 截取无此带）。修复 = 面板永远关闭窗口级 hasShadow；日后要层次感，
// 在合成层自绘（CALayer shadow / 9-slice），不得重开原生阴影。
import AppKit
import XCTest
@testable import GlassClip

@MainActor
final class FloatingPanelShadowTests: XCTestCase {
    /// 面板不得携带窗口级原生阴影（黑色线框回归防御）。
    func testPanelHasNoNativeShadow() async throws {
        let panelController = PanelController(controller: makeIsolatedController())
        panelController.show()
        // 建窗与上屏发生在 runloop 上，给一拍时间（与 SettingsWindowTests 同模式）。
        try await Task.sleep(nanoseconds: 300_000_000)

        let panel = try XCTUnwrap(panelController.panelForTesting, "panel never created")
        XCTAssertFalse(panel.hasShadow,
                       "native window shadow on a rounded glass panel renders as a tight rectangular black rim (black-frame regression)")
        panelController.hide()
    }
}
