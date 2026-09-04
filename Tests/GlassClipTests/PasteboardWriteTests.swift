// PasteboardWriteTests.swift — 粘贴回写路径特征测试（阶段①′-2）。
//
// 边界说明：PasteboardIO.pasteboard 固定返回 NSPasteboard.general，不可注入，
// 因此本文件是**唯一**会用例期间替换系统剪贴板的测试组。每个用例先快照
// general 上全部可读类型，tearDown 前尽力还原（依赖 pasteboard server 的
// 类型无法逐字节还原，属已知限制）。GlassClip 未运行时跑这些用例才安全。
//
// 钉死的是"粘贴保真度"：表示顺序、自标记、纯文本降级、坏表示跳过、
// 空数据跳过、颜色必须走 writeObjects 否则别的应用读不出。
import AppKit
import XCTest

@testable import GlassClip

@MainActor
final class PasteboardWriteTests: XCTestCase {

    /// 用例开始前剪贴板上的快照（uti → 字节），用于结束时还原。
    private var snapshot: [(uti: String, data: Data)] = []

    override func setUpWithError() throws {
        snapshot = PasteboardIO.readEntries().map { ($0.uti, $0.data) }
    }

    override func tearDown() {
        // 尽力还原：清掉测试写入的内容，把快照逐类型写回，最后去掉自标记残留。
        let board = PasteboardIO.pasteboard
        board.clearContents()
        for entry in snapshot {
            _ = board.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.uti))
        }
        super.tearDown()
    }

    /// 读回 general 上当前的全部表示（顺序即 pasteboard 的类型顺序）。
    private func readBack() -> [PasteboardEntry] {
        PasteboardIO.readEntries()
    }

    /// 只保留本次真正写入的表示（保持相对顺序）。
    ///
    /// 实测事实（见 testPasteboardDerivesEquivalentTypes）：写 RTF/纯文本时
    /// pasteboard 服务器会额外派生等价类型（NeXT RTF、utf16-external、
    /// Carbon flavor、NSStringPboardType），自标记类型本身也在 readEntries
    /// 结果里。因此断言只能锚在"我们写的这些 UTI 的相对顺序与字节"上。
    private func ownEntries(_ utis: [String]) -> [PasteboardEntry] {
        let written = Set(utis)
        return readBack().filter { written.contains($0.uti) }
    }

    // MARK: - 保真度

    /// 全部可读表示按 pos 顺序写回，并带上自家标记类型。
    /// 顺序是粘贴保真的核心：接收方按类型优先级挑第一个能用的。
    func testCopyWritesAllRepresentationsInStoredOrder() async throws {
        let controller = makeIsolatedController()
        await controller.handleCapture(
            CapturedContent(kind: .richText, identity: "t:multi", searchText: "multi", previewText: "multi",
                            payloads: [ClipboardPayload(uti: UTI.rtf, data: Data("{\\rtf1}".utf8)),
                                       ClipboardPayload(uti: UTI.plainText, data: Data("multi".utf8))]),
            app: nil)
        let item = try XCTUnwrap(controller.items.first)

        await controller.copy(item)

        let entries = ownEntries([UTI.rtf, UTI.plainText])
        XCTAssertEqual(entries.map(\.uti), [UTI.rtf, UTI.plainText], "表示顺序必须与入库 pos 一致")
        XCTAssertEqual(entries.first?.data, Data("{\\rtf1}".utf8))
        XCTAssertEqual(entries.last?.data, Data("multi".utf8))
        XCTAssertTrue(PasteboardIO.containsSelfMarker(), "写回必须带自标记，否则粘贴会被当成新拷贝再记一次")
    }

    /// ⌘⇧V 纯文本粘贴：只保留纯文本表示，RTF/HTML 一律丢弃。
    func testCopyAsPlainTextKeepsOnlyPlainTextRepresentation() async throws {
        let controller = makeIsolatedController()
        await controller.handleCapture(
            CapturedContent(kind: .richText, identity: "t:plain", searchText: "plain", previewText: "plain",
                            payloads: [ClipboardPayload(uti: UTI.rtf, data: Data("{\\rtf1}".utf8)),
                                       ClipboardPayload(uti: UTI.plainText, data: Data("plain".utf8))]),
            app: nil)

        await controller.copy(try XCTUnwrap(controller.items.first), asPlainText: true)

        let entries = ownEntries([UTI.plainText, UTI.rtf])
        XCTAssertEqual(entries.map(\.uti), [UTI.plainText], "RTF 表示必须被丢弃")
        XCTAssertEqual(entries.first?.data, Data("plain".utf8))
    }

    /// 指向已丢失文件的表示：跳过该表示，其余照写（宁缺不崩）。
    func testCopySkipsRepresentationWhoseFileDisappeared() async throws {
        let blobs = makeSandboxBlobs()
        let controller = HistoryController(settings: makeIsolatedSettings(), blobs: blobs)
        let big = Data(repeating: 0x55, count: BlobStore.inlineThreshold + 8)
        await controller.handleCapture(
            CapturedContent(kind: .text, identity: "t:lost", searchText: "lost", previewText: "lost",
                            payloads: [ClipboardPayload(uti: UTI.plainText, data: big),
                                       ClipboardPayload(uti: UTI.html, data: Data("<i>x</i>".utf8))]),
            app: nil)
        let item = try XCTUnwrap(controller.items.first)
        let stored = await controller.payloads(for: item)
        let spilled = try XCTUnwrap(stored.first(where: { $0.filePath != nil })?.filePath)
        try FileManager.default.removeItem(atPath: spilled)

        await controller.copy(item)

        let entries = ownEntries([UTI.html, UTI.plainText])
        XCTAssertEqual(entries.map(\.uti), [UTI.html], "读不出字节的表示被静默跳过")
        XCTAssertEqual(entries.first?.data, Data("<i>x</i>".utf8))
    }

    /// 全部表示都读不出时：copy 直接 return，连 clearContents 都不执行——
    /// 用户当前剪贴板内容原样保留（这条一旦回退会毁掉用户正在拷的东西）。
    func testCopyWithNothingReadableLeavesPasteboardUntouched() async throws {
        let blobs = makeSandboxBlobs()
        let controller = HistoryController(settings: makeIsolatedSettings(), blobs: blobs)
        let big = Data(repeating: 0x66, count: BlobStore.inlineThreshold + 8)
        await controller.handleCapture(
            CapturedContent(kind: .text, identity: "t:alllost", searchText: "l", previewText: "l",
                            payloads: [ClipboardPayload(uti: UTI.plainText, data: big)]), app: nil)
        let item = try XCTUnwrap(controller.items.first)
        for path in await controller.payloads(for: item).compactMap(\.filePath) {
            try FileManager.default.removeItem(atPath: path)
        }

        let countBefore = PasteboardIO.changeCount()
        let typesBefore = PasteboardIO.pasteboard.types
        await controller.copy(item)

        XCTAssertEqual(PasteboardIO.changeCount(), countBefore, "剪贴板未被写过（changeCount 不变）")
        XCTAssertEqual(PasteboardIO.pasteboard.types, typesBefore)
    }

    // MARK: - 门面级细节

    /// 空字节表示不写入：NSPasteboard 上空 BLOB 会让接收方读到"存在但为空"的类型。
    func testWriteSkipsEmptyPayloads() {
        PasteboardIO.pasteboard.clearContents()
        PasteboardIO.write(payloads: [
            ClipboardPayload(uti: UTI.plainText, data: Data()),
            ClipboardPayload(uti: UTI.rtf, data: Data("{\\rtf1}".utf8)),
        ], marker: UUID())

        XCTAssertEqual(ownEntries([UTI.rtf, UTI.plainText]).map(\.uti), [UTI.rtf], "零长度表示应被跳过")
    }

    /// 自标记只在自家写入后存在：外部应用写的剪贴板不得被误判为自家而漏捕。
    func testSelfMarkerOnlyAfterOwnWrite() {
        let board = PasteboardIO.pasteboard
        board.clearContents()
        board.setString("from another app", forType: .string)
        XCTAssertFalse(PasteboardIO.containsSelfMarker())

        PasteboardIO.write(payloads: [ClipboardPayload(uti: UTI.plainText, data: Data("mine".utf8))], marker: UUID())
        XCTAssertTrue(PasteboardIO.containsSelfMarker())
    }

    /// 颜色必须经 NSColor 对象写入（writeObjects），直接 setData 归档字节
    /// 别的应用读不出颜色；读回侧 readColorEntry 走 secure coding 反归档。
    func testColorRepresentationRoundTripsAsObjectNotBytes() throws {
        let color = NSColor.systemOrange
        let archived = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)

        PasteboardIO.write(payloads: [ClipboardPayload(uti: UTI.color, data: archived)], marker: UUID())

        XCTAssertTrue(PasteboardIO.pasteboard.types?.contains(.color) ?? false,
                      "颜色应以 NSColor 对象形态出现在板上")
        let entry = try XCTUnwrap(PasteboardIO.readColorEntry(), "读回应拿到颜色表示")
        XCTAssertEqual(entry.uti, UTI.color)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: entry.data)
        XCTAssertEqual(decoded?.usingColorSpace(.sRGB), color.usingColorSpace(.sRGB))
    }

    // MARK: - 系统派生类型（防"1:1 假设"）

    /// 实测事实：写 2 个表示，板上出现 6 个类型。pasteboard 服务器会自动派生
    /// 等价类型（NeXT RTF、utf16-external-plain-text、Carbon flavor、
    /// NSStringPboardType），再加上自标记本身。
    ///
    /// 因此 readEntries() 的结果集 ≠ 写入集，任何"按写入类型反推板上类型"的
    /// 改动都会错。派生名单随 macOS 版本变化，这里只钉"派生发生了"这一事实。
    func testPasteboardDerivesEquivalentTypesBeyondThoseWritten() {
        let wrote = [UTI.plainText, UTI.rtf]
        PasteboardIO.write(payloads: [
            ClipboardPayload(uti: UTI.rtf, data: Data("{\\rtf1}".utf8)),
            ClipboardPayload(uti: UTI.plainText, data: Data("d".utf8)),
        ], marker: UUID())

        let onBoard = readBack().map(\.uti)
        XCTAssertEqual(Set(wrote).subtracting(onBoard), [], "写入的表示必须都还能读回")
        XCTAssertGreaterThan(onBoard.count, wrote.count + 1, "板上类型数 > 写入数 + 自标记（服务器有派生）")
    }
}
