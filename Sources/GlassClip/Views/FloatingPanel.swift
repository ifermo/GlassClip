// FloatingPanel.swift — 浮动历史面板的 AppKit 窗口层。
//
// 设计共识中的窗口行为全部在这里落地：宽度固定 520，高度随列表内容
// 自适应（min 230 / max 680，且不超过光标所在屏可用高度）、出现在
// 光标附近且跨屏感知、失焦自动隐藏、fade ≈150ms 渐入、不抢焦点
// （nonactivating，GlassClip 保持 accessory 而当前应用保持前台）。
//
// 分层：GlassPanel（窗口子类）只解决"无边框面板能否成为 key 窗口"，
// PanelController 负责生命周期（创建/定位/显隐）与热键接线；
// SwiftUI 内容（PanelRootView）通过 NSHostingView 直接作为窗口内容，
// 材质与圆角形状由 SwiftUI panelMaterial 双路径一并负责（26+ Liquid
// Glass / 14/15 ultraThinMaterial fallback）。

import AppKit
import SwiftUI

/// 面板窗口。
///
/// NSPanel 默认对无边框样式返回 canBecomeKey = false——键盘导航
/// （↑↓/Enter/Esc）会全部失效，必须显式打开。仅此一个职责。
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 面板生命周期控制器：热键切换、惰性建窗、定位、渐入渐出。
@MainActor
final class PanelController: NSObject {
    /// 面板宽度固定（设计共识），高度自适应。
    static let panelWidth: CGFloat = 520
    /// 高度下限：盖住搜索条 + Tab 条 + 约 2 行；空态也用此高度。
    static let minPanelHeight: CGFloat = 230
    /// 高度上限（沿用原 680 共识），实际还受光标所在屏钳制。
    static let maxPanelHeight: CGFloat = 680
    /// 高度上限随屏幕钳制时预留的垂直边距。
    static let screenVerticalMargin: CGFloat = 24

    /// 面板动画时长：渐入与改位/改高两处共用（AppKit 的 NSAnimationContext 侧）。
    /// 与 SwiftUI 侧的 Animation.panelQuick / .previewToggle 是两套节奏体系，
    /// 数值相近纯属各自场景的合适值，不要合并。
    static let animationDuration: TimeInterval = 0.15

    /// 高度钳位纯函数（尺寸策略的唯一归属地）：内容高度 → 面板高度。
    /// 先 max = min(680, 屏幕可用高 − 24)，再对 min 取下限——极端小屏上
    /// min 是绝对地板，可用性优先于完全容纳。
    static func clampedPanelHeight(contentHeight: CGFloat, screenVisibleHeight: CGFloat) -> CGFloat {
        let maxHeight = min(maxPanelHeight, screenVisibleHeight - screenVerticalMargin)
        return max(minPanelHeight, min(contentHeight, maxHeight))
    }

    /// 数据层（列表数据源与动作执行者）。
    let controller: HistoryController
    /// 全局热键。生命周期与 PanelController 相同。
    private let hotKeyManager = HotKeyManager()
    /// 面板窗口，首次 show 时惰性创建后复用（反复建窗开销大且丢滚动位置）。
    private var panel: GlassPanel?
    /// 最近一次实测的内容总高（SwiftUI 经 onHeightChange 上报，未钳位）。
    /// 首次 show 前无实测值，以 min 起步；上屏后一帧内由实测回调修正。
    private var measuredContentHeight: CGFloat = PanelController.minPanelHeight
    /// show 时刻冻结的锚点：光标位置与其所在屏 visibleFrame。可见期间
    /// 高度变化只围绕此锚点伸缩，面板不追鼠标。
    private var anchorMouse = NSPoint.zero
    private var anchorVisibleFrame = NSRect.zero

    /// "打开设置"回调：由 AppDelegate 注入（面板齿轮 → 自持设置窗口）。
    var onOpenSettings: (() -> Void)?

    init(controller: HistoryController) {
        self.controller = controller
    }

    /// 启动接线：热键按下 → 切换面板。由 AppDelegate 启动序列调用。
    func start() {
        hotKeyManager.onHotKey = { [weak self] in self?.toggle() }
        reapplyHotKey()
    }

    /// 按当前设置重新注册热键（启动时与设置页改键后各调用一次）。
    func reapplyHotKey() {
        let combo = HotKeyCombo(modifiers: controller.settings.hotKeyModifiers, keyCode: controller.settings.hotKeyCode)
        hotKeyManager.register(combo)
    }

