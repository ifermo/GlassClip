// HistoryControllerCaptureTests.swift — 数据层捕获/合并/清理语义特征测试（阶段①′-2）。
//
// 目的：拆分 HistoryController（采集摄取 / 历史存储 / 图像渲染三块）之前，
// 把它当前的实际表现钉死。它是全应用唯一的写路径，此前零测试。
//
// 手法：直接 await handleCapture(...) 驱动摄取——绕开 0.4s 轮询与启动摄取，
// 不触发 monitor.start()（该定时器无 stop，测试进程里会一直滴答）。
// 持久化断言一律另开 HistoryDatabase 读回同一沙箱库文件，因此不依赖 start()。
//
// 已知缺陷按 testCurrentBehavior_ 前缀断言其存在（见文件末尾两条）。
import AppKit
import XCTest

@testable import GlassClip

@MainActor
final class HistoryControllerCaptureTests: XCTestCase {

    /// 沙箱落盘层（同一用例内可复用给第二个 controller）。
    private lazy var blobs: BlobStore = makeSandboxBlobs()

    /// 构造一个指向沙箱的数据层（不调 start()，因此不起轮询、不读真实剪贴板）。
    private func makeController(limit: Int? = nil, sensitive: [String]? = nil) -> HistoryController {
        let settings = makeIsolatedSettings()
        if let limit { settings.historyLimit = limit }
        if let sensitive { settings.sensitiveApps = sensitive }
        return HistoryController(settings: settings, blobs: blobs)
    }

    /// 纯文本捕获内容（identity 规则与捕获管线一致：t: 前缀）。
    private func textContent(_ string: String, identity: String = "t:seed", utis: [String] = [UTI.plainText]) -> CapturedContent {
        CapturedContent(
            kind: .text,
            identity: identity,
            searchText: string.lowercased(),
            previewText: string,
            payloads: utis.map { ClipboardPayload(uti: $0, data: Data(string.utf8)) }
        )
        .withKind(utis.contains(UTI.rtf) ? .richText : (utis.contains(UTI.html) ? .html : .text))
    }

