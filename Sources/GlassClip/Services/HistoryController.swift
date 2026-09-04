// HistoryController.swift — 数据层总控：捕获入队、去重合并、缩略图/图标、
// 上限淘汰、粘贴回写、收藏/删除/清空。UI（面板、设置页）通过本类读写历史。
//
// 并发模型：@MainActor ObservableObject——items 数组是唯一内存事实源，
// @Published 驱动 SwiftUI 刷新；耗时工作（SQLite、落盘、图片处理）在
// await 点交给 actor/ detached Task，主线程只做轻量编排。
// 捕获可能高频到达（0.4s 轮询 + 用户连发），经 pendingCaptures 队列
// 串行消化，保证数据库写入永不并发。
//
// 持久化优先原则：先写库、成功后再删文件、最后动内存 items——
// 任何一步失败宁可留下孤儿文件，也不丢历史或出现"内存有库里无"。

import AppKit
import Combine
import Foundation

/// 历史记录的总控制器，也是 UI 观察数据变化的唯一入口。
@MainActor
final class HistoryController: ObservableObject {
    /// 内存中的历史列表（新 → 旧）。列表、收藏小节、预览分栏全部由它驱动。
    @Published private(set) var items: [ClipboardItem] = []

    /// 用户设置（热键/上限/敏感名单/autoPaste）。注入共享单例，测试可换。
    let settings: AppSettings
    /// 二进制落盘层（Blobs/Thumbs/Icons 三目录）。注入参数化，测试可指向临时目录
    /// （database 由 blobs.databaseURL 派生，因此它是库路径的唯一决定者）。
    private let blobs: BlobStore
    /// SQLite 历史库（actor，串行访问）。
    private let database: HistoryDatabase
    /// 剪贴板轮询监控。
    private let monitor = PasteboardMonitor()
    /// 待处理捕获队列：滴答解析完成后先入队，由消化 Task 逐条处理。
    private var pendingCaptures: [(CapturedContent, AppSource?)] = []
    /// 是否已有消化 Task 在跑（防止并发起多个）。
    private var isProcessingCaptures = false

    /// 初始化数据层并接通捕获回调。
    ///
    /// `try!`：数据库打不开属致命状态（历史工具没有"无库运行"的意义），
    /// 直接崩溃暴露问题，好过静默丢数据运行。
    init(settings: AppSettings = .shared, blobs: BlobStore = BlobStore()) {
        self.settings = settings
        self.blobs = blobs
        self.database = try! HistoryDatabase(location: blobs.databaseURL)
        monitor.onCapture = { [weak self] content, app in
            self?.enqueueCapture(content, app: app)
        }
    }

    /// 启动序列：加载历史 → 启动轮询 → 预热富文本缓存 → 启动摄取当前剪贴板。
    ///
    /// 由 AppDelegate 的异步 Task 调用，不阻塞应用启动。
    func start() async {
        items = (try? await database.loadItems()) ?? []
        monitor.start()
        await primeRichTextCache()
        await captureCurrentPasteboard()
    }

    /// 启动摄取：把启动那一刻剪贴板上的现内容收进历史（实现期补充决策，
    /// 避免重启后面板为空）。自家标记存在（上次退出前粘贴过）则跳过。
    /// 与轮询的幂等性：摄取走同一条 handleCapture，去重键保证重复内容只合并。
    private func captureCurrentPasteboard() async {
        guard !PasteboardIO.containsSelfMarker(), let content = PasteboardIO.readCapturedContent() else { return }
        await handleCapture(content, app: PasteboardIO.currentSource())
    }

