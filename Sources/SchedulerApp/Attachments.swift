import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import SchedulerCore

struct Attachment: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let data: Data
    let kind: String
    var pageCount: Int = 1
    var firstPage: Int = 1
    var lastPage: Int = 1
    /// A PDF with a usable text layer is sent as text: more accurate than a rendered page, and no vision model needed.
    var hasTextLayer = false
    var sendAsText = false
    var preview: NSImage?
    /// Only rasterized content needs a verified vision model.
    var requiresVision: Bool { kind == "image" || (kind == "pdf" && !sendAsText) }
    var size: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
    var label: String {
        switch kind {
        case "pdf": "\(size) · 第 \(firstPage)–\(lastPage) 页 · " + (sendAsText ? "按文本发送" : "转成图片发送")
        case "image": "\(size) · 图片"
        default: "\(size) · 文本"
        }
    }
}

enum AttachmentProcessor {
    static let allowed = ["png", "jpg", "jpeg", "heic", "webp", "pdf", "txt", "md"]
    static func load(url: URL) throws -> Attachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let suffix = url.pathExtension.lowercased()
        guard allowed.contains(suffix) else { throw AppError("支持 PNG、JPEG、HEIC、WebP、PDF、TXT 和 MD。") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= 20 * 1024 * 1024 else { throw AppError("请选择 20 MB 以内的普通文件。") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 20 * 1024 * 1024 else { throw AppError("文件超过 20 MB。") }
        let kind = ["txt", "md", "pdf"].contains(suffix) ? suffix : "image"
        var attachment = Attachment(name: url.lastPathComponent, data: data, kind: kind)
        switch kind {
        case "pdf":
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw AppError("PDF 无法读取或有密码，请先解锁。") }
            attachment.pageCount = pdf.pageCount; attachment.lastPage = min(pdf.pageCount, 5)
            attachment.hasTextLayer = hasUsableText(pdf)
            attachment.sendAsText = attachment.hasTextLayer
            attachment.preview = thumbnail(pdf)
        case "image":
            _ = try normalizeImage(data)
            attachment.preview = thumbnail(data)
        default:
            guard String(data: data, encoding: .utf8) != nil else { throw AppError("\(url.lastPathComponent) 不是 UTF-8 文本，请转换编码。") }
        }
        return attachment
    }
    /// Sampled rather than exhaustive: enough to tell a digital document from a scan without reading a whole book.
    static func hasUsableText(_ pdf: PDFDocument) -> Bool {
        let sampled = min(pdf.pageCount, 8)
        var characters = 0
        for index in 0..<sampled {
            characters += (pdf.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        return characters / max(1, sampled) >= 20
    }
    static func pageText(_ page: PDFPage) -> String {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func thumbnail(_ pdf: PDFDocument) -> NSImage? {
        guard let page = pdf.page(at: 0) else { return nil }
        return page.thumbnail(of: NSSize(width: 96, height: 96), for: .mediaBox)
    }
    static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 96]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    static func prepare(text: String, attachments: [Attachment]) throws -> PreparedInput {
        guard text.count <= 20000 else { throw AppError("文字最多 2 万字，请缩小范围。") }
        var result = PreparedInput(text: text)
        for attachment in attachments {
            try Task.checkCancellation()
            if attachment.kind == "txt" || attachment.kind == "md" {
                guard let text = String(data: attachment.data, encoding: .utf8) else { throw AppError("\(attachment.name) 不是 UTF-8 文本，请转换编码。") }
                result.text += "\n\n【附件：\(attachment.name)】\n" + text
            } else if attachment.kind == "pdf" {
                guard attachment.firstPage >= 1, attachment.lastPage >= attachment.firstPage,
                      attachment.lastPage <= attachment.pageCount,
                      attachment.lastPage - attachment.firstPage < 10,
                      let document = PDFDocument(data: attachment.data) else { throw AppError("PDF 页码无效，一次最多选择 10 页。") }
                if attachment.sendAsText {
                    var pages: [String] = []
                    for index in (attachment.firstPage - 1)..<attachment.lastPage {
                        try Task.checkCancellation()
                        guard let page = document.page(at: index) else { throw AppError("无法读取 PDF 第 \(index + 1) 页。") }
                        let text = pageText(page)
                        if !text.isEmpty { pages.append("【附件：\(attachment.name) 第 \(index + 1) 页】\n" + text) }
                    }
                    guard pages.joined().count >= 20 else {
                        throw AppError("所选 PDF 页面没有可提取的文字。请改选页面，或在附件上切换为“按图片”发送。")
                    }
                    result.text += "\n\n" + pages.joined(separator: "\n\n")
                    guard result.text.count <= 20000 else { throw AppError("本次超过 2 万字，请减少附件或 PDF 页数。") }
                    continue
                }
                for index in (attachment.firstPage - 1)..<attachment.lastPage {
                    try Task.checkCancellation()
                    let data: Data = try autoreleasepool {
                        guard let page = document.page(at: index) else { throw AppError("无法读取 PDF 第 \(index + 1) 页。") }
                        guard let reference = page.pageRef else { throw AppError("PDF 页面内容不可用。") }
                        var bounds = reference.getBoxRect(.mediaBox)
                        if abs(reference.rotationAngle) % 180 == 90 { bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width) }
                        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { throw AppError("PDF 页面尺寸无效。") }
                        let scale = min(2, 2200 / max(bounds.width, bounds.height))
                        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
                        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AppError("无法渲染 PDF 页面。") }
                        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                        let target = CGRect(x: 0, y: 0, width: width, height: height)
                        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
                        context.drawPDFPage(reference)
                        guard let image = context.makeImage() else { throw AppError("PDF 转图失败。") }
                        return try jpeg(image)
                    }
                    result.images.append(.init(label: "\(attachment.name) 第 \(index + 1) 页", jpeg: data))
                }
            } else {
                result.images.append(.init(label: attachment.name, jpeg: try normalizeImage(attachment.data)))
            }
            guard result.text.count <= 20000, result.images.count <= 10,
                  result.images.reduce(0, { $0 + $1.jpeg.count }) <= 12 * 1024 * 1024 else { throw AppError("本次超过 2 万字、10 张图片/页面或 12 MB 图像预算，请减少附件或 PDF 页数。") }
        }
        return result
    }
    static func normalizeImage(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width * height <= 80_000_000 else { throw AppError("图片无法解码或超过 8000 万像素。") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true,
                                     kCGImageSourceThumbnailMaxPixelSize:2200, kCGImageSourceShouldCacheImmediately:true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AppError("图片无法解码。") }
        return try jpeg(image)
    }
    static func jpeg(_ image: CGImage) throws -> Data {
        // JPEG has no alpha; composite transparent inputs over white to keep dark text readable.
        guard let matte = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AppError("无法准备图片背景。") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        matte.setFillColor(CGColor(gray: 1, alpha: 1)); matte.fill(rect); matte.draw(image, in: rect)
        guard let flattened = matte.makeImage() else { throw AppError("图片处理失败。") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw AppError("无法编码图片。") }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality:0.88, kCGImagePropertyOrientation:1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppError("图片编码失败。") }
        return output as Data
    }
    @MainActor static func probeImage(code: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 420, height: 150))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 420, height: 150).fill()
        (code as NSString).draw(at: NSPoint(x: 32, y: 50), withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 45, weight: .medium), .foregroundColor:NSColor.black])
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AppError("无法创建图片测试样本。") }
        return try jpeg(cgImage)
    }
}
