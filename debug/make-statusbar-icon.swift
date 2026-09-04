// make-statusbar-icon.swift — 从彩色 AppIcon 生成状态栏模板图。
//
// 用法（仓库根目录）: swift debug/make-statusbar-icon.swift [源图] [输出]
//
// 规则：先从画布边缘泛洪抠除近白色不透明底（App 图标的白色圆角画布），
// 再把剩余不透明区域 → 纯黑、保留 alpha（isTemplate 模板图只需黑+透明）。
// 输出 36×36 画布，glyph 占 32×32（18pt @2x，四周各留 1pt）。
// 源图默认 Resources/AppIcon.png，App 图标更换后重跑本脚本保持同源。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let srcPath = args.count > 1 ? args[1] : "Resources/AppIcon.png"
let dstPath = args.count > 2 ? args[2] : "Sources/GlassClip/Resources/StatusBarIcon.png"

let canvas = 36
let glyph = 32

func loadCGImage(_ url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("无法读取 \(url.path)")
    }
    return image
}

func pixelBuffer(of image: CGImage) -> (buf: [UInt8], width: Int, height: Int) {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
}

// 泛洪去白底：从四边出发，近白（RGB 均 ≥ 235）的不透明像素连同其连通区清成透明。
// 图标内部的白色（背页纸张等）被黑色描边隔开、不可达，得以保留。
func stripWhiteBackground(_ image: CGImage, threshold: UInt8 = 235) -> CGImage {
    let (bufIn, w, h) = pixelBuffer(of: image)
    var buf = bufIn
    var cleared = [Bool](repeating: false, count: w * h)
    func isNearWhite(_ i: Int) -> Bool {
        buf[i * 4] >= threshold && buf[i * 4 + 1] >= threshold && buf[i * 4 + 2] >= threshold && buf[i * 4 + 3] > 0
    }
    var stack: [Int] = []
    for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
    for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
    while let i = stack.popLast() {
        guard !cleared[i], isNearWhite(i) else { continue }
        cleared[i] = true
        buf[i * 4 + 3] = 0
        let x = i % w, y = i / w
        if x > 0 { stack.append(i - 1) }
        if x < w - 1 { stack.append(i + 1) }
        if y > 0 { stack.append(i - w) }
        if y < h - 1 { stack.append(i + w) }
    }
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

let source = stripWhiteBackground(loadCGImage(URL(fileURLWithPath: srcPath)))

// 诊断：抠底后 32×32 分块的 alpha 地图（空白=透明），肉眼核对剪影范围。
do {
    let (buf, w, _) = pixelBuffer(of: source)
    let block = w / 32
    for row in 0..<32 {
        var line = ""
        for col in 0..<32 {
            let x = col * block + block / 2, y = row * block + block / 2
            line += buf[(y * w + x) * 4 + 3] == 0 ? " " : "#"
        }
        print(line)
    }
}

// 取景裁剪（CGImage 坐标原点在左上）：去掉底部纸卷——它缩到 18pt 后
// 只剩一条与纸身断开的横杠。保留双纸叠放 + 文字行 + 折角 + 别针残迹。
guard let bottomCut = source.cropping(to: CGRect(x: 0, y: 0,
                                                 width: source.width,
                                                 height: Int(Double(source.height) * 0.78))) else {
    fatalError("裁剪失败")
}

// 透明边距自动裁齐：扫描 alpha 包围盒，四周留 2% 边距——内容居中，
// 且源图构图变化时无需手调裁剪参数。
func trimmedToInk(_ image: CGImage) -> CGImage {
    let (buf, w, h) = pixelBuffer(of: image)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w where buf[(y * w + x) * 4 + 3] > 8 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= minX else { fatalError("裁剪后无墨迹") }
    let m = Int(Double(max(w, h)) * 0.02)
    let x0 = max(0, minX - m), y0 = max(0, minY - m)
    let x1 = min(w, maxX + 1 + m), y1 = min(h, maxY + 1 + m)
    return image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))!
}
let cropped = trimmedToInk(bottomCut)