    /// 预热富文本缓存：把最近 60 条富文本解析成 NSAttributedString 存入
    /// RichTextCache，面板滚动时行渲染零解析延迟。
    ///
    /// `items.lazy` 的意义：只为前 60 条物化，不对全量历史构建过滤副本
    /// （历史可能数千条，预览同时只会用到极少数）。
    private func primeRichTextCache() async {
        let richItems = items.lazy.filter { $0.kind == .richText }.prefix(60)
        for item in richItems {
            let payloads = await payloads(for: item)
            guard let attributed = payloads.attributedFromRTF else { continue }
            RichTextCache.prime(item.id, attributed)
        }
    }

    // MARK: - 捕获

    /// 捕获入口：入队并保证恰有一个消化 Task 在串行处理。
    ///
    /// 队列意义：轮询滴答与用户连续拷贝可能让捕获扎堆到达，
    /// 逐条 await 数据库写入，绝不并发。Task 引用刻意不持有：
    /// 它自行排干队列并清标志，没有任何取消需求。
    private func enqueueCapture(_ content: CapturedContent, app: AppSource?) {
        pendingCaptures.append((content, app))
        guard !isProcessingCaptures else { return }
        isProcessingCaptures = true
        Task { [weak self] in
            while let self, let (content, app) = self.pendingCaptures.first {
                self.pendingCaptures.removeFirst()
                await self.handleCapture(content, app: app)
            }
            self?.isProcessingCaptures = false
        }
    }

    /// 单条捕获的完整处理：敏感过滤 → 附属资源 → 去重分流（合并/新建）。
    ///
    /// 合并路径要点（设计共识"同内容合并置顶"）：
    /// - payload 表示做并集：旧条目已有的表示保留（老应用可能只给 RTF，
    ///   新拷贝给了 RTF+纯文本，合并后两种表示都有，粘贴兼容面更大）；
    /// - kind 取"更富"的（纯文本 < HTML < 富文本）；
    /// - createdAt 刷新为 now，并从原位置移到列表头（视觉上的"置顶"）；
    /// - 来源名/图标/缩略图只在有新值时覆盖，绝不因新拷贝缺信息而降级清空；
    /// - favorite 状态天然保留（updateMetadata 刻意不碰收藏列）。
    func handleCapture(_ content: CapturedContent, app: AppSource?) async {
        if settings.sensitiveFilter.isSensitive(app) { return }

        let now = Date()
        var thumbnailPath: String?
        if content.kind == .image, let png = content.payloads.first(where: { $0.uti == UTI.png })?.data {
            thumbnailPath = makeThumbnail(png, id: UUID())
        }
        let appIconPath = await appIconPath(for: app)
        let incoming = content.payloads.map { StoredPayload(uti: $0.uti, inline: $0.data, filePath: nil) }

        if let existingID = try? await database.uuidForIdentity(content.identity),
           let index = items.firstIndex(where: { $0.id == existingID }) {
            var item = items[index]
            var payloads = incoming
            let existingPayloads = (try? await database.payloads(for: item.id)) ?? []
            for payload in existingPayloads where !payloads.contains(where: { $0.uti == payload.uti }) {
                payloads.append(payload)
            }
            item.kind = Self.richer(item.kind, content.kind)
            item.searchText = content.searchText
            item.previewText = content.previewText
            item.createdAt = now
            if let name = app?.name { item.appName = name }
            if let iconPath = appIconPath { item.appIconPath = iconPath }
            if let thumbnailPath { item.thumbnailPath = thumbnailPath }

            let stored = await storePayloads(payloads, itemID: item.id)
            try? await database.updateMetadata(item)
            try? await database.replacePayloads(itemId: item.id, payloads: stored)
            items.remove(at: index)
            items.insert(item, at: 0)
        } else {
            let item = ClipboardItem(
                id: UUID(),
                kind: content.kind,
                identity: content.identity,
                searchText: content.searchText,
                previewText: content.previewText,
                appName: app?.name,
                appIconPath: appIconPath,
                thumbnailPath: thumbnailPath,
                createdAt: now,
                favorite: false,
                favoriteAt: nil
            )
            let stored = await storePayloads(incoming, itemID: item.id)
            try? await database.insert(item: item, payloads: stored)
            items.insert(item, at: 0)
            await enforceLimit()
        }
    }

