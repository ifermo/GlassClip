// GlassClipApp.swift — 应用入口与全局生命周期管理。
//
// GlassClip 是一个菜单栏（ accessory ）型剪贴板历史工具：没有常规主窗口，
// 所有交互经由三个表面——浮动历史面板（PanelController）、状态栏图标及其菜单、
// 设置窗口（本文件自持的 NSWindow）。
//
// 架构上本文件承担四件事：
//  1. SwiftUI App 入口（@main），但刻意保持极简——真正的装配全部走 AppDelegate；
//  2. 应用启动序列：激活策略 → 面板 → 状态栏 → 捕获管线 → 调试参数；
//  3. 状态栏菜单的构建（含菜单项 target 布线，踩过 NSMenu 验证的坑，见下）；
//  4. 设置窗口的自持管理（复用而非重建，且必须真实可见，回归测试已锁定）。
//
// 线程约束：整个类标注 @MainActor——AppKit UI 与 NSStatusItem 都要求主线程，
// HistoryController 内部自行处理并发，这里不做跨线程调度。

import CoreGraphics
import ObjectiveC
import SwiftUI

// MARK: - SwiftUI 入口

/// SwiftUI App 协议入口。
///
/// 刻意只用一个占位 `Settings` scene：macOS 26 上，accessory（LSUIElement）+
/// 仅 Settings scene 的组合会让 SwiftUI 的私有 `showSettingsWindow:` 静默失效
/// （sendAction 返回 true 但永远不建窗，提前 `NSApp.activate` 也无效）。
/// 因此设置窗口改由 AppDelegate 自持 NSWindow 实现（见 `openSettingsWindow()`），
/// 这里保留 scene 只是为了让 @main 的 App 图仍然合法。
@main
struct GlassClipApp: App {
    /// 通过 Adaptor 把 AppDelegate 桥进 SwiftUI 生命周期；
    /// `applicationDidFinishLaunching` 是整个应用的实际起点。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 占位 scene，永不呈现内容；设置界面由 AppDelegate 的 NSWindow 承载。
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

/// 全局装配与生命周期中枢。
///
/// 持有并串联三大子系统：
/// - `HistoryController`：数据层入口（SQLite + BlobStore + 去重/收藏语义）；
/// - `PanelController`：浮动历史面板的窗口与交互管理；
/// - `NSStatusItem`：菜单栏图标与菜单。
///
/// 生命周期：`applicationDidFinishLaunching` 完成全部装配后，本对象常驻
/// 进程直至退出（accessory 应用没有"最后窗口关闭即退出"的语义）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 进程级单例引用。
    ///
    /// 测试环境会直接实例化 AppDelegate（不会走真正的启动流程），因此允许为 nil；
    /// 仅在应用真实启动后才有值。用隐式解包是为了让调用侧书写简洁，
    /// 代价是访问前必须确认应用已启动。
    static private(set) var shared: AppDelegate!

    /// 数据层入口。lazy：首次访问时才构建，避免初始化链条过早触碰 SQLite。
    lazy var controller = HistoryController()

    /// 浮动历史面板控制器。启动序列中创建，隐式解包与启动顺序绑定。
    private var panelController: PanelController!

    /// 菜单栏状态项。保持强引用——NSStatusItem 不被持有时会立即从菜单栏消失。
    private var statusItem: NSStatusItem?

    /// 自持的设置窗口；惰性创建，整个进程生命周期内复用同一实例。
    private var settingsWindow: NSWindow?

    /// 尽早关闭 Tahoe 的自动菜单图标——必须先于任何菜单构建，
    /// AppDelegate.init 是本类最早的确定性时机（见 NSMenuItem.disableIcons）。
    override init() {
        super.init()
        NSMenuItem.disableIcons()
    }

    // MARK: 生命周期

    /// 应用启动序列。顺序有依赖关系，不可随意调换：
    /// 1. 登记单例 + 设为 accessory（无 Dock 图标、不抢焦点）；
    /// 2. 创建面板并接通"打开设置"回调（面板内的齿轮按钮走同一路径）；
    /// 3. 装状态栏（用户感知到应用已就绪的第一个信号）；
    /// 4. 启动捕获管线（异步 Task，不阻塞启动）；
    /// 5. 处理 `--show-panel` 调试参数（等 0.6s 让面板窗口先完成装配再弹出）。
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // accessory：菜单栏应用的标准策略——不在 Dock 显示、不能成为前台应用。
        // 必须在创建任何窗口之前设定，否则会短暂闪现 Dock 图标。
        NSApp.setActivationPolicy(.accessory)

