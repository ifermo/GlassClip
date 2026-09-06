// PanelRootView.swift — 面板的 SwiftUI 根视图：搜索、Tab + 分类 chips、
// 列表、预览分栏、键盘导航。设计共识中的交互规格（键盘表、Esc 分层退出、
// 打即搜、Space 预览、Tab 轮换分类 / ⇧Tab 切 Tab）全部在本文件实现。
//
// 结构：顶部搜索条 → 全部/收藏 Tab ┃ 分类 chips（单选可取消，与 Tab 正交
// 叠加；分类是 ItemCategory 的派生属性，不入库）→ 发丝线 → 内容区
// （空态 / 列表（+ 可选右侧 252px 预览分栏））。
//
// 高度自适应：本视图实测 chrome 与列表内容高度、经 onHeightChange 上报；
// min/max 与屏幕钳位全部在 PanelController，本视图不知道任何尺寸常量。
//
// 键盘处理用 NSEvent 本地监视器而非 SwiftUI .onExitCommand/.button 键位：
// 面板需要"打即搜"（无焦点字符也进搜索框）与多键语义（Tab/Space/⌫），
// 本地监视器是唯一能统一拦截这些键的位置。监视器随视图出现/消失安装/移除。

import AppKit
import SwiftUI

// MARK: - 根视图

/// 面板内容根视图。
struct PanelRootView: View {
    /// 数据层（观察 items 变化刷新列表）。
    @ObservedObject var controller: HistoryController
    /// 关闭面板（粘贴后/Esc 兜底层）。
    let onClose: () -> Void
    /// 打开设置（齿轮按钮）。
    let onOpenSettings: () -> Void
    /// 内容理想高度上报（AppKit 侧钳位后 setFrame）。本视图不知道 min/max。
    let onHeightChange: (CGFloat) -> Void

    /// 搜索词（打即搜的目标域）。
    @State private var query = ""
    /// 当前 Tab。
    @State private var segment: Segment = .all
    /// 当前分类过滤（nil = 不过滤；与 Tab 正交叠加，Tab 轮换的目标域）。
    @State private var category: ItemCategory?
    /// 键盘/点击选中的行（nil = 无选中，validateSelection 会补上首行）。
    @State private var selectedID: UUID?
    /// 预览分栏展示的条目（nil = 分栏收起）。
    @State private var previewItem: ClipboardItem?
    /// 搜索框焦点（打即搜时程序化聚焦）。
    @FocusState private var searchFocused: Bool
    /// 键盘事件本地监视器（随视图生命周期安装/移除）。
    @State private var keyMonitor: Any?

    /// chrome 区（搜索条 + Tab 条 + 发丝线）实测高。
    @State private var chromeHeight: CGFloat = 0
    /// 列表内容实测高（LazyVStack 全量，含小节头/分隔线/底边距）。
    /// 空态分支没有列表，恒为 0。
    @State private var listContentHeight: CGFloat = 0

    /// 面板内容理想高度 = chrome + 列表内容，交给 AppKit 钳位。
    /// chrome 未完成首次布局前不上报，避免把 0 暂存进 PanelController。
    private func reportPanelHeight() {
        guard chromeHeight > 0 else { return }
        onHeightChange(chromeHeight + listContentHeight)
    }

    /// 面板玻璃形状：圆角 20、连续曲率。panelMaterial（材质+外观）与
    /// clipShape（内容裁切）必须共用同一形状，杜绝两层形状错位。
    static let panelShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    // MARK: 派生列表

    /// 搜索 + Tab + 分类过滤后的基础列表。
    ///
    /// 求值模型（2026-09-05 收口）：渲染路径在 body 里对本属性**单次求值**，
    /// 小节/计数全部向下传递——历史实现里 favoriteItems/recentItems/计数
    /// 各自独立触发一遍过滤，是搬运契约时代"刻意保持原样"的产物，②′
    /// 完成后该约束已过时。非渲染路径（选中校验、键盘引擎）仍走 flatItems。
    private var filtered: [ClipboardItem] {
        HistoryListModel.filtered(items: controller.items, query: query, segment: segment, category: category)
    }

    /// 键盘导航的一维顺序 = 收藏小节在前 + 历史小节在后（与视觉一致）。
    /// 仅非渲染路径使用（选中校验、键盘引擎的 flatItemsProvider）。
    private var flatItems: [ClipboardItem] {
        let base = filtered
        return HistoryListModel.flatItems(
            favoriteItems: HistoryListModel.favoriteItems(base),
            recentItems: HistoryListModel.recentItems(base, segment: segment))
    }

    // MARK: 主体

