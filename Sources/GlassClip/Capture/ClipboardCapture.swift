// ClipboardCapture.swift — 捕获管线的解析与归一化核心（纯函数，无副作用）。
//
// 输入是从剪贴板读出的原始 (UTI, Data) 条目集合，输出是待入库的
// `CapturedContent`；类型判定按 颜色 → 文件 → 图片 → 文本 的优先级尝试，
// 命中即返回。本模块不触碰 NSPasteboard（那是 PasteboardIO 的职责），
// 只做字节级解析，因此可以无头单测（ClipboardCaptureTests 直接喂 fixture）。
//
// 两个核心设计：
// - identity（去重键）：带类型前缀（c:/f:/i:/t:），同一份内容的不同表示
//   归一化到同一个键——"纯文本变体合并置顶"的机制基础；
// - 大小护栏：总量 >100MB 整体跳过（防单条超大拷贝拖垮存储），
//   总量为 0 视为空剪贴板。

import AppKit
import CryptoKit
import Foundation

// MARK: - 输入结构

/// 剪贴板上的一个原始表示：UTI + 对应字节。
///
/// 与 `ClipboardPayload` 结构相同但角色不同：本类型是"读到的原始输入"，
/// payload 是"决定落库的输出"。
struct PasteboardEntry: Sendable, Equatable {
    /// 统一类型标识。
    var uti: String
    /// 该表示的原始字节。
    var data: Data
}

// MARK: - 捕获核心

/// 无状态的捕获解析器（全静态成员，线程安全）。
enum ClipboardCapture {
    /// 单次捕获的字节总量上限：超过即放弃（设计共识：单条 >100MB 跳过）。
    static let maxPayloadSize = 100 * 1024 * 1024

    /// 自写入标记 UTI：粘贴回写时先写入该类型的 UUID 标记，
    /// 捕获侧看到它就跳过本次变更（否则自己粘贴的内容会被再次捕获，
    /// 无限刷时间戳）。与 changeCount 轮询组成双保险。
    static let selfWriteUTI = "com.glassclip.marker"

    /// 拼去重键：类型前缀 + 该类型的身份主体。
    ///
    /// 前缀收口成一处的原因：identity 是"纯文本变体合并置顶"机制的比对键，
    /// 六个构造点必须用同一份前缀表，拼错一个字符就退化成"永不合并"。
    /// 前缀值参与已入库数据的比对，改值等于换去重域——只允许新增，禁止改既有值。
    static func identity(_ prefix: IdentityPrefix, _ body: String) -> String {
        prefix.rawValue + body
    }

    /// 把原始条目集合解析为待入库内容；不构成有效内容时返回 nil。
    ///
    /// - Parameters:
    ///   - entries: 剪贴板上的全部非空表示（含内部追加的颜色条目）。
    ///   - app: 来源应用（nil = 未知来源，如登录窗前的捕获）。
    ///
    /// 判定顺序即优先级：颜色/文件/图片是强特征类型，文本兜底。
    /// 总量检查说明：total == 0 时每个 entry 必然都为空（各 entry 非负），
    /// 无需再单独写"存在非空条目"的判断。
    static func capture(from entries: [PasteboardEntry], app: AppSource?) -> CapturedContent? {
        // 总量为 0 已蕴含每个 entry 都为空（字节数非负），无需再单独检查
        // "是否存在非空条目"。
        let total = entries.reduce(0) { $0 + $1.data.count }
        guard total > 0, total <= maxPayloadSize else { return nil }

        if let color = captureColor(entries) { return color }
        if let file = captureFiles(entries) { return file }
        if let image = captureImage(entries) { return image }
        return captureTextual(entries, app: app)
    }

    // MARK: 颜色

