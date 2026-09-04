// ClipboardCaptureTests.swift — 捕获解析核心的纯函数回归测试。
//
// 策略：直接给 ClipboardCapture.capture 喂 (UTI, Data) fixture，
// 不触碰系统剪贴板（无头、确定性）。锁定六类内容的解析正确性、
// identity 去重键的跨表示归一（"纯文本变体合并"的机制基础）、
// 大小护栏与 HTML 剥标签。同文件还包含 ColorHexTests（hex 互转）
// 与 RelativeTimeTests（相对时间阶梯，注入固定 now）。

import AppKit
import XCTest
@testable import GlassClip

final class ClipboardCaptureTests: XCTestCase {
    /// 纯文本基线路径：kind/identity/preview 全部符合预期。
    func testPlainTextCapture() {
        let content = ClipboardCapture.capture(
            from: [PasteboardEntry(uti: UTI.plainText, data: Data("hello world".utf8))],
            app: nil
        )
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.kind, .text)
        XCTAssertEqual(content?.identity, "t:hello world")
        XCTAssertEqual(content?.previewText, "hello world")
        XCTAssertEqual(content?.payloads.first?.uti, UTI.plainText)
    }

    /// RTF 捕获：类型判为富文本；identity 从 RTF 提取的可见文本生成；
    /// payload 必须同时含 RTF 原文与派生纯文本（粘贴兼容面）。
    func testRichTextCapturesPlainFallback() {
        let attributed = NSAttributedString(string: "Bold move", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try! attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let content = ClipboardCapture.capture(from: [
            PasteboardEntry(uti: UTI.rtf, data: rtf),
            PasteboardEntry(uti: UTI.plainText, data: Data("Bold move".utf8)),
        ], app: nil)
        XCTAssertEqual(content?.kind, .richText)
        XCTAssertEqual(content?.identity, "t:Bold move")
        let utis = content?.payloads.map(\.uti)
        XCTAssertEqual(utis?.contains(UTI.rtf), true)
        XCTAssertEqual(utis?.contains(UTI.plainText), true)
    }

    /// HTML 捕获：identity/搜索用剥标签后的可见文本，
    /// 实体（&amp;）必须被正确解码——否则同文本搜不到。
    func testHTMLStripsTagsForIdentity() {
        let html = "<b>Hello</b> &amp; <i>world</i>"
        let content = ClipboardCapture.capture(from: [
            PasteboardEntry(uti: UTI.html, data: Data(html.utf8)),
            PasteboardEntry(uti: UTI.plainText, data: Data("Hello & world".utf8)),
        ], app: nil)
        XCTAssertEqual(content?.kind, .html)
        XCTAssertEqual(content?.identity, "t:Hello & world")
        XCTAssertEqual(content?.searchText, "Hello & world")
    }

    /// 核心去重语义（设计共识"纯文本变体也合并"）：同一段文字以纯文本
    /// 与 RTF 两种形态分别捕获，identity 必须一致——合并置顶的机制基础。
    func testSamePlainContentAcrossKindsSharesIdentity() {
        let plain = ClipboardCapture.capture(from: [PasteboardEntry(uti: UTI.plainText, data: Data("shared".utf8))], app: nil)
        let attributed = NSAttributedString(string: "shared")
        let rtf = try! attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rich = ClipboardCapture.capture(from: [PasteboardEntry(uti: UTI.rtf, data: rtf)], app: nil)
        XCTAssertEqual(plain?.identity, rich?.identity)
    }

    /// 图片身份稳定性：同一张图以 PNG 与 TIFF 两种表示捕获，
    /// PNG 归一化后哈希必须一致（identity 相同）——
    /// TIFF 的拷贝不会另起一条记录。
    func testImageIdentityStableAndPNGNormalized() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let fromPNG = ClipboardCapture.capture(from: [PasteboardEntry(uti: UTI.png, data: png)], app: nil)
        let fromTIFF = ClipboardCapture.capture(from: [PasteboardEntry(uti: UTI.tiff, data: tiff)], app: nil)
        XCTAssertEqual(fromPNG?.kind, .image)
        XCTAssertEqual(fromPNG?.identity, fromTIFF?.identity, "TIFF must normalize to the same identity as PNG")
        XCTAssertTrue(fromPNG?.identity.hasPrefix("i:") ?? false)
    }

    /// 文件 URL 捕获：类型/预览（文件名）/搜索域（含文件名）逐项验证。
    func testFileURLCapture() throws {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let content = ClipboardCapture.capture(from: [PasteboardEntry(uti: UTI.fileURL, data: url.dataRepresentation)], app: nil)
        XCTAssertEqual(content?.kind, .file)
        XCTAssertEqual(content?.identity, "f:/tmp/report.pdf")
        XCTAssertEqual(content?.previewText, "report.pdf")
        XCTAssertTrue(content?.searchText.contains("report.pdf") ?? false)
        XCTAssertEqual(content?.payloads.count, 1)
    }

    /// 颜色捕获：NSColor 归档字节 → sRGB hex（#FF8000）；
    /// payload 双表示（原始颜色 + 纯文本 "#hex"）。
    func testColorCaptureAndHex() throws {
        let color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        let data = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        let content = ClipboardCapture.capture(from: [PasteboardEntry(uti: "NSColor", data: data)], app: nil)
        XCTAssertEqual(content?.kind, .color)
        XCTAssertEqual(content?.identity, "c:FF8000")
        XCTAssertEqual(content?.previewText, "#FF8000")
        XCTAssertEqual(content?.payloads.count, 2)
        // 刻意写裸字面量而非 UTI.plainText：钉的是值本身，不是常量引用。
        XCTAssertEqual(content?.payloads[1].uti, "public.utf8-plain-text")
        XCTAssertEqual(content?.payloads[1].data, Data("#FF8000".utf8))
    }

    /// 大小护栏：空输入（无条目/全空字节）与超限（>100MB）都必须返回 nil
    /// ——空剪贴板不记录，超大拷贝不拖垮存储。
    func testEmptyAndOversizedInputRejected() {
        XCTAssertNil(ClipboardCapture.capture(from: [], app: nil))
        XCTAssertNil(ClipboardCapture.capture(from: [PasteboardEntry(uti: UTI.plainText, data: Data())], app: nil))
        let huge = ClipboardCapture.maxPayloadSize + 1
        XCTAssertNil(ClipboardCapture.capture(
            from: [PasteboardEntry(uti: UTI.plainText, data: Data(count: huge))],
            app: nil
        ))
    }

    /// stripTags 的精确行为：块级标签换行、实体解码、首尾去空白。
    /// 期望值 "a<b\n  c"：&lt; → <，</p> → \n，&nbsp; → 空格（未 trim 中段）。
    func testStripTagsEntities() {
        XCTAssertEqual(ClipboardCapture.stripTags("<p>a&lt;b</p> &nbsp;c"), "a<b\n  c")
    }
}

