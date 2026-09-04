// PackagingMetadataTests.swift — 打包元数据契约：Info.plist 是随包直发的启动门槛。
//
// 为什么单独钉这个：LSMinimumSystemVersion 高于真实运行下限时，macOS 14/15 的
// LaunchServices 会直接弹"应用的这个版本不能与此版本的macOS配合使用"拒绝启动，
// 而开发机（26）上 swift build/test 全绿——没有任何运行时测试能抓到它。
// 运行下限契约声明在 Package.swift 的 platforms（.macOS(.v14)：26+ 走 Liquid
// Glass，14/15 走 ultraThinMaterial 回退），Info.plist 必须与之同步。
// Makefile 对这份 plist 除版本号外原样拷贝，因此钉仓库根的源文件即可覆盖产物。

import XCTest

final class PackagingMetadataTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func infoPlist() throws -> [String: Any] {
        let url = Self.packageRoot.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "仓库根 Info.plist 必须是合法的属性列表"
        )
    }

    func testLSMinimumSystemVersionMatchesDeclaredFloor() throws {
        let plist = try infoPlist()
        let minVersion = try XCTUnwrap(
            plist["LSMinimumSystemVersion"] as? String,
            "Info.plist 必须显式声明 LSMinimumSystemVersion（缺失时门槛退回二进制 minos，契约失去唯一事实源）"
        )
        XCTAssertEqual(
            minVersion, "14.0",
            "运行下限契约为 macOS 14.0（见 Package.swift platforms）；任何更高的值都会让 14/15 直接拒绝启动"
        )
    }
}