// 保纵横比缩放到指定长边。
func scaledToFit(_ image: CGImage, longSide: Int) -> CGImage {
    let k = CGFloat(longSide) / CGFloat(max(image.width, image.height))
    let w = Int((CGFloat(image.width) * k).rounded())
    let h = Int((CGFloat(image.height) * k).rounded())
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

// 抠线重塑：黑色描边/文字行 → 透明槽；其余不透明区域 → 纯黑。
// 填充剪影在 18pt 会糊成方块，靠透明槽保留"双纸叠放 + 文字行"的辨识度。
func carveLines(_ image: CGImage, threshold: UInt8 = 120) -> CGImage {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in 0..<(w * h) where buf[i * 4 + 3] > 0 {
        if buf[i * 4] < threshold, buf[i * 4 + 1] < threshold, buf[i * 4 + 2] < threshold {
            buf[i * 4 + 3] = 0
        } else {
            buf[i * 4] = 0
            buf[i * 4 + 1] = 0
            buf[i * 4 + 2] = 0
        }
    }
    return ctx.makeImage()!
}

let carveScale = 128
let final = scaledToFit(carveLines(scaledToFit(cropped, longSide: carveScale)), longSide: glyph)

let outCtx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                       bytesPerRow: canvas * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
outCtx.interpolationQuality = .high
outCtx.draw(final, in: CGRect(x: (canvas - final.width) / 2, y: (canvas - final.height) / 2,
                              width: final.width, height: final.height))

// 像素重映射：RGB → 0（premultiplied 黑）；alpha 二值化——重采样的半透明
// 槽位/边缘归 0（更脆的透明槽），实心区归 255，18pt 下不发虚。
if let data = outCtx.data {
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(canvas * canvas) {
        pixels[i * 4] = 0
        pixels[i * 4 + 1] = 0
        pixels[i * 4 + 2] = 0
        pixels[i * 4 + 3] = pixels[i * 4 + 3] > 210 ? 255 : 0
    }
    // 去孤点：清掉 8 邻域内零个实心邻居的孤立像素（描边残迹）。
    // 阈值必须保持"零邻居"——2px 细的文字行恰好只有 2 个同行邻居，
    // 再收紧会连文字槽结构一起吃掉。
    for row in 0..<canvas {
        for col in 0..<canvas {
            let i = row * canvas + col
            guard pixels[i * 4 + 3] > 0 else { continue }
            var neighbors = 0
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let r = row + dy, c = col + dx
                    if (0..<canvas).contains(r), (0..<canvas).contains(c),
                       pixels[(r * canvas + c) * 4 + 3] > 0 { neighbors += 1 }
                }
            }
            if neighbors == 0 { pixels[i * 4 + 3] = 0 }
        }
    }
    // 诊断：最终画布 alpha 地图（# 不透明，. 半透明，空 透明）。
    for row in 0..<canvas {
        var line = ""
        for col in 0..<canvas {
            let a = pixels[(row * canvas + col) * 4 + 3]
            line += a > 200 ? "#" : (a > 40 ? "." : " ")
        }
        print(line)
    }
}

guard let outImage = outCtx.makeImage() else { fatalError("无法合成输出图像") }

let dstURL = URL(fileURLWithPath: dstPath)
try? FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(dstURL as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fatalError("无法创建输出文件 \(dstPath)")
}
CGImageDestinationAddImage(dest, outImage, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("写出失败 \(dstPath)") }
print("已写出 \(dstPath)（\(canvas)×\(canvas)，18pt @2x 模板图）")

// 回读校验：按视觉方向（上=图像顶部）打印写盘后的 alpha 地图。
do {
    let (buf, w, h) = pixelBuffer(of: loadCGImage(dstURL))
    var opaque = 0
    for i in 0..<(w * h) where buf[i * 4 + 3] > 200 { opaque += 1 }
    print("回读：\(w)×\(h)，不透明像素 \(opaque)/\(w * h)")
    for row in stride(from: h - 1, through: 0, by: -1) {
        var line = ""
        for col in 0..<w {
            let a = buf[(row * w + col) * 4 + 3]
            line += a > 200 ? "#" : (a > 40 ? "." : " ")
        }
        print(line)
    }
}

// 真实感预览：把最终图标按 6 倍最近邻放大，左半铺亮色菜单栏底、右半铺
// 暗色菜单栏底（模板图在暗色下由系统反色，这里手动画白色版模拟），
// 写到 .build/statusbar-preview.png 供目测。
do {
    let scale = 6
    let side = canvas * scale
    let preview = CGContext(data: nil, width: side * 2, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 8, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let light = CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    let dark = CGColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
    preview.interpolationQuality = .none
    preview.setFillColor(light)
    preview.fill(CGRect(x: 0, y: 0, width: side, height: side))
    preview.setFillColor(dark)
    preview.fill(CGRect(x: side, y: 0, width: side, height: side))
    // 左：黑色原样（亮色菜单栏）
    preview.draw(outImage, in: CGRect(x: 0, y: 0, width: side, height: side))
    // 右：手动反色成白色（模拟暗色菜单栏的系统反转）
    let invertCtx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                              bytesPerRow: canvas * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    invertCtx.draw(outImage, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    if let invData = invertCtx.data {
        let p = invData.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(canvas * canvas) where p[i * 4 + 3] > 0 {
            let v = p[i * 4 + 3]
            p[i * 4] = v; p[i * 4 + 1] = v; p[i * 4 + 2] = v
        }
    }
    if let inverted = invertCtx.makeImage() {
        preview.draw(inverted, in: CGRect(x: side, y: 0, width: side, height: side))
    }
    if let pv = preview.makeImage(),
       let pdest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: ".build/statusbar-preview.png") as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(pdest, pv, nil)
        CGImageDestinationFinalize(pdest)
        print("预览已写出 .build/statusbar-preview.png（左亮/右暗，6 倍放大）")
    }
}