    var body: some View {
        let base = filtered
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                segmentBar(itemCount: base.count)
                Divider().glassHairline
            }
            // chrome 高度实测（嵌套 VStack 与原扁平结构逐像素等价，
            // 仅为测量提供单一挂点）。
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0; reportPanelHeight() }
            content(filtered: base)
        }
        // 材质与外观形状由 panelMaterial 双路径负责（26+ glassEffect /
        // 14/15 ultraThinMaterial，见 Formatting.swift 注释）——不要换回
        // NSGlassEffectView：其 cornerRadius 在"作为无边框透明窗口
        // contentView"的用法下不可靠（圆角外围浅色残留 bug 根因，见
        // FloatingPanel 视觉结构注释）。clipShape 只管内容裁切，
        // 保证发丝线等全宽元素不溢出圆角。
        .panelMaterial(in: Self.panelShape)
        .clipShape(Self.panelShape)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
        // 任何使列表变化的信号都要重新校验选中行（可能已滚出过滤结果）。
        .onChange(of: controller.items) { _, _ in
            validateSelection()
            // 预览分栏持有的是条目快照，收藏/合并置顶/删除后必须换成新副本，
            // 否则分栏一直停在旧值上（与列表里的 ★ 状态对不上）。
            syncPreviewItem()
        }
        .onChange(of: query) { _, _ in validateSelection() }
        .onChange(of: segment) { _, _ in validateSelection() }
        .onChange(of: category) { _, _ in validateSelection() }
    }

    // MARK: - 搜索条

    /// 放大镜 + 输入框 + （有词时）清空按钮 + 设置齿轮。
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Tab 条

    /// 过滤条（结构见 PanelFilterBar；状态所有权留在本视图）。
    private func segmentBar(itemCount: Int) -> some View {
        PanelFilterBar(segment: $segment, category: $category, itemCount: itemCount)
    }

    // MARK: - 内容区

    /// 三态：全空（首次使用）→ 无匹配/无收藏 → 列表（+ 可选预览分栏）。
    /// 两个空态分支没有列表内容，上报 chrome 高度（钳位后落到 min）。
    /// 收藏/历史小节与键盘一维序在这里各派生一次，随参数向下传递。
    @ViewBuilder
    private func content(filtered base: [ClipboardItem]) -> some View {
        let favorites = HistoryListModel.favoriteItems(base)
        let recents = HistoryListModel.recentItems(base, segment: segment)
        let flat = HistoryListModel.flatItems(favoriteItems: favorites, recentItems: recents)
        if controller.items.isEmpty {
            EmptyStateView(
                title: "Nothing here yet",
                subtitle: "Copy anything and it will show up here.\nPress the hotkey anytime to open GlassClip."
            )
            .onAppear { listContentHeight = 0; reportPanelHeight() }
        } else if flat.isEmpty {
            EmptyStateView(
                title: "No matches",
                subtitle: query.isEmpty
                    ? (category == nil ? "Nothing favorited yet." : "Nothing in this category yet.")
                    : "No items match “\(query)”."
            )
            .onAppear { listContentHeight = 0; reportPanelHeight() }
        } else {
            HStack(spacing: 0) {
                listView(favorites: favorites, recents: recents)
                if let previewItem {
                    Divider().glassHairline
                    PreviewPane(item: previewItem, controller: controller)
                        .frame(width: 252)
                        .transition(.opacity)
                }
            }
        }
    }

    /// 历史列表：收藏小节置顶、发丝线分隔、LazyVStack 惰性渲染长列表。
    /// 选中行变化时滚动居中（键盘长距离导航时目标行始终可见）。
    private func listView(favorites: [ClipboardItem], recents: [ClipboardItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: []) {
                    if !favorites.isEmpty {
                        sectionHeader("Favorites")
                        ForEach(favorites) { item in
                            row(for: item)
                        }
                        if !recents.isEmpty {
                            Divider().glassHairline
                                .padding(.vertical, 4)
                        }
                    }
                    if !recents.isEmpty {
                        sectionHeader("History")
                        ForEach(recents) { item in
                            row(for: item)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                // 列表内容全量高度实测：ScrollView 会撑满窗口（测量其自身
                // 无意义），但 LazyVStack 在其内部按内容取高——行高统一时
                // 未渲染行的估算无漂移（依赖 44px 行高共识）。
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listContentHeight = $0; reportPanelHeight() }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.panelQuick) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// 小节标题（Favorites / History，全大写小字号宽字距）。
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    /// 单行 + 全部鼠标交互：单击选中、右键菜单（复制/粘贴/纯文本粘贴/
    /// 收藏/预览/删除）。.id(item.id) 供 ScrollViewReader 定位。
    ///
    /// 收藏动作只把 **id** 交给数据层，不交 item：闭包捕获的是某次渲染的
    /// 快照，快照里的 favorite 一旦过期，取反就会朝错误方向翻转（已收藏的
    /// 行点了 ★ 仍被判成未收藏），表现为"取消不掉"。id 恒真，目标状态由
    /// 数据层按 items 现读现翻。
    private func row(for item: ClipboardItem) -> some View {
        HistoryRow(
            item: item,
            isSelected: item.id == selectedID,
            onToggleFavorite: { Task { await controller.toggleFavorite(id: item.id) } }
        )
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = item.id }
        .contextMenu {
            Button("Copy") { Task { await controller.copy(item) } }
            Button("Paste") { Task { await copyAndClose(item, plain: false) } }
            Button("Paste as Plain Text") { Task { await copyAndClose(item, plain: true) } }
            Divider()
            Button(item.favorite ? "Remove from Favorites" : "Add to Favorites") {
                Task { await controller.toggleFavorite(id: item.id) }
            }
            Button(previewItem?.id == item.id ? "Hide Preview" : "Preview") {
                togglePreview(item)
            }
            Divider()
            Button("Delete", role: .destructive) { Task { await deleteItem(item) } }
        }
    }

    // MARK: - 动作

    /// 键盘引擎（②′ 抽取，语义见 PanelKeyboardRouter）：状态经 Binding
    /// 注入、派生列表与渲染同源；@State 所有权仍在本视图。
    private var router: PanelKeyboardRouter {
        PanelKeyboardRouter(
            query: $query, segment: $segment, category: $category,
            selectedID: $selectedID, previewItem: $previewItem,
            // FocusState 的投影不是普通 Binding，包一层 get/set；引擎侧
            // 因此可用普通 Binding 伪造（特征测试不依赖真实焦点存储）。
            searchFocused: Binding(get: { searchFocused }, set: { searchFocused = $0 }),
            controller: controller, onClose: onClose, flatItemsProvider: { flatItems }
        )
    }

    /// NSEvent 本地监视器的入口。每次事件现构引擎：Binding 是存储句柄，
    /// 构造只是打包句柄，成本可忽略。
    private func routeKeyEvent(_ event: NSEvent) -> NSEvent? {
        router.handleKeyEvent(event)
    }

    /// 选中行有效性校验（实现在 PanelKeyboardRouter）。
    private func validateSelection() {
        router.validateSelection()
    }

    /// 把预览分栏持有的条目快照换成 items 里的当前副本。
    ///
    /// 条目被删（或滚出列表）时快照无处可换，收起分栏——留着会显示一条
    /// 已经不存在的记录。
    private func syncPreviewItem() {
        guard let id = previewItem?.id else { return }
        previewItem = controller.items.first { $0.id == id }
    }

    /// 预览开关（实现在 PanelKeyboardRouter）。
    private func togglePreview(_ item: ClipboardItem) {
        router.togglePreview(item)
    }

    /// 粘贴三连（实现在 PanelKeyboardRouter）。
    private func copyAndClose(_ item: ClipboardItem, plain: Bool) async {
        await router.copyAndClose(item, plain: plain)
    }

    /// 删除行（实现在 PanelKeyboardRouter）。
    private func deleteItem(_ item: ClipboardItem) async {
        await router.deleteItem(item)
    }

    // MARK: - 键盘

    /// 安装 keyDown 本地监视器（先移除旧的防重复安装）。
    /// 本地监视器只作用于本进程内的事件，面板外不受影响。
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            routeKeyEvent(event)
        }
    }

    /// 移除监视器（视图消失时必须拆，否则泄漏并继续拦截事件）。
    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

