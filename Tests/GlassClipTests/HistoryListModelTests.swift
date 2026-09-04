// HistoryListModelTests.swift — 面板列表派生/选中逻辑的特征测试（阶段②′）。
//
// 这批用例钉的是"从 PanelRootView 逐字搬进 HistoryListModel"的那几段逻辑：
// 搬运本身由 git diff 审查担保（语句未改），这里补的是搬运之后可被断言的
// 语义边界——尤其是键盘导航赖以工作的钳制与回落规则。
//
// 刻意不去"顺手优化"求值次数或排序稳定性：任何与旧实现不同之处都算行为变化。
import AppKit
import XCTest

@testable import GlassClip

@MainActor
final class HistoryListModelTests: XCTestCase {

    /// 条目工厂：只给过滤/排序真正关心的维度赋值。
    private func item(_ id: UUID = UUID(), identity: String, search: String, favorite: Bool = false, favoriteAt: Date? = nil) -> ClipboardItem {
        ClipboardItem(id: id, kind: .text, identity: identity, searchText: search, previewText: search,
                      appName: nil, appIconPath: nil, thumbnailPath: nil,
                      createdAt: Date(timeIntervalSince1970: 1000), favorite: favorite, favoriteAt: favoriteAt)
    }

    /// 按身份取回（断言"是哪几条"比断言 id 集合更可读）。
    private func identities(_ items: [ClipboardItem]) -> [String] {
        items.map(\.identity)
    }

    // MARK: - 过滤

    /// 空搜索词 = 全量原序（原序即 controller.items 的新→旧）。
    func testEmptyQueryKeepsAllItemsInOrder() {
        let all = [item(identity: "a", search: "alpha"), item(identity: "b", search: "beta")]
        XCTAssertEqual(identities(HistoryListModel.filtered(items: all, query: "", segment: .all)), ["a", "b"])
    }

    /// 命中域是 searchText（不是 previewText）；大小写不敏感。
    /// 把匹配域换成 previewText 会静默改变搜索结果，这条就是防它。
    func testSearchMatchesSearchTextCaseInsensitively() {
        let hit = ClipboardItem(id: UUID(), kind: .text, identity: "h", searchText: "hello world", previewText: "不同的一处",
                                appName: nil, appIconPath: nil, thumbnailPath: nil,
                                createdAt: Date(), favorite: false, favoriteAt: nil)
        let miss = ClipboardItem(id: UUID(), kind: .text, identity: "m", searchText: "other", previewText: "hello world",
                                 appName: nil, appIconPath: nil, thumbnailPath: nil,
                                 createdAt: Date(), favorite: false, favoriteAt: nil)

        let result = HistoryListModel.filtered(items: [hit, miss], query: "HELLO", segment: .all)
        XCTAssertEqual(identities(result), ["h"], "只在 searchText 上匹配")
    }

    /// 实测事实：匹配用的是 `localizedCaseInsensitiveContains`——它对大小写
    /// （含本地化大小写映射）不敏感，但**不折叠音标**。因此 "CAFÉ" 能命中
    /// "café résumé"，而 ASCII 写的 "resume"/"cafe" 命中不了。
    /// 换成 diacriticInsensitive 比较或 String.folding 会静默改变搜索结果集。
    func testSearchIsCaseInsensitiveButDiacriticSensitive() {
        let items = [item(identity: "c", search: "café résumé")]

        XCTAssertEqual(identities(HistoryListModel.filtered(items: items, query: "CAFÉ", segment: .all)), ["c"],
                       "大小写（含音标形式的大写）不敏感")
        XCTAssertEqual(identities(HistoryListModel.filtered(items: items, query: "RÉSUMÉ", segment: .all)), ["c"])
        XCTAssertEqual(HistoryListModel.filtered(items: items, query: "resume", segment: .all).map(\.identity), [],
                       "ASCII 无音标写法命中不了 → 搜索是音标敏感的")
        XCTAssertEqual(HistoryListModel.filtered(items: items, query: "cafe", segment: .all).map(\.identity), [])
    }

