// ClipboardItem.swift — 剪贴板条目的领域模型。
//
// 本文件定义三层概念：
// - `ClipboardKind`：条目的内容大类（决定列表行图标与预览策略）；
// - `ClipboardItem`：一条历史记录的持久化行模型（SQLite items 表的一行），
//   也是 UI 列表/预览直接消费的视图模型；
// - `ClipboardPayload` / `CapturedContent`：捕获管线的中间产物——
//   剪贴板上原始字节（按 UTI 组织）与解析归一化后的待入库内容。
//
// 命名约定：`identity` 是去重/合并键（见下），`previewText` 是给人看的，
// `searchText` 是给匹配用的——三者用途不同，不可混用。

import Foundation

// MARK: - 内容类型

/// 剪贴板内容的六个大类。
///
/// rawValue 同时是 SQLite items 表 kind 列的存储值，已入库的枚举值
/// 不可改名（否则旧库读不出来）。
enum ClipboardKind: String, Codable, Sendable {
    case text
    case richText
    case html
    case image
    case file
    case color

    /// 列表行/预览面板显示的类型标签（UI 文案，遵循"UI 英文"共识）。
    var label: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .html: "HTML"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }
}

// MARK: - 历史条目

/// 一条剪贴板历史记录（对应 SQLite items 表的一行）。
///
/// 生命周期：捕获管线产出 `CapturedContent` → 落库为 `ClipboardItem` →
/// UI 列表消费；去重命中时不新建而是更新已有行（`updateMetadata`）。
struct ClipboardItem: Identifiable, Equatable, Sendable {
    /// 主键。去重命中的合并场景下，旧条目保留原 id（收藏等状态得以延续）。
    let id: UUID
    /// 内容大类。
    var kind: ClipboardKind
    /// 去重/合并键：同一 identity 视为"同一份内容"（纯文本变体也合并），
    /// 命中时旧行置顶而非插入新行。生成规则见捕获管线（PasteboardIO）。
    var identity: String
    /// 搜索索引用的小写化文本（打即搜的匹配域，已按匹配需求归一化）。
    var searchText: String
    /// 列表行展示的内容预览（单行截断由 UI 负责，这里存原始预览串）。
    var previewText: String
    /// 来源应用名（启动摄取/前台归因为未知时可能为 nil）。
    var appName: String?
    /// 来源应用图标的磁盘缓存路径（BlobStore Icons/ 下，按 bundleID 复用）。
    var appIconPath: String?
    /// 图片类条目的缩略图路径；非图片条目为 nil。
    var thumbnailPath: String?
    /// 捕获时间（去重合并时会被刷新为最新时间，实现"同内容置顶"）。
    var createdAt: Date
    /// 是否收藏。收藏条目独立小节展示，不受条数上限与 Clear History 约束。
    var favorite: Bool
    /// 收藏时间（取消收藏时置 nil）；收藏小节按此时间倒序。
    var favoriteAt: Date?
}

// MARK: - 捕获管线中间结构

/// 剪贴板上按单个 UTI 取出的原始字节。
///
/// 一次捕获可能得到多个 payload（同一内容的不同表示，如富文本 + 纯文本 + HTML），
/// 全部保留以便回写剪贴板时保真还原。
struct ClipboardPayload: Sendable, Equatable {
    /// 该字节数据对应的统一类型标识（UTI），如 "public.utf8-plain-text"。
    let uti: String
    /// 原始字节。大二进制（> BlobStore.inlineThreshold）在落库前会被移出为磁盘文件，
    /// 这里始终携带完整数据，是"捕获→存储"之间的传递载体。
    var data: Data
}

/// 捕获管线的最终产物：解析归一化完成、待写入数据库的内容。
///
/// 与 `ClipboardPayload` 的分工：payloads 是"原样字节"（回写剪贴板用），
/// identity/searchText/previewText 是"加工产物"（去重与 UI 用）。
struct CapturedContent: Sendable {
    /// 归类后的内容大类。
    var kind: ClipboardKind
    /// 去重/合并键（跨类型归一：纯文本变体共享同一 identity）。
    var identity: String
    /// 小写化搜索文本。
    var searchText: String
    /// 列表预览串。
    var previewText: String
    /// 全部原始表示，按捕获顺序排列（落库时 pos 列保序）。
    var payloads: [ClipboardPayload]
}
