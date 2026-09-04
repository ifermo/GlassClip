// BlobStore.swift — 二进制数据的磁盘存储层。
//
// 存储策略（设计共识）：SQLite 只存"小"数据与元信息，大字节落盘为文件、
// 库内存路径。边界由 `inlineThreshold` 划定（≤32KB 内联进 BLOB，更大落盘），
// 目的是防止单条 >100MB 的图片/文件把数据库撑爆、拖慢全表查询。
//
// 磁盘布局（baseURL 默认为 ~/Library/Application Support/GlassClip/）：
// - history.db   —— SQLite 主库（路径便捷入口 `databaseURL`）
// - Blobs/       —— 超限 payload 的原文文件（payload-<uuid>.bin）
// - Thumbs/      —— 图片条目的 PNG 缩略图（<uuid>.png）
// - Icons/       —— 来源应用图标缓存（<bundleID>.png，按应用去重复用）
//
// 并发约束：结构体本身无状态可变（baseURL 为 let），Sendable；
// 文件写入用 .atomic 保证中途崩溃不留半截文件。

import Foundation

struct BlobStore: Sendable {
    /// 存储根目录。测试可注入临时目录，生产走 Application Support。
    let baseURL: URL

    /// 初始化并确保三个子目录存在。
    ///
    /// 目录创建用 `try?` 吞错：目录已存在（最常见情形）会抛错但无碍；
    /// 真正的磁盘故障会在后续写入时以更明确的错误暴露。
    init(baseURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseURL = baseURL ?? support.appendingPathComponent("GlassClip", isDirectory: true)
        for sub in ["Blobs", "Thumbs", "Icons"] {
            try? FileManager.default.createDirectory(at: self.baseURL.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    /// 主数据库文件路径（HistoryDatabase 的默认打开位置）。
    var databaseURL: URL { baseURL.appendingPathComponent("history.db") }

    // MARK: - Payloads

    /// 内联/落盘的分界：≤32KB 的 payload 直接存 SQLite BLOB，
    /// 超过的写为 Blobs/ 下的文件、库里只存路径。
    static let inlineThreshold = 32 * 1024

    /// 把超限 payload 原文写入磁盘，返回落盘路径（存入 payloads.file_path 列）。
    ///
    /// - Parameters:
    ///   - data: payload 完整字节（可能上百 MB）。
    ///   - id: 所属条目 id，用作文件名主体（一个条目一个原文文件）。
    /// - Throws: 磁盘写入失败（空间不足、权限等）。
    func writeLargePayload(_ data: Data, id: UUID) throws -> String {
        let url = baseURL.appendingPathComponent("Blobs/payload-\(id.uuidString).bin")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// 尽力删除一个落盘文件（条目删除/清空历史时清理 Blobs 用）。
    ///
    /// 不抛错：文件已不存在属正常路径；删除失败至多留下孤儿文件，
    /// 不应让它阻断数据库删除流程。
    func deleteFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Thumbnails & icons

    /// 写入图片条目的 PNG 缩略图，返回路径（存入 items.thumbnail 列）。
    func writeThumbnail(_ data: Data, id: UUID) throws -> String {
        let url = baseURL.appendingPathComponent("Thumbs/\(id.uuidString).png")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// 某来源应用图标的缓存路径（是否真的存在由调用方判断）。
    ///
    /// 图标按 bundleID 而非条目 id 命名：同一应用的几百条记录共享一个图标文件。
    func appIconPath(forBundleID bundleID: String) -> String {
        baseURL.appendingPathComponent("Icons/\(bundleID).png").path
    }

    /// 写入来源应用图标缓存，返回路径（存入 items.app_icon 列）。
    func writeAppIcon(_ data: Data, bundleID: String) throws -> String {
        let url = baseURL.appendingPathComponent("Icons/\(bundleID).png")
        try data.write(to: url, options: .atomic)
        return url.path
    }
}