        panelController = PanelController(controller: controller)
        // 面板齿轮按钮与状态栏菜单的 Settings… 共用同一条打开路径，
        // 保证两处入口行为一致（历史上曾因 SwiftUI 私有 selector 分叉出 bug）。
        panelController.onOpenSettings = { [weak self] in self?.openSettingsWindow() }
        panelController.start()
        setupStatusItem()

        // 捕获管线独立于 UI 启动：即使面板从未打开，剪贴板历史也在持续记录。
        Task { await controller.start() }

        // 调试/自动化参数：启动后自动弹出面板，供截图与真机验证使用。
        if ProcessInfo.processInfo.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.panelController.show()
            }
        }
        // 调试/自动化参数（黑线框回归用）：弹出面板
        // 并截取窗口合成图像（带阴影与无阴影各一张）后退出。需要屏幕
        // 录制权限（首次运行弹系统授权框）。
        if ProcessInfo.processInfo.arguments.contains("--shot-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.shotPanelForDebug()
            }
        }
    }

    /// 供设置界面在热键录制完成后调用，把新热键重新注册到系统。
    func reapplyHotKey() {
        panelController?.reapplyHotKey()
    }

    // MARK: 状态栏菜单

    /// 创建菜单栏状态项并挂上菜单。
    ///
    /// 注意 statusItem 必须由本类强持有（`statusItem` 属性）：
    /// NSStatusBar 只返回弱引用对象，无人持有时图标即刻消失。
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 与 App 图标同源的模板图（StatusBarIcon.png，从 Resources/AppIcon.png
        // 派生，位图已入库不再需要重新生成）；isTemplate = true 时系统按菜单栏
        // 亮暗自动反转。资源缺失时退回 SF Symbol，状态栏不至于无图标。
        item.button?.image = Self.statusBarTemplateImage()
            ?? NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "GlassClip")

        item.menu = makeStatusBarMenu()
        statusItem = item
    }

    /// 状态栏模板图：36×36 px 资源按 18pt 呈现（@2x 视网膜下原分辨率渲染）。
    /// internal 供 StatusBarIconTests 钉住打包与模板属性。
    static func statusBarTemplateImage() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "StatusBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    /// 构建状态栏下拉菜单：Show / Settings… / Quit 三项。
    ///
    /// target 布线规则（踩坑所得，勿"简化"）：
    /// - Show / Settings 的 action 实现在本类上，由末尾的遍历统一补 target；
    /// - Quit 的 action `terminate(_:)` 实现在 NSApplication 上，AppDelegate
    ///   不响应它——若把 target 也设成 self，NSMenu 弹出时的逐项验证会失败，
    ///   菜单项表现为永久置灰。因此必须显式指向 NSApp。
    /// 该约束由 StatusBarMenuTests 无头锁定（菜单构建后跑 update() 验证）。
    func makeStatusBarMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Show", action: #selector(showPanel)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", action: #selector(openSettings)))
        menu.addItem(.separator())
        // terminate(_:) 实现在 NSApplication 上；若此项的 target 留在
        // AppDelegate，NSMenu 弹出时的验证会把它永久置灰。
        let quit = menuItem("Quit", action: #selector(NSApplication.terminate(_:)))
        quit.target = NSApp
        menu.addItem(quit)
        // 只补齐尚未设置 target 的项，避免覆盖上面显式指定的 NSApp。
        menu.items.forEach { if $0.target == nil { $0.target = self } }
        return menu
    }

    /// 构建菜单项的统一工厂：一律不带快捷键等价键。
    ///
    /// 状态栏菜单的条目不允许携带 key equivalent 修饰键（系统对 status item
    /// 菜单有此约束），所以每项都用空 keyEquivalent 构建，并把修饰掩码清空。
    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.keyEquivalentModifierMask = []
        return item
    }

    // MARK: 菜单动作

    /// 菜单项动作：弹出历史面板。
    @objc private func showPanel() {
        panelController.show()
    }

    /// 菜单项动作：打开设置窗口（与面板齿轮同一闭包路径）。
    @objc private func openSettings() {
        openSettingsWindow()
    }

    // MARK: 设置窗口

    /// 打开设置窗口；已存在则复用，不存在才新建。
    ///
    /// 为什么不用 SwiftUI `Settings` scene：见 GlassClipApp 顶部注释——
    /// macOS 26 上 accessory 应用的私有 `showSettingsWindow:` 静默 no-op。
    /// 复用（而非每次新建）由 SettingsWindowTests 锁定。
    ///
    /// 窗口参数说明：
    /// - `isReleasedWhenClosed = false`：点关闭按钮只藏不释放，保证实例可复用；
    /// - styleMask 只给 titled + closable：不允许缩小/调整大小，也不需要
    ///   最小化（工具型窗口，行为越确定越好）。
    func openSettingsWindow() {
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "GlassClip Settings"
            window.isReleasedWhenClosed = false
            // 用 NSHostingView 承载 SwiftUI 设置界面，桥接 AppKit 窗口与 SwiftUI 内容；
            // AppControllerRef 是数据层的 ObservableObject 桥，供设置页观察/写入偏好。
            window.contentView = NSHostingView(
                rootView: SettingsView().environmentObject(AppControllerRef.shared)
            )
            settingsWindow = window
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        // accessory 应用默认无法激活为前台应用；不显式 activate 的话
        // 窗口能显示但无法获得键盘焦点（热键录制/文本框会失灵）。
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 测试支持

    /// 测试钩子：暴露设置窗口供断言可见性/复用性（SettingsWindowTests 使用）。
    var settingsWindowForTesting: NSWindow? { settingsWindow }

    /// 测试钩子：关闭并清空设置窗口，让用例之间互不残留状态。
    func closeSettingsWindowForTesting() {
        settingsWindow?.close()
        settingsWindow = nil
    }

    /// 调试钩子（--shot-panel，供外部脚本驱动截图回归）：弹出面板（强制
    /// 不透明，规避脚本化启动时淡入动画卡住的现象），再用 screencapture
    /// 按窗口 id 截取合成图像——无阴影版（窗口本体）与带阴影版（用户所
    /// 见）各一张，写完即退出。需要屏幕录制权限（首次运行弹系统授权框）。
    func shotPanelForDebug() {
        guard CGRequestScreenCaptureAccess() else {
            FileHandle.standardError.write("TCC: screen recording permission denied for GlassClip\n".data(using: .utf8)!)
            exit(3)
        }
        panelController.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let panel = self.panelController.panelForTesting else { exit(2) }
            if panel.alphaValue < 0.99 { panel.alphaValue = 1 }
            let outDir = ProcessInfo.processInfo.environment["GLASSCLIP_DUMP_DIR"] ?? "/tmp/glassclip-debug"
            let id = panel.windowNumber
            for args in [["-x", "-o", "-l\(id)", "\(outDir)/win-noshadow.png"],
                         ["-x", "-l\(id)", "\(outDir)/win-shadow.png"]] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = args
                try? p.run()
                p.waitUntilExit()
            }
            exit(0)
        }
    }
}

