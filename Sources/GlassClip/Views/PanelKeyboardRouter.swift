// PanelKeyboardRouter.swift — 面板键盘引擎与行级动作（阶段②′ 从 PanelRootView 逐行搬入）。
//
// 与 HistoryListModel 同属②′的 UI 引擎抽取：键盘语义（Esc 分层退出、
// Tab 轮换分类/⇧Tab 切 Tab、打即搜、Space 预览、⌫ 删除、Enter/⌘Enter 粘贴）
// 与行级动作原先长在 SwiftUI 视图里，视图的 private 成员 + @State 无法在
// 脱离活动视图树的副本上就地读写（运行时前置条件），无法特征化。
//
// 抽取形态：普通 struct，状态经 Binding 注入——搬入的每句语句与原实现
// 逐字相同（等价性由 git diff 审查担保）；@State 所有权仍留在视图，
// 本类型不持有渲染状态，不改变 SwiftUI 的失效与重渲染时机。

import AppKit
import SwiftUI

/// 面板键盘引擎：keyDown 语义表 + 行级动作（选中校验/预览/粘贴/删除）。
@MainActor
struct PanelKeyboardRouter {
    @Binding var query: String
    @Binding var segment: Segment
    @Binding var category: ItemCategory?
    @Binding var selectedID: UUID?
    @Binding var previewItem: ClipboardItem?
    @Binding var searchFocused: Bool

    /// 数据层（粘贴/删除动作执行者与 autoPaste 读取）。
    let controller: HistoryController
    /// 关闭面板（粘贴后/Esc 兜底层）。
    let onClose: () -> Void
    /// 键盘导航的一维顺序供给（视图侧与渲染取同一份派生列表）。
    let flatItemsProvider: () -> [ClipboardItem]

    /// 键盘导航的一维顺序 = 收藏小节在前 + 历史小节在后（与视觉一致）。
    private var flatItems: [ClipboardItem] { flatItemsProvider() }

    // MARK: - 动作

    /// 选中行有效性校验：选中不存在（被删/被过滤）或为空时，
    /// 回落到列表首行——键盘操作永远有落点。
    func validateSelection() {
        if HistoryListModel.needsSelectionFallback(selectedID, in: flatItems) {
            selectedID = flatItems.first?.id
        }
    }

    /// 预览开关：同一行再按一次收起；打开时顺带把选中移到该行。
    func togglePreview(_ item: ClipboardItem) {
        if previewItem?.id == item.id {
            withAnimation(.previewToggle) { previewItem = nil }
        } else {
            selectedID = item.id
            withAnimation(.previewToggle) { previewItem = item }
        }
    }

    /// 粘贴三连（Enter/菜单共用）：写剪贴板 → 关面板 → （可选）150ms 后
    /// 合成 ⌘V。150ms 延迟是给"面板下屏、焦点回到原应用"留时间，
    /// 否则 Auto Paste 的按键可能落进还没完全退场的面板。
    func copyAndClose(_ item: ClipboardItem, plain: Bool) async {
        await controller.copy(item, asPlainText: plain)
        onClose()
        if controller.settings.autoPaste {
            try? await Task.sleep(nanoseconds: 150_000_000)
            AutoPaster.paste()
        }
    }

    /// 删除行；若预览分栏正显示它，先收起预览避免悬空引用。
    func deleteItem(_ item: ClipboardItem) async {
        if previewItem?.id == item.id {
            previewItem = nil
        }
        await controller.delete(item)
    }

    // MARK: - 键盘

    /// 键盘语义表（设计共识）。返回 nil 表示事件已被消费；返回 event 表示
    /// 放行（交给第一响应者，如搜索框的文本输入）。
    ///
    /// 守卫：只有面板是 key 窗口时才拦截，避免影响其他窗口。
    /// `pureCommand` = 修饰键去掉 ⌘/⇧ 后的剩余部分，用于区分
    /// "纯 ⌘/⇧ 组合"与"带 ⌃/⌥ 的组合"。
    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard NSApp.keyWindow is GlassPanel else { return event }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let pureCommand = modifiers.subtracting([.command, .shift])

        // Esc — 分层退出（设计共识）：预览 → 搜索词 → 分类 → 收藏 Tab → 关面板。
        if event.keyCode == KeyCode.escape {
            if previewItem != nil {
                withAnimation(.previewToggle) { previewItem = nil }
            } else if !query.isEmpty {
                query = ""
                searchFocused = false
            } else if category != nil {
                category = nil
            } else if segment == .favorites {
                segment = .all
            } else {
                onClose()
            }
            return nil
        }

        // ↑↓ 移动选中（到边界停住），预览开着时跟随。
        if event.keyCode == KeyCode.downArrow || event.keyCode == KeyCode.upArrow {
            moveSelection(event.keyCode == KeyCode.downArrow ? 1 : -1)
            return nil
        }

        // ⌘Enter / ⌘⇧Enter — 粘贴（加 ⇧ 为纯文本粘贴）。
        if event.keyCode == KeyCode.return && pureCommand == modifiers && modifiers.contains(.command) {
            let plain = modifiers.contains(.shift)
            if let item = selectedItem {
                Task { await copyAndClose(item, plain: plain) }
                return nil
            }
        }

        // Enter — 粘贴选中行；无选中则关闭面板。
        if event.keyCode == KeyCode.return {
            if let item = selectedItem {
                Task { await copyAndClose(item, plain: false) }
            } else {
                onClose()
            }
            return nil
        }

        // Tab — 分类轮换（无分类 → JSON → Text → Links → Images → 无分类，
        // 含空档所以键盘随时能清空）；⇧Tab — All/收藏互换（原 Tab 语义）。
        if event.keyCode == KeyCode.tab {
            if modifiers.contains(.shift) {
                segment = segment == .all ? .favorites : .all
            } else {
                category = ItemCategory.next(after: category)
            }
            return nil
        }

        // Space — 预览开关（仅在搜索框为空时，避免与输入空格冲突）。
        if event.keyCode == KeyCode.space && query.isEmpty {
            if let item = selectedItem {
                togglePreview(item)
            }
            return nil
        }

        // ⌫ — 删除选中行（仅在搜索框为空时，避免与改词冲突）。
        if event.keyCode == KeyCode.delete && query.isEmpty {
            if let item = selectedItem {
                Task { await deleteItem(item) }
                return nil
            }
        }

        // 打即搜：无 ⌃/⌘ 修饰的可打印字符直接进搜索框（焦点不在框内也生效）。
        // ⇧ 放行（大写字母），⌘/⌃ 组合放行给系统快捷键。
        if pureCommand == modifiers, modifiers.isDisjoint(with: [.control, .command]),
           let characters = event.characters, let first = characters.first,
           isTypable(first)
        {
            if !searchFocused {
                searchFocused = true
            }
            query.append(first)
            return nil
        }

        return event
    }

    /// 字符是否可进搜索框：剔除控制字符（不可见字符/功能键的字符表示）。
    private func isTypable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// 当前选中的条目（selectedID → flatItems 解析；行可能刚被删）。
    private var selectedItem: ClipboardItem? {
        HistoryListModel.selectedItem(selectedID, in: flatItems)
    }

    /// ↑↓ 移动选中：钳制在 [0, count-1]；预览开着时跟随选中刷新内容。
    private func moveSelection(_ delta: Int) {
        let items = flatItems
        guard !items.isEmpty else { return }
        selectedID = HistoryListModel.movedSelection(from: selectedID, in: items, delta: delta)
        if previewItem != nil, let item = selectedItem {
            previewItem = item
        }
    }
}
