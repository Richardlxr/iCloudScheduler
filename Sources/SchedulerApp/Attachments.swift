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
    var label: String { kind == "pdf" ? "\(pageCount) 页 · 发送第 \(firstPage)–\(lastPage) 页" : ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
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
        if kind == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw AppError("PDF 无法读取或有密码，请先解锁。") }
            attachment.pageCount = pdf.pageCount; attachment.lastPage = min(pdf.pageCount, 5)
        }
        return attachment
    }
    static func prepare(text: String, attachments: [Attachment]) throws -> PreparedInput {
        guard text.count <= 20000 else { throw AppError("文字最多 2 万字，请缩小范围。") }
        var result = PreparedInput(text: text)
        for attachment in attachments {
            try Task.checkCancellation()
            if attachment.kind == "txt" || attachment.kind == "md" {
                guard let text = String(data: attachment.data, encoding: .utf8) else { throw AppError("\(attachment.name) 不是 UTF-8 文本，请转换编码。") }
                result.text += "\n\n附件 \(attachment.name)：\n" + text
            } else if attachment.kind == "pdf" {
                guard attachment.firstPage >= 1, attachment.lastPage >= attachment.firstPage,
                      attachment.lastPage <= attachment.pageCount,
                      attachment.lastPage - attachment.firstPage < 10,
                      let document = PDFDocument(data: attachment.data) else { throw AppError("PDF 页码无效，一次最多选择 10 页。") }
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