/// NSColor ↔ hex 互转：6 位往返、# 前缀容忍、8 位（含 alpha）解析时
/// alpha 不进入 hex 输出、非法输入一律 nil。
final class ColorHexTests: XCTestCase {
    func testRoundTrip() throws {
        let color = try XCTUnwrap(NSColor.fromHex("3366CC"))
        XCTAssertEqual(color.srgbHex, "3366CC")
        XCTAssertEqual(NSColor.fromHex("#FF0000")?.srgbHex, "FF0000")
        XCTAssertEqual(NSColor.fromHex("FF000080")?.srgbHex, "FF0000")
    }

    func testInvalidHexRejected() {
        XCTAssertNil(NSColor.fromHex("XYZ"))
        XCTAssertNil(NSColor.fromHex("12345"))
    }
}

/// 相对时间阶梯：now/分钟/小时/Yesterday/天数 各档边界（注入固定 now，
/// 不受测试运行时刻影响）。
final class RelativeTimeTests: XCTestCase {
    func testBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RelativeTime.format(now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(RelativeTime.format(now.addingTimeInterval(-5 * 60), now: now), "5m")
        XCTAssertEqual(RelativeTime.format(now.addingTimeInterval(-3 * 3600), now: now), "3h")
        XCTAssertEqual(RelativeTime.format(now.addingTimeInterval(-1 * 86_400), now: now), "Yesterday")
        XCTAssertEqual(RelativeTime.format(now.addingTimeInterval(-5 * 86_400), now: now), "5d")
    }
}
