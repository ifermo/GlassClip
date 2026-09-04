// winprobe.swift — 列出 GlassClip 当前在屏窗口的 id 与 bounds（TSV）。
// 列: num  layer  alpha  x  y  w  h   （bounds 单位是 point）
import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("ERR: window list unavailable (Screen Recording permission?)\n".data(using: .utf8)!)
    exit(2)
}
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "GlassClip" else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let alpha = (w[kCGWindowAlpha as String] as? Double ?? -1 * 100).rounded() / 100
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? -1, y = b["Y"] as? Double ?? -1
    let ww = b["Width"] as? Double ?? -1, hh = b["Height"] as? Double ?? -1
    print("\(num)\t\(layer)\t\(alpha)\t\(x)\t\(y)\t\(ww)\t\(hh)")
}