    /// 富文本程度比较：纯文本(0) < HTML(1) < 富文本(2)；文本族之外的类型
    /// 一律视为最高档——实际不会参与比较（不同 identity 前缀的种类永不合并），
    /// 兜底只是让未知类型保守地保留旧值。
    nonisolated private static func richer(_ a: ClipboardKind, _ b: ClipboardKind) -> ClipboardKind {
        let rank: [ClipboardKind: Int] = [.text: 0, .html: 1, .richText: 2]
        let ra = rank[a] ?? 3
        let rb = rank[b] ?? 3
        return rb > ra ? b : a
    }

    /// payload 落库前的"大小分流"：超过 32KB 内联阈值的字节移到 Blobs/ 文件，
    /// 库里只存路径（防大图片撑爆 SQLite）。
    ///
    /// 写文件放 Task.detached：BlobStore 写盘是同步阻塞 IO，甩出 MainActor
    /// 执行再 await 结果，避免长拷贝时卡 UI。落盘失败（try? 为 nil）降级为
    /// 内联存储——数据不丢，只是库会大一点。
    private func storePayloads(_ payloads: [StoredPayload], itemID: UUID) async -> [StoredPayload] {
        var stored: [StoredPayload] = []
        for var payload in payloads {
            if let inline = payload.inline, inline.count > BlobStore.inlineThreshold {
                let path = try? await Task.detached {
                    try self.blobs.writeLargePayload(inline, id: UUID())
                }.value
                if let path {
                    payload.inline = nil
                    payload.filePath = path
                }
            }
            stored.append(payload)
        }
        return stored
    }

