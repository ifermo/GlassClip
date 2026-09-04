// HistoryRow.swift — 历史列表的单行视图与行级子组件。
//
// 行规格（设计共识）：44px 行高；左 = 类型图标/缩略图/色块（24px 域），
// 中 = 单行内容预览，右 = 悬停才出现的 ★ + 相对时间。
// 选中/悬停的底色都走 Color.primary 低透明度叠加——在玻璃材质上
// 浅色/深色模式自动成立，无需两套色值。
//
// 本文件还承载两个 @MainActor 内存缓存（IconCache / RichTextCache）：
// 列表每帧渲染几十行，磁盘读图与 RTF 解析必须走缓存。

import AppKit
import SwiftUI

// MARK: - 行视图

/// 一条历史记录的列表行。
struct HistoryRow: View {
    /// 展示的条目。
    let item: ClipboardItem
    /// 键盘/点击选中态（底色加深）。
    let isSelected: Bool
    /// ★ 点击回调（收藏/取消收藏）。
    let onToggleFavorite: () -> Void

    /// 悬停态（★ 显隐与浅底色的驱动）。
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            leadingView
                .frame(width: 24, height: 24)
            middleView
            Spacer(minLength: 4)
            // ★：已收藏的行常显，未收藏的行悬停才出现（设计共识"悬停 ★"）。
            if item.favorite || isHovered {
                Button(action: onToggleFavorite) {
                    Image(systemName: item.favorite ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(item.favorite ? Color.yellow.opacity(0.9) : Color.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            // 相对时间：等宽数字避免行间跳动。
            Text(RelativeTime.format(item.createdAt))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        // 让整行（含空白区）都可点击/悬停，而不只是有内容的子视图。
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.panelQuick) { isHovered = hovering }
        }
    }

    // MARK: 左侧标识

    /// 左侧 24px 标识位：图片 → 缩略图；颜色 → 色块；其余 → 应用图标
    /// （无图标缓存时退回 SF Symbol）。
    @ViewBuilder
    private var leadingView: some View {
        switch item.kind {
        case .image:
            ThumbnailView(path: item.thumbnailPath)
        case .color:
            // 色块内容来自 previewText（捕获时存的就是裸 hex）；
            // 解析失败退回系统强调色，绝不显示成黑色方块。
            let hex = item.previewText
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: NSColor.fromHex(hex) ?? .controlAccentColor))
                .swatchStroke(cornerRadius: 5)
        default:
            AppIconView(path: item.appIconPath, kind: item.kind)
        }
    }

    // MARK: 中间预览

    /// 中间单行预览：富文本走专门渲染（保留格式痕迹），文件名中间截断，
    /// 图片显示来源应用名，其余显示 previewText（换行折叠为空格）。
    @ViewBuilder
    private var middleView: some View {
        switch item.kind {
        case .richText:
            RichTextLine(itemID: item.id, previewText: item.previewText)
        case .color:
            Text(item.previewText)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        case .file:
            Text(item.previewText)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
        case .image:
            Text(item.appName ?? "Image")
                .font(.system(size: 13))
                .lineLimit(1)
        default:
            Text(item.previewText.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 13))
                .lineLimit(1)
        }
    }
}

// MARK: - 应用图标

/// 来源应用图标：Icons/ 缓存命中显示真图标，否则按类型给 SF Symbol 占位。
private struct AppIconView: View {
    let path: String?
    let kind: ClipboardKind

    var body: some View {
        if let path, let image = IconCache.image(at: path) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    /// 无图标时的类型符号（文本/富文本/HTML 各有辨识度）。
    private var symbol: String {
        switch kind {
        case .text: "doc.plaintext"
        case .richText: "doc.richtext"
        case .html: "curlybraces.square"
        default: "doc"
        }
    }
}

// MARK: - 图片缓存

/// 路径 → NSImage 的进程内缓存（列表滚动时避免反复磁盘解码）。
///
/// 淘汰策略刻意简单：超过 200 张整体清空（下次按需重读）。
/// 剪贴板工具的生命周期内这个量级完全够用，不值得引入 LRU。
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    /// 取缓存图；未命中读盘并入缓存，读盘失败返回 nil（调用方走占位图）。
    static func image(at path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[path] = image
        return image
    }
}

// MARK: - 缩略图

/// 图片条目的缩略图（32px 圆角，描边让浅色图在玻璃上可辨）。
private struct ThumbnailView: View {
    let path: String?

    var body: some View {
        if let path, let image = IconCache.image(at: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
        } else {
            Image(systemName: "photo")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 富文本行

/// 富文本条目的单行预览：用 NSTextField（AppKit label）渲染富文本属性串，
/// 能带出字重/颜色等格式痕迹；SwiftUI Text 对 NSAttributedString 支持不足。
private struct RichTextLine: NSViewRepresentable {
    let itemID: UUID
    let previewText: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 13)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = RichTextCache.attributedString(itemID: itemID, fallback: previewText)
    }
}

/// 富文本解析结果缓存（UUID → NSAttributedString）。
///
/// 写入时机：HistoryController.primeRichTextCache 预热最近 60 条。
/// 未命中时退化为纯文本 fallback（不现场解析 RTF——那会卡滚动）。
@MainActor
enum RichTextCache {
    private static var cache: [UUID: NSAttributedString] = [:]

    /// 取缓存富文本；未命中返回换行折叠后的纯文本串。
    static func attributedString(itemID: UUID, fallback: String) -> NSAttributedString {
        if let cached = cache[itemID] { return cached }
        return NSAttributedString(string: fallback.replacingOccurrences(of: "\n", with: " "))
    }

    /// 写入缓存；超 100 条整体清空（与 IconCache 同款简单淘汰）。
    static func prime(_ itemID: UUID, _ attributed: NSAttributedString) {
        if cache.count > 100 { cache.removeAll() }
        cache[itemID] = attributed
    }
}
