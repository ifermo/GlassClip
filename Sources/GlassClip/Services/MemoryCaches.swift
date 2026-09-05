// MemoryCaches.swift — 列表渲染用的两个进程内内存缓存。
//
// 从 HistoryRow.swift 原样搬入（2026-09-05，③′ helper 提取组）：全局
// 可变 @MainActor 状态不该住在视图文件里——RichTextCache 的写入方是
// HistoryController.primeRichTextCache（Services 层），声明在被依赖的
// 一侧，视图文件只消费。
//
// 两个缓存的淘汰阈值刻意保持不一致（IconCache 200 / RichTextCache 100）：
// 统一阈值 = 改变淘汰时机 = 可观测差异，属行为变更，不在等价搬运范围内。

import AppKit
import Foundation

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

// MARK: - 富文本缓存

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
