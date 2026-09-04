// PasteboardMonitor.swift — 剪贴板变更监控（捕获管线的触发器）。
//
// 设计共识：0.4s 轮询 changeCount，而非 NSPasteboard 通知/事件钩子——
// 系统没有"剪贴板变了"的可靠推送API，轮询是常驻工具的朴素可靠解。
// 每次滴答：计数变了 → 排除自家写入 → 读取解析 → 回调 onCapture。
//
// 线程约束：@MainActor。Timer 闭包本身不带隔离，但定时器挂在主 RunLoop，
// 用 MainActor.assumeIsolated 桥接（运行时确实在主线程，桥接是安全的）。

import AppKit
import Foundation

/// 轮询式剪贴板监控器。
@MainActor
final class PasteboardMonitor {
    /// 定时器的第二份强引用（RunLoop 调度时已持有一份），防被释放。
    /// 本类没有 stop()：start 之后定时器存活到进程结束——这是冻结的已知缺陷，
    /// 属性保留着，将来补 stop() 时是唯一可用的挂点。
    private var timer: Timer?
    /// 上次轮询看到的变更计数（去重基线：只对"变了"的滴答做读取解析）。
    private var lastChangeCount: Int = 0

    /// 捕获回调：解析完成的待入库内容 + 来源归因。
    /// 由 HistoryController 在启动时接上（enqueueCapture）。
    var onCapture: (@MainActor (CapturedContent, AppSource?) -> Void)?

    /// 启动轮询。
    ///
    /// 两个细节：
    /// - 基线取"当前"计数而非 0：启动瞬间剪贴板里的存量内容不当作变更
    ///   （启动摄取由 HistoryController.captureCurrentPasteboard 专门负责）；
    /// - RunLoop mode 用 .common：菜单跟踪/滚动等模态期间默认 mode 挂起，
    ///   .common 保证用户在别的应用菜单里复制时也能被记录。
    func start() {
        lastChangeCount = PasteboardIO.changeCount()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 声明"刚才那次剪贴板变更是我们自己写的"。
    ///
    /// 粘贴回写后调用：把基线同步到当前计数，让下个滴答不把自家的
    /// 写入当外部变更。与剪贴板上的自标记（containsSelfMarker）组成
    /// 双保险——标记防"读到"，基线防"走进来"。
    func noteSelfWrite() {
        lastChangeCount = PasteboardIO.changeCount()
    }

    /// 一次轮询滴答：计数未变 → 直接返回；是自家写入 → 跳过；
    /// 否则读取解析并回调。任何一步失败都静默结束（下个滴答再来）。
    private func tick() {
        let count = PasteboardIO.changeCount()
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !PasteboardIO.containsSelfMarker() else { return }

        guard let content = PasteboardIO.readCapturedContent() else { return }
        onCapture?(content, PasteboardIO.currentSource())
    }
}
