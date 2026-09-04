# GlassClip 构建与使用说明

本地优先（local-first）的 macOS 剪贴板历史管理器，纯原生 Swift 实现：macOS 26 上呈现 Liquid Glass，macOS 14/15 使用标准毛玻璃材质（运行下限 14.0）。所有数据都留在本地，无云、无账号、无遥测。

---

## 1. 环境要求

- **运行：macOS 14.0 或更高** —— `Package.swift` 目标平台为 `.macOS(.v14)`。26+ 走 Liquid Glass（`glassEffect`），14/15 走 `ultraThinMaterial` fallback（`Formatting.swift` 的 `panelMaterial`）。
- **构建：Xcode 26**（提供 macOS 26 SDK 与 Swift 6.2 工具链）或等价的命令行工具。因为 `Package.swift` 声明 `swift-tools-version: 6.2`，必须使用匹配的 SDK 构建——构建机系统版本不受运行下限约束。
- **Make** —— 通常随 Xcode 命令行工具（`xcode-select --install`）一起安装。

> 本仓库已声明为 Swift 6 语言模式，构建会进行严格并发检查；正常开发机上的 `make` / `swift build` 不应报并发错误。

---

## 2. 项目结构（简要）

```
GlassClip/
├── Package.swift              # SwiftPM 清单（运行下限 macOS 14.0, Swift 6.2）
├── Makefile                   # 构建入口
├── Info.plist                # App 包描述（标识符、版本、accessory 声明等）
├── Resources/
│   └── AppIcon.png           # 应用图标源（建议 1024×1024）—— 打包时由它生成 .icns
├── Sources/GlassClip/         # 全部源码（App / Capture / Services / Storage / Views / Utilities / Debug）
├── Tests/GlassClipTests/      # 单元测试
├── dist/                      # 打包产物（.app / .dmg），已被 .gitignore 忽略
└── .build/                    # SwiftPM 构建缓存，已被 .gitignore 忽略
```

---

## 3. 构建

所有构建都通过 Make 完成。常用目标：

| 命令 | 作用 |
|------|------|
| `make build` | 调试构建（arm64） |
| `make build-universal` | 通用二进制（arm64 + x86_64）调试构建 |
| `make app` | 构建通用 release 二进制 → 组装 `dist/GlassClip.app` → 生成图标 → 本地自签名（ad-hoc） |
| `make dmg` | 在 `make app` 基础上生成 `dist/GlassClip.dmg` |
| `make install` | 安装到 `/Applications` |
| `make run` | 从命令行直接调试运行 |
| `make test` | 运行单元测试 |
| `make clean` | 清理 `.build` 与 `dist` |

各目标细节（`Makefile` 内对应实现）：
- `make app` 内部依次执行：通用 `swift build -c release` → 清理并重建 `.app` 目录 → 拷贝可执行文件与 `Info.plist` → 调用 `$(MAKE) icon` 重新生成图标 → ad-hoc `codesign --force --deep -s -`。
- 也可以脱离 Make 直接用 SwiftPM：`swift build -c release`、`swift test`。

首次 `make app` 会创建 `.build` 缓存、用 `sips`+`iconutil` 生成图标集合，并完成签名。

---

## 4. 应用图标

- 图标源位于 **`Resources/AppIcon.png`**（推荐使用 1024×1024 或更大尺寸）。
- `make app` / `make icon` 会自动从它生成 16px…1024px(2x) 的 iconset，再用 `iconutil` 合成
  `dist/GlassClip.app/Contents/Resources/AppIcon.icns`。
- **替换图标**：用新图覆盖 `Resources/AppIcon.png`（保持足够分辨率），然后重新 `make app` 即可，无需改代码。
- 仓库根目录的 `icon.png` 是本次提供的图标素材副本，内容与 `Resources/AppIcon.png` 一致；后续改动请以 `Resources/AppIcon.png` 为准。
- 该 App 在 `Info.plist` 中被声明为 **accessory 应用**（`LSUIElement = true`），没有 Dock 图标，启动后只出现在**菜单栏**。

---

## 5. 安装与运行

- **开发调试**：`make run`，或直接打开 `dist/GlassClip.app`（`make app` 之后）。
- **分发**：`make dmg` 生成 `dist/GlassClip.dmg`；或 `make install` 安装到 `/Applications`。
- **签名说明**：`.app` 使用 ad-hoc 自签名。在未被信任的开发机上首次打开可能被 Gatekeeper 拦截，需在
  **系统设置 → 隐私与安全性** 中手动允许运行。

---

## 6. 使用说明

### 启动与入口
- 启动后菜单栏出现一个剪贴板图标；点击可打开 **Show / Settings… / Quit**。
- 默认快捷键 **⌥⌘V** 开关悬浮面板（可在 **Settings → General** 中重新录制）。

### 面板操作
| 操作 | 快捷键 / 方式 |
|------|---------------|
| 打开 / 关闭面板 | 菜单栏图标，或 ⌥⌘V |
| 上下选择 | ↑ ↓ |
| 复制并写入剪贴板（Enter 后若开启 Auto Paste 会自动粘贴） | Enter / ⌘V |
| 以纯文本粘贴 | ⌘⇧V 或右键菜单 |
| 即时搜索 | 直接键入任意字符 |
| 全部 ↔ 收藏 切换 | Tab |
| 预览当前项 | Space（图片 / 渲染后的 HTML / RTF / 颜色 / 文件列表） |
| 删除当前项 | ⌫ |
| 分层退出 | Esc（依次：关预览 → 清搜索 → 回「全部」→ 关面板） |

### 关键特性
- **收藏**：星标项不受历史上限与「清空」影响，始终保留。
- **敏感应用过滤**：在 1Password、Bitwarden、KeePassXC、Keychain Access 等应用中复制的内容不会被记录；可在 **Settings → Privacy** 中按应用名或 Bundle ID 增删。
- **自动粘贴**：在 **Settings → Paste** 中开启，需要授予「辅助功能」权限（首次会弹出系统提示）。
- **开机自启**：**Settings → General → Launch at Login**。
- **数据位置**：`~/Library/Application Support/GlassClip/`，含一个 SQLite 数据库及较大的负载文件（图片、缩略图、应用图标）。备份、删除或软链该目录即可管理全部数据。

### 启动参数（调试用）
- `--show-panel`：启动约 0.6 秒后自动弹出面板，便于在自动化/调试时验证 UI。

---

## 7. 测试

`make test` 运行 `Tests/GlassClipTests/` 下的 SwiftPM 单元测试，覆盖剪贴板捕获、SQLite 存取、敏感过滤、富文本/颜色格式化、设置窗口等。CI 配置见 `.github/workflows/`。

---

## 8. 常见问题

- **面板弹不出来**：先确认默认快捷键 ⌥⌘V 未被系统或其他 App 占用；也可以点菜单栏图标手动打开。
- **自动粘贴不生效**：到 **Settings → Paste** 检查开关，并确认已在系统「辅助功能」中授权 GlassClip。
- **改了图标却没变**：确认覆盖的是 `Resources/AppIcon.png` 且重新执行了 `make app`（旧 `.app` 不会自动更新）。
- **构建报 `sandbox_apply: Operation not permitted`**：这是受限/沙箱执行环境特有的现象（SwiftPM 写 `~/.swiftpm` 被拦截）。在普通开发机上直接 `make` / `swift build` 不受影响；如命令行工具缺失，先运行 `xcode-select --install`。
