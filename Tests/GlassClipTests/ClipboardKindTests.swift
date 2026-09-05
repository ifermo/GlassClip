// ClipboardKindTests.swift — kind → 行表现映射的契约（label / fallbackSymbol）。
//
// 两个映射收口进 ClipboardKind 后，值就是展示协议的一部分：漂移会直接
// 改变列表占位图标与预览头文案。逐类钉住（T2 等价替换的补钉）。
import XCTest

@testable import GlassClip

final class ClipboardKindTests: XCTestCase {

    func testLabelsMatchLegacyCopy() {
        XCTAssertEqual(ClipboardKind.text.label, "Text")
        XCTAssertEqual(ClipboardKind.richText.label, "Rich Text")
        XCTAssertEqual(ClipboardKind.html.label, "HTML")
        XCTAssertEqual(ClipboardKind.image.label, "Image")
        XCTAssertEqual(ClipboardKind.file.label, "File")
        XCTAssertEqual(ClipboardKind.color.label, "Color")
    }

    func testFallbackSymbolsMatchLegacyMapping() {
        XCTAssertEqual(ClipboardKind.text.fallbackSymbol, "doc.plaintext")
        XCTAssertEqual(ClipboardKind.richText.fallbackSymbol, "doc.richtext")
        XCTAssertEqual(ClipboardKind.html.fallbackSymbol, "curlybraces.square")
        // 三类非文本行各有专属标识视图，不走占位路径；值沿用历史 default 分支。
        XCTAssertEqual(ClipboardKind.image.fallbackSymbol, "doc")
        XCTAssertEqual(ClipboardKind.file.fallbackSymbol, "doc")
        XCTAssertEqual(ClipboardKind.color.fallbackSymbol, "doc")
    }
}