// MARK: - 菜单图标抑制

extension NSMenuItem {
    /// 关闭 Tahoe 给菜单项自动添加的 SF Symbol 图标（AppKit 按 action
    /// selector 与标准标题匹配注入）。
    ///
    /// 机制：swizzle `image` getter 恒返 nil——AppKit 渲染菜单时向菜单项
    /// 要图一律拿到空，自动图标不再绘制。Brent Simmons 的社区方案
    /// （NetNewsWire 正式采用，Rogue Amoeba 推荐）。
    ///
    /// 为什么不用 NSMenuEnableActionImages defaults 键：实测只有全局域生效
    /// （波及所有应用，越权），register(defaults:) 注册域与应用持久域均
    /// 无效（2026-09-04 两轮实测，应用域键值落盘后图标照旧）。
    /// swizzle 是进程内唯一可靠手段；副作用是本应用所有菜单项一律无图标
    /// ——这正是设计意图（状态栏菜单与面板右键菜单都回到纯文字）。
    ///
    /// 幂等保护：method_exchangeImplementations 重复执行会互相还原
    /// （第二次调用等于撤销第一次），必须有已安装标记挡住重入。
    @MainActor private static var swizzleInstalled = false

    @MainActor
    static func disableIcons() {
        guard !swizzleInstalled else { return }
        swizzleInstalled = true

        let originalSelector = #selector(getter: image)
        let nilImageSelector = #selector(returnNilInsteadOfImage)

        guard let originalMethod = class_getInstanceMethod(NSMenuItem.self, originalSelector),
              let newMethod = class_getInstanceMethod(NSMenuItem.self, nilImageSelector)
        else { return }

        method_exchangeImplementations(originalMethod, newMethod)
    }

    /// swizzle 交换后的实现体：调用它等于调用原 `image` getter（方法名
    /// 已被交换，勿按字面理解）。
    @objc private func returnNilInsteadOfImage() -> NSImage? {
        nil
    }
}
