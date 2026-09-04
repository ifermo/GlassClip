// HistoryDatabase.swift — SQLite 持久化层（底层直接使用系统 sqlite3 C API）。
//
// 职责：items/payloads 两张表的读写、去重键查询、收藏状态、条数上限淘汰、
// 清空历史。二进制大对象的"落盘文件"由 BlobStore 管理，本层只存路径。
//
// 并发模型：整类是 actor——所有读写天然串行，杜绝 sqlite 句柄的跨线程竞态；
// 打开连接时额外加 SQLITE_OPEN_FULLMUTEX（库级互斥）作为双保险。
// 迁移建表在 nonisolated 静态方法中完成（此时 actor 尚未可用）。
//
// Schema 要点：
// - items：一行 = 一条历史。identity 列是去重键（有索引）；favorite 条目
//   不受条数上限与 Clear History 约束（设计共识）。
// - payloads：一行 = 条目的一个 UTI 表示。主键 (item_id, uti) 保证同一
//   条目同一 UTI 只有一行；pos 列保留剪贴板上的表示顺序（回写时按序还原）。
// - 大 payload：inline BLOB 只存 ≤32KB 的小数据，更大的存 Blobs/ 文件路径。

import Foundation
import SQLite3

// MARK: - 读取模型

/// payloads 表一行的读取视图：一个 UTI 表示的字节（内联）或其落盘路径。
///
/// `data` 访问器统一两种存储形态：优先取内联字节，否则从磁盘文件惰性读取；
/// 两者皆无（理论上不该发生）返回 nil。文件读取失败同样静默为 nil——
/// 调用方（粘贴回写）对拿不到数据的处理是跳过该表示。
struct StoredPayload: Sendable, Equatable {
    /// 统一类型标识（UTI）。
    var uti: String
    /// ≤32KB 小数据的内联字节；大数据为 nil。
    var inline: Data?
    /// 大数据的磁盘文件路径；内联数据为 nil。
    var filePath: String?

    /// 该表示的完整字节：内联优先，否则读盘。
    var data: Data? {
        if let inline { return inline }
        if let filePath { return try? Data(contentsOf: URL(fileURLWithPath: filePath)) }
        return nil
    }
}

extension Sequence where Element == StoredPayload {
    /// 取指定 UTI 的第一个表示的完整字节；没有该表示、或那一层字节读不出
    /// （文件被外部清理）都返回 nil。
    ///
    /// 语义与原写法 `first(where: { $0.uti == uti })?.data` 逐字相同：
    /// 保持 first 命中（同一 UTI 理论只出现一次，重复时取先出现的那个），
    /// 且"缺表示"与"读盘失败"两种 nil 不加区分。
    func data(forUTI uti: String) -> Data? {
        first { $0.uti == uti }?.data
    }

    /// RTF 表示 → NSAttributedString；无 RTF 或解析失败返回 nil。
    ///
    /// 预览预热（HistoryController.primeRichTextCache）与预览渲染
    /// （PreviewPane 的 NSTextView）原本各写一遍这两行。
    ///
    /// 只服务于 [StoredPayload]：捕获管线那边的 [ClipboardPayload] 其
    /// data 不可为空、且全站只有唯一一处 PNG 查找，套同一层抽象反而遮住差异。
    var attributedFromRTF: NSAttributedString? {
        guard let rtf = data(forUTI: UTI.rtf) else { return nil }
        return NSAttributedString(rtf: rtf, documentAttributes: nil)
    }
}

// MARK: - 数据库

