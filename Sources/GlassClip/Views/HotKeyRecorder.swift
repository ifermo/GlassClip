// HotKeyRecorder.swift — 热键录制控件（设置页 General 用）。
//
// 为什么是 NSViewRepresentable + 手绘 NSView：SwiftUI 原生没有
// 全局热键录制控件；录制态需要"捕获任意修饰键组合"并自绘三态外观，
// AppKit 自绘视图是最直接可靠的载体。
//
// 交互：点击进入录制态（显示 "Type shortcut…"）→ 按下带主修饰键的
// 组合即录制完成，Esc 取消。录制完成后经回调把组合写回设置并触发
// 全局热键重注册（AppDelegate.reapplyHotKey）。

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - SwiftUI 桥

/// NSViewRepresentable 包装：SwiftUI 侧只看到 `combo` 绑定。
struct HotKeyRecorderView: NSViewRepresentable {
    /// 双向绑定：控件写入新组合，外部（设置变化）也能反向刷新控件。
    @Binding var combo: HotKeyCombo

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        let view = HotKeyRecorderNSView()
        view.combo = combo
        view.onChange = { newCombo in
            combo = newCombo
            // 新组合立即生效：经 AppDelegate 让 PanelController 重注册全局热键。
            AppDelegate.shared?.reapplyHotKey()
        }
        return view
    }

    func updateNSView(_ view: HotKeyRecorderNSView, context: Context) {
        // 只在外部值确实变化时回写，避免录制过程中 SwiftUI 刷新打断输入。
        if view.combo != combo {
            view.combo = combo
            view.needsDisplay = true
        }
    }
}

// MARK: - AppKit 录制控件

/// 自绘录制控件：三态底色 + 居中文本。
final class HotKeyRecorderNSView: NSView {
    /// 当前组合（录制完成时更新）。
    var combo = HotKeyCombo.default {
        didSet { needsDisplay = true }
    }

    /// 录制完成回调（SwiftUI 桥接入设）。
    var onChange: ((HotKeyCombo) -> Void)?
    /// 录制态（点击进入，完成/取消退出）。
    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    /// 可聚焦（成为 firstResponder 才能接收 keyDown）。
    override var acceptsFirstResponder: Bool { true }
    /// 固有尺寸：设置表单里的标准热键框。
    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 28) }

    /// 三态绘制：录制中（强调色 25%）→ 聚焦（强调色 12%）→ 常态（次级 35%），
    /// 1px 描边 + 居中文本（录制态显示提示词，常态显示当前组合）。
    override func draw(_ dirtyRect: NSRect) {
        let isActive = isRecording || window?.firstResponder == self
        let background = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        } else if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        } else {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        }
        background.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        background.lineWidth = 1
        background.stroke()

        let text: String
        if isRecording {
            text = "Type shortcut…"
        } else {
            text = combo.displayString
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    /// 点击切换录制态；进入录制时抢占焦点（后续按键都进 keyDown）。
    override func mouseDown(with event: NSEvent) {
        isRecording.toggle()
        if isRecording { window?.makeFirstResponder(self) }
    }

    /// 录制态按键处理：
    /// - Esc 取消录制（不改变现有组合）；
    /// - 非录制态放行给父类；
    /// - 其余按键：把 NSEvent 修饰键翻成 Carbon 掩码，要求含至少一个
    ///   主修饰键（⌘/⌃/⌥）——单 ⇧ 或无修饰的组合会吞掉系统所有正常输入，
    ///   不允许作为全局热键；通过后写入 combo 并触发回调，退出录制态。
    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }

        if event.keyCode == KeyCode.escape {
            isRecording = false
            return
        }

        let flags = event.modifierFlags
        var carbon = 0
        if flags.contains(.command) { carbon |= Int(cmdKey) }
        if flags.contains(.option) { carbon |= Int(optionKey) }
        if flags.contains(.control) { carbon |= Int(controlKey) }
        if flags.contains(.shift) { carbon |= Int(shiftKey) }

        let hasMainModifier = carbon & (Int(cmdKey) | Int(controlKey) | Int(optionKey)) != 0
        guard hasMainModifier else { return }

        combo = HotKeyCombo(modifiers: carbon, keyCode: UInt32(event.keyCode))
        onChange?(combo)
        isRecording = false
    }
}
