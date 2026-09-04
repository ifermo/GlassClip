// corner.swift — 打印 PNG 角区/边区的亮度+alpha ASCII 图，直读像素级形态。
// 用法: corner <png> <TL|TR|BL|BR|TOP|BOT|LEFT|RIGHT> [size]
// 图例: '0'..'9' = 亮度十档(0 最暗); '.' = 基本透明(alpha<12)
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3,
      let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let rep = NSBitmapImageRep(data: data) else { print("ERR load"); exit(2) }
let w = rep.pixelsWide, h = rep.pixelsHigh
let n = args.count >= 4 ? (Int(args[3]) ?? 14) : 14
let region = args[2]

func cell(_ x: Int, _ y: Int) -> String {
    guard x >= 0, y >= 0, x < w, y < h, let c = rep.colorAt(x: x, y: y) else { return "?" }
    if rawMode {
        let a = Int((Double(c.alphaComponent) * 100).rounded())
        let l = Int(((0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)) * 100).rounded())
        return String(format: "%4d/%d", l, a)  // 亮度/alpha
    }
    let a = Double(c.alphaComponent) * 100
    if a < 12 { return "." }
    let l = (0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)) * 100
    if l < 10 { return "0" }
    if l >= 99.5 { return "9" }
    return String(Int(l / 10))
}
let rawMode = region == "TOPRAW" || region == "LEFTRAW"
let regKey = rawMode ? String(region.dropLast(3)) : region

var xs = [Int](), ys = [Int]()
switch regKey {
case "TL": xs = Array(0..<n); ys = Array(0..<n)
case "TR": xs = Array((w - n)..<w); ys = Array(0..<n)
case "BL": xs = Array(0..<n); ys = Array((h - n)..<h)
case "BR": xs = Array((w - n)..<w); ys = Array((h - n)..<h)
case "TOP": xs = Array((w / 2 - n / 2)..<(w / 2 + n / 2)); ys = Array(0..<n)
case "BOT": xs = Array((w / 2 - n / 2)..<(w / 2 + n / 2)); ys = Array((h - n)..<h)
case "LEFT": xs = Array(0..<n); ys = Array((h / 2 - n / 2)..<(h / 2 + n / 2))
case "RIGHT": xs = Array((w - n)..<w); ys = Array((h / 2 - n / 2)..<(h / 2 + n / 2))
default: print("ERR region"); exit(2)
}
print("== \(region) \(args[1]) x[\(xs.first!)..\(xs.last!)] ==")
for y in ys {
    var line = String(format: "%5d ", y)
    for x in xs { line += cell(x, y) }
    print(line)
}