/// SQLite 历史库的 actor 封装。
///
/// 用法：由 HistoryController 独占持有；所有方法 throws——sqlite 层的失败
/// 以 `GlassClipError.sqlite`（含引擎错误消息）上抛，由调用方决定吞或报。
actor HistoryDatabase {
    /// sqlite3 连接句柄。
    ///
    /// `nonisolated(unsafe)`：C 指针无法参与 Swift 隔离检查，实际安全性由
    /// actor 串行语义保证（所有使用都在 actor 内）+ FULLMUTEX 打开标志兜底。
    nonisolated(unsafe) private var handle: OpaquePointer?
    /// 数据库文件位置（仅存档用途，错误信息里带路径）。
    private let location: URL

    /// 打开（必要时创建）数据库并确保 schema 就绪。
    ///
    /// - Throws: 目录创建失败或 `databaseOpenFailed` / `sqlite`。
    init(location: URL) throws {
        self.location = location
        // 数据库所在目录可能尚不存在（首次启动/测试临时路径），先建目录。
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        handle = try Self.openAndMigrate(location: location)
    }

    /// 打开连接 + 幂等建表建索引。
    ///
    /// nonisolated static：init 阶段 actor 隔离尚未生效，C API 调用放在类方法里。
    /// 全部语句使用 IF NOT EXISTS，重复启动/升级均为无操作（无需版本化迁移，
    /// schema 自首版即稳定）。
    private nonisolated static func openAndMigrate(location: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        // FULLMUTEX：sqlite 内部加锁，防御未来代码路径意外跨线程使用句柄。
        guard sqlite3_open_v2(location.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw GlassClipError.databaseOpenFailed(location.path)
        }
        // WAL 模式：写入不再阻塞读、崩溃后自动恢复到一致状态，适合常驻进程频繁小写入。
        try exec(db!, "PRAGMA journal_mode=WAL")
        try exec(db!, """
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            identity TEXT NOT NULL,
            kind TEXT NOT NULL,
            search_text TEXT NOT NULL DEFAULT '',
            preview_text TEXT NOT NULL DEFAULT '',
            app_name TEXT,
            app_icon TEXT,
            thumbnail TEXT,
            created_at REAL NOT NULL,
            favorite INTEGER NOT NULL DEFAULT 0,
            favorite_at REAL
        )
        """)
        // identity 索引：每次捕获都要做去重键等值查询（uuidForIdentity）。
        try exec(db!, "CREATE INDEX IF NOT EXISTS idx_items_identity ON items(identity)")
        // created_at 索引：列表按时间倒序加载 + 条数上限的 OFFSET 淘汰查询。
        try exec(db!, "CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at)")
        try exec(db!, """
        CREATE TABLE IF NOT EXISTS payloads (
            item_id TEXT NOT NULL,
            uti TEXT NOT NULL,
            pos INTEGER NOT NULL,
            inline BLOB,
            file_path TEXT,
            PRIMARY KEY (item_id, uti)
        )
        """)
        return db!
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: sqlite C API 薄封装

    /// 执行无结果语句（PRAGMA / CREATE / 无参 DELETE），sqlite 错误消息上抛。
    private nonisolated static func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw GlassClipError.sqlite(message)
        }
    }

    /// actor 内执行无结果语句（`exec` 的隔离版本）。
    private func execute(_ sql: String) throws {
        try Self.exec(handle!, sql)
    }

    /// 预编译 SQL 为 stmt；失败时携带引擎错误消息抛出。
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GlassClipError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        return stmt!
    }

    /// SQLITE_TRANSIENT 常量：让 sqlite 在 bind 时自行拷贝缓冲区，
    /// 从而 Swift 侧的临时 String/Data 在语句执行前销毁也安全。
    /// sqlite3 头文件里该常量是 ((sqlite3_destructor_type)-1)，Swift 需按位构造。
    private static let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    // MARK: 绑定

    /// 绑定 String 参数（-1 表示以 NUL 结尾自动测长）。
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    /// 绑定 Double 参数（时间戳、REAL 列）。
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    /// 绑定 Int 参数（pos、favorite 等整型列）。
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    /// 绑定 Data 参数为 BLOB（空 Data 也是合法 BLOB，区别于 NULL）。
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Data) {
        value.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), Self.transient)
        }
    }

    /// 可空绑定：nil 落为 SQL NULL（inline / file_path / favorite_at 列）。
    private func bindNullable(_ stmt: OpaquePointer, _ index: Int32, _ value: Data?) {
        if let value {
            bind(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// 可空 String 绑定。
    private func bindNullable(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bind(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// 可空 Double 绑定（favorite_at 为 nil 即"未收藏时间"）。
    private func bindNullable(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// 读取 TEXT 列为 String；SQL NULL 返回 nil。
    ///
    /// 可空列专用（appName / appIconPath / thumbnailPath / payloads.file_path）：
    /// nil 与空串在这几处语义不同（有值 vs 从没录过）。
    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    /// 读取 TEXT 列，SQL NULL 回退为空串。
    ///
    /// 用于 NOT NULL 列与 loadItems 那套"行宁可显示异常也不凭空消失"的容错回落；
    /// 收口成一处，免得八个 `?? ""` 各写一遍、漏掉一个就把非空列读成 nil。
    private func textOrEmpty(_ stmt: OpaquePointer, _ index: Int32) -> String {
        text(stmt, index) ?? ""
    }

    /// 执行写入型语句并断言 DONE；失败携带引擎错误消息抛出。
    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw GlassClipError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    // MARK: - Reads

    /// 全量加载历史条目，按捕获时间倒序（面板列表的初始数据源）。
    ///
    /// 容错策略：单行字段损坏（UUID/kind 解析失败）回退到默认值而不是
    /// 丢弃整行——历史数据宁可显示异常也不凭空消失。
    func loadItems() throws -> [ClipboardItem] {
        let sql = """
        SELECT id, identity, kind, search_text, preview_text, app_name, app_icon, thumbnail,
               created_at, favorite, favorite_at
        FROM items ORDER BY created_at DESC
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var items: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: textOrEmpty(stmt, 0)) ?? UUID()
            let item = ClipboardItem(
                id: id,
                kind: ClipboardKind(rawValue: textOrEmpty(stmt, 2)) ?? .text,
                identity: textOrEmpty(stmt, 1),
                searchText: textOrEmpty(stmt, 3),
                previewText: textOrEmpty(stmt, 4),
                appName: text(stmt, 5),
                appIconPath: text(stmt, 6),
                thumbnailPath: text(stmt, 7),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                favorite: sqlite3_column_int(stmt, 9) != 0,
                favoriteAt: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
            )
            items.append(item)
        }
        return items
    }

    /// 按去重键查已有条目的 id——捕获管线判断"新条目还是合并置顶"的入口查询。
    ///
    /// 命中 identity 索引；未命中返回 nil（走插入路径）。
    func uuidForIdentity(_ identity: String) throws -> UUID? {
        let stmt = try prepare("SELECT id FROM items WHERE identity = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, identity)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return UUID(uuidString: textOrEmpty(stmt, 0))
    }

    /// 加载某条目的全部 UTI 表示，按 pos 排序（粘贴回写时的数据来源）。
    ///
    /// inline 列三态处理：SQL NULL → nil（走文件路径）；零长度 → 空 Data
    /// （合法值，如空字符串）；其余 → 拷贝 BLOB 字节。
    /// 注意 sqlite3_column_blob 对零长度 BLOB 可能返回非法指针，必须先按
    /// byteCount 分流，不能直接用 `!` 强解。
    func payloads(for id: UUID) throws -> [StoredPayload] {
        let stmt = try prepare("""
        SELECT uti, inline, file_path FROM payloads WHERE item_id = ? ORDER BY pos
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        var result: [StoredPayload] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let byteCount = Int(sqlite3_column_bytes(stmt, 1))
            let inline: Data?
            if sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                inline = nil
            } else if byteCount == 0 {
                inline = Data()
            } else {
                inline = Data(bytes: sqlite3_column_blob(stmt, 1)!, count: byteCount)
            }
            result.append(StoredPayload(uti: textOrEmpty(stmt, 0), inline: inline, filePath: text(stmt, 2)))
        }
        return result
    }

    /// 条数上限淘汰查询：返回"最新的 limit 条非收藏"之外的更旧条目 id。
    ///
    /// SQL 技巧：`LIMIT -1 OFFSET ?` = 跳过前 limit 行后取剩余全部。
    /// 收藏条目被 WHERE favorite = 0 排除——上限不约束收藏（设计共识）。
    /// 返回顺序由旧到新无所谓，调用方逐条删除并清理对应落盘文件。
    func oldestNonFavoriteIDs(beyondLimit limit: Int) throws -> [UUID] {
        let stmt = try prepare("""
        SELECT id FROM items WHERE favorite = 0 ORDER BY created_at DESC LIMIT -1 OFFSET ?
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, limit)
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = UUID(uuidString: textOrEmpty(stmt, 0)) { ids.append(id) }
        }
        return ids
    }

    // MARK: - Writes

    /// 插入新条目及其全部 payload 表示。
    ///
    /// payload 经 `replacePayloads` 写入（先清后插，语义等价于"全新条目"）。
    /// - Throws: sqlite 错误（如主键冲突——正常流程不会发生，去重路径走 update）。
    func insert(item: ClipboardItem, payloads: [StoredPayload]) throws {
        let stmt = try prepare("""
        INSERT INTO items (id, identity, kind, search_text, preview_text, app_name, app_icon, thumbnail, created_at, favorite, favorite_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, item.id.uuidString)
        bind(stmt, 2, item.identity)
        bind(stmt, 3, item.kind.rawValue)
        bind(stmt, 4, item.searchText)
        bind(stmt, 5, item.previewText)
        bindNullable(stmt, 6, item.appName)
        bindNullable(stmt, 7, item.appIconPath)
        bindNullable(stmt, 8, item.thumbnailPath)
        bind(stmt, 9, item.createdAt.timeIntervalSince1970)
        bind(stmt, 10, item.favorite ? 1 : 0)
        bindNullable(stmt, 11, item.favoriteAt?.timeIntervalSince1970)
        try stepDone(stmt)
        try replacePayloads(itemId: item.id, payloads: payloads)
    }

    /// 更新条目元信息（去重命中合并置顶时调用：刷新时间戳/预览/来源等）。
    ///
    /// 刻意不更新 favorite/favorite_at 两列：合并必须保留用户已点下的收藏状态。
    func updateMetadata(_ item: ClipboardItem) throws {
        let stmt = try prepare("""
        UPDATE items SET identity = ?, kind = ?, search_text = ?, preview_text = ?,
                         app_name = ?, app_icon = ?, thumbnail = ?, created_at = ?
        WHERE id = ?
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, item.identity)
        bind(stmt, 2, item.kind.rawValue)
        bind(stmt, 3, item.searchText)
        bind(stmt, 4, item.previewText)
        bindNullable(stmt, 5, item.appName)
        bindNullable(stmt, 6, item.appIconPath)
        bindNullable(stmt, 7, item.thumbnailPath)
        bind(stmt, 8, item.createdAt.timeIntervalSince1970)
        bind(stmt, 9, item.id.uuidString)
        try stepDone(stmt)
    }

    /// 全量替换某条目的 payload 表示：先 DELETE 后逐行 INSERT。
    ///
    /// 逐行循环里必须 reset + clear_bindings 再复用同一 stmt（预编译一次）。
    /// pos 取枚举下标，保证读取端按原顺序还原。
    func replacePayloads(itemId: UUID, payloads: [StoredPayload]) throws {
        let delete = try prepare("DELETE FROM payloads WHERE item_id = ?")
        defer { sqlite3_finalize(delete) }
        bind(delete, 1, itemId.uuidString)
        try stepDone(delete)
        let stmt = try prepare("INSERT INTO payloads (item_id, uti, pos, inline, file_path) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        for (index, payload) in payloads.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bind(stmt, 1, itemId.uuidString)
            bind(stmt, 2, payload.uti)
            bind(stmt, 3, index)
            bindNullable(stmt, 4, payload.inline)
            bindNullable(stmt, 5, payload.filePath)
            try stepDone(stmt)
        }
    }

    /// 某条目指向落盘文件的全部路径（删除条目后同步清理 BlobStore 文件用）。
    func payloadFilePaths(for id: UUID) throws -> [String] {
        try filePaths("SELECT file_path FROM payloads WHERE item_id = ? AND file_path IS NOT NULL", binding: id)
    }

    /// 三个"只要一列路径"的查询（单条目/清空-保留收藏/清空-全删）共用的只读助手。
    private func filePaths(_ sql: String, binding id: UUID? = nil) throws -> [String] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let id { bind(stmt, 1, id.uuidString) }
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let path = text(stmt, 0) { paths.append(path) }
        }
        return paths
    }

    /// 设置/取消收藏。
    ///
    /// - Parameter date: 收藏时传当前时间（写入 favorite_at，收藏小节按它倒序）；
    ///   取消收藏时传 nil（favorite_at 置空）。
    func setFavorite(id: UUID, favorite: Bool, at date: Date?) throws {
        let stmt = try prepare("UPDATE items SET favorite = ?, favorite_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, favorite ? 1 : 0)
        bindNullable(stmt, 2, date?.timeIntervalSince1970)
        bind(stmt, 3, id.uuidString)
        try stepDone(stmt)
    }

    /// 删除单条：先删 payloads 再删 items（无外键约束，顺序保证不留孤儿 payload 行）。
    ///
    /// 落盘文件的清理不在本层——调用方拿 `payloadFilePaths(for:)` 的结果
    /// 交 BlobStore 删除，数据库失败时文件得以保留（先库后文件的安全顺序）。
    func deleteItem(id: UUID) throws {
        let deletePayloads = try prepare("DELETE FROM payloads WHERE item_id = ?")
        defer { sqlite3_finalize(deletePayloads) }
        bind(deletePayloads, 1, id.uuidString)
        try stepDone(deletePayloads)
        let deleteItem = try prepare("DELETE FROM items WHERE id = ?")
        defer { sqlite3_finalize(deleteItem) }
        bind(deleteItem, 1, id.uuidString)
        try stepDone(deleteItem)
    }

    /// 清空历史。
    ///
    /// - Parameter keepingFavorites: true 时保留收藏条目（Clear History 的默认语义）。
    /// - Returns: 被删条目指向的落盘文件路径列表，调用方负责删除文件
    ///   （先删库行、成功后再删文件：中途失败最多留孤儿文件，不丢单）。
    func clear(keepingFavorites: Bool) throws -> [String] {
        let filePaths = try clearPayloadFilePaths(keepingFavorites: keepingFavorites)
        if keepingFavorites {
            try execute("DELETE FROM payloads WHERE item_id IN (SELECT id FROM items WHERE favorite = 0)")
            try execute("DELETE FROM items WHERE favorite = 0")
        } else {
            try execute("DELETE FROM payloads")
            try execute("DELETE FROM items")
        }
        return filePaths
    }

    /// 清空前先取走将被删除条目的落盘文件路径（供 `clear` 返回）。
    private func clearPayloadFilePaths(keepingFavorites: Bool) throws -> [String] {
        try filePaths(keepingFavorites
            ? "SELECT file_path FROM payloads WHERE file_path IS NOT NULL AND item_id IN (SELECT id FROM items WHERE favorite = 0)"
            : "SELECT file_path FROM payloads WHERE file_path IS NOT NULL")
    }
}

// MARK: - 错误类型

/// 持久化层错误：打开失败（含路径）与 SQL 执行失败（含引擎错误消息）。
enum GlassClipError: Error {
    case databaseOpenFailed(String)
    case sqlite(String)
}
