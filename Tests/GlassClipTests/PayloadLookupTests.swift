// PayloadLookupTests.swift — ③′-b 新增抽象的行为钉子（Q5b：新抽象必须就地可测）。
//
// 覆盖三个收口点各自的语义边界：
// - [StoredPayload].data(forUTI:)：first 命中、缺表示与读盘失败都归 nil；
// - [StoredPayload].attributedFromRTF：解析成功/无 RTF 两条路径；
// - NSImage.pngData：与收口前那条三步链逐字节相同。

import AppKit
import XCTest

@testable import GlassClip

final class PayloadLookupTests: XCTestCase {
    private func payload(_ uti: String, _ text: String) -> StoredPayload {
        StoredPayload(uti: uti, inline: Data(text.utf8), filePath: nil)
    }

    /// 命中即返回该 UTI 的字节；没有该表示返回 nil。
    func testReturnsBytesForMatchingUTI() throws {
        let payloads = [payload(UTI.rtf, "rtf-bytes"), payload(UTI.plainText, "plain")]
        XCTAssertEqual(payloads.data(forUTI: UTI.plainText), Data("plain".utf8))
        XCTAssertNil(payloads.data(forUTI: UTI.html))
    }

    /// 同一 UTI 重复出现时取先出现的那个——收口前用的是 first(where:)，
    /// 换成 firstIndex/last 都会悄悄改变粘贴回写的内容。
    func testFirstMatchWinsWhenUTIRepeated() {
        let payloads = [payload(UTI.plainText, "first"), payload(UTI.plainText, "second")]
        XCTAssertEqual(payloads.data(forUTI: UTI.plainText), Data("first".utf8))
    }

    /// 大 payload 走磁盘：文件读不出（被外部清理）与"没有该表示"同样返回 nil，
    /// 调用方（copy/预览）本来就只区分 nil 与非 nil。
    func testUnreadableFilePathYieldsNil() {
        let missing = StoredPayload(uti: UTI.png, inline: nil, filePath: "/nonexistent/glassclip-\(UUID().uuidString)")
        XCTAssertEqual([missing].data(forUTI: UTI.png), nil)
    }

    /// 空序列不能崩。
    func testEmptySequence() {
        XCTAssertNil([StoredPayload]().data(forUTI: UTI.rtf))
        XCTAssertNil([StoredPayload]().attributedFromRTF)
    }

    /// RTF 解析：给出真实 RTF 时应能取出可见文本。
    func testAttributedFromRTFParses() throws {
        let attributed = NSAttributedString(
            string: "Rich hello",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )
        let rtf = try XCTUnwrap(
            attributed.data(from: NSRange(location: 0, length: attributed.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        )
        let payloads = [StoredPayload(uti: UTI.rtf, inline: rtf, filePath: nil)]
        XCTAssertEqual(payloads.attributedFromRTF?.string, "Rich hello")
    }

    /// 无 RTF 表示时返回 nil（调用方据此回落到纯文本渲染）。
    func testAttributedFromRTFNilWithoutRTF() {
        XCTAssertNil([payload(UTI.plainText, "plain")].attributedFromRTF)
    }

    /// RTF 字节损坏时不崩、返回 nil。
    func testAttributedFromRTFNilOnGarbage() {
        let payloads = [StoredPayload(uti: UTI.rtf, inline: Data([0x00, 0x01, 0x02]), filePath: nil)]
        XCTAssertNil(payloads.attributedFromRTF)
    }
}

/// PNG 编码收口的等价性证明：结果字节必须与收口前三步链完全相同。
final class PNGEncodingTests: XCTestCase {
    private func swatchImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        return image
    }

    func testNSImagePNGDataEqualsLegacyChain() throws {
        let image = swatchImage()
        let legacy = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:])
        )
        let current = try XCTUnwrap(image.pngData)
        XCTAssertEqual(current, legacy, "PNG 字节必须与收口前逐字节相同")
        XCTAssertEqual(current.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "PNG 签名")
        XCTAssertNotNil(NSImage(data: current), "产出必须可解码")
    }
}
