// HistoryListModel.swift — 面板列表的派生与选中逻辑（从 PanelRootView 逐行搬入）。
//
// 为什么是纯静态函数而不是"持有状态的模型"：PanelRootView 的 query/segment/
// selectedID 是 @State，把它们搬进 ObservableObject 会改变 SwiftUI 的失效与
// 重渲染时机——那就不再是"行为不变"的搬运。这里只做输入→输出的纯函数，
// 状态所有权仍留在视图里，搬进来的每一句语句都与原实现逐字相同。
//
// 求值次数由调用方决定：渲染路径在 PanelRootView.body 内对 filtered 单次
// 求值后向下传递（2026-09-05 收口）；选中校验与键盘引擎等非渲染路径各自
// 独立求值。本类型不缓存、不持状态。
import Foundation

/// 面板列表的派生视图与选中位置计算。
@MainActor
enum HistoryListModel {

    /// 搜索 + Tab 过滤后的基础列表：搜索词命中 searchText 域
    /// （大小写/本地化不敏感），收藏 Tab 再叠一层收藏过滤，分类再叠一层
    /// （三轴 AND；category 为 nil = 不过滤）。
    static func filtered(items: [ClipboardItem], query: String, segment: Segment, category: ItemCategory? = nil) -> [ClipboardItem] {
        let base = query.isEmpty
            ? items
            : items.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
        let bySegment = segment == .favorites ? base.filter(\.favorite) : base
        guard let category else { return bySegment }
        return bySegment.filter { ItemCategory.classify($0) == category }
    }

    /// 收藏小节：按收藏时间倒序（设计共识），不受搜索外的高限约束。
    static func favoriteItems(_ filtered: [ClipboardItem]) -> [ClipboardItem] {
        filtered.filter(\.favorite).sorted { ($0.favoriteAt ?? .distantPast) > ($1.favoriteAt ?? .distantPast) }
    }

    /// 历史小节：非收藏、时间倒序；收藏 Tab 下为空（只显示收藏）。
    static func recentItems(_ filtered: [ClipboardItem], segment: Segment) -> [ClipboardItem] {
        segment == .favorites ? [] : filtered.filter { !$0.favorite }
    }

    /// 键盘导航的一维顺序 = 收藏小节在前 + 历史小节在后（与视觉一致）。
    static func flatItems(favoriteItems: [ClipboardItem], recentItems: [ClipboardItem]) -> [ClipboardItem] {
        favoriteItems + recentItems
    }

    /// 选中是否已失效（被删/被过滤/尚为空）——成立时视图应回落到首行。
    static func needsSelectionFallback(_ selectedID: UUID?, in flatItems: [ClipboardItem]) -> Bool {
        let ids = Set(flatItems.map(\.id))
        return selectedID == nil || !ids.contains(selectedID!)
    }

    /// 当前选中的条目（selectedID → flatItems 解析；行可能刚被删）。
    static func selectedItem(_ selectedID: UUID?, in flatItems: [ClipboardItem]) -> ClipboardItem? {
        selectedID.flatMap { id in flatItems.first { $0.id == id } }
    }

    /// ↑↓ 移动选中：钳制在 [0, count-1]。
    ///
    /// 空列表时返回原值——原实现是 `guard !items.isEmpty else { return }`，
    /// 即选中位置保持不变（不是清空）。
    static func movedSelection(from selectedID: UUID?, in flatItems: [ClipboardItem], delta: Int) -> UUID? {
        guard !flatItems.isEmpty else { return selectedID }
        let currentIndex = flatItems.firstIndex { $0.id == selectedID } ?? -1
        let nextIndex = max(0, min(flatItems.count - 1, currentIndex + delta))
        return flatItems[nextIndex].id
    }
}
