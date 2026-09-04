# GlassClip

简体中文 | [English](README.md)

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

本地优先、注重隐私的 macOS 剪贴板历史管理器。纯原生 Swift 实现：macOS 26 上呈现 Liquid Glass，macOS 14/15 使用标准毛玻璃材质。

所有数据都留在本机——无云端、无账号、无遥测。

## 功能特性

- **全类型捕获** — 文本、富文本（RTF）、HTML、图片、文件 URL、颜色
- **Liquid Glass 悬浮面板** — 单一面板随处唤起（macOS 26 走 Liquid Glass；macOS 14/15 走标准毛玻璃材质）
- **即时搜索** — 直接键入即可过滤，无需先点搜索框
- **收藏** — 星标项进入独立分区，不受历史上限和「清空」影响
- **智能去重** — 重复复制同一内容自动置顶；同一内容的纯文本与富文本变体合并为一条
- **面板内预览** — 按 `Space` 分栏预览图片、渲染后的 HTML/RTF、颜色和文件列表
- **键盘优先** — 全部操作无需鼠标
- **敏感应用过滤** — 在 1Password、Bitwarden、KeePassXC、Keychain Access 中复制的内容不会被记录（列表可编辑）
- **高效存储** — SQLite 数据库，大负载单独落盘；上千条历史依然流畅
- **100% 离线**

## 系统要求

- **运行：** macOS 14.0 或更高 — Apple Silicon 或 Intel Mac
- **构建：** Xcode 26 或更新（macOS 26 SDK、Swift 6.2 工具链）

## 从源码构建

```bash
make app        # 通用 .app（arm64 + x86_64），ad-hoc 签名
make dmg        # .app → dist/GlassClip.dmg
make install    # 安装到 /Applications
make test       # 单元测试
make run        # 从命令行调试运行
```

更详细的构建参数、图标替换和常见问题见 [BUILD_AND_USAGE.md](BUILD_AND_USAGE.md)。

## 使用方法

| 操作 | 快捷键 |
|---|---|
| 打开 / 关闭面板 | 菜单栏图标，或 `⌥⌘V`（可在设置中重新录制） |
| 上下选择 | `↑` `↓` |
| 粘贴选中项 | `Enter` |
| 预览选中项 | `Space` |
| 以纯文本粘贴 | `⌘⇧V`（或右键菜单） |
| 搜索 | 直接键入任意字符 |
| 全部 ↔ 收藏 切换 | `Tab` |
| 删除选中项 | `⌫` |
| 关闭预览 / 清空搜索 / 关面板 | `Esc`（逐层生效） |

### 自动粘贴

默认情况下，选中条目只会写入剪贴板，再由你自己按 `⌘V` 粘贴。

若想在 `Enter` 时直接粘贴，请在 **设置 → 粘贴** 中开启**自动粘贴**，并在系统弹出提示时授予**辅助功能**权限。之后 GlassClip 会向之前使用的应用合成一次 `⌘V`。

## 许可证

[MIT](LICENSE)
