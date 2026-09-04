// HistoryDatabaseSemanticsTests.swift — 持久化层语义特征测试（阶段①′-1）。
//
// 目的：在拆分 HistoryDatabase（SQLite 句柄封装 / SQL 集中）之前，把它当前
// **实际**表现钉死，包括看起来像缺陷的部分。按重构契约，本轮不修任何缺陷，
// 因此缺陷用 testCurrentBehavior_ 前缀显式断言其存在——日后修复必然让该测试
// 变红，改测试的人从而知道行为变了。
//
// 与既有 HistoryDatabaseTests 的分工：那 7 条覆盖"正向往返"（插入读回、去重键、
// 替换保序、收藏、上限淘汰、清空保收藏、大 payload 往返）；本文件补它没碰的
// 排序方向、favorite 豁免边界、非事务性、孤儿文件、文件名布局、多连接共开。
//
// 全部用例经 TestHarness 的临时沙箱，不触碰用户真实 history.db。
import AppKit
import XCTest

@testable import GlassClip

@MainActor
final class HistoryDatabaseSemanticsTests: XCTestCase {

    /// 测试条目工厂：只在"读回必须一致"的字段上给确定值。
    private func makeItem(
        id: UUID = UUID(),
        identity: String = "t:seed",
        kind: ClipboardKind = .text,
        previewText: String = "seed",
        thumbnailPath: String? = nil,
        appIconPath: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1000),
        favorite: Bool = false
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            kind: kind,
            identity: identity,
            searchText: previewText.lowercased(),
            previewText: previewText,
            appName: "TestApp",
            appIconPath: appIconPath,
            thumbnailPath: thumbnailPath,
            createdAt: createdAt,
            favorite: favorite,
            favoriteAt: favorite ? createdAt : nil
        )
    }

    /// 打开一个沙箱库（同时返回其落盘层，用于断言磁盘侧状态）。
    private func openDatabase() throws -> (HistoryDatabase, BlobStore) {
        let blobs = makeSandboxBlobs()
        return (try HistoryDatabase(location: blobs.databaseURL), blobs)
    }

    // MARK: - 排序与选择语义

    /// items 表的读取顺序是 created_at 严格倒序（新→旧），与插入顺序无关。
    /// 阶段②要把列表模型从 PanelRootView 抽出，这条顺序是 flatItems 的地基。
    func testLoadItemsOrdersNewestFirstRegardlessOfInsertionOrder() async throws {
        let (db, _) = try openDatabase()
        // 故意按 旧→中→新 之外的乱序插入：中、新、旧。
        try await db.insert(item: makeItem(identity: "t:mid", createdAt: Date(timeIntervalSince1970: 200)), payloads: [])
        try await db.insert(item: makeItem(identity: "t:new", createdAt: Date(timeIntervalSince1970: 300)), payloads: [])
        try await db.insert(item: makeItem(identity: "t:old", createdAt: Date(timeIntervalSince1970: 100)), payloads: [])

        let loaded = try await db.loadItems()
        XCTAssertEqual(loaded.map(\.identity), ["t:new", "t:mid", "t:old"])
    }

    /// 上限淘汰的边界：limit 大于等于非收藏条数时一个都不该淘汰；
    /// limit 为 0 时全部非收藏都在"超出上限"集合内（收藏仍豁免）。
    /// HistoryController.enforceLimit 直接把 settings.historyLimit 传进来，
    /// 这两个边界决定了设置页把上限调到极端值时的行为。
    func testOldestNonFavoriteLimitBoundaries() async throws {
        let (db, _) = try openDatabase()
        for index in 1...3 {
            try await db.insert(item: makeItem(identity: "t:\(index)", createdAt: Date(timeIntervalSince1970: Double(index))), payloads: [])
        }
        try await db.insert(item: makeItem(identity: "t:fav", createdAt: Date(timeIntervalSince1970: 0), favorite: true), payloads: [])

        let nonePruned = try await db.oldestNonFavoriteIDs(beyondLimit: 3)
        XCTAssertEqual(nonePruned.count, 0, "非收藏恰好等于上限时不淘汰")
        let allNonFavorites = try await db.oldestNonFavoriteIDs(beyondLimit: 0)
        XCTAssertEqual(allNonFavorites.count, 3, "limit 0 → 全部非收藏都算超额")
        let everyRow = try await db.loadItems()
        let prunedRows = everyRow.filter { allNonFavorites.contains($0.id) }
        XCTAssertEqual(prunedRows.count, 3)
        XCTAssertFalse(prunedRows.contains { $0.favorite }, "收藏条目永远不出现在淘汰集合里")
    }

    // MARK: - 合并置顶的不变量

    /// 去重合并（updateMetadata）必须原样保留 favorite 与 favorite_at：
    /// 传入的 struct 里 favorite=false 也不能把用户已点下的收藏冲掉。
    func testUpdateMetadataNeverTouchesFavoriteColumns() async throws {
        let (db, _) = try openDatabase()
        let id = UUID()
        let favorited = makeItem(id: id, identity: "t:dup", createdAt: Date(timeIntervalSince1970: 500), favorite: true)
        try await db.insert(item: favorited, payloads: [])

        // 模拟合并置顶：同一条目刷新时间戳与预览，但 favorite 字段是 false。
        let merged = makeItem(id: id, identity: "t:dup", previewText: "changed", createdAt: Date(timeIntervalSince1970: 900), favorite: false)
        try await db.updateMetadata(merged)

        let reloaded = try await db.loadItems()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.previewText, "changed", "元信息应当被刷新")
        XCTAssertEqual(reloaded.first?.createdAt.timeIntervalSince1970 ?? 0, 900, accuracy: 0.001, "时间戳应当置顶")
        XCTAssertTrue(reloaded.first?.favorite ?? false, "favorite 必须跨合并存活")
        XCTAssertEqual(reloaded.first?.favoriteAt?.timeIntervalSince1970 ?? 0, 500, accuracy: 0.001, "favorite_at 必须跨合并存活")
    }

    /// currentBehavior：identity 列只有普通索引、没有唯一约束。
    /// 去重完全依赖调用方先查 uuidForIdentity，库里可以并存同 identity 的多行。
    /// 修复它（加 UNIQUE）会改变合并/并发捕获路径，因此本轮只做断言。
    func testCurrentBehavior_identityColumnIsNotUnique() async throws {
        let (db, _) = try openDatabase()
        try await db.insert(item: makeItem(id: UUID(), identity: "t:same", createdAt: Date(timeIntervalSince1970: 1)), payloads: [])
        try await db.insert(item: makeItem(id: UUID(), identity: "t:same", createdAt: Date(timeIntervalSince1970: 2)), payloads: [])

        let loaded = try await db.loadItems()
        XCTAssertEqual(loaded.count, 2, "重复 identity 允许入库（无唯一约束）")
        let found = try await db.uuidForIdentity("t:same")
        XCTAssertNotNil(found, "LIMIT 1 命中其中一行即返回，不报错")
    }

    // MARK: - 事务边界

    /// currentBehavior：replacePayloads 不开事务——先 DELETE 提交、再逐行 INSERT。
    /// 中途失败（这里用同一 UTI 撞主键制造失败）时，已有 payload 已经没了，
    /// 且新 payload 只落了失败前的部分。条目行本身仍在，变成"无表示"的空条目。
    /// 拆 SQL 层时若引入事务，本测试会变红——那时应连同 HistoryController 一起评估。
    func testCurrentBehavior_replacePayloadsIsNotTransactional() async throws {
        let (db, _) = try openDatabase()
        let item = makeItem()
        try await db.insert(item: item, payloads: [
            StoredPayload(uti: UTI.plainText, inline: Data("keep".utf8), filePath: nil),
        ])

        do {
            try await db.replacePayloads(itemId: item.id, payloads: [
                StoredPayload(uti: UTI.rtf, inline: Data("rtf".utf8), filePath: nil),
                StoredPayload(uti: UTI.rtf, inline: Data("dup".utf8), filePath: nil),
            ])
            XCTFail("同一 UTI 应当违反主键约束并抛错")
        } catch is GlassClipError {
            // 只断言"抛错"这一事实；错误文案随 sqlite 版本变化，不钉。
        }

        let remaining = try await db.payloads(for: item.id)
        XCTAssertNotEqual(remaining.map(\.uti), [UTI.plainText],
                          "非事务：旧 payload 已被 DELETE 提交掉，不会回滚")
    }

    /// payloads 主键是 (item_id, uti)：同一 UTI 的第二次 INSERT 冲突。
    /// 捕获管线若给出一份 payloads 里重复的 UTI，就会走到这条路径。
    func testDuplicateUTIWithinOneItemViolatesPrimaryKey() async throws {
        let (db, _) = try openDatabase()
        let item = makeItem()
        do {
            try await db.insert(item: item, payloads: [
                StoredPayload(uti: UTI.plainText, inline: Data("a".utf8), filePath: nil),
                StoredPayload(uti: UTI.plainText, inline: Data("b".utf8), filePath: nil),
            ])
            XCTFail("同一条目的重复 UTI 应当违反主键约束")
        } catch {
            XCTAssertTrue(error is GlassClipError, "应以 GlassClipError 上抛，实际 \(type(of: error))")
        }
    }

    // MARK: - 孤儿文件现状（已知缺陷，冻结不修）

    /// currentBehavior：**缩略图/条目合并路径**替换 thumbnail 列时，
    /// 旧缩略图文件不会进入任何清理名单——库里已不引用它，磁盘上仍留一份。
    /// 这条断言是"孤儿文件泄漏"的证据：修复后它会变红。
    func testCurrentBehavior_orphanThumbnailFileIsNeverReported() async throws {
        let (db, blobs) = try openDatabase()
        let id = UUID()
        let oldThumb = try blobs.writeThumbnail(Data("old-png".utf8), id: id)
        try await db.insert(item: makeItem(id: id, thumbnailPath: oldThumb), payloads: [])

        let newThumb = try blobs.writeThumbnail(Data("new-png".utf8), id: UUID())
        try await db.updateMetadata(makeItem(id: id, thumbnailPath: newThumb))

        XCTAssertNotNil(try? Data(contentsOf: URL(fileURLWithPath: oldThumb)), "旧缩略图文件仍在磁盘上（未被清理）")
        let reported = try await db.payloadFilePaths(for: id)
        XCTAssertFalse(reported.contains(oldThumb),
                       "payloadFilePaths 只查 payloads 表，看不到 items.thumbnail——清理不到它")
    }

    /// currentBehavior：replacePayloads 换掉落盘 payload 时，
    /// 被替掉的旧 Blobs 文件既不返回给调用方、也不在库里留痕。
    func testCurrentBehavior_replacingPayloadsOrphansOldBlobFile() async throws {
        let (db, blobs) = try openDatabase()
        let item = makeItem()
        let bigData = Data(repeating: 0xCD, count: BlobStore.inlineThreshold + 64)
        let spillPath = try blobs.writeLargePayload(bigData, id: item.id)
        try await db.insert(item: item, payloads: [StoredPayload(uti: UTI.png, inline: nil, filePath: spillPath)])
        let beforeReplace = try await db.payloadFilePaths(for: item.id)
        XCTAssertEqual(beforeReplace, [spillPath])

        try await db.replacePayloads(itemId: item.id, payloads: [
            StoredPayload(uti: UTI.png, inline: Data("small".utf8), filePath: nil),
        ])

        let afterReplace = try await db.payloadFilePaths(for: item.id)
        XCTAssertTrue(afterReplace.isEmpty, "库里已不再引用落盘文件，调用方拿不到旧路径")
        XCTAssertTrue(FileManager.default.fileExists(atPath: spillPath),
                      "旧 Blobs 文件残留：replacePayloads 无返回路径清单，调用方无从清理")
    }

    /// 持久化层从不删文件：删除条目/清空历史只返回路径清单，磁盘状态不变。
    /// "先写库、成功后再由调用方删文件"的安全顺序靠这个分工成立。
    func testDatabaseLayerNeverDeletesFiles() async throws {
        let (db, blobs) = try openDatabase()
        let doomed = makeItem(id: UUID(), identity: "t:doomed")
        let path = try blobs.writeLargePayload(Data("bytes".utf8), id: doomed.id)
        try await db.insert(item: doomed, payloads: [StoredPayload(uti: UTI.png, inline: nil, filePath: path)])

        try await db.deleteItem(id: doomed.id)
        let rows = try await db.loadItems()
        let leftoverPayloads = try await db.payloads(for: doomed.id)
        XCTAssertTrue(rows.isEmpty, "行已删")
        XCTAssertTrue(leftoverPayloads.isEmpty, "payload 行随条目一起删（无孤儿 payload 行）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "文件删除不属于本层职责，必须留给调用方")
    }

    /// 清空（不留收藏）返回全部落盘路径；收藏豁免那条路径同理。
    func testClearReturnsEverySpilledPathForCallerCleanup() async throws {
        let (db, blobs) = try openDatabase()
        let normal = makeItem(id: UUID(), identity: "t:n")
        let favorite = makeItem(id: UUID(), identity: "t:f", favorite: true)
        let normalPath = try blobs.writeLargePayload(Data("n".utf8), id: normal.id)
        let favoritePath = try blobs.writeLargePayload(Data("f".utf8), id: favorite.id)
        try await db.insert(item: normal, payloads: [StoredPayload(uti: UTI.png, inline: nil, filePath: normalPath)])
        try await db.insert(item: favorite, payloads: [StoredPayload(uti: UTI.png, inline: nil, filePath: favoritePath)])

        let keepFav = try await db.clear(keepingFavorites: true)
        XCTAssertEqual(keepFav, [normalPath], "只报将被删的非收藏落盘路径")
        let stillThere = try await db.loadItems()
        XCTAssertEqual(stillThere.map(\.identity), ["t:f"])

        let all = try await db.clear(keepingFavorites: false)
        XCTAssertEqual(all, [favoritePath], "第二轮只剩收藏一条，报它的路径")
        let rowsAfterFullClear = try await db.loadItems()
        XCTAssertTrue(rowsAfterFullClear.isEmpty)
    }

    // MARK: - 连接与存储形态

    /// 同一库文件被第二个 actor 打开时能读到已提交数据，且幂等建表不报错。
    /// （拆 SQLite 句柄封装时必须保持这条：AppSettings 改上限等路径会重开库。）
    func testSecondConnectionReadsCommittedData() async throws {
        let blobs = makeSandboxBlobs()
        let first = try HistoryDatabase(location: blobs.databaseURL)
        let item = makeItem(identity: "t:persist")
        try await first.insert(item: item, payloads: [StoredPayload(uti: UTI.plainText, inline: Data("v".utf8), filePath: nil)])

        let second = try HistoryDatabase(location: blobs.databaseURL)
        let loaded = try await second.loadItems()
        XCTAssertEqual(loaded.map(\.identity), ["t:persist"])
        let payloads = try await second.payloads(for: item.id)
        XCTAssertEqual(payloads.first?.data, Data("v".utf8))
    }

    /// StoredPayload.data 的三态：内联优先于路径；两者皆空为 nil；
    /// 零长度内联是合法空值（空字符串表示），不得退化成读盘。
    func testStoredPayloadDataResolutionOrder() throws {
        let blobs = makeSandboxBlobs()
        let realPath = try blobs.writeLargePayload(Data("on-disk".utf8), id: UUID())

        XCTAssertEqual(StoredPayload(uti: UTI.plainText, inline: Data("inline".utf8), filePath: realPath).data, Data("inline".utf8),
                       "内联优先，即使路径也有效")
        XCTAssertEqual(StoredPayload(uti: UTI.plainText, inline: nil, filePath: realPath).data, Data("on-disk".utf8))
        XCTAssertEqual(StoredPayload(uti: UTI.plainText, inline: Data(), filePath: realPath).data, Data(),
                       "零长度内联是合法空值")
        XCTAssertNil(StoredPayload(uti: UTI.plainText, inline: nil, filePath: "/nonexistent/path.bin").data,
                     "读盘失败静默为 nil——调用方按跳过该表示处理")
    }

    // MARK: - 磁盘布局（孤儿分析与迁移脚本都依赖这些字符串）

    /// Blobs/Thumbs/Icons 的命名规则：payload 按条目 id 唯一，
    /// 图标按 bundleID 共享（同一应用几百条记录共用一个文件）。
    func testBlobStoreFileNamingLayout() throws {
        let blobs = makeSandboxBlobs()
        let id = UUID()
        XCTAssertEqual(try blobs.writeLargePayload(Data("p".utf8), id: id), blobs.baseURL.appendingPathComponent("Blobs/payload-\(id.uuidString).bin").path)
        XCTAssertEqual(try blobs.writeThumbnail(Data("t".utf8), id: id), blobs.baseURL.appendingPathComponent("Thumbs/\(id.uuidString).png").path)
        XCTAssertEqual(blobs.appIconPath(forBundleID: "com.apple.Safari"), blobs.baseURL.appendingPathComponent("Icons/com.apple.Safari.png").path)
        XCTAssertEqual(try blobs.writeAppIcon(Data("i".utf8), bundleID: "com.apple.Safari"), blobs.appIconPath(forBundleID: "com.apple.Safari"),
                       "两个图标写入入口必须给同一路径，否则按 bundleID 去重失效")
    }

    /// deleteFile 对不存在的路径不抛错（"尽力删除"契约）：
    /// HistoryController 的清理序列依赖它在中途失败时继续走完。
    func testDeleteFileIsBestEffortAndNeverThrows() throws {
        let blobs = makeSandboxBlobs()
        blobs.deleteFile(at: blobs.baseURL.appendingPathComponent("Blobs/missing.bin").path)
        let path = try blobs.writeLargePayload(Data("x".utf8), id: UUID())
        blobs.deleteFile(at: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