    /// 热键语义：可见即隐藏，否则显示。
    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    /// 显示面板：冻结锚点 → 按缓存高度落位 → 上屏成为 key → 150ms easeOut 渐入。
    ///
    /// show 不做高度动画：直接以缓存高度上屏（隐藏期间内容可能已变，
    /// 上屏后一帧内由实测回调修正，误差被渐入遮盖）。
    /// 先 makeKeyAndOrderFront 再做透明度动画：保证动画期间窗口已可见
    /// 且能接收键盘，用户可以在淡入过程中直接开始打字。
    func show() {
        let panel = ensurePanel()
        captureAnchor()
        let height = Self.clampedPanelHeight(
            contentHeight: measuredContentHeight,
            screenVisibleHeight: anchorVisibleFrame.height
        )
        placePanel(panel, height: height, animated: false)
        panel.makeKeyAndOrderFront(nil)
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// 隐藏面板。orderOut 立即下屏（无渐出）——粘贴回写场景里
    /// "面板消失 → 焦点回到原应用 → 合成 ⌘V"要尽快完成。
    func hide() {
        panel?.orderOut(nil)
    }

    /// SwiftUI 实测回调（PanelRootView.onHeightChange）：无条件更新缓存；
    /// 仅当面板可见且新高度与当前差 ≥1pt 时才 setFrame——打即搜每键触发
    /// 回调，无变化的高频调用在这里被挡掉。
    func applyMeasuredHeight(_ contentHeight: CGFloat) {
        measuredContentHeight = ceil(contentHeight)
        guard let panel, panel.isVisible, !anchorVisibleFrame.isEmpty else { return }
        let target = Self.clampedPanelHeight(
            contentHeight: measuredContentHeight,
            screenVisibleHeight: anchorVisibleFrame.height
        )
        guard abs(target - panel.frame.height) >= 1 else { return }
        placePanel(panel, height: target, animated: true)
    }

    /// 惰性创建面板（一次创建，进程内复用）。
    ///
    /// 窗口配置逐项说明：
    /// - styleMask [.borderless, .nonactivatingPanel]：无边框 + 上屏不激活
    ///   本应用（当前应用保持前台，剪贴板归属逻辑不受干扰）；
    /// - level .floating：悬浮在普通窗口之上（设计共识）；
    /// - isOpaque = false + backgroundColor = .clear：窗口本体全透明，
    ///   圆角外观完全交给 SwiftUI 内容层的 glassEffect 形状；
    /// - hasShadow = false：必须关。borderless 透明窗口的原生阴影由
    ///   AppKit 按窗口矩形边界生成，不认玻璃视图的圆角裁切，会在
    ///   圆角玻璃外沿糊出一圈紧贴边缘的黑色硬线框（黑框 bug 根因，
    ///   debug/ 截图回路逐像素证实 + FloatingPanelShadowTests 回归锁定）。
    ///   需要投影层次时在合成层自绘，不得重开窗口级阴影；
    /// - collectionBehavior：所有 Space 可见（canJoinAllSpaces）、支持
    ///   全屏应用上方辅助显示（fullScreenAuxiliary）、不参与 ⌘` 窗口循环
    ///   （ignoresCycle，工具面板不该进 App 窗口切换序列）；
    /// - delegate 指向自己：失焦隐藏（windowDidResignKey）。
    ///
    /// 视觉结构：NSHostingView 直接作为 contentView，SwiftUI 根视图
    /// （PanelRootView）用 panelMaterial(in: 圆角 20 连续曲率) 承担材质与
    /// 外观形状（26+ Liquid Glass / 14/15 ultraThinMaterial fallback）——
    /// 三层形状收敛在 SwiftUI 一处，26 上窗口服务器按该形状合成玻璃。
    ///
    /// 历史教训（2026-09-04 圆角外围浅色残留 bug）：此前用
    /// NSGlassEffectView(cornerRadius: 20) 包 NSHostingView，其实测在
    /// "作为无边框透明窗口 contentView"的用法下未按设定值裁切玻璃霜面，
    /// 四角在内容圆弧之外露出浅色材质（SwiftUI clipShape 20 与玻璃层
    /// 形状不一致）。glassEffect 的 in: shape 参数不存在该歧义，形状
    /// 由 SwiftUI 显式给定；不要换回 NSGlassEffectView。
    private func ensurePanel() -> GlassPanel {
        if let panel { return panel }

        let panel = GlassPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.panelWidth, height: Self.minPanelHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self as NSWindowDelegate

        let hosting = NSHostingView(
            rootView: PanelRootView(
                controller: controller,
                onClose: { [weak self] in self?.hide() },
                onOpenSettings: { [weak self] in self?.onOpenSettings?() },
                onHeightChange: { [weak self] in self?.applyMeasuredHeight($0) }
            )
        )
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// 冻结锚点：记下 show 时刻"光标所在屏幕"的光标位置与该屏
    /// visibleFrame（多显示器时跟随鼠标而非主屏，找不到退回 NSScreen.main）。
    /// 可见期间的高度变化全部以此为基准，面板不追鼠标。
    private func captureAnchor() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        anchorMouse = mouse
        anchorVisibleFrame = screen?.visibleFrame ?? .zero
    }

    /// 以冻结锚点定位并定高：底边贴光标下方 16px、面板向上生长，
    /// 横向/纵向钳进 anchorVisibleFrame（避开 Dock 与菜单栏，留 8px 边距）。
    ///
    /// - animated=false：show 时用（上屏前直接落位，无动画）；
    /// - animated=true：可见期间高度变化用（0.15s easeOut，与渐入同参数，
    ///   连续变化时上一次动画被替换衔接，观感为平滑呼吸）。
    private func placePanel(_ panel: NSPanel, height: CGFloat, animated: Bool) {
        guard !anchorVisibleFrame.isEmpty else { return }

        var origin = NSPoint(x: anchorMouse.x - 24, y: anchorMouse.y - height - 16)
        origin.x = max(anchorVisibleFrame.minX + 8, min(origin.x, anchorVisibleFrame.maxX - Self.panelWidth - 8))
        origin.y = max(anchorVisibleFrame.minY + 8, min(origin.y, anchorVisibleFrame.maxY - height - 8))
        let frame = NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: height))

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// 失焦隐藏（fileprivate 供 delegate 扩展调用）。
    fileprivate func handleResignKey() {
        hide()
    }

    /// 测试/调试钩子：暴露当前面板窗口（与 settingsWindowForTesting 同风格）。
    var panelForTesting: GlassPanel? { panel }
}

// MARK: - 失焦隐藏

extension PanelController: NSWindowDelegate {
    /// 窗口失去 key 状态（点了别的应用/别的屏幕）→ 立即隐藏。
    /// NSWindowDelegate 回调不带隔离，桥接方式与 PasteboardMonitor 相同：
    /// 窗口事件必然在主线程，assumeIsolated 是安全的。
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            handleResignKey()
        }
    }
}
