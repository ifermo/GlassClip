# debug/ — 黑线框截图回归回路（一次性排查产物，保留作视觉回归）

## 背景结论（2026-09-04）

用户症状："窗口最外层始终有一个黑色线框"。逐像素差分证实根因为
**窗口级原生阴影**：`GlassPanel`（borderless + `backgroundColor=.clear`）上，
AppKit 按**窗口矩形边界**生成阴影，不认 `NSGlassEffectView` 的圆角裁切，
在玻璃边缘外糊出一圈紧贴的深色半透明带（实测 0/33%、0/17% alpha 梯度），
叠加在玻璃上沿白色高光（92/100）上形成高对比黑线。内容层无描边
（无阴影截取干净）。修复 = `panel.hasShadow = false`
（FloatingPanel.swift `ensurePanel()`，注释含完整因果）。

## 回路用法

```bash
bash debug/run-loop.sh          # 构建 + 启动 --shot-panel + 像素断言，退出码 0=绿 1=红
```

- 依赖 App 的 `--shot-panel` 调试参数（GlassClipApp）：弹出面板并
  `screencapture -l` 截取带/无阴影两张窗口图到 /tmp/glassclip-debug/。
- **首次运行会弹"屏幕录制"授权**（授权对象是 GlassClip 本身，不是终端）；
  重新链接（cdhash 变化）后可能再弹一次，点允许即可。
- `ringcheck.swift`：两条判据——贴边阴影带（不透明缘外侧 1..12px 深色
  半透明像素）与内缘描边（缘内 0..2px 显著变暗）。
- `corner.swift <png> <TL|TR|BL|BR|TOP|BOT|LEFT|RIGHT|TOPRAW|LEFTRAW> [n]`：
  像素 ASCII 放大图，人工复核形态用。
- `winprobe.swift [OwnerName]`：在屏窗口 id/bounds（TSV）。

## 注意

- 脚本化启动时面板淡入动画可能卡在 alpha≈0.01（`sample` 见
  `NSAnimation _runBlocking` 停在后台队列）；`--shot-panel` 里强制
  `alphaValue = 1` 规避。此现象独立于黑框 bug，若日后复现再立专项。
- cacheDisplay 对玻璃材质渲染为纯白占位（back-buffer 路径不可信），
  排查视觉问题时不要走那条捷径。
