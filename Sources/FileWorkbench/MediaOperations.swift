import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PDF 和图片处理仅生成内存结果；冲突检测与原子保存由文档会话统一负责。
enum MediaOperationError: Error, LocalizedError, Equatable {
    case invalidPDF
    case lockedPDF
    case restrictedPDF
    case invalidImage
    case unsupportedImageFormat
    case invalidParameter(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPDF: "PDF 文件损坏、为空，或没有可读取的页面。"
        case .lockedPDF: "PDF 已加密，请先解锁文档后再执行此操作。"
        case .restrictedPDF: "此 PDF 的权限不允许执行所选操作。"
        case .invalidImage: "图片文件损坏或无法解码。"
        case .unsupportedImageFormat: "仅支持读取 PNG、JPEG 和 HEIC/HEIF 图片。"
        case .invalidParameter(let detail): "参数无效：\(detail)"
        case .encodingFailed(let format): "无法生成 \(format) 文件。"
        }
    }
}

enum PDFOperations {
    static func read(_ data: Data) throws -> PDFDocument {
        guard !data.isEmpty, let document = PDFDocument(data: data) else {
            throw MediaOperationError.invalidPDF
        }
        guard !document.isLocked else { throw MediaOperationError.lockedPDF }
        guard document.pageCount > 0,
              (0..<document.pageCount).allSatisfy({ document.page(at: $0) != nil }) else {
            throw MediaOperationError.invalidPDF
        }
        return document
    }

    /// 页码从 0 开始。只修改页面旋转属性，不把矢量内容重新栅格化。
    static func rotate(_ data: Data, pageIndexes: [Int], clockwiseQuarterTurns: Int = 1) throws -> Data {
        let document = try read(data)
        try validate(pageIndexes, in: document)
        guard document.allowsDocumentAssembly else { throw MediaOperationError.restrictedPDF }
        let degrees = (clockwiseQuarterTurns % 4) * 90
        for index in pageIndexes {
            let page = try page(at: index, in: document)
            page.rotation = (page.rotation + degrees + 360) % 360
        }
        return try serialize(document)
    }

    /// 合并时保留各页原始 PDF 内容、页面框和批注；文档级元数据采用第一个输入。
    static func merge(_ inputs: [Data]) throws -> Data {
        guard !inputs.isEmpty else { throw MediaOperationError.invalidParameter("至少选择一个 PDF。") }
        let documents = try inputs.map(read)
        guard documents.allSatisfy({ $0.allowsDocumentAssembly && $0.allowsCopying }) else {
            throw MediaOperationError.restrictedPDF
        }
        let output = PDFDocument()
        output.documentAttributes = documents[0].documentAttributes
        for document in documents {
            try appendCopies(of: Array(0..<document.pageCount), from: document, to: output)
        }
        return try serialize(output)
    }

    /// 按调用方给定顺序提取页面。重复页码视为输入错误，避免无意复制页面。
    static func extract(_ data: Data, pageIndexes: [Int]) throws -> Data {
        let document = try read(data)
        try validate(pageIndexes, in: document)
        guard document.allowsDocumentAssembly && document.allowsCopying else {
            throw MediaOperationError.restrictedPDF
        }
        let output = PDFDocument()
        output.documentAttributes = document.documentAttributes
        try appendCopies(of: pageIndexes, from: document, to: output)
        return try serialize(output)
    }

