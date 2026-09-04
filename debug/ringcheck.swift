// ringcheck.swift — 对窗口截图做黑线框像素断言，两个症状各一条判据：
//  A) 环带判据（原始症状）：紧贴玻璃边缘外侧（alpha≥95 的不透明起点）
//     的 1..12px 内，若存在深色（亮度 < 55% 内区）且半透明（alpha≥12）
//     的像素 → 阴影糊边（用户描述的"黑色线框"，即带阴影截图中的
//     0/33、0/17 贴边带）。
//  B) 描边判据（内容层自查）：不透明边缘内 0..1px 若显著暗于内区 → 描边。
// 用法: ringcheck <png> [contentWidthPt=520]
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2,
      let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let rep = NSBitmapImageRep(data: data) else { print("ERR load"); exit(2) }
let w = rep.pixelsWide, h = rep.pixelsHigh
let contentW = args.count >= 3 ? (Double(args[2]) ?? 520) : 520
let scale = Double(w) / contentW

func pa(_ x: Int, _ y: Int) -> (lum: Double, a: Double)? {
    guard x >= 0, y >= 0, x < w, y < h, let c = rep.colorAt(x: x, y: y) else { return nil }
    let l = (0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)) * 100
    return (l, Double(c.alphaComponent) * 100)
}

var bandHits = 0, bandSamples = 0, strokeHits = 0, strokeSamples = 0
var detail = [String]()

func checkLine(_ kind: Int, from: Int, to: Int, fixed: Int) {
    for i in stride(from: from, to: to, by: max(1, (to - from) / 60)) {
        // 沿法线找到不透明边缘（内向外），kind: 0=top,1=bot,2=left,3=right
        var edge = -1
        let maxD = kind < 2 ? h : w
        for d in 0..<maxD {
            let x = kind < 2 ? i : (kind == 2 ? d : w - 1 - d)
            let y = kind < 2 ? (kind == 0 ? d : h - 1 - d) : i
            if let p = pa(x, y), p.a >= 95 { edge = d; break }
        }
        guard edge >= 0 else { continue }
        // 内区基线（边缘内 40px）
        let inX = kind < 2 ? i : (kind == 2 ? min(w - 1, edge + 40) : max(0, w - 1 - edge - 40))
        let inY = kind < 2 ? (kind == 0 ? min(h - 1, edge + 40) : max(0, h - 1 - edge - 40)) : i
        guard let inner = pa(inX, inY) else { continue }
        bandSamples += 1; strokeSamples += 1
        var band = false, stroke = false
        for g in 1...12 { // 边缘外侧带（阴影）
            let x = kind < 2 ? i : (kind == 2 ? max(0, edge - g) : min(w - 1, w - 1 - edge + g))
            let y = kind < 2 ? (kind == 0 ? max(0, edge - g) : max(0, h - 1 - edge + g)) : i
            if edge - g < 0 { break }
            if let p = pa(x, y), p.a >= 12, p.lum < inner.lum * 0.55 { band = true; break }
        }
        for g in 0...2 { // 边缘内侧 0..2px（描边）
            let x = kind < 2 ? i : (kind == 2 ? edge + g : w - 1 - edge - g)
            let y = kind < 2 ? (kind == 0 ? edge + g : h - 1 - edge - g) : i
            if let p = pa(x, y), p.lum < inner.lum * 0.4, p.lum < 55 { stroke = true; break }
        }
        if band { bandHits += 1; if detail.count < 6 { detail.append("band kind=\(kind) edge=\(edge)") } }
        if stroke { strokeHits += 1; if detail.count < 12 { detail.append("stroke kind=\(kind) edge=\(edge)") } }
    }
}
checkLine(0, from: Int(0.12 * Double(w)), to: Int(0.88 * Double(w)), fixed: 0)
checkLine(1, from: Int(0.12 * Double(w)), to: Int(0.88 * Double(w)), fixed: 0)
checkLine(2, from: Int(0.12 * Double(h)), to: Int(0.88 * Double(h)), fixed: 0)
checkLine(3, from: Int(0.12 * Double(h)), to: Int(0.88 * Double(h)), fixed: 0)

let bandFrac = Double(bandHits) / Double(max(1, bandSamples))
let strokeFrac = Double(strokeHits) / Double(max(1, strokeSamples))
print("samples: band \(bandHits)/\(bandSamples)  stroke \(strokeHits)/\(strokeSamples)")
for d in detail { print("  \(d)") }
let fails = (bandHits > 0 && bandFrac > 0.25) || (strokeFrac > 0.25)
print(fails ? "VERDICT: FAIL — 黑线框存在（贴边阴影带 \(String(format: "%.0f", bandFrac * 100))% / 内缘描边 \(String(format: "%.0f", strokeFrac * 100))%）"
             : "VERDICT: PASS — 无贴边阴影带、无内缘描边（scale=\(String(format: "%.2f", scale)))")
if fails { exit(1) }