    /// 生成图片缩略图（最长边 ≤256px，等比，PNG 落盘）。
    ///
    /// nonisolated：纯图像处理，不依赖 actor 状态（blobs 是 Sendable let，
    /// 非 isolated 上下文可访问）。实际上仍从主线程调用。
    /// 绘制流程：解码原图 → 计算缩放（只缩不放，min(...,1)）→ 离屏画布
    /// 绘制 → TIFF 中转 → PNG 编码 → BlobStore 落盘。任一步失败返回 nil，
    /// 条目照常入库，只是预览分栏没有缩略图。
    nonisolated private func makeThumbnail(_ png: Data, id: UUID) -> String? {
        guard let image = NSImage(data: png) else { return nil }
        let maxSize: CGFloat = 256
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxSize / max(size.width, size.height), 1)
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let thumbnail = NSImage(size: target)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        thumbnail.unlockFocus()
        guard let data = thumbnail.pngData else { return nil }
        return try? blobs.writeThumbnail(data, id: id)
    }

    /// 来源应用图标：Icons/ 下按 bundleID 缓存，未命中才去解析应用并渲染 64px PNG。
    ///
    /// 图标按应用去重（同应用几百条记录共享一个文件），缓存命中时零成本返回。
    private func appIconPath(for app: AppSource?) async -> String? {
        guard let bundleID = app?.bundleID else { return nil }
        let path = blobs.appIconPath(forBundleID: bundleID)
        if FileManager.default.fileExists(atPath: path) { return path }
        guard let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 64, height: 64)
        guard let data = icon.pngData else { return nil }
        return try? blobs.writeAppIcon(data, bundleID: bundleID)
    }

    /// 条数上限淘汰（设计共识：上限默认 1000，收藏不受约束）。
    ///
    /// 每次新增条目后调用：查出"最新 limit 条非收藏"以外的旧条目，
    /// 逐条彻底清除（库行 + 落盘文件 + 缩略图），最后同步内存列表。
    private func enforceLimit() async {
        let limit = settings.historyLimit
        guard let stale = try? await database.oldestNonFavoriteIDs(beyondLimit: limit), !stale.isEmpty else { return }
        for id in stale {
            await purge(id, thumbnailPath: items.first { $0.id == id }?.thumbnailPath)
        }
        let staleSet = Set(stale)
        items.removeAll { staleSet.contains($0.id) }
    }

    /// 把一条记录从它存在的所有地方删干净：payload 落盘文件、缩略图、库行。
    /// 手动删除与上限淘汰共用，保证两条路径的清理语义一致。
    /// 顺序：先取路径 → 删文件 → 删库行。若最后一步失败，残留行会指向
    /// 已删除的文件；读取端（StoredPayload.data）按 nil 降级，调用方跳过
    /// 该表示，不会崩溃——宁要"丢表示"不要"留死文件"。
    private func purge(_ id: UUID, thumbnailPath: String?) async {
        let filePaths = (try? await database.payloadFilePaths(for: id)) ?? []
        for path in filePaths { blobs.deleteFile(at: path) }
        if let thumbnailPath { blobs.deleteFile(at: thumbnailPath) }
        try? await database.deleteItem(id: id)
    }

    // MARK: - Queries

    /// 读取某条目的全部 payload 表示（预览分栏与粘贴回写的数据源）。
    /// 大 payload 在此从磁盘文件惰性读回（StoredPayload.data 统一两种形态）。
    func payloads(for item: ClipboardItem) async -> [StoredPayload] {
        (try? await database.payloads(for: item.id)) ?? []
    }

    // MARK: - Actions

    /// 把条目写回剪贴板（Enter/点击行的动作）。
    ///
    /// - Parameter asPlainText: ⌘⇧V 纯文本粘贴——只取纯文本表示，
    ///   丢弃 RTF/HTML 富文本形态。
    /// 写入自带 UUID 标记（防自捕获），随后同步监控基线（双保险之二）。
    /// payload 读不出数据（文件被外部清理）的条目静默跳过。
    func copy(_ item: ClipboardItem, asPlainText: Bool = false) async {
        let payloads = await payloads(for: item)
        let selected: [ClipboardPayload]
        if asPlainText {
            guard let data = payloads.data(forUTI: UTI.plainText) else { return }
            selected = [ClipboardPayload(uti: UTI.plainText, data: data)]
        } else {
            selected = payloads.compactMap { stored in
                stored.data.map { ClipboardPayload(uti: stored.uti, data: $0) }
            }
        }
        guard !selected.isEmpty else { return }
        PasteboardIO.write(payloads: selected, marker: item.id)
        monitor.noteSelfWrite()
    }

    /// 收藏/取消收藏（悬停 ★ 与右键菜单）。库先写，内存后同步；
    /// favoriteAt 只在收藏瞬间记录（收藏小节的排序键）。
    func toggleFavorite(_ item: ClipboardItem) async {
        let favorite = !item.favorite
        try? await database.setFavorite(id: item.id, favorite: favorite, at: favorite ? Date() : nil)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].favorite = favorite
            items[index].favoriteAt = favorite ? Date() : nil
        }
    }

    /// 删除单条（⌫/右键菜单）：purge 全位置清理 + 内存移除。
    func delete(_ item: ClipboardItem) async {
        await purge(item.id, thumbnailPath: item.thumbnailPath)
        items.removeAll { $0.id == item.id }
    }

    /// 清空历史（保留收藏——设计共识）。
    ///
    /// 库层返回被删条目的 payload 文件路径清单，逐一删除；
    /// 缩略图不在该清单里（它不挂在 payloads 表），需按内存列表补删。
    /// 收藏条目在库与磁盘上都原样保留。
    func clearHistory() async {
        let filePaths = (try? await database.clear(keepingFavorites: true)) ?? []
        for path in filePaths { blobs.deleteFile(at: path) }
        for item in items where !item.favorite {
            if let thumb = item.thumbnailPath { blobs.deleteFile(at: thumb) }
        }
        items.removeAll { !$0.favorite }
    }
}