// MARK: - 过滤条

/// 面板顶部的过滤条：All/Favorites Tab ┃ 分类 chips（单选，再点取消）+
/// 右侧结果计数。发丝竖线分隔两组：Tab 互斥、分类与 Tab 正交叠加，
/// 视觉上分开两轴。
///
/// 独立成 struct 供离屏宽度测量（PanelFilterBarWidthTests）：六个 chip +
/// 计数贴着 520pt 面板宽的上限，装不下的回归要在这里红，而不是在真机
/// 上把 chip 挤成截断。
struct PanelFilterBar: View {
    @Binding var segment: Segment
    @Binding var category: ItemCategory?
    /// 结果计数（单复数标签由本组件格式化；body 单次求值后传入）。
    let itemCount: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Segment.allCases) { value in
                ChipButton(title: value.title, symbol: value.symbol, isSelected: segment == value) {
                    segment = value
                }
            }
            Divider()
                .glassHairline
                .frame(height: 14)
                .padding(.horizontal, 4)
            ForEach(ItemCategory.allCases) { value in
                ChipButton(title: value.title, symbol: nil, isSelected: category == value) {
                    category = category == value ? nil : value
                }
            }
            Spacer()
            Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

// MARK: - Chip 按钮

/// 胶囊样式的小号按钮（Tab 与分类 chip 共用；选中填主色 14%，未选中仅次级文字）。
/// symbol 为 nil = 纯文字 chip：分类四个 chip 不带图标（六个 chip + 计数
/// 贴着 520pt 面板宽的上限，图标会挤破单行），同时与带图标的 Tab 按钮
/// 形成两轴的视觉区分。
private struct ChipButton: View {
    let title: String
    let symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSelected ? Color.primary.opacity(0.14) : Color.clear)
            )
            .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}