    /// bounds 使用未旋转页面的 PDF 坐标（左下角为原点），调用方负责从视图坐标转换。
    static func addTextAnnotation(_ data: Data, pageIndex: Int, bounds: CGRect, text: String) throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaOperationError.invalidParameter("批注文字不能为空。")
        }
        return try annotate(data, pageIndex: pageIndex, bounds: bounds) { bounds in
            let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            annotation.contents = text
            annotation.color = .systemYellow
            return annotation
        }
    }

    /// 高亮矩形同样使用页面坐标；多行选区应对每行分别调用，避免覆盖行间空白。
    static func addHighlight(_ data: Data, pageIndex: Int, bounds: CGRect) throws -> Data {
        try annotate(data, pageIndex: pageIndex, bounds: bounds) { bounds in
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = NSColor.yellow.withAlphaComponent(0.35)
            // QuadPoints 相对批注框，按 PDFKit 要求的左上、右上、左下、右下顺序排列。
            annotation.quadrilateralPoints = [
                NSValue(point: NSPoint(x: 0, y: bounds.height)),
                NSValue(point: NSPoint(x: bounds.width, y: bounds.height)),
                NSValue(point: .zero),
                NSValue(point: NSPoint(x: bounds.width, y: 0))
            ]
            return annotation
        }
    }

    /// 每张图片生成一页，归一方向后按每像素一个 PDF point 定义页面尺寸。
    static func imagesToPDF(_ images: [Data]) throws -> Data {
        guard !images.isEmpty else { throw MediaOperationError.invalidParameter("至少选择一张图片。") }
        let output = PDFDocument()
        for data in images {
            let image = try ImageOperations.read(data)
            let size = NSSize(width: image.width, height: image.height)
            guard let page = PDFPage(image: NSImage(cgImage: image, size: size)) else {
                throw MediaOperationError.encodingFailed("PDF")
            }
            output.insert(page, at: output.pageCount)
        }
        return try serialize(output)
    }

    private static func annotate(
        _ data: Data, pageIndex: Int, bounds: CGRect,
        makeAnnotation: (CGRect) -> PDFAnnotation
    ) throws -> Data {
        let document = try read(data)
        guard document.allowsCommenting else { throw MediaOperationError.restrictedPDF }
        let page = try page(at: pageIndex, in: document)
        guard finitePositive(bounds), page.bounds(for: .cropBox).contains(bounds) else {
            throw MediaOperationError.invalidParameter("批注范围必须为页面内的有效矩形。")
        }
        page.addAnnotation(makeAnnotation(bounds))
        return try serialize(document)
    }

    private static func validate(_ indexes: [Int], in document: PDFDocument) throws {
        guard !indexes.isEmpty else { throw MediaOperationError.invalidParameter("至少选择一页。") }
        guard Set(indexes).count == indexes.count else { throw MediaOperationError.invalidParameter("页码不能重复。") }
        for index in indexes { _ = try page(at: index, in: document) }
    }

    private static func page(at index: Int, in document: PDFDocument) throws -> PDFPage {
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            throw MediaOperationError.invalidParameter("页码超出文档范围。")
        }
        return page
    }

    private static func appendCopies(of indexes: [Int], from source: PDFDocument, to output: PDFDocument) throws {
        var copiedPages: [Int: PDFPage] = [:]
        var annotations: [(original: PDFAnnotation, copy: PDFAnnotation)] = []
        for index in indexes {
            let original = try page(at: index, in: source)
            guard let copy = original.copy() as? PDFPage,
                  original.annotations.count == copy.annotations.count else {
                throw MediaOperationError.encodingFailed("PDF")
            }
            output.insert(copy, at: output.pageCount)
            copiedPages[index] = copy
            annotations.append(contentsOf: zip(original.annotations, copy.annotations).map { ($0, $1) })
        }

        // PDFPage.copy() 的内部跳转仍指向原文档页；必须在所有目标页就位后重建，否则保存会误跳第一页。
        for (original, copy) in annotations {
            guard let destination = (original.action as? PDFActionGoTo)?.destination ?? original.destination else { continue }
            copy.destination = nil
            copy.action = nil
            // 提取结果没有包含目标页时清除无效跳转，保留批注本身；URL 等外部动作不进入此分支。
            guard let target = destination.page, let copiedTarget = copiedPages[source.index(for: target)] else { continue }
            let mappedDestination = PDFDestination(page: copiedTarget, at: destination.point)
            mappedDestination.zoom = destination.zoom
            copy.action = PDFActionGoTo(destination: mappedDestination)
        }
    }

    private static func serialize(_ document: PDFDocument) throws -> Data {
        guard let data = document.dataRepresentation(), !data.isEmpty else {
            throw MediaOperationError.encodingFailed("PDF")
        }
        return data
    }

    private static func finitePositive(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}

enum ImageExportFormat {
    case png
    case jpeg(quality: Double)
}

enum ImageOperations {
    // 解码前限制像素规模，避免小体积高分辨率压缩图片造成异常内存分配。
    static let maximumDimension = 32_768
    static let maximumPixelCount = 64_000_000

    /// 读取第一帧并归一 EXIF 方向，因此裁剪和尺寸始终对应用户看到的图片。
    static func read(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw MediaOperationError.invalidImage
        }
        let supported = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier]
        guard let type = CGImageSourceGetType(source), supported.contains(type as String) else {
            throw MediaOperationError.unsupportedImageFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw MediaOperationError.invalidImage
        }
        try validate(width: width.intValue, height: height.intValue)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw MediaOperationError.invalidImage
        }
        try validate(width: image.width, height: image.height)
        return image
    }

    static func rotate90(_ image: CGImage, clockwise: Bool = true) throws -> CGImage {
        let context = try makeContext(width: image.height, height: image.width)
        context.translateBy(x: CGFloat(image.height) / 2, y: CGFloat(image.width) / 2)
        context.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
        return try result(from: context)
    }

    /// 像素矩形采用左上角原点；必须落在图片内且为整数，避免隐式取整改变用户选区。
    static func crop(_ image: CGImage, pixelRect: CGRect) throws -> CGImage {
        let components = [pixelRect.origin.x, pixelRect.origin.y, pixelRect.width, pixelRect.height]
        guard components.allSatisfy({ $0.isFinite && $0.rounded() == $0 }),
              pixelRect.width > 0, pixelRect.height > 0,
              CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(pixelRect) else {
            throw MediaOperationError.invalidParameter("裁剪范围必须为图片内的整数像素矩形。")
        }
        guard let cropped = image.cropping(to: pixelRect) else { throw MediaOperationError.invalidImage }
        return cropped
    }

    static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try result(from: context)
    }

    static func export(_ image: CGImage, format: ImageExportFormat) throws -> Data {
        try validate(width: image.width, height: image.height)
        let type: UTType
        let pixels: CGImage
        var properties: [CFString: Any] = [:]
        switch format {
        case .png:
            type = .png
            pixels = image
        case .jpeg(let quality):
            guard quality.isFinite, (0...1).contains(quality) else {
                throw MediaOperationError.invalidParameter("JPEG 质量必须在 0 到 1 之间。")
            }
            type = .jpeg
            properties[kCGImageDestinationLossyCompressionQuality] = quality
            // JPEG 不支持透明通道，明确以白底合成，避免透明区域被编码为黑色。
            let context = try makeContext(width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.fill(rect)
            context.draw(image, in: rect)
            pixels = try result(from: context)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw MediaOperationError.encodingFailed(type.identifier)
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaOperationError.encodingFailed(type.identifier) }
        return data as Data
    }

    private static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              width * height <= maximumPixelCount else {
            throw MediaOperationError.invalidParameter("图片宽高须为正整数，单边不超过 32768 像素，且总像素不超过 6400 万。")
        }
    }

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        try validate(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaOperationError.encodingFailed("图片")
        }
        return context
    }

    private static func result(from context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else { throw MediaOperationError.encodingFailed("图片") }
        return image
    }
}
