// HistoryDatabaseTests.swift — SQLite 持久化层回归测试（临时目录真库）。
//
// 策略：每个用例在临时目录开一个全新 HistoryDatabase，跑完即删，
// 互不共享状态；覆盖读写往返、去重键查询、payload 替换保序、收藏、
// 上限淘汰（收藏豁免）、清空保收藏、大 payload 文件路径往返。
// 同文件还包含 SensitiveAppsFilterTests（敏感名单匹配语义）。

import AppKit
import XCTest
@testable import GlassClip

final class HistoryDatabaseTests: XCTestCase {
    /// 本用例组的数据库路径（setUp 里按 UUID 生成，天然隔离）。
    private var location: URL!

    override func setUpWithError() throws {
        location = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("glassclip-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: location.deletingLastPathComponent())
    }

    /// 构造测试条目的工厂：全部字段给合理默认，用例只覆盖关心的维度。
    private func makeItem(
        id: UUID = UUID(),
        identity: String = "t:hello",
        kind: ClipboardKind = .text,
        createdAt: Date = Date(),
        favorite: Bool = false
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            kind: kind,
            identity: identity,
            searchText: "hello",
            previewText: "hello",
            appName: "TestApp",
            appIconPath: nil,
            thumbnailPath: nil,
            createdAt: createdAt,
            favorite: favorite,
            favoriteAt: favorite ? createdAt : nil
        )
    }

    /// 插入一条（含 payload）→ 全量读回，字段逐一比对；
    /// 时间戳用固定值（700）验证 REAL 列精度无损。
    func testInsertAndLoadRoundtrip() async throws {
        let db = try HistoryDatabase(location: location)
        let date = Date(timeIntervalSince1970: 700)
        let item = makeItem(createdAt: date)
        try await db.insert(
            item: item,
            payloads: [StoredPayload(uti: UTI.plainText, inline: Data("hello".utf8), filePath: nil)]
        )

        let loaded = try await db.loadItems()
        XCTAssertEqual(loaded.count, 1)
        let loadedItem = try XCTUnwrap(loaded.first)
        XCTAssertEqual(loadedItem.id, item.id)
        XCTAssertEqual(loadedItem.identity, item.identity)
        XCTAssertEqual(loadedItem.kind, .text)
        XCTAssertEqual(loadedItem.appName, "TestApp")
        XCTAssertEqual(loadedItem.createdAt.timeIntervalSince1970, 700, accuracy: 0.001)
        XCTAssertFalse(loadedItem.favorite)

        let payloads = try await db.payloads(for: item.id)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?.data, Data("hello".utf8))
    }

    /// 去重键查询：命中返回原 id，未命中返回 nil——
    /// 捕获管线"合并还是新建"分流依赖这一语义。
    func testIdentityLookup() async throws {
        let db = try HistoryDatabase(location: location)
        let item = makeItem(identity: "i:abc123")
        try await db.insert(item: item, payloads: [])
        let found = try await db.uuidForIdentity("i:abc123")
        XCTAssertEqual(found, item.id)
        let missing = try await db.uuidForIdentity("i:nope")
        XCTAssertNil(missing)
    }

    /// payload 全量替换：旧表示被清掉、新表示按传入顺序落位（pos 保序），
    /// 同一 UTI 只保留替换后的最新字节。
    func testReplacePayloadsMergesOrder() async throws {
        let db = try HistoryDatabase(location: location)
        let item = makeItem()
        try await db.insert(item: item, payloads: [
            StoredPayload(uti: UTI.plainText, inline: Data("v1".utf8), filePath: nil),
        ])
        try await db.replacePayloads(itemId: item.id, payloads: [
            StoredPayload(uti: UTI.rtf, inline: Data("rtf".utf8), filePath: nil),
            StoredPayload(uti: UTI.plainText, inline: Data("v2".utf8), filePath: nil),
        ])
        let payloads = try await db.payloads(for: item.id)
        XCTAssertEqual(payloads.map(\.uti), [UTI.rtf, UTI.plainText])
        XCTAssertEqual(payloads.last?.data, Data("v2".utf8))
    }

    /// 收藏切换：收藏写入 favoriteAt（固定时间 999 验证精度），
    /// 取消收藏两列都要归零——favoriteAt 残留会污染收藏小节排序。
    func testFavoriteToggle() async throws {
        let db = try HistoryDatabase(location: location)
        let item = makeItem()
        try await db.insert(item: item, payloads: [])
        let at = Date(timeIntervalSince1970: 999)
        try await db.setFavorite(id: item.id, favorite: true, at: at)
        let loaded = try await db.loadItems()
        XCTAssertTrue(loaded.first?.favorite ?? false)
        XCTAssertEqual(loaded.first?.favoriteAt?.timeIntervalSince1970 ?? 0, 999, accuracy: 0.001)
        try await db.setFavorite(id: item.id, favorite: false, at: nil)
        let reloaded = try await db.loadItems()
        XCTAssertFalse(reloaded.first?.favorite ?? true)
        XCTAssertNil(reloaded.first?.favoriteAt)
    }

    /// 上限淘汰语义：5 条（index 0 是收藏、时间最早）+ limit 2 →
    /// 收藏豁免，最新的 2 条非收藏（3、4）保留，最旧的 2 条非收藏
    /// （1、2）被淘汰。用时间戳反查被删者，比比 id 更可读。
    func testLimitPrunesOldestNonFavorites() async throws {
        let db = try HistoryDatabase(location: location)
        for index in 0..<5 {
            let item = makeItem(
                identity: "t:\(index)",
                createdAt: Date(timeIntervalSince1970: Double(index)),
                favorite: index == 0
            )
            try await db.insert(item: item, payloads: [])
        }
        // 共 5 条；收藏（时间戳 0）豁免、最新的 2 条非收藏（3、4）保留
        // → 最旧的 2 条非收藏被淘汰。
        let stale = try await db.oldestNonFavoriteIDs(beyondLimit: 2)
        XCTAssertEqual(stale.count, 2)
        let ids = Set(stale)
        let createdAts = try await db.loadItems().filter { ids.contains($0.id) }.map(\.createdAt.timeIntervalSince1970)
        XCTAssertEqual(Set(createdAts), Set([1.0, 2.0]), "oldest non-favorites are pruned first")
    }

    /// 清空历史保留收藏（设计共识）：收藏条目与其 payload 原样保留，
    /// 普通条目（含 payload 行）全删。
    /// deleted.count == 0：收藏条目没有落盘文件，路径清单应为空。
    func testClearKeepsFavorites() async throws {
        let db = try HistoryDatabase(location: location)
        let favorite = makeItem(identity: "t:fav", favorite: true)
        let normal = makeItem(identity: "t:normal")
        try await db.insert(item: favorite, payloads: [
            StoredPayload(uti: UTI.plainText, inline: Data("fav".utf8), filePath: nil),
        ])
        try await db.insert(item: normal, payloads: [
            StoredPayload(uti: UTI.plainText, inline: Data("normal".utf8), filePath: nil),
        ])

        let deleted = try await db.clear(keepingFavorites: true)
        XCTAssertEqual(deleted.count, 0)
        let remaining = try await db.loadItems()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.identity, "t:fav")
        let payloads = try await db.payloads(for: favorite.id)
        XCTAssertEqual(payloads.count, 1)
    }

    /// 大 payload 落盘路径往返：>32KB 数据存文件路径 → 读回时经
    /// StoredPayload.data 惰性读盘，字节必须与原文完全一致。
    /// 这条锁住"库存路径、盘存字节"的存储分工不回退。
    func testLargePayloadFilePathRoundtrip() async throws {
        let blobs = BlobStore(baseURL: location.deletingLastPathComponent().appendingPathComponent("Support"))
        let bigData = Data(repeating: 0xAB, count: BlobStore.inlineThreshold + 100)
        let path = try blobs.writeLargePayload(bigData, id: UUID())
        let db = try HistoryDatabase(location: blobs.databaseURL)
        let item = makeItem()
        try await db.insert(item: item, payloads: [
            StoredPayload(uti: UTI.png, inline: nil, filePath: path),
        ])
        let payloads = try await db.payloads(for: item.id)
        XCTAssertEqual(payloads.first?.data?.count, bigData.count)
        XCTAssertEqual(payloads.first?.data, bigData)
    }
}

