// PasteboardIO.swift — NSPasteboard 的读写门面（捕获管线的系统边界）。
//
// 职责仅三件事：读取系统剪贴板的原始字节、读来源归因、把 payload 回写剪贴板。
// 所有"解析/去重/建 identity"的智力活都推给 ClipboardCapture，本文件保持
// 纯 IO，便于 mock 与测试。
//
// 线程约束：整体 @MainActor——NSPasteboard 读取要求主线程，且来源归因
// 依赖 NSWorkspace.frontmostApplication（同样主线程语义）。

import AppKit
import Foundation

/// 系统剪贴板访问层。
@MainActor
enum PasteboardIO {
    /// 系统通用剪贴板（集中一个入口，测试/未来多剪贴板扩展时好替换）。
    static var pasteboard: NSPasteboard { .general }

    /// 当前变更计数：每次任何人写剪贴板它 +1。
    /// 轮询监控（PasteboardMonitor）靠比较两次轮询间的计数判断"有新内容"。
    static func changeCount() -> Int {
        pasteboard.changeCount
    }

    /// 剪贴板是否带有自家写入标记（`ClipboardCapture.selfWriteUTI`）。
    ///
    /// 有标记 = 这份内容是 GlassClip 自己粘贴回写的 → 跳过捕获，
    /// 否则"粘贴一条旧记录"会被当成新拷贝再记一次。
    static func containsSelfMarker() -> Bool {
        pasteboard.types?.contains { $0.rawValue == ClipboardCapture.selfWriteUTI } ?? false
    }

    /// 读取剪贴板当前全部非空表示，保持剪贴板自身的类型顺序。
    ///
    /// - 同一 UTI 重复出现时只取第一次（`seen` 去重）；
    /// - 取不到数据或数据为空的类型直接跳过（空类型无捕获价值）；
    /// - 颜色类型不在此列——NSColor 经 writeObjects 写入，无法按类型直读，
    ///   走专门的 `readColorEntry()`。
    static func readEntries() -> [PasteboardEntry] {
        guard let types = pasteboard.types, !types.isEmpty else { return [] }
        var entries: [PasteboardEntry] = []
        var seen = Set<String>()
        for type in types {
            let uti = type.rawValue
            guard seen.insert(uti).inserted else { continue }
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            entries.append(PasteboardEntry(uti: uti, data: data))
        }
        return entries
    }

    /// 读取颜色表示：经 NSColor(from:) 解析后再安全归档为字节。
    ///
    /// 为什么不直接读 data(forType:)：颜色对象由 AppKit writeObjects 写入，
    /// 其字节表示是键值归档，必须走 NSColor 的专用入口解析；
    /// requiringSecureCoding 保证只解出 NSColor，拒绝任意反归档风险。
    static func readColorEntry() -> PasteboardEntry? {
        guard let color = NSColor(from: pasteboard),
              let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        else { return nil }
        return PasteboardEntry(uti: UTI.color, data: data)
    }

    /// 一次完整的"读取 + 解析"：原始表示 + 颜色补充 + 来源归因 → CapturedContent。
    ///
    /// 返回 nil 的情形：剪贴板为空 / 全是空条目 / 超过大小上限 / 自家写入。
    /// （自家写入的拦截在调用方 PasteboardMonitor：先查 containsSelfMarker。）
    static func readCapturedContent() -> CapturedContent? {
        var entries = readEntries()
        if let color = readColorEntry() {
            entries.append(color)
        }
        return ClipboardCapture.capture(from: entries, app: currentSource())
    }

    /// 来源归因：取前台应用作为拷贝来源。
    ///
    /// 特例：前台是登录窗（com.apple.loginwindow）时视为未知来源（nil）——
    /// 系统锁屏/切换用户瞬间的前台信息没有归因意义（实现期补充决策）。
    static func currentSource() -> AppSource? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.apple.loginwindow"
        else { return nil }
        return AppSource(name: app.localizedName, bundleID: app.bundleIdentifier)
    }

    /// 粘贴回写：把选中条目的全部表示写回系统剪贴板。
    ///
    /// 流程与细节：
    /// 1. clearContents 清掉旧内容（顺带让 changeCount +1）；
    /// 2. 先写自标记（UUID 字符串，类型 selfWriteUTI）——捕获监控看到标记
    ///    就跳过本次变更，防止"粘贴"被当成"新拷贝"；
    /// 3. 逐个写 payload：空数据跳过；颜色类型必须反归档成 NSColor 走
    ///    writeObjects（setData 写归档字节，别的应用读不出颜色）；其余 setData。
    static func write(payloads: [ClipboardPayload], marker: UUID) {
        pasteboard.clearContents()
        pasteboard.setString(marker.uuidString, forType: NSPasteboard.PasteboardType(ClipboardCapture.selfWriteUTI))
        for payload in payloads {
            guard !payload.data.isEmpty else { continue }
            let data = payload.data
            let type = NSPasteboard.PasteboardType(payload.uti)
            if payload.uti == UTI.color {
                if let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                    pasteboard.writeObjects([color])
                    continue
                }
            }
            pasteboard.setData(data, forType: type)
        }
        // 写完立刻读一次计数，拿到的是本次写入后的值（监控轮询以计数变化为信号）。
        _ = pasteboard.changeCount
    }
}