    /// 颜色捕获：UTI 含 "color" 的条目反归档为 NSColor，转 sRGB 十六进制。
    ///
    /// - identity "c:<hex>"：同一颜色（hex 相同）视为同一内容，去重合并；
    /// - payload 保留原始颜色归档，并附加 "#<hex>" 纯文本表示——粘贴到
    ///   只接受文本的地方也能落出 "#FF0000"。
    /// 反归档失败（数据损坏/类型不符）静默降级，继续尝试下一类捕获。
    private static func captureColor(_ entries: [PasteboardEntry]) -> CapturedContent? {
        guard let entry = entries.first(where: { $0.uti.lowercased().contains("color") }) else { return nil }
        guard let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: entry.data),
              let hex = color.srgbHex
        else { return nil }
        return CapturedContent(
            kind: .color,
            identity: identity(.color, hex),
            searchText: "#\(hex) color",
            previewText: "#\(hex)",
            payloads: [
                ClipboardPayload(uti: entry.uti, data: entry.data),
                ClipboardPayload(uti: UTI.plainText, data: Data("#\(hex)".utf8)),
            ]
        )
    }

    // MARK: 文件

    /// 文件捕获：file-url（现代）与 NSFilenamesPboardType（遗留 JSON 数组）两种来源。
    ///
    /// - 解析：遗留类型按 [String] 路径数组解码；现代类型按 URL dataRepresentation。
    /// - 去重：同一批拷贝可能含重复/别名路径，按标准化路径（解析符号链接、
    ///   统一大小写形式）去重。
    /// - identity "f:<全部标准化路径>"：同一组文件再次拷贝 → 合并置顶。
    /// - previewText 是逗号分隔的文件名；searchText 同时覆盖文件名与全路径，
    ///   支持按路径片段搜索。
    private static func captureFiles(_ entries: [PasteboardEntry]) -> CapturedContent? {
        var urls: [URL] = []
        for entry in entries where entry.uti == UTI.fileURL || entry.uti == "NSFilenamesPboardType" {
            if entry.uti == "NSFilenamesPboardType",
               let paths = try? JSONDecoder().decode([String].self, from: entry.data) {
                urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
            } else if let url = URL(dataRepresentation: entry.data, relativeTo: nil) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return nil }

        var seen = Set<String>()
        urls = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let names = urls.map { $0.lastPathComponent }.joined(separator: ", ")
        let payloads = urls.map { ClipboardPayload(uti: UTI.fileURL, data: $0.dataRepresentation) }
        return CapturedContent(
            kind: .file,
            identity: identity(.file, urls.map { $0.standardizedFileURL.path }.joined(separator: "\n")),
            searchText: names + " " + urls.map { $0.path }.joined(separator: " "),
            previewText: names,
            payloads: payloads
        )
    }

    // MARK: 图片

    /// 图片捕获：取第一个命中的位图表示，统一转 PNG 后以内容哈希为去重键。
    ///
    /// - 统一转 PNG 是身份稳定的前提：同一张图以 TIFF/JPEG 两种表示出现时，
    ///   归一化后字节一致，SHA256 才相同 → 去重生效；
    /// - identity "i:<sha256>"；
    /// - searchText 只有 "image"——像素内容无法文本索引，这是已知妥协
    ///   （搜索图片靠类型过滤，不靠内容）。
    private static func captureImage(_ entries: [PasteboardEntry]) -> CapturedContent? {
        let imageUTIs: Set<String> = [UTI.png, UTI.tiff, UTI.jpeg, UTI.gif]
        guard let entry = entries.first(where: { imageUTIs.contains($0.uti) }) else { return nil }
        guard let pngData = Self.pngData(from: entry.data, uti: entry.uti) else { return nil }
        let digest = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        return CapturedContent(
            kind: .image,
            identity: identity(.image, digest),
            searchText: "image",
            previewText: "Image",
            payloads: [ClipboardPayload(uti: UTI.png, data: pngData)]
        )
    }

    /// 把任意位图字节归一化为 PNG：PNG 原样透传（避免重编码损耗/变慢），
    /// 其余经 NSBitmapImageRep 解码后重编码为 PNG；解码失败返回 nil。
    ///
    /// internal 可见性供单测直接验证"PNG 透传 / 非 PNG 转码"两条路径。
    static func pngData(from data: Data, uti: String) -> Data? {
        if uti == UTI.png { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.pngData
    }

    // MARK: 文本 / 富文本 / HTML

    /// 文本族捕获：从条目里分别取 纯文本 / RTF / HTML 三种表示，再按
    /// RTF > HTML > 纯文本 的富文本优先级决定条目类型。
    ///
    /// 各表示"首个命中生效"（同一 UTI 理论上只出现一次，防御重复条目）。
    /// 纯文本解码顺序 UTF-8 → UTF-16（Windows/老应用常给 UTF-16）。
    ///
    /// 去重语义（设计共识"纯文本变体也合并"）：
    /// - 三种路径的 identity 统一为 "t:<可见文本>"——同一段文字以 RTF/HTML/
    ///   纯文本不同表示拷贝时，identity 一致 → 合并置顶；
    /// - payload 始终附带派生的纯文本表示，保证粘贴到纯文本目标不丢内容。
    private static func captureTextual(_ entries: [PasteboardEntry], app: AppSource?) -> CapturedContent? {
        var plain: String?
        var rtf: Data?
        var html: String?

        for entry in entries {
            switch entry.uti {
            case UTI.plainText:
                if plain == nil, let s = String(data: entry.data, encoding: .utf8) ?? String(data: entry.data, encoding: .utf16) {
                    plain = s
                }
            case UTI.rtf:
                if rtf == nil { rtf = entry.data }
            case UTI.html:
                if html == nil, let s = String(data: entry.data, encoding: .utf8) { html = s }
            default:
                break
            }
        }

        guard plain != nil || rtf != nil || html != nil else { return nil }

        // RTF 路径：用 NSAttributedString 提取可见文本作 identity/搜索/预览。
        if let rtf {
            let attrs = NSAttributedString(rtf: rtf, documentAttributes: nil)
            let plainFromRTF = attrs?.string
            let text = plain ?? plainFromRTF ?? ""
            var payloads: [ClipboardPayload] = [ClipboardPayload(uti: UTI.rtf, data: rtf)]
            if let plainData = text.data(using: .utf8) {
                payloads.append(ClipboardPayload(uti: UTI.plainText, data: plainData))
            }
            return CapturedContent(
                kind: .richText,
                identity: identity(.text, text),
                searchText: text,
                previewText: text,
                payloads: payloads
            )
        }

        // HTML 路径：剥标签得到可见文本；有独立纯文本表示时预览优先用它
        // （源头给的纯文本比剥标签结果更干净）。
        if let html {
            let text = stripTags(html)
            var payloads: [ClipboardPayload] = [ClipboardPayload(uti: UTI.html, data: Data(html.utf8))]
            if let plainData = (plain ?? text).data(using: .utf8) {
                payloads.append(ClipboardPayload(uti: UTI.plainText, data: plainData))
            }
            let preview = plain ?? text
            return CapturedContent(
                kind: .html,
                identity: identity(.text, preview),
                searchText: preview,
                previewText: preview,
                payloads: payloads
            )
        }

        // 纯文本路径：identity 用全文保证精确去重；previewText 对超长文本
        // 截断到 1 万字符（列表只需要首行级预览，存全文浪费内存）。
        let text = plain ?? ""
        let collapsed = text.count > 10_000 ? String(text.prefix(10_000)) : text
        return CapturedContent(
            kind: .text,
            identity: identity(.text, text),
            searchText: text,
            previewText: collapsed,
            payloads: [ClipboardPayload(uti: UTI.plainText, data: Data(text.utf8))]
        )
    }

    /// HTML 实体解码表。构建为常量：每次调用重建字典是不必要的开销。
    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]

    /// 轻量 HTML→纯文本转换（刻意不用 NSAttributedString 全量解析：
    /// 捕获路径 0.4s 一次，只求够快够稳）。
    ///
    /// 步骤：块级标签（br/p/div 结束）先行换行保排版 → 正则剥掉全部标签 →
    /// 解码常见实体 → 掐头去尾空白。覆盖剪贴板 HTML 的绝大多数形态；
    /// 罕见实体残留是可接受的显示级瑕疵。
    static func stripTags(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "</div>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in entities {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - identity 前缀

/// 去重键（identity）的类型前缀。六个构造点共用这一份表。
///
/// 与 `UTI` 同样的约束：值参与已入库数据的比对，改值等于换去重域
/// ——历史记录的 identity 全部认不出来，同内容再拷贝会新增一条而非合并置顶。
/// 只允许新增 case，禁止修改或删除既有值。
enum IdentityPrefix: String {
    case color = "c:"
    case file = "f:"
    case image = "i:"
    case text = "t:"
}

// MARK: - UTI 常量

/// 本项目用到的统一类型标识字符串常量。
///
/// 刻意用裸字符串常量而非 UTType：捕获层只做精确匹配与跨进程写读，
/// 不需要 UTType 的声明能力，常量更轻且无运行时依赖。
enum UTI {
    static let plainText = "public.utf8-plain-text"
    static let rtf = "public.rtf"
    static let html = "public.html"
    static let png = "public.png"
    static let tiff = "public.tiff"
    static let jpeg = "public.jpeg"
    static let gif = "com.compuserve.gif"
    static let fileURL = "public.file-url"
    static let color = "com.apple.cocoa.color"
}

/// 来源应用归因：前台应用的名字与 bundleID。
///
/// 两字段均可空：组合出"完全未知来源"（如 loginwindow 前台时，见
/// PasteboardIO.currentSource）到"只有名字没有 bundleID"等各种残缺形态。
struct AppSource: Sendable, Equatable {
    /// 应用显示名（本地化名）。
    var name: String?
    /// 应用 bundle 标识（敏感过滤的精确匹配键）。
    var bundleID: String?
}
