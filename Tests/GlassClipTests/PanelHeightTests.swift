// PanelHeightTests.swift — 面板高度钳位回归。
//
// 锁定 clampedPanelHeight 的边界语义（尺寸策略唯一归属地）：
// min 230 是绝对地板（极端小屏上可用性优先于完全容纳）；
// max = min(680, 屏幕可用高 − 24)。
import XCTest
@testable import GlassClip

@MainActor
final class PanelHeightTests: XCTestCase {
    /// 内容不足 min → 取 min（空态/一两条列表时面板不缩成火柴盒）。
    func testContentBelowMinClampsToMin() {
        let height = PanelController.clampedPanelHeight(contentHeight: 100, screenVisibleHeight: 1200)
        XCTAssertEqual(height, PanelController.minPanelHeight)
    }

    /// 内容超过 max → 取 680（大屏上沿用原共识上限，超出部分列表内滚）。
    func testContentAboveMaxClampsToMax() {
        let height = PanelController.clampedPanelHeight(contentHeight: 1000, screenVisibleHeight: 1200)
        XCTAssertEqual(height, PanelController.maxPanelHeight)
    }

    /// 小屏钳制生效：max 压到屏幕可用高 − 24 以下。
    func testSmallScreenClampsMax() {
        let height = PanelController.clampedPanelHeight(contentHeight: 1000, screenVisibleHeight: 700)
        XCTAssertEqual(height, 700 - PanelController.screenVerticalMargin)
    }

    /// 退化小屏（可用高 − 24 < min）→ min 地板兜底，宁可溢出不可不可用。
    func testDegenerateScreenFallsBackToMin() {
        let height = PanelController.clampedPanelHeight(contentHeight: 1000, screenVisibleHeight: 200)
        XCTAssertEqual(height, PanelController.minPanelHeight)
    }

    /// 内容恰落在 [min, max] 区间内 → 原样通过（自适应的常规路径）。
    func testContentInRangePassesThrough() {
        let height = PanelController.clampedPanelHeight(contentHeight: 456, screenVisibleHeight: 1200)
        XCTAssertEqual(height, 456)
    }
}
