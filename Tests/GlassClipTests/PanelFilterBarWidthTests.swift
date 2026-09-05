// PanelFilterBarWidthTests.swift — 过滤条单行宽度回归。
//
// 六个 chip（Tab 2 + 分类 4）+ 计数标签贴着 520pt 面板宽的上限：
// 超宽时 SwiftUI 不换行而是压缩 Text，chip 标题被截断成 "Imag…"，
// 这种破相只能离屏量出来。用 NSHostingView.fittingSize 拿过滤条的
// 理想宽度（Spacer 理想宽为 0，即全部内容的固有宽度），必须 ≤ 面板宽。
import AppKit
import SwiftUI
import XCTest

@testable import GlassClip

@MainActor
final class PanelFilterBarWidthTests: XCTestCase {

    /// 计数取三位数量级——历史最多时的最长态也要装得下。
    func testFilterBarFitsPanelWidth() {
        let bar = PanelFilterBar(segment: .constant(.all), category: .constant(nil), itemCount: 999)
        let size = NSHostingView(rootView: bar).fittingSize

        XCTAssertGreaterThan(size.width, 0, "离屏测量应得到真实宽度（0 = 测量本身失效）")
        XCTAssertLessThanOrEqual(size.width, PanelController.panelWidth,
                                 "过滤条理想宽 \(size.width) 超出面板宽 \(PanelController.panelWidth)，chip 会被截断")
    }
}
