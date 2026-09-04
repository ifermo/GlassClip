// PreviewPane.swift — 预览分栏：六种内容类型各自的完整预览。
//
// 结构：头部（类型 + 完整时间 · 来源应用）→ 内容区（按类型分发）→
// 脚注（总字节数 + 条目 id 前 8 位）。
//
// 数据流：payloads 由 .task(id: item.id) 在选中行变化时异步加载
// （可能涉及大文件从磁盘读回），加载完成前各预览组件以空态自洽。

import AppKit
import SwiftUI
import WebKit

/// 预览分栏根视图。
struct PreviewPane: View {
    /// 正在预览的条目。
    let item: ClipboardItem
    /// 数据层（读 payload）。
    @ObservedObject var controller: HistoryController

    /// 该条目的全部表示；.task(id:) 保证换行切换时重新加载。
    @State private var payloads: [StoredPayload] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().glassHairline
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().glassHairline
            footer
        }
        .task(id: item.id) {
            payloads = await controller.payloads(for: item)
        }
    }

    /// 头部：类型标签 + "完整时间戳 · 来源应用"。
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.kind.label)
                .font(.system(size: 12, weight: .semibold))
            Text(DateFormatting.full(item.createdAt) + (item.appName.map { " · \($0)" } ?? ""))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 按类型分发的预览内容。
    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            TextPreview(text: item.previewText)
        case .richText:
            RichTextPreview(payloads: payloads)
        case .html:
            HTMLPreview(payloads: payloads)
        case .image:
            ImagePreview(payloads: payloads)
        case .file:
            FilePreview(item: item)
        case .color:
            ColorPreview(hex: item.previewText)
        }
    }

    /// 脚注：所有表示的字节总和（等宽数字）+ 条目 id 前 8 位（弱标识，
    /// 便于对照数据库/排查）。
    private var footer: some View {
        HStack {
            Text(ByteFormatting.format(payloads.reduce(0) { $0 + ($1.data?.count ?? 0) }))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            Text(item.id.uuidString.prefix(8).uppercased())
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 纯文本

/// 可选中的滚动文本视图（previewText 截断上限 1 万字符，完整显示足够）。
private struct TextPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

// MARK: - 富文本

/// RTF 完整渲染：非编辑 NSTextView（NSScrollView 包裹）。
/// 有 RTF 表示按富文本渲染，否则退化为纯文本；背景透明融入玻璃面板。
private struct RichTextPreview: NSViewRepresentable {
    let payloads: [StoredPayload]

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if let attributed = payloads.attributedFromRTF {
            textView.textStorage?.setAttributedString(attributed)
            return
        }
        let plain = payloads.data(forUTI: UTI.plainText)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        textView.textStorage?.setAttributedString(NSAttributedString(string: plain, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
        ]))
    }
}

// MARK: - HTML

/// HTML 完整渲染：WKWebView + 注入的浅色/深色自适应 CSS。
///
/// - `setValue(false, forKey: "drawsBackground")`：WKWebView 的背景属性
///   在现代 SDK 已不可直接设值，用 KVC 打开透明背景以融入玻璃面板；
/// - `color-scheme: light dark` + `light-dark()`：页面配色跟随系统外观；
/// - baseURL 传 nil：纯字符串加载，无网络/相对资源解析。
private struct HTMLPreview: NSViewRepresentable {
    let payloads: [StoredPayload]

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let html = payloads.data(forUTI: UTI.html),
              let htmlString = String(data: html, encoding: .utf8)
        else { return }
        let css = """
        <style>
          :root { color-scheme: light dark; }
          body { font: -apple-system-body 12px -apple-system; margin: 10px;
                 background: transparent; color: light-dark(#1d1d1f, #f5f5f7); word-break: break-word; }
        </style>
        """
        let wrapped = "<html><head><meta charset='utf-8'>\(css)</head><body>\(htmlString)</body></html>"
        webView.loadHTMLString(wrapped, baseURL: nil)
    }
}

// MARK: - 图片

/// 图片预览：原图等比适配 + 下方尺寸标注；数据读不出给专用空态。
private struct ImagePreview: View {
    let payloads: [StoredPayload]

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        // 分母 max(...,1) 防零尺寸图除零。
                        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) px")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .padding(.bottom, 8)
            } else {
                EmptyStateView(title: "Image unavailable", subtitle: "The image data could not be loaded.")
            }
        }
        .padding(10)
        .onAppear(perform: loadImage)
        .onChange(of: payloads) { _, _ in loadImage() }
    }

    /// 取 PNG 表示解码（捕获层已统一归一化为 PNG，只需认一种）。
    private func loadImage() {
        guard let data = payloads.data(forUTI: UTI.png) else { return }
        image = NSImage(data: data)
    }
}

// MARK: - 文件

/// 文件列表预览：每行 = 图标 + 文件名 + 全路径；路径已不存在的行红色警示。
private struct FilePreview: View {
    let item: ClipboardItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(filePaths, id: \.self) { path in
                    fileRow(path)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 单个文件行。存在性实时查询（文件可能拷贝后已被移走/删除）。
    private func fileRow(_ path: String) -> some View {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let exists = FileManager.default.fileExists(atPath: path)
        return HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 红色路径 = 文件已不存在（视觉上直接告诉用户粘贴会失效）。
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(exists ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.red.opacity(0.7)))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    /// 从 searchText 反解路径列表：捕获时把"文件名 + 全路径"用空格拼进了
    /// searchText（供搜索），这里按"以 / 开头的 token"还原路径。
    /// 已知妥协：含空格的路径会被截断显示（identity/粘贴不受影响，
    /// 它们走 payload 的原始 file-url 数据）。
    private var filePaths: [String] {
        item.searchText
            .components(separatedBy: " ")
            .filter { $0.hasPrefix("/") }
    }
}

// MARK: - 颜色

/// 颜色预览：大色块 + hex 文本（可选中复制）+ 色彩模式标注（RGB/RGBA）。
private struct ColorPreview: View {
    /// 裸 hex（来自 previewText）。
    let hex: String

    private var color: NSColor? { NSColor.fromHex(hex) }

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.map(Color.init(nsColor:)) ?? Color.gray)
                .aspectRatio(1.6, contentMode: .fit)
                .swatchStroke(cornerRadius: 14)
                .padding(.horizontal, 14)
            Text("#\(hex)")
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .textSelection(.enabled)
            Text("HEX · \(hex.count == 6 ? "RGB" : "RGBA")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
