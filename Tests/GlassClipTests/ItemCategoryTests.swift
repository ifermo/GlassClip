// ItemCategoryTests.swift — 派生分类判定的规则矩阵。
//
// 分类是过滤时实时派生（不入库），判定正确性全靠这份矩阵钉住：
// JSON 严格解析（对象/数组限定、标量排除、语法错误落回文本、超大跳过）、
// 链接整段单 URL（http/https 限定、无 scheme 不猜、夹字不算）、
// 互斥分区（Text 不含 JSON/链接）、文本族三类 kind 都参与判定、
// file/color 恒不分类。
import XCTest

@testable import GlassClip

final class ItemCategoryTests: XCTestCase {


    // MARK: - JSON

    func testJSONObjectAndArrayAreJSON() {
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "{\"a\": 1}")), .json)
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "[1, 2, 3]")), .json)
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "  \n {\"key\": [true, null]} \t ")), .json,
                       "首尾空白被容忍")
    }

    func testMalformedAndScalarJSONFallBackToText() {
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "{\"a\": ")), .text, "语法错误 → 文本")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "{\"a\":1} trailing")), .text, "尾随垃圾 → 文本")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "[1,2")), .text)
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "42")), .text, "JSON 标量不算")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "\"just a string\"")), .text)
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "true")), .text)
    }

    func testOversizedJSONSkipsParsing() {
        let big = "{\"pad\":\"" + String(repeating: "x", count: ItemCategory.maxJSONParseLength) + "\"}"
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: big)), .text, "超上限不解析 → 文本")
    }

    // MARK: - 链接

    func testBareHTTPSAreLinks() {
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "https://example.com")), .link)
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "http://example.com/a/b?q=1#frag")), .link)
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "  https://example.com  ")), .link,
                       "首尾空白被容忍")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "HTTPS://Example.com/Path")), .link,
                       "scheme 大小写不敏感")
    }

    func testNonLinksStayText() {
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "ftp://example.com")), .text, "仅 http/https")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "www.example.com")), .text, "无 scheme 不猜")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "see https://example.com now")), .text,
                       "夹在文字里不算")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "https://example.com/a\nhttps://b.com")), .text,
                       "两个 URL 不算")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "https://")), .text, "无 host")
    }

    // MARK: - 互斥分区与作用域

    func testPlainTextIsTextCategory() {
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .text, searchText: "hello world")), .text)
    }

    func testWholeTextFamilyIsClassifiedByVisibleText() {
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .richText, searchText: "https://example.com")), .link,
                       "富文本条目的可见文本是 URL 也算链接（浏览器复制落地为 richText/html）")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .html, searchText: "{\"a\":1}")), .json,
                       "HTML 条目的可见文本是 JSON 也算")
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .richText, searchText: "notes")), .text)
    }

    func testImageClassifiesAsImageAndFileColorStayUnclassified() {
        XCTAssertEqual(ItemCategory.classify(makeClipboardItem(kind: .image, searchText: "image")), .image)
        XCTAssertNil(ItemCategory.classify(makeClipboardItem(kind: .file, searchText: "/tmp/a.txt")), "文件不属于任何分类，只在 All 出现")
        XCTAssertNil(ItemCategory.classify(makeClipboardItem(kind: .color, searchText: "#FF0000 color")))
    }

    // MARK: - 展示与轮换

    func testItemLabelOnlyOverridesJSONAndLink() {
        XCTAssertEqual(ItemCategory.json.itemLabel, "JSON")
        XCTAssertEqual(ItemCategory.link.itemLabel, "Link")
        XCTAssertNil(ItemCategory.text.itemLabel, "文本/图片沿用 kind 标签")
        XCTAssertNil(ItemCategory.image.itemLabel)
    }

    func testChipTitlesFollowDeclarationOrder() {
        XCTAssertEqual(ItemCategory.allCases.map(\.title), ["JSON", "Text", "Links", "Images"],
                       "chip 顺序 = 声明顺序 = Tab 轮换顺序")
    }

    func testTabCycleCoversNilRoundTrip() {
        XCTAssertEqual(ItemCategory.next(after: nil), .json)
        XCTAssertEqual(ItemCategory.next(after: .json), .text)
        XCTAssertEqual(ItemCategory.next(after: .text), .link)
        XCTAssertEqual(ItemCategory.next(after: .link), .image)
        XCTAssertNil(ItemCategory.next(after: .image), "图片之后回到无分类（循环清空）")
    }
}
