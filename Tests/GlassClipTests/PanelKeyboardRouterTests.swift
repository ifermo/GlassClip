// PanelKeyboardRouterTests.swift — 键盘引擎特征测试（阶段②′）。
//
// 抽取动机的兑现：handleKeyEvent 一族长在 SwiftUI 视图里时无法脱离
// 视图树特征化（@State 前置条件），抽成 PanelKeyboardRouter 后在这里
// 用伪造的 Binding 状态 + 合成的 NSEvent 逐条钉住语义表：Esc 分层退出、
// Tab 轮换分类/⇧Tab 切 Tab、打即搜、Space 预览、⌫ 删除、Enter/⌘Enter、
// ↑↓ 移动与预览跟随、keyWindow 守卫。
//
// 副作用边界（刻意设计，勿"顺手补全"）：
// - Enter/⌘Enter 用不在库里的假条目 → HistoryController.copy 对空
//   payloads 提前 return，不会写系统剪贴板；
// - 夹具强制 autoPaste = false：本文件任何路径都不得触发
//   AutoPaster.paste()（它向前台应用合成真实 ⌘V）。
import AppKit
import SwiftUI
import XCTest

@testable import GlassClip

@MainActor
final class PanelKeyboardRouterTests: XCTestCase {

    /// 引擎状态的假存储：Binding(get:set:) 挂在普通 var 上，
    /// 脱离 SwiftUI 视图树可自由读写（这正是抽取要换来的可测性）。
    private final class RouterState {
        var query = ""
        var segment: Segment = .all
        var category: ItemCategory?
        var selectedID: UUID?
        var previewItem: ClipboardItem?
        var searchFocused = false
        var closed = false
    }

    private var state: RouterState!
    private var items: [ClipboardItem] = []
    private var router: PanelKeyboardRouter!
    private var panel: GlassPanel?

    override func setUp() {
        super.setUp()
        state = RouterState()
        items = []
    }

