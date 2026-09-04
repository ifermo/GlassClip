// swift-tools-version: 6.2
// GlassClip 的 SwiftPM 清单：无 xcodeproj 的纯 SwiftPM 可执行包。
// - 运行下限 macOS 14.0：26+ 走 Liquid Glass（glassEffect），14/15 走
//   ultraThinMaterial fallback（见 Formatting.swift panelMaterial）；
// - 构建仍需 Swift 6.2 工具链 / macOS 26 SDK（swift-tools-version 锁定）；
// - 零第三方依赖，唯一外部库是系统自带的 sqlite3（链接系统 lib，非 SPM 依赖）；
// - 测试目标使用 XCTest（HistoryDatabase / ClipboardCapture / SettingsWindow /
//   StatusBarMenu 四组回归）。
import PackageDescription

let package = Package(
    name: "GlassClip",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "GlassClip",
            path: "Sources/GlassClip",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "GlassClipTests",
            dependencies: ["GlassClip"],
            path: "Tests/GlassClipTests"
        )
    ]
)