    /// 收藏 Tab = 在搜索结果之上再叠一层收藏过滤。
    func testFavoritesSegmentStacksOnTopOfSearch() {
        let a = item(identity: "a", search: "x", favorite: true, favoriteAt: Date(timeIntervalSince1970: 1))
        let b = item(identity: "b", search: "x")
        let c = item(identity: "c", search: "y", favorite: true, favoriteAt: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(identities(HistoryListModel.filtered(items: [a, b, c], query: "x", segment: .favorites)), ["a"])
    }

    // MARK: - 分小节

    /// 收藏小节按 favoriteAt 倒序（不是按捕获时间、不是按列表原序）。
    func testFavoriteSectionSortsByFavoriteAtDescending() {
        let old = item(identity: "fav-old", search: "s", favorite: true, favoriteAt: Date(timeIntervalSince1970: 100))
        let fresh = item(identity: "fav-new", search: "s", favorite: true, favoriteAt: Date(timeIntervalSince1970: 900))
        let noDate = item(identity: "fav-nil", search: "s", favorite: true, favoriteAt: nil)

        let section = HistoryListModel.favoriteItems([old, noDate, fresh])
        XCTAssertEqual(identities(section), ["fav-new", "fav-old", "fav-nil"],
                       "favoriteAt 为 nil 落到 distantPast → 恒排最后")
    }

    /// 历史小节 = 非收藏；收藏 Tab 下整节为空（只显示收藏）。
    func testRecentSectionExcludesFavoritesAndEmptiesInFavoritesTab() {
        let fav = item(identity: "f", search: "s", favorite: true, favoriteAt: Date())
        let plain = item(identity: "p", search: "s")

        XCTAssertEqual(identities(HistoryListModel.recentItems([fav, plain], segment: .all)), ["p"])
        XCTAssertTrue(HistoryListModel.recentItems([fav, plain], segment: .favorites).isEmpty)
    }

    /// 键盘导航的一维顺序：收藏小节在前、历史小节在后（与视觉一致）。
    func testFlatOrderPutsFavoritesBeforeHistory() {
        let fav = item(identity: "f", search: "s", favorite: true, favoriteAt: Date())
        let plain = item(identity: "p", search: "s")
        let filteredAll = [fav, plain]

        let flat = HistoryListModel.flatItems(
            favoriteItems: HistoryListModel.favoriteItems(filteredAll),
            recentItems: HistoryListModel.recentItems(filteredAll, segment: .all))
        XCTAssertEqual(identities(flat), ["f", "p"])
    }

    // MARK: - 选中回落与解析

    /// 未选中 / 选中已不在列表（被删或被过滤掉）→ 需要回落到首行。
    func testNeedsSelectionFallbackCoversNilAndMissingID() {
        let a = item(identity: "a", search: "s")
        let b = item(identity: "b", search: "s")

        XCTAssertTrue(HistoryListModel.needsSelectionFallback(nil, in: [a, b]))
        XCTAssertTrue(HistoryListModel.needsSelectionFallback(UUID(), in: [a, b]), "选中的行已消失")
        XCTAssertFalse(HistoryListModel.needsSelectionFallback(a.id, in: [a, b]), "选中有效时不得回落")
        XCTAssertTrue(HistoryListModel.needsSelectionFallback(a.id, in: []), "列表空了，选中即失效")
    }

    /// selectedItem：id 不在列表里返回 nil（行可能刚被删），不崩不误取。
    func testSelectedItemResolvesOrReturnsNil() {
        let a = item(identity: "a", search: "s")
        XCTAssertEqual(HistoryListModel.selectedItem(a.id, in: [a])?.identity, "a")
        XCTAssertNil(HistoryListModel.selectedItem(nil, in: [a]))
        XCTAssertNil(HistoryListModel.selectedItem(UUID(), in: [a]))
        XCTAssertNil(HistoryListModel.selectedItem(a.id, in: []))
    }

    // MARK: - ↑↓ 钳制

    /// 无选中时按 ↓ 落到首行；按 ↑ 也落到首行（currentIndex 兜底为 -1，
    /// -1 + (-1) 被 max(0, …) 抬回 0）——键盘永远有落点。
    func testFirstArrowWithoutSelectionLandsOnHead() {
        let a = item(identity: "a", search: "s")
        let b = item(identity: "b", search: "s")
        let flat = [a, b]

        XCTAssertEqual(HistoryListModel.movedSelection(from: nil, in: flat, delta: 1), a.id)
        XCTAssertEqual(HistoryListModel.movedSelection(from: nil, in: flat, delta: -1), a.id)
    }

    /// 两端钳死：越界不循环（回绕会改变"到边界停住"的共识）。
    func testSelectionClampsAtBothEnds() {
        let a = item(identity: "a", search: "s")
        let b = item(identity: "b", search: "s")
        let c = item(identity: "c", search: "s")
        let flat = [a, b, c]

        XCTAssertEqual(HistoryListModel.movedSelection(from: a.id, in: flat, delta: -1), a.id, "首行再往上不动")
        XCTAssertEqual(HistoryListModel.movedSelection(from: c.id, in: flat, delta: 1), c.id, "末行再往下不动")
        XCTAssertEqual(HistoryListModel.movedSelection(from: c.id, in: flat, delta: 9), c.id, "越界不回绕")
    }

    /// 多步移动与选中已消失时的行为：以 -1 为基准重头数。
    func testMoveWithMissingSelectionRestartsFromHead() {
        let a = item(identity: "a", search: "s")
        let b = item(identity: "b", search: "s")
        let flat = [a, b]

        XCTAssertEqual(HistoryListModel.movedSelection(from: UUID(), in: flat, delta: 1), a.id,
                       "选中的行不在列表里 → currentIndex 视为 -1，下一步落首行")
        XCTAssertEqual(HistoryListModel.movedSelection(from: a.id, in: flat, delta: 2), b.id, "一次跨两步")
    }

    /// 空列表原样返回传入值（原实现是提前 return，不触碰 selectedID）。
    func testMoveOnEmptyListReturnsInputUnchanged() {
        let stray = UUID()
        XCTAssertNil(HistoryListModel.movedSelection(from: nil, in: [], delta: 1))
        XCTAssertEqual(HistoryListModel.movedSelection(from: stray, in: [], delta: 1), stray)
    }

    // MARK: - 组合：搜索收窄后的选中行为

    /// 搜索结果作为 flat 源时，选中有效性与解析都以过滤后的列表为准——
    /// 这正是面板"改搜索词后选中不会跳到看不见的路"的机制。
    func testSelectionSemanticsFollowFilteredList() {
        let kept = item(identity: "k", search: "visible")
        let hidden = item(identity: "h", search: "hidden")
        let flat = HistoryListModel.filtered(items: [kept, hidden], query: "vis", segment: .all)

        XCTAssertEqual(identities(flat), ["k"])
        XCTAssertTrue(HistoryListModel.needsSelectionFallback(hidden.id, in: flat), "被过滤掉的行算失效")
        XCTAssertEqual(HistoryListModel.movedSelection(from: hidden.id, in: flat, delta: 1), kept.id,
                       "失效选中按 ↓ 落到过滤结果首行")
    }
}