    override func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        router = nil
        state = nil
        super.tearDown()
    }

    // MARK: - 夹具

    private func makeRouter() -> PanelKeyboardRouter {
        let controller = makeIsolatedController()
        // 硬防御：本文件任何测试路径都不得合成真实 ⌘V。
        controller.settings.autoPaste = false
        return PanelKeyboardRouter(
            query: Binding(get: { self.state.query }, set: { self.state.query = $0 }),
            segment: Binding(get: { self.state.segment }, set: { self.state.segment = $0 }),
            category: Binding(get: { self.state.category }, set: { self.state.category = $0 }),
            selectedID: Binding(get: { self.state.selectedID }, set: { self.state.selectedID = $0 }),
            previewItem: Binding(get: { self.state.previewItem }, set: { self.state.previewItem = $0 }),
            searchFocused: Binding(get: { self.state.searchFocused }, set: { self.state.searchFocused = $0 }),
            controller: controller,
            onClose: { self.state.closed = true },
            flatItemsProvider: { self.items }
        )
    }

    /// 让 keyWindow 守卫放行：真 GlassPanel 上屏按键（生产同款 styleMask）。
    /// keyWindow 登记走 window server 异步路径——轮询等待而非定长睡眠
    /// （定长睡眠在窗口服务器繁忙时会假失败）。
    /// 授予与否是会话级状态：屏幕锁定/会话切换后后台测试进程拿不到 key，
    /// 连 activate 都无效（2026-09-05 实测）。拿不到就跳过本轮语义用例
    /// 而不是假失败——守卫的"放行"半边由不依赖窗口的穿透用例常态钉住。
    private func becomeKeyPanel() async throws {
        let panel = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        let deadline = Date().addingTimeInterval(2)
        while !(NSApp.keyWindow is GlassPanel) {
            if Date() > deadline {
                throw XCTSkip("窗口服务器未授予 keyWindow（会话状态相关）——键盘语义用例本轮跳过")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func keyEvent(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// 轮询等 fire-and-forget Task 跑完（Enter/⌫ 分支内的 Task）。
    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - keyWindow 守卫

    /// 面板不是 key 窗口时整表放行：事件原样返回，状态零触碰。
    func testEventsPassThroughWhenPanelIsNotKey() async throws {
        router = makeRouter()
        // 无任何 key 面板（含其他用例遗留窗口也不该是 GlassPanel 之外的巧合）。
        let event = keyEvent(KeyCode.escape, characters: "\u{1B}")
        let result = router.handleKeyEvent(event)
        XCTAssertTrue(result === event, "守卫必须放行原始事件")
        XCTAssertFalse(state.closed, "Esc 不该被消费")
    }

    /// 守卫放行路径：真面板成为 key 窗口后语义表才接管（后续用例的前提）。
    func testEscIsConsumedWhenGlassPanelIsKey() async throws {
        router = makeRouter()
        try await becomeKeyPanel()
        let result = router.handleKeyEvent(keyEvent(KeyCode.escape, characters: "\u{1B}"))
        XCTAssertNil(result, "面板为 key 窗口时 Esc 必须被消费")
        XCTAssertTrue(state.closed)
    }

    // MARK: - Esc 分层退出

    func testEscUnwindsLayersInOrder() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        let a = makeClipboardItem(), b = makeClipboardItem()
        items = [a, b]

        // 第 1 层：预览开着 → 只收预览，下层不动。
        state.selectedID = a.id
        state.previewItem = a
        state.query = "q"
        state.category = .json
        state.segment = .favorites
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.escape, characters: "\u{1B}")))
        XCTAssertNil(state.previewItem)
        XCTAssertEqual(state.query, "q")
        XCTAssertEqual(state.category, .json)
        XCTAssertEqual(state.segment, .favorites)
        XCTAssertFalse(state.closed)

        // 第 2 层：搜索词 → 清词 + 退焦点，分类/Tab 不动。
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.escape, characters: "\u{1B}")))
        XCTAssertEqual(state.query, "")
        XCTAssertFalse(state.searchFocused)
        XCTAssertEqual(state.category, .json)
        XCTAssertEqual(state.segment, .favorites)
        XCTAssertFalse(state.closed)

        // 第 3 层：分类 → 清分类，Tab 不动。
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.escape, characters: "\u{1B}")))
        XCTAssertNil(state.category)
        XCTAssertEqual(state.segment, .favorites)
        XCTAssertFalse(state.closed)

        // 第 4 层：收藏 Tab → 回 All。
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.escape, characters: "\u{1B}")))
        XCTAssertEqual(state.segment, .all)
        XCTAssertFalse(state.closed)

        // 第 5 层：关面板。
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.escape, characters: "\u{1B}")))
        XCTAssertTrue(state.closed)
    }

    // MARK: - Tab / ⇧Tab

    func testTabCyclesCategoryThroughNilRoundTrip() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        let expected: [ItemCategory?] = [.json, .text, .link, .image, nil]
        for want in expected {
            XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.tab, characters: "\t")))
            XCTAssertEqual(state.category, want, "Tab 轮换到 \(String(describing: want))")
        }
        XCTAssertEqual(state.segment, .all, "Tab 轮换不碰 Tab 轴")
    }

    func testShiftTabTogglesSegmentWithoutTouchingCategory() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        state.category = .link
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.tab, characters: "\t", modifiers: [.shift])))
        XCTAssertEqual(state.segment, .favorites)
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.tab, characters: "\t", modifiers: [.shift])))
        XCTAssertEqual(state.segment, .all)
        XCTAssertEqual(state.category, .link, "⇧Tab 不碰分类")
    }

    // MARK: - 打即搜

    func testTypeToSearchRoutesPrintablesIntoQueryAndFocuses() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        XCTAssertNil(router.handleKeyEvent(keyEvent(0, characters: "a")))
        XCTAssertEqual(state.query, "a")
        XCTAssertTrue(state.searchFocused, "无修饰字符进框并聚焦搜索框")

        // 既有语义（原注释"⇧ 放行（大写字母）"）：⇧ 组合不代打，事件放行，
        // 大写字符由已聚焦的搜索框自己插入——引擎侧查询不得变。
        let shiftB = keyEvent(11, characters: "B", modifiers: [.shift])
        XCTAssertTrue(router.handleKeyEvent(shiftB) === shiftB)
        XCTAssertEqual(state.query, "a")
    }

    func testCommandAndControlCombosPassThroughUntouched() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        let cmdA = keyEvent(0, characters: "a", modifiers: [.command])
        XCTAssertTrue(router.handleKeyEvent(cmdA) === cmdA, "⌘ 组合放行给系统快捷键")
        let ctrlA = keyEvent(0, characters: "a", modifiers: [.control])
        XCTAssertTrue(router.handleKeyEvent(ctrlA) === ctrlA, "⌃ 组合放行")
        XCTAssertEqual(state.query, "", "放行字符不得进搜索框")
    }

    // MARK: - Space / ↑↓ / ⌫ / Enter

    func testSpaceTogglesPreviewOnlyWhenQueryEmpty() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        let a = makeClipboardItem(), b = makeClipboardItem()
        items = [a, b]
        state.selectedID = a.id

        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.space, characters: " ")))
        XCTAssertEqual(state.previewItem?.id, a.id, "Space 开预览")
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.space, characters: " ")))
        XCTAssertNil(state.previewItem, "再按收起")

        state.query = "x"
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.space, characters: " ")))
        XCTAssertEqual(state.query, "x ", "有搜索词时空格进搜索框，不开预览")
        XCTAssertNil(state.previewItem)
    }

    func testArrowsClampAtBothEndsAndPreviewFollows() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        let a = makeClipboardItem(), b = makeClipboardItem(), c = makeClipboardItem()
        items = [a, b, c]

        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.downArrow, characters: "\u{F701}")))
        XCTAssertEqual(state.selectedID, a.id, "无选中按 ↓ 落首行")
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.upArrow, characters: "\u{F700}")))
        XCTAssertEqual(state.selectedID, a.id, "首行再往上不动")

        state.previewItem = a
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.downArrow, characters: "\u{F701}")))
        XCTAssertEqual(state.selectedID, b.id)
        XCTAssertEqual(state.previewItem?.id, b.id, "预览开着时跟随选中")
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.downArrow, characters: "\u{F701}")))
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.downArrow, characters: "\u{F701}")))
        XCTAssertEqual(state.selectedID, c.id, "末行再往下不动")
    }

    func testBackspaceDeletesSelectedItemAndCollapsesItsPreview() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        let a = makeClipboardItem()
        items = [a]
        state.selectedID = a.id
        state.previewItem = a

        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.delete, characters: "\u{7F}")))
        try await waitUntil(state.previewItem == nil, timeout: 2)
        XCTAssertFalse(state.closed, "⌫ 不关面板")
    }

    func testEnterClosesPanelWithAndWithoutSelection() async throws {
        router = makeRouter()
        try await becomeKeyPanel()

        // 无选中：同步关面板。
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.return, characters: "\r")))
        XCTAssertTrue(state.closed)

        // 有选中（假条目，无 payloads：copy 提前 return，不碰真剪贴板）：
        // fire-and-forget Task 里关面板。选中与列表必须是同一条目，
        // 否则 selectedItem 解析不到就走了"无选中"分支（假绿）。
        state.closed = false
        let a = makeClipboardItem()
        items = [a]
        state.selectedID = a.id
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.return, characters: "\r")))
        try await waitUntil(state.closed, timeout: 2)

        // ⌘Enter 同语义。
        state.closed = false
        state.selectedID = a.id
        XCTAssertNil(router.handleKeyEvent(keyEvent(KeyCode.return, characters: "\r", modifiers: [.command])))
        try await waitUntil(state.closed, timeout: 2)
    }
}
