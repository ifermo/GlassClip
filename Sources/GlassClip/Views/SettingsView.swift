// SettingsView.swift — 设置窗口内容（五个 Tab，设计共识的分区）：
// General（热键/自启）/ History（上限/清空）/ Privacy（敏感应用名单）/
// Paste（Auto Paste + 辅助功能权限引导）/ About。
//
// 桥接说明：设置窗口由 AppDelegate 自持（ accessory 应用不走 SwiftUI
// Settings scene），SwiftUI 环境里没有现成的 HistoryController——
// AppControllerRef 通过 AppDelegate 单例把它递进来（环境对象注入，
// 见 GlassClipApp.openSettingsWindow 的 environmentObject）。
//
// UI 文案遵循共识保持英文。

import AppKit
import Combine
import SwiftUI

// MARK: - 数据桥

/// 让设置页拿到共享 HistoryController 的桥（环境对象）。
///
/// controller 是计算属性、惰性解析：设置窗口可能在应用完全启动前被打开
/// （测试场景），此时 AppDelegate.shared 尚为 nil，返回 nil 让页面
/// 优雅降级（清空按钮不生效）而不是崩溃。
@MainActor
final class AppControllerRef: ObservableObject {
    static let shared = AppControllerRef()
    var controller: HistoryController? { AppDelegate.shared?.controller }
}

// MARK: - 根视图

/// TabView 容器：五个设置分区。
struct SettingsView: View {
    /// 当前选中 Tab（默认 General）。
    @State private var tab: Tab = .general

    /// 五个设置分区。
    enum Tab: Hashable {
        case general, history, privacy, paste, about
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            HistorySettingsView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(Tab.privacy)
            PasteSettingsView()
                .tabItem { Label("Paste", systemImage: "doc.on.clipboard") }
                .tag(Tab.paste)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        // 与 AppDelegate 里创建的窗口尺寸一致（480×320）。
        .frame(width: 480, height: 320)
    }
}

// MARK: - General

/// 面板热键 + 开机自启。
struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Panel Hotkey") {
                HStack {
                    // 热键 = 修饰键 + 键码两个设置字段的合成绑定：
                    // 录制器看到的是完整 HotKeyCombo，写回时拆成两个字段各自持久化。
                    HotKeyRecorderView(combo: Binding(
                        get: { HotKeyCombo(modifiers: settings.hotKeyModifiers, keyCode: settings.hotKeyCode) },
                        set: { combo in
                            settings.hotKeyModifiers = combo.modifiers
                            settings.hotKeyCode = combo.keyCode
                        }
                    ))
                    Text("Show or hide the panel from anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                // launchAtLogin 是计算属性（系统实时状态），
                // set 端走 setLaunchAtLogin（内部手动 objectWillChange）。
                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

/// 历史上限滑杆 + 清空历史。
struct HistorySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var appController: AppControllerRef

    var body: some View {
        Form {
            Section("Retention") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Maximum items")
                        Spacer()
                        Text("\(settings.historyLimit)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    // 上限范围 200–5000、步长 100（设计共识）。
                    // 淘汰在下次捕获时由 enforceLimit 执行，不实时裁剪。
                    Slider(
                        value: Binding(
                            get: { Double(settings.historyLimit) },
                            set: { settings.historyLimit = Int($0) }
                        ),
                        in: 200...5000,
                        step: 100
                    )
                    Text("Favorites are never removed automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Maintenance") {
                Button("Clear History", role: .destructive) {
                    Task { await appController.controller?.clearHistory() }
                }
                .accessibilityHint("Removes all items except favorites")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

/// 敏感应用名单编辑：列表 + 删除 + 追加输入框。
struct PrivacySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    /// 正在输入的新应用名。
    @State private var newApp = ""

    var body: some View {
        Form {
            Section {
                Text("Clips copied while these apps are active are never recorded. Matched by app name or bundle ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sensitive Apps") {
                ForEach(settings.sensitiveApps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button {
                            settings.sensitiveApps.removeAll { $0 == app }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Add app name or bundle ID", text: $newApp)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addApp)
                    Button("Add", action: addApp)
                        .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 追加名单：去空白、拒空串、拒绝重复（大小写敏感的重复由
    /// SensitiveAppsFilter 在匹配端归一化，这里只挡完全相同的输入）。
    private func addApp() {
        let trimmed = newApp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !settings.sensitiveApps.contains(trimmed) else { return }
        settings.sensitiveApps.append(trimmed)
        newApp = ""
    }
}

// MARK: - Paste

/// Auto Paste 开关 + 辅助功能权限状态与引导。
struct PasteSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    /// 权限状态（用户在系统设置里授权后界面要自动更新，见下方轮询）。
    @State private var trusted = AutoPaster.isTrusted

    var body: some View {
        Form {
            Section("Auto Paste") {
                Toggle("Paste automatically after selecting an item", isOn: $settings.autoPaste)
                Text("Sends ⌘V to the app you were using. Requires the Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Accessibility Permission") {
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Permission granted" : "Permission needed")
                    Spacer()
                    if !trusted {
                        Button("Grant") {
                            AutoPaster.promptTrust()
                        }
                    }
                }
                .task {
                    // 系统不推送授权变更通知，2s 轮询实时刷新状态；
                    // .task 绑定视图生命周期：离开页面即取消，不常驻。
                    for await _ in Timer.publish(every: 2, on: .main, in: .common).autoconnect().values {
                        trusted = AutoPaster.isTrusted
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

/// 版本信息页：图标 + 名称 + 版本 + 一句话简介。
struct AboutSettingsView: View {
    /// 从 Info.plist 读版本号；SwiftPM 裸可执行进程没有该键，回退 1.0.0
    /// （打包后的 .app 才有真实版本信息）。
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "1.0.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "list.clipboard")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("GlassClip")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("A private, local-first clipboard history.\nMIT License.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