    /// 生成可被 NSImage 解码的合法 PNG（缩略图/图像捕获路径需要真实图像字节）。
    private func makePNGData(width: Int = 8, height: Int = 8) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation, "无法生成 TIFF")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff), "TIFF 无法回读为 bitmap")
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]), "无法编码 PNG")
    }

    /// 直接从沙箱库文件读回（证明写路径真的落库，且不经过内存列表）。
    private func reloadPayloads(_ id: UUID) async throws -> [StoredPayload] {
        let db = try HistoryDatabase(location: blobs.databaseURL)
        return try await db.payloads(for: id)
    }

    // MARK: - 新建路径

    /// 首次捕获：插入为最新一条、落库、payload 按传入顺序保序。
    func testFirstCaptureInsertsAtTopAndPersists() async throws {
        let controller = makeController()
        await controller.handleCapture(textContent("Hello", identity: "t:hello", utis: [UTI.plainText]), app: AppSource(name: "Safari", bundleID: "com.apple.Safari"))

        XCTAssertEqual(controller.items.count, 1)
        XCTAssertEqual(controller.items.first?.previewText, "Hello")
        XCTAssertEqual(controller.items.first?.kind, .text)
        XCTAssertEqual(controller.items.first?.appName, "Safari")

        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        XCTAssertEqual(rows.map(\.identity), ["t:hello"], "内存与库必须同步（先写库后动内存）")
        let payloads = try await reloadPayloads(rows[0].id)
        XCTAssertEqual(payloads.map(\.uti), [UTI.plainText])
        XCTAssertEqual(payloads.first?.data, Data("Hello".utf8))
    }

    /// 同一 identity 第二次捕获：不新增行，改为置顶并刷新时间戳。
    /// 合并置顶是设计共识，也是面板"同内容只有一条"的唯一保证。
    func testSameIdentityMergesToTopInsteadOfDuplicating() async throws {
        let controller = makeController()
        await controller.handleCapture(textContent("first", identity: "t:a"), app: nil)
        await controller.handleCapture(textContent("second", identity: "t:b"), app: nil)
        let originalID = try XCTUnwrap(controller.items.first(where: { $0.identity == "t:a" })?.id)

        await controller.handleCapture(textContent("first again", identity: "t:a"), app: nil)

        XCTAssertEqual(controller.items.count, 2, "同 identity 不新增条目")
        XCTAssertEqual(controller.items.first?.id, originalID, "合并必须沿用原 id（收藏等状态挂在 id 上）")
        XCTAssertEqual(controller.items.first?.previewText, "first again", "预览/搜索域无条件刷新")
        XCTAssertEqual(controller.items.first?.searchText, "first again")
        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.id, originalID, "库里也按新 created_at 排在最前")
    }

    /// 表示并集：新拷贝没带的旧表示要保留（老应用只给 RTF、新拷贝给纯文本，
    /// 合并后两种都能粘），且新传入的表示排在前面（pos 顺序即回写剪贴板顺序）。
    func testMergeUnionsPayloadRepresentationsKeepingIncomingFirst() async throws {
        let controller = makeController()
        await controller.handleCapture(
            CapturedContent(kind: .richText, identity: "t:u", searchText: "u", previewText: "u",
                            payloads: [ClipboardPayload(uti: UTI.rtf, data: Data("rtf-v1".utf8))]),
            app: nil)
        let id = try XCTUnwrap(controller.items.first?.id)

        await controller.handleCapture(
            CapturedContent(kind: .text, identity: "t:u", searchText: "u", previewText: "u",
                            payloads: [ClipboardPayload(uti: UTI.plainText, data: Data("plain-v2".utf8))]),
            app: nil)

        let payloads = try await reloadPayloads(id)
        XCTAssertEqual(payloads.map(\.uti), [UTI.plainText, UTI.rtf], "新的在前、旧的补齐")
        XCTAssertEqual(payloads.first?.data, Data("plain-v2".utf8))
        XCTAssertEqual(payloads.last?.data, Data("rtf-v1".utf8), "旧表示的字节必须原样存活")
    }

    /// kind 取"更富"：纯文本 < HTML < 富文本，且绝不因新拷贝更"素"而降级。
    func testMergeAdoptsRicherKindAndNeverDowngrades() async throws {
        let controller = makeController()
        await controller.handleCapture(textContent("a", identity: "t:rich", utis: [UTI.plainText]), app: nil)
        await controller.handleCapture(
            CapturedContent(kind: .richText, identity: "t:rich", searchText: "a", previewText: "a",
                            payloads: [ClipboardPayload(uti: UTI.rtf, data: Data("r".utf8))]), app: nil)
        XCTAssertEqual(controller.items.first?.kind, .richText, "纯文本条目被富文本拷贝升级")

        await controller.handleCapture(textContent("a", identity: "t:rich", utis: [UTI.plainText]), app: nil)
        XCTAssertEqual(controller.items.first?.kind, .richText, "更素的重拷不降级")
    }

    /// 来源信息只增不减：新拷贝归因不到应用时，旧的 appName/图标/缩略图不得被清空。
    func testMergeNeverDowngradesSourceMetadata() async throws {
        let controller = makeController()
        await controller.handleCapture(textContent("x", identity: "t:meta"), app: AppSource(name: "Numbers", bundleID: "com.apple.Numbers"))
        let before = try XCTUnwrap(controller.items.first)

        await controller.handleCapture(textContent("x", identity: "t:meta"), app: nil)
        let after = try XCTUnwrap(controller.items.first)

        XCTAssertEqual(after.appName, "Numbers", "来源名缺失时保留旧值")
        XCTAssertEqual(after.id, before.id)
    }

    /// 敏感来源（密码管理器等）在写库前就被拦掉：内存与磁盘都不留痕。
    func testSensitiveSourceCapturesNothing() async throws {
        let controller = makeController(sensitive: ["1Password"])
        await controller.handleCapture(textContent("hunter2", identity: "t:secret"), app: AppSource(name: "1Password", bundleID: "com.1password.1password"))

        XCTAssertTrue(controller.items.isEmpty, "敏感来源直接 return")
        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        XCTAssertTrue(rows.isEmpty, "库里也不该有一行")
    }

    /// 图片捕获：缩略图按最长边 256 等比生成并落到 Thumbs/，路径写进 items.thumbnail。
    func testImageCaptureWritesThumbnailToDisk() async throws {
        let controller = makeController()
        let png = try makePNGData(width: 40, height: 40)
        await controller.handleCapture(
            CapturedContent(kind: .image, identity: "i:sha256", searchText: "", previewText: "Image",
                            payloads: [ClipboardPayload(uti: UTI.png, data: png)]), app: nil)

        let item = try XCTUnwrap(controller.items.first)
        let thumbPath = try XCTUnwrap(item.thumbnailPath, "图片条目应带缩略图路径")
        XCTAssertTrue(thumbPath.contains("/Thumbs/"), "缩略图必须落在 Thumbs/ 子目录")
        XCTAssertNotNil(NSImage(contentsOfFile: thumbPath), "缩略图应是可解码的 PNG")
        XCTAssertEqual(Set(try fileNames(in: "Thumbs")), Set([lastPathComponent(thumbPath)]))
    }

    /// 超过 32KB 的表示溢盘：库里只存路径与 nil 内联，读回字节与原文完全一致。
    func testOversizedPayloadSpillsToBlobFileAndRoundTrips() async throws {
        let controller = makeController()
        let big = Data(repeating: 0x42, count: BlobStore.inlineThreshold + 4096)
        await controller.handleCapture(
            CapturedContent(kind: .text, identity: "t:big", searchText: "big", previewText: "big",
                            payloads: [ClipboardPayload(uti: UTI.plainText, data: big)]), app: nil)

        let id = try XCTUnwrap(controller.items.first?.id)
        let stored = try await reloadPayloads(id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertNil(stored.first?.inline, "超限数据不该留在库里")
        let path = try XCTUnwrap(stored.first?.filePath)
        XCTAssertTrue(path.contains("/Blobs/"), "溢盘文件必须落在 Blobs/")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), big)
        XCTAssertEqual(stored.first?.data?.count, big.count, "经 StoredPayload.data 惰性读盘应拿到完整原文")
    }

    // MARK: - 淘汰与清理

    /// 上限淘汰：超出 limit 的最旧非收藏条目被清除，收藏条目豁免（设计共识）。
    /// 文件级清理在 testDeleteClearsRowPayloadsBlobAndThumbnail 里验证
    /// （本用例的 payload 都小于内联阈值，不落盘）。
    func testEnforceLimitKeepsNewestNonFavoritesAndAllFavorites() async throws {
        let controller = makeController(limit: 2)
        // 三条普通 + 一条收藏（收藏豁免上限）。
        for index in 1...3 {
            await controller.handleCapture(textContent("n\(index)", identity: "t:n\(index)"), app: nil)
        }
        await controller.handleCapture(textContent("fav", identity: "t:fav"), app: nil)
        await controller.toggleFavorite(id: try XCTUnwrap(controller.items.first(where: { $0.identity == "t:fav" })).id)
        for index in 4...5 {
            await controller.handleCapture(textContent("n\(index)", identity: "t:n\(index)"), app: nil)
        }

        let remaining = controller.items.map(\.identity)
        XCTAssertEqual(Set(remaining), Set(["t:n5", "t:n4", "t:fav"]), "只留最新 2 条非收藏 + 全部收藏")
        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        XCTAssertEqual(Set(rows.map(\.identity)), Set(remaining), "内存与库同步淘汰")
    }

    /// 手动删除：payload 行、条目行、落盘文件、缩略图四处一起干净。
    func testDeleteClearsRowPayloadsBlobAndThumbnail() async throws {
        let controller = makeController()
        let png = try makePNGData()
        let big = Data(repeating: 0x11, count: BlobStore.inlineThreshold + 16)
        await controller.handleCapture(
            CapturedContent(kind: .image, identity: "t:del", searchText: "del", previewText: "del",
                            payloads: [ClipboardPayload(uti: UTI.png, data: png), ClipboardPayload(uti: UTI.plainText, data: big)]),
            app: nil)
        let item = try XCTUnwrap(controller.items.first)
        let thumb = try XCTUnwrap(item.thumbnailPath)
        let blobsOnDisk = try await reloadPayloads(item.id).compactMap(\.filePath)
        XCTAssertFalse(blobsOnDisk.isEmpty, "前置条件：应已产生溢盘文件")

        await controller.delete(item)

        XCTAssertTrue(controller.items.isEmpty)
        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        let leftover = try await db.payloads(for: item.id)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(leftover.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumb), "缩略图应随条目删除")
        for path in blobsOnDisk {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "溢盘文件应随条目删除")
        }
    }

    /// 清空历史：非收藏连文件一起清，收藏条目与其文件保留（设计共识）。
    func testClearHistoryKeepsFavoritesAndTheirFiles() async throws {
        let controller = makeController()
        await controller.handleCapture(textContent("keep", identity: "t:keep"), app: nil)
        let favorite = try XCTUnwrap(controller.items.first)
        await controller.toggleFavorite(id: favorite.id)
        let big = Data(repeating: 0x22, count: BlobStore.inlineThreshold + 16)
        await controller.handleCapture(
            CapturedContent(kind: .text, identity: "t:gone", searchText: "gone", previewText: "gone",
                            payloads: [ClipboardPayload(uti: UTI.plainText, data: big)]), app: nil)
        let doomedPath = try await reloadPayloads(try XCTUnwrap(controller.items.first?.id)).first?.filePath
        let doomedBlob = try XCTUnwrap(doomedPath, "前置条件：待清条目应有溢盘文件")

        await controller.clearHistory()

        XCTAssertEqual(controller.items.map(\.identity), ["t:keep"])
        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        XCTAssertEqual(rows.map(\.identity), ["t:keep"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomedBlob), "被清空条目的落盘文件应删除")
    }

    /// 收藏状态跨"重建数据层"存活（同沙箱库开第二个 controller）。
    func testFavoriteStateSurvivesFreshDataLayer() async throws {
        let first = makeController()
        await first.handleCapture(textContent("pinned", identity: "t:pinned"), app: nil)
        await first.toggleFavorite(id: try XCTUnwrap(first.items.first).id)

        let reopened = HistoryController(settings: makeIsolatedSettings(), blobs: blobs)
        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.first?.favorite ?? false)
        XCTAssertNotNil(rows.first?.favoriteAt, "收藏小节按 favorite_at 倒序，该列不能丢")
        XCTAssertTrue(reopened.items.isEmpty, "新 controller 未 start() 前内存列表为空（加载发生在 start）")
    }

    // MARK: - 收藏（回归：★ 取消不掉 / 状态与显示不符）

    /// 回归：★ 的翻转必须以 items 现状为准，而不是调用方手里的快照。
    ///
    /// 旧签名 `toggleFavorite(_ item:)` 用 `!item.favorite` 定目标状态。视图
    /// 闭包捕获的 ClipboardItem 只是某次渲染的快照，同一份快照连点两次 ★
    /// 会两次都算出 favorite=true（第二次仍以为"当前未收藏"），写回库里还是
    /// 1 —— 这就是"收藏之后无法取消收藏"，★ 也停在旧状态。
    /// 新签名只收 id，目标状态由数据层按 items 现读现翻。
    func testToggleFavoriteFlipsAgainstLiveStateNotCallerSnapshot() async throws {
        let controller = makeController()
        await controller.handleCapture(textContent("pinned", identity: "t:pinned"), app: nil)
        let snapshot = try XCTUnwrap(controller.items.first)

        await controller.toggleFavorite(id: snapshot.id)
        XCTAssertTrue(controller.items.first?.favorite ?? false, "第一次点击 → 收藏")

        // 关键：复用同一份（此刻已过期的）快照，只取它的恒真部分 id。
        await controller.toggleFavorite(id: snapshot.id)
        XCTAssertFalse(controller.items.first?.favorite ?? false, "第二次点击必须按现状翻转 → 取消收藏")
        XCTAssertNil(controller.items.first?.favoriteAt, "取消收藏要把 favorite_at 归零，否则污染收藏小节排序")

        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        XCTAssertFalse(rows.first?.favorite ?? false, "库与内存必须一致")
        XCTAssertNil(rows.first?.favoriteAt)
    }

    /// 收藏时刻只取一次：库与内存必须是同一个 favorite_at。
    /// 旧实现两次调用 Date()，会话内与重启后的收藏小节顺序可能对不上。
    func testToggleFavoriteUsesOneTimestampForStoreAndMemory() async throws {
        let controller = makeController()
        await controller.handleCapture(textContent("pinned", identity: "t:pinned"), app: nil)
        let id = try XCTUnwrap(controller.items.first).id

        await controller.toggleFavorite(id: id)

        let inMemory = try XCTUnwrap(controller.items.first(where: { $0.id == id })?.favoriteAt)
        let db = try HistoryDatabase(location: blobs.databaseURL)
        let rows = try await db.loadItems()
        let stored = try XCTUnwrap(rows.first?.favoriteAt, "前置条件：库里应有该行")
        XCTAssertEqual(inMemory.timeIntervalSince1970, stored.timeIntervalSince1970, accuracy: 0.001,
                       "库与内存应是同一个收藏时刻")
    }

    /// 合并置顶不得把收藏状态盖回旧值：捕获路径不是 favorite 的所有者。
    /// （库侧同语义由 HistoryDatabaseSemanticsTests 钉住，这里钉内存侧——
    /// 列表与 ★ 直接读的是内存。）
    func testMergeKeepsFavoriteInMemoryWhileReordering() async throws {
        let controller = makeController()
        await controller.handleCapture(textContent("first", identity: "t:first"), app: nil)
        await controller.handleCapture(textContent("pinned", identity: "t:pinned"), app: nil)
        let id = try XCTUnwrap(controller.items.first(where: { $0.identity == "t:pinned" })).id
        await controller.toggleFavorite(id: id)

        // 再拷一次同一内容 → 合并置顶（刷新 createdAt 并移到表头）。
        await controller.handleCapture(textContent("pinned", identity: "t:pinned"), app: nil)

        let merged = try XCTUnwrap(controller.items.first(where: { $0.id == id }))
        XCTAssertTrue(merged.favorite, "合并后内存里的收藏状态必须存活")
        XCTAssertNotNil(merged.favoriteAt, "收藏时刻同样不能被合并清掉")
    }

    // MARK: - 已知缺陷（冻结不修，按契约断言其存在）

    /// currentBehavior：合并路径换新缩略图时不删旧的——旧 PNG 永远留在 Thumbs/。
    /// 缩略图文件名用的是随机 UUID（HistoryController 里 makeThumbnail(png, id: UUID())），
    /// 与条目 id 无关，因此即便想按条目反查也查不到。修复后本测试变红。
    func testCurrentBehavior_mergePathOrphansPreviousThumbnailFile() async throws {
        let controller = makeController()
        await controller.handleCapture(
            CapturedContent(kind: .image, identity: "i:dup", searchText: "", previewText: "Image",
                            payloads: [ClipboardPayload(uti: UTI.png, data: try makePNGData(width: 10, height: 10))]), app: nil)
        let oldThumb = try XCTUnwrap(controller.items.first?.thumbnailPath)

        await controller.handleCapture(
            CapturedContent(kind: .image, identity: "i:dup", searchText: "", previewText: "Image",
                            payloads: [ClipboardPayload(uti: UTI.png, data: try makePNGData(width: 20, height: 20))]), app: nil)
        let newThumb = try XCTUnwrap(controller.items.first?.thumbnailPath)

        XCTAssertNotEqual(oldThumb, newThumb, "合并确实换了新的缩略图文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldThumb), "旧缩略图未被删除 → 孤儿")
        XCTAssertEqual(try fileNames(in: "Thumbs").count, 2, "同一条目两次图片捕获留下 2 个文件、库里只引用 1 个")
    }

    /// currentBehavior：合并路径替换超限 payload 时，旧 Blobs 文件同样成孤儿
    /// （replacePayloads 不返回被替掉的路径清单）。反复拷贝同一张大图会线性堆文件。
    func testCurrentBehavior_mergePathOrphansPreviousSpilledBlob() async throws {
        let controller = makeController()
        let big = Data(repeating: 0x33, count: BlobStore.inlineThreshold + 32)
        await controller.handleCapture(
            CapturedContent(kind: .text, identity: "t:spilldup", searchText: "s", previewText: "s",
                            payloads: [ClipboardPayload(uti: UTI.plainText, data: big)]), app: nil)
        let firstSpill = try await reloadPayloads(try XCTUnwrap(controller.items.first?.id)).first?.filePath
        let firstBlob = try XCTUnwrap(firstSpill)

        await controller.handleCapture(
            CapturedContent(kind: .text, identity: "t:spilldup", searchText: "s", previewText: "s",
                            payloads: [ClipboardPayload(uti: UTI.plainText, data: Data(repeating: 0x44, count: BlobStore.inlineThreshold + 32))]), app: nil)
        let secondSpill = try await reloadPayloads(try XCTUnwrap(controller.items.first?.id)).first?.filePath
        let secondBlob = try XCTUnwrap(secondSpill)

        XCTAssertNotEqual(firstBlob, secondBlob, "溢盘文件名含随机 UUID，每次都是新文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstBlob), "第一次的落盘文件未被清理 → 孤儿")
    }

    // MARK: - 路径小工具

    private func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func fileNames(in subdirectory: String) throws -> [String] {
        let url = blobs.baseURL.appendingPathComponent(subdirectory, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
}

private extension CapturedContent {
    /// 测试构造器糖：按 utis 推断 kind，避免每个用例重复写四元组。
    func withKind(_ kind: ClipboardKind) -> CapturedContent {
        var copy = self
        copy.kind = kind
        return copy
    }
}
