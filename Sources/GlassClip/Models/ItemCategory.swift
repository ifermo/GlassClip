// ItemCategory.swift — 面板分类过滤的四个分类（实时派生，不入库）。
//
// 与 ClipboardKind 的分工：kind 是捕获管线写进库的内容大类（决定行图标
// 与预览策略）；分类是 UI 过滤维度的派生属性——同一份 JSON 在 kind 上是
// .text，在分类上归 JSON。派生而非入库（设计共识）：全部历史条目立即
// 生效，捕获管线与库零改动。
//
// 判定输入是 searchText：文本族三个 kind 的 searchText 都持有全文可见
// 文本（.text 全文、.html 的 plain??剥标签、.richText 可见文本）。

import Foundation

/// 面板分类过滤的四个分类。声明顺序 = chip 顺序 = Tab 轮换顺序。
enum ItemCategory: String, CaseIterable, Identifiable {
    case json
    case text
    case link
    case image

    var id: String { rawValue }

    /// 分类 chip 标题（UI 英文；分类级用复数）。
    var title: String {
        switch self {
        case .json: "JSON"
        case .text: "Text"
        case .link: "Links"
        case .image: "Images"
        }
    }

    /// 条目级预览标签；nil = 沿用 kind.label（文本/图片类的分类与 kind 标签一致）。
    var itemLabel: String? {
        switch self {
        case .json: "JSON"
        case .link: "Link"
        case .text, .image: nil
        }
    }

    /// Tab 键轮换：无分类 → json → text → link → image → 无分类（循环）。
    static func next(after current: ItemCategory?) -> ItemCategory? {
        guard let current else { return allCases.first }
        guard let index = allCases.firstIndex(of: current), index + 1 < allCases.count else { return nil }
        return allCases[index + 1]
    }

    // MARK: - 判定

    /// JSON 解析尝试的字节上限：超过即按文本处理（防大文本拖慢每次过滤）。
    static let maxJSONParseLength = 1_048_576

    /// 条目归入的分类；nil = 不属于任何分类（file/color 只在 All 出现）。
    ///
    /// 互斥分区（设计共识）：文本族先试 JSON、再试链接，都未命中才算
    /// 文本——"文本"分类不含 JSON/链接条目。
    static func classify(_ item: ClipboardItem) -> ItemCategory? {
        switch item.kind {
        case .image:
            return .image
        case .text, .richText, .html:
            if isJSON(item.searchText) { return .json }
            if isLink(item.searchText) { return .link }
            return .text
        case .file, .color:
            return nil
        }
    }

    /// JSON 判定：去首尾空白后必须以 { 或 [ 开头（标量不算），且
    /// JSONSerialization 严格解析通过——不传 .fragmentsAllowed，顶层标量
    /// 与尾随垃圾默认即被拒绝，语法错误的"疑似 JSON"落回文本。
    static func isJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return false }
        guard trimmed.utf8.count <= maxJSONParseLength else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
    }

    /// 链接判定：去首尾空白后整段文本恰好是一个 URL（中间不得有空白），
    /// scheme 仅 http/https，host 非空。无 scheme 的 www.… 不猜；
    /// file:// 属于 File kind，本就不进文本族。
    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }
}
