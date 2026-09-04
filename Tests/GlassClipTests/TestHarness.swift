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

    /// 用例名可能含括号与空格，清洗成可用作路径与域名的片段。
    private func safe(_ label: String) -> String {
        label.filter(\.isLetter).prefix(24).lowercased()
    }
}
