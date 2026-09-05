// TestHarness.swift — 测试隔离基座：一次性落盘沙箱 + 独立偏好域。
//
// 背景：HistoryController 的默认依赖指向真实用户数据——BlobStore 落在
// ~/Library/Application Support/GlassClip/（history.db 与三个子目录），
// AppSettings.shared 落在 UserDefaults.standard。因此任何 `HistoryController()`
// 都可能删改用户真实历史。本文件提供唯一入口，把两者指向随用例销毁的沙箱。
//
// 约定：需要数据层的用例一律经 makeIsolatedController() 构造，不要直接
// 调 HistoryController() / AppSettings.shared / BlobStore()。
import Foundation
import XCTest

@testable import GlassClip

extension XCTestCase {
    /// 构造脱离用户数据的落盘层：根目录在系统临时目录下，用例结束删除。
    @MainActor
    func makeSandboxBlobs(label: String = #function) -> BlobStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassClipTests-\(UUID().uuidString)-\(safe(label))", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlobStore(baseURL: root)
    }

    /// 构造独立偏好实例：写入专属 UserDefaults 域，用例结束清除该域。
    @MainActor
    func makeIsolatedSettings(label: String = #function) -> AppSettings {
        let suiteName = "com.ken.glassclip.tests.\(safe(label))-\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return AppSettings(defaults: defaults)
    }

    /// 构造沙箱数据层（未 start()，因此不会启动剪贴板轮询）。
    @MainActor
    func makeIsolatedController(label: String = #function) -> HistoryController {
        HistoryController(settings: makeIsolatedSettings(label: label), blobs: makeSandboxBlobs(label: label))
    }

    /// ClipboardItem 展示侧测试工厂（全仓唯一一份，③′ 测试侧消重）：
    /// HistoryListModel / ItemCategory / PanelKeyboardRouter 三组测试共用。
    /// 字段给无害默认，用例只覆盖关心的维度；previewText 缺省等于
    /// searchText（"预览即搜索文本"的常见形态）——区分两者正是
    /// testSearchMatchesSearchTextCaseInsensitively 的职责。
    /// 库层测试（HistoryDatabaseTests / SemanticsTests）的工厂刻意不合入：
    /// 它们各自钉着持久化语义（appName 往返断言、favoriteAt=createdAt
    /// 耦合、searchText 小写化），合一只会把旋钮换成另一份复杂度。
    func makeClipboardItem(
        id: UUID = UUID(),
        kind: ClipboardKind = .text,
        identity: String = "x",
        searchText: String = "s",
        previewText: String? = nil,
        favorite: Bool = false,
        favoriteAt: Date? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            kind: kind,
            identity: identity,
            searchText: searchText,
            previewText: previewText ?? searchText,
            appName: nil,
            appIconPath: nil,
            thumbnailPath: nil,
            createdAt: Date(timeIntervalSince1970: 1000),
            favorite: favorite,
            favoriteAt: favoriteAt
        )
    }

    /// 用例名可能含括号与空格，清洗成可用作路径与域名的片段。
    private func safe(_ label: String) -> String {
        label.filter(\.isLetter).prefix(24).lowercased()
    }
}