/// 敏感应用名单的匹配语义：名称/bundleID 双匹配、大小写不敏感、
/// 未知来源不误伤、默认名单覆盖主流密码管理器。
final class SensitiveAppsFilterTests: XCTestCase {
    /// 名称与 bundleID 任一命中即敏感；nil 来源（无法归因）不算敏感。
    func testMatchesNameAndBundleID() {
        let filter = SensitiveAppsFilter(entries: ["1Password", "com.bitwarden.desktop"])
        XCTAssertTrue(filter.isSensitive(AppSource(name: "1Password", bundleID: "com.1password.1password")))
        XCTAssertTrue(filter.isSensitive(AppSource(name: "Something", bundleID: "com.bitwarden.desktop")))
        XCTAssertFalse(filter.isSensitive(AppSource(name: "Safari", bundleID: "com.apple.Safari")))
        XCTAssertFalse(filter.isSensitive(nil))
    }

    /// 名单输入大小写不敏感（"keepassxc" 命中显示名 "KeePassXC"）。
    func testCaseInsensitive() {
        let filter = SensitiveAppsFilter(entries: ["keepassxc"])
        XCTAssertTrue(filter.isSensitive(AppSource(name: "KeePassXC", bundleID: nil)))
    }

    /// 默认名单必须覆盖钥匙串访问与 Bitwarden（隐私底线，防名单回归）。
    func testDefaultsIncludePasswordManagers() {
        let filter = SensitiveAppsFilter(entries: SensitiveAppsFilter.defaults)
        XCTAssertTrue(filter.isSensitive(AppSource(name: "Keychain Access", bundleID: nil)))
        XCTAssertTrue(filter.isSensitive(AppSource(name: "Bitwarden", bundleID: nil)))
    }
}
