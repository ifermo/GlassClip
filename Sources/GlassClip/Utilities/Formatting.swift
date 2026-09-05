// Formatting.swift — 格式化与轻量样式工具集。
//
// 五个互相独立的部分：
// - NSColor ↔ HEX 字符串互转（颜色捕获/预览用）；
// - RelativeTime：历史行的相对时间（"15m"/"Yesterday"）；
// - DateFormatting：预览头的完整时间戳；
// - ByteFormatting：预览脚注的字节大小；
// - Divider/Animation 的玻璃面板样式小助手。
//
// 本文件刻意零状态化（除缓存的 formatter），全部纯函数，随处可用。

import AppKit
import Foundation
import SwiftUI

// MARK: - 位图 → PNG

extension NSBitmapImageRep {
    /// 编码为 PNG 字节。
    var pngData: Data? { representation(using: .png, properties: [:]) }
}

extension NSImage {
    /// 经 TIFF 中转拿到位图表示再编码为 PNG；解不出位图表示时返回 nil。
    ///
    /// 三处生产点（图片缩略图、来源应用图标、捕获层归一化）原本各写一遍
    /// 这条三步链，API 调用序列逐字相同。
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.pngData
    }
}

// MARK: - 颜色 ↔ HEX

extension NSColor {
    /// 转成 sRGB 空间后的 "RRGGBB" 大写十六进制（不含 alpha）。
    ///
    /// 先 `usingColorSpace(.sRGB)` 是关键：颜色捕获可能拿到 Display P3
    /// 等任意空间的 NSColor，不转换就直接读分量会得到错误的视觉值。
    /// 转换失败（极少见）返回 nil。
    var srgbHex: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "%02X%02X%02X",
            Int(round(srgb.redComponent * 255)),
            Int(round(srgb.greenComponent * 255)),
            Int(round(srgb.blueComponent * 255))
        )
    }

    /// 解析十六进制字符串为颜色；非法输入返回 nil。
    ///
    /// 接受 6 位（RRGGBB，alpha=1）或 8 位（RRGGBBAA），可带 # 前缀与
    /// 首尾空白。刻意不支持 3 位缩写：本项目写入的 hex 永远来自
    /// `srgbHex`（6 位）或用户手输（6/8 位），窄解析 = 早暴露坏数据。
    static func fromHex(_ hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let scalar = UInt64(value, radix: 16) else { return nil }
        if value.count == 8 {
            return NSColor(
                srgbRed: CGFloat((scalar >> 24) & 0xFF) / 255,
                green: CGFloat((scalar >> 16) & 0xFF) / 255,
                blue: CGFloat((scalar >> 8) & 0xFF) / 255,
                alpha: CGFloat(scalar & 0xFF) / 255
            )
        }
        return NSColor(
            srgbRed: CGFloat((scalar >> 16) & 0xFF) / 255,
            green: CGFloat((scalar >> 8) & 0xFF) / 255,
            blue: CGFloat(scalar & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 相对时间

/// 历史行右侧的相对时间标签："now" → "15m" → "3h" → "2d" → "Yesterday"
/// → 日期 → 带年份日期（跨年）。
enum RelativeTime {
    // DateFormatter 构造成本高，而 format 每个历史行都要跑一次，
    // 因此两个 formatter 缓存为常量。它们只被用于只读的 string(from:)，
    // 该用法在现代 macOS 上是线程安全的。
    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// 把时间点格式化为人类可读的相对标签。
    ///
    /// - Parameters:
    ///   - date: 目标时间。
    ///   - now: 参照"当前时间"，参数化以便测试注入固定时钟。
    /// 阶梯：<1min "now"（含负值——时钟偏差时 date 在 now 之后，seconds
    /// 为负，落进同一桶，不显示负数）；<1h 分钟；<24h 小时；<7天 天数
    /// （恰好 1 天显示 "Yesterday"）；<330 天显示 "MMM d"；更老加年份。
    static func format(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400:
            let hours = Int(seconds / 3600)
            return "\(hours)h"
        case ..<(7 * 86_400):
            let days = Int(seconds / 86_400)
            return days == 1 ? "Yesterday" : "\(days)d"
        default:
            return (seconds < 330 * 86_400 ? shortDate : fullDate).string(from: date)
        }
    }
}

// MARK: - 完整时间戳

/// 预览分栏头部用的完整时间（中等日期 + 短时间，本地化格式）。
enum DateFormatting {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func full(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - 字节大小

/// 字节量的三档人类可读格式：B / KB（1 位小数）/ MB（1 位小数）。
/// 预览脚注显示条目总大小用；大于 1GB 的条目在捕获层就被拦了。
enum ByteFormatting {
    static func format(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - View style helpers

extension Divider {
    /// 玻璃面板上的发丝分隔线：Divider 本体在半透明材质上几乎不可见，
    /// 叠一层 8% 主色的 overlay 让它在浅色/深色玻璃上都能读出来。
    var glassHairline: some View {
        overlay(Color.primary.opacity(0.08))
    }
}

extension View {
    /// 面板材质双路径：macOS 26+ 走 Liquid Glass（glassEffect 一并承担
    /// 材质、高光与外观形状），14/15 走 ultraThinMaterial fallback。
    /// 两路共用调用方传入的同一 shape，圆角/裁切一致性不因分支分裂；
    /// 选中/悬停的 primary 低透明叠加在两种材质上都自动成立。
    ///
    /// 14 路径无法在 26 真机上运行时验证（无 macOS 模拟器），保持极简、
    /// 不做盲调装饰；后续如有 14 实机目测再谈精修。
    @ViewBuilder
    func panelMaterial(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension Animation {
    /// 预览分栏显隐动画的统一时长与曲线：Space/右键菜单/Esc 三个入口
    /// 共用同一 Animation 常量，保证转场手感完全一致。
    static let previewToggle = Animation.easeOut(duration: 0.12)

    /// 面板内轻量状态过渡（选中行的滚动跟随、行的悬停高亮）：0.1s 一档。
    ///
    /// 两处刻意共用：改这一个常量会同时改变滚动与悬停的手感——
    /// 它们同属"面板对自己的一小步反馈"，分开调会让同一面板出现两种节奏。
    static let panelQuick = Animation.easeOut(duration: 0.1)
}
