// Segment.swift — 面板顶部 Tab 的段模型（全部 / 收藏）。
//
// 从 PanelRootView 逐行搬入，定义未改。之所以独立成文件而不是留在视图里：
// `HistoryListModel` 的 filtered / recentItems 以它作为入参，
// 让它声明在被依赖的一侧而不是某个视图文件内部，
// ④′ 目录分层时不必再回头处理这条依赖。

import Foundation

/// 顶部 Tab：全部 / 收藏。
enum Segment: String, CaseIterable, Identifiable {
    case all
    case favorites
    var id: String { rawValue }
    var title: String { self == .all ? "All" : "Favorites" }
    var symbol: String { self == .all ? "square.stack.3d.up" : "star.fill" }
}
