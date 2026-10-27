import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import FileWorkbench

@MainActor
final class MediaOperationsTests: XCTestCase {
    func testImageRoundTripTransformsAndFormats() throws {
        let input = try makeImage(width: 12, height: 8)
        let png = try ImageOperations.export(input, format: .png)
        XCTAssertEqual(try sourceType(png), UTType.png.identifier)
        let image = try ImageOperations.read(png)
        XCTAssertEqual(image.width, 12)
        XCTAssertEqual(image.height, 8)

        let rotated = try ImageOperations.rotate90(image)
        XCTAssertEqual(rotated.width, 8)
        XCTAssertEqual(rotated.height, 12)
        let restored = try ImageOperations.rotate90(rotated, clockwise: false)
        XCTAssertEqual(restored.width, 12)
        XCTAssertEqual(restored.height, 8)
        let cropped = try ImageOperations.crop(image, pixelRect: CGRect(x: 2, y: 1, width: 6, height: 4))
        XCTAssertEqual(cropped.width, 6)
        XCTAssertEqual(cropped.height, 4)
        let resized = try ImageOperations.resize(cropped, width: 30, height: 20)
        let jpeg = try ImageOperations.export(resized, format: .jpeg(quality: 0.9))
        XCTAssertEqual(try sourceType(jpeg), UTType.jpeg.identifier)
        let decoded = try ImageOperations.read(jpeg)
        XCTAssertEqual(decoded.width, 30)
        XCTAssertEqual(decoded.height, 20)
    }

    func testImageOrientationIsNormalizedOnRead() throws {
        let image = try makeImage(width: 12, height: 8)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let normalized = try ImageOperations.read(data as Data)
        XCTAssertEqual(normalized.width, 8)
        XCTAssertEqual(normalized.height, 12)
    }

    func testImageEditsRetainMetadataWithoutReapplyingSourceOrientation() throws {
        let input = try makeImage(width: 12, height: 8)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let originalProperties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "图片作者", kCGImagePropertyTIFFImageDescription: "拍摄说明"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:01:02 03:04:05", kCGImagePropertyExifUserComment: "Preserve capture comment",
                                            kCGImagePropertyExifPixelXDimension: 12, kCGImagePropertyExifPixelYDimension: 8,
                                            kCGImagePropertyExifSubjectArea: [2, 3]],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLatitude: 30.25]
        ]
        CGImageDestinationAddImage(destination, input, originalProperties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = data as Data
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let fixtureProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any])
        let fixtureExif = try XCTUnwrap(fixtureProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(fixtureExif[kCGImagePropertyExifUserComment] as? String, "Preserve capture comment", "先确认 ImageIO 已正确生成原始测试元数据")
        let normalized = try ImageOperations.read(original)
        let outputs = [try ImageOperations.rotate90(normalized),
                       try ImageOperations.crop(normalized, pixelRect: CGRect(x: 1, y: 2, width: 4, height: 6)),
                       try ImageOperations.resize(normalized, width: 30, height: 20)]
        for image in outputs {
            // 控制器先把变换结果放进无损 PNG 快照，JPEG 保存再编码；两个阶段都不能丢失描述或复用旧方向。
            let png = try ImageOperations.export(image, format: .png, preservingMetadataFrom: original)
            let jpeg = try ImageOperations.export(ImageOperations.read(png), format: .jpeg(quality: 0.92), preservingMetadataFrom: png)
            for encoded in [png, jpeg] {
                let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
                let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
                let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
                XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist] as? String, "图片作者")
                XCTAssertEqual(tiff[kCGImagePropertyTIFFImageDescription] as? String, "拍摄说明")
                XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2025:01:02 03:04:05")
                XCTAssertEqual(exif[kCGImagePropertyExifUserComment] as? String, "Preserve capture comment")
                XCTAssertEqual(gps[kCGImagePropertyGPSLatitude] as? Double, 30.25)
                XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue, image.width)
                XCTAssertEqual((exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue, image.height)
                XCTAssertNil(exif[kCGImagePropertyExifSubjectArea], "裁剪或旋转后不能复用旧像素区域")
                let reopened = try ImageOperations.read(encoded)
                XCTAssertEqual(reopened.width, image.width)
                XCTAssertEqual(reopened.height, image.height)
            }
        }
    }

    func testImageRotationDirectionAndCropOrigin() throws {
        let red: [UInt8] = [255, 0, 0, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let blue: [UInt8] = [0, 0, 255, 255]
        let yellow: [UInt8] = [255, 255, 0, 255]
        let magenta: [UInt8] = [255, 0, 255, 255]
        let cyan: [UInt8] = [0, 255, 255, 255]
        let pixels = Data(red + green + blue + yellow + magenta + cyan)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertEqual(try rgbaBytes(ImageOperations.rotate90(image)), magenta + blue + red + cyan + yellow + green)
        XCTAssertEqual(try rgbaBytes(ImageOperations.crop(image, pixelRect: CGRect(x: 0, y: 0, width: 1, height: 1))), red)
    }

    func testJPEGTransparentPixelsUseWhiteBackground() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let transparent = try XCTUnwrap(context.makeImage())
        let jpeg = try ImageOperations.export(transparent, format: .jpeg(quality: 1))
        let bytes = try rgbaBytes(ImageOperations.read(jpeg))
        XCTAssertTrue(bytes.allSatisfy { $0 >= 250 })
    }

    func testHEICRead() throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("本机 ImageIO 未提供 HEIC 编码器，不能生成验收样本。")
        }
        CGImageDestinationAddImage(destination, try makeImage(width: 128, height: 64), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try ImageOperations.read(data as Data)
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 64)
    }

    func testImageValidationRejectsCorruptionAndInvalidGeometry() throws {
        XCTAssertThrowsError(try ImageOperations.read(Data("broken".utf8)))
        let image = try makeImage(width: 12, height: 8)
        for rect in [CGRect(x: -1, y: 0, width: 2, height: 2),
                     CGRect(x: 0.5, y: 0, width: 2, height: 2),
                     CGRect(x: 0, y: 0, width: 13, height: 8),
                     CGRect(x: 0, y: 0, width: 0, height: 8)] {
            XCTAssertThrowsError(try ImageOperations.crop(image, pixelRect: rect))
        }
        XCTAssertThrowsError(try ImageOperations.resize(image, width: 0, height: 10))
        XCTAssertThrowsError(try ImageOperations.resize(image, width: Int.max, height: 10))
        XCTAssertThrowsError(try ImageOperations.resize(image, width: 10_000, height: 10_000))
        XCTAssertThrowsError(try ImageOperations.export(image, format: .jpeg(quality: .nan)))
        XCTAssertThrowsError(try ImageOperations.export(image, format: .jpeg(quality: 1.1)))
    }

    func testPDFRotateMergeExtractPreservePageGeometryAndAnnotations() throws {
        let initial = try makePDF(pageSizes: [CGSize(width: 120, height: 80), CGSize(width: 200, height: 100)])
        let annotated = try PDFOperations.addTextAnnotation(initial, pageIndex: 0,
                                                          bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                                                          text: "中文批注")
        let rotated = try PDFOperations.rotate(annotated, pageIndexes: [0], clockwiseQuarterTurns: 1)
        let rotatedDocument = try PDFOperations.read(rotated)
        XCTAssertEqual(rotatedDocument.page(at: 0)?.rotation, 90)
        XCTAssertEqual(rotatedDocument.page(at: 1)?.rotation, 0)
        XCTAssertEqual(rotatedDocument.page(at: 0)?.annotations.first?.contents, "中文批注")
        XCTAssertEqual(try PDFOperations.read(initial).page(at: 0)?.rotation, 0)

        let merged = try PDFOperations.merge([rotated, initial])
        let mergedDocument = try PDFOperations.read(merged)
        XCTAssertEqual(mergedDocument.pageCount, 4)
        XCTAssertEqual(mergedDocument.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 200, height: 100))
        XCTAssertEqual(mergedDocument.page(at: 0)?.annotations.first?.contents, "中文批注")
        XCTAssertEqual(mergedDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "测试文档")

        let extracted = try PDFOperations.read(PDFOperations.extract(merged, pageIndexes: [3, 0]))
        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertEqual(extracted.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 200, height: 100))
        XCTAssertEqual(extracted.page(at: 1)?.rotation, 90)
        XCTAssertEqual(extracted.page(at: 1)?.annotations.first?.contents, "中文批注")
    }

    func testPDFHighlightAndImagesToPDF() throws {
        let image = try ImageOperations.export(makeImage(width: 120, height: 80), format: .png)
        let pdf = try PDFOperations.imagesToPDF([image, image])
        let highlightBounds = CGRect(x: 10, y: 10, width: 50, height: 10)
        let highlighted = try PDFOperations.addHighlight(pdf, pageIndex: 1, bounds: highlightBounds)
        let document = try PDFOperations.read(highlighted)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 120, height: 80))
        let annotation = try XCTUnwrap(document.page(at: 1)?.annotations.first)
        XCTAssertEqual(annotation.type, "Highlight")
        XCTAssertEqual(annotation.bounds, highlightBounds)
        XCTAssertEqual(annotation.quadrilateralPoints?.count, 4)
    }

    func testPDFBatchHighlightsPreservePagesAnnotationsGeometryAndMetadata() throws {
        let initial = try makePDF(pageSizes: [CGSize(width: 120, height: 80), CGSize(width: 200, height: 100)])
        let noted = try PDFOperations.addTextAnnotation(initial, pageIndex: 0, bounds: CGRect(x: 5, y: 5, width: 10, height: 10), text: "保留批注")
        let source = try PDFOperations.rotate(noted, pageIndexes: [1])
        let marks = [PDFOperations.Highlight(pageIndex: 0, bounds: CGRect(x: 10, y: 30, width: 80, height: 10)),
                     .init(pageIndex: 0, bounds: CGRect(x: 10, y: 50, width: 60, height: 10)),
                     .init(pageIndex: 1, bounds: CGRect(x: 20, y: 40, width: 100, height: 12))]
        let document = try PDFOperations.read(PDFOperations.addHighlights(source, highlights: marks))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 1)?.rotation, 90)
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "测试文档")
        XCTAssertEqual(document.page(at: 0)?.annotations.first?.contents, "保留批注")
        for mark in marks {
            let annotation = try XCTUnwrap(document.page(at: mark.pageIndex)?.annotations.first { $0.type == "Highlight" && $0.bounds == mark.bounds })
            XCTAssertEqual(annotation.quadrilateralPoints?.count, 4)
        }
        XCTAssertEqual(try PDFOperations.read(source).page(at: 0)?.annotations.filter { $0.type == "Highlight" }.count, 0)
        XCTAssertTrue(try PDFOperations.read(source).page(at: 1)?.annotations.isEmpty == true)
    }

    func testPDFBatchHighlightsRejectEntireInvalidSelection() throws {
        let source = try makePDF(pageSizes: [CGSize(width: 120, height: 80)])
        let valid = PDFOperations.Highlight(pageIndex: 0, bounds: CGRect(x: 5, y: 5, width: 30, height: 10))
        for invalid in [PDFOperations.Highlight(pageIndex: 5, bounds: valid.bounds),
                        .init(pageIndex: 0, bounds: CGRect(x: -1, y: 5, width: 10, height: 10)),
                        .init(pageIndex: 0, bounds: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))] {
            XCTAssertThrowsError(try PDFOperations.addHighlights(source, highlights: [valid, invalid]))
        }
        XCTAssertThrowsError(try PDFOperations.addHighlights(source, highlights: []))
        XCTAssertTrue(try PDFOperations.read(source).page(at: 0)?.annotations.isEmpty == true)
    }

    func testDecodedImageToPDFPreservesNormalizedGeometry() throws {
        let image = try ImageOperations.rotate90(makeImage(width: 120, height: 80))
        let document = try PDFOperations.read(PDFOperations.imageToPDF(image))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 80, height: 120))
    }

    func testPDFMergeRemapsInternalLinksAndPreservesExternalURLs() throws {
        let prefix = try makePDF(pageSizes: [CGSize(width: 40, height: 50)])
        let linked = try makeLinkedPDF()
        let merged = try PDFOperations.read(PDFOperations.merge([prefix, linked, linked]))
        XCTAssertEqual(merged.pageCount, 5)
        // 相同输入重复合并时，各自链接仍留在自己的页面组内，不能落到原索引或另一个副本。
        for start in [1, 3] {
            try assertDestination(merged, pageIndex: start, name: "forward", targetIndex: start + 1,
                                  point: CGPoint(x: 20, y: 30), zoom: 1.5)
            try assertDestination(merged, pageIndex: start + 1, name: "backward", targetIndex: start,
                                  point: CGPoint(x: 11, y: 12), zoom: 2)
            let external = try annotation(in: merged, pageIndex: start, name: "external")
            XCTAssertEqual((external.action as? PDFActionURL)?.url?.absoluteString, "https://example.com/files")
        }
    }

    func testPDFExtractRemapsLinksAndRemovesTargetsOutsideSelection() throws {
        let linked = try makeLinkedPDF()
        let sameOrder = try PDFOperations.read(PDFOperations.extract(linked, pageIndexes: [0, 1]))
        try assertDestination(sameOrder, pageIndex: 0, name: "forward", targetIndex: 1,
                              point: CGPoint(x: 20, y: 30), zoom: 1.5)
        let reversed = try PDFOperations.read(PDFOperations.extract(linked, pageIndexes: [1, 0]))
        try assertDestination(reversed, pageIndex: 1, name: "forward", targetIndex: 0,
                              point: CGPoint(x: 20, y: 30), zoom: 1.5)
        try assertDestination(reversed, pageIndex: 0, name: "backward", targetIndex: 1,
                              point: CGPoint(x: 11, y: 12), zoom: 2)

        let singlePage = try PDFOperations.read(PDFOperations.extract(linked, pageIndexes: [0]))
        let invalidLink = try annotation(in: singlePage, pageIndex: 0, name: "forward")
        XCTAssertNil(invalidLink.destination)
        XCTAssertNil(invalidLink.action)
        let external = try annotation(in: singlePage, pageIndex: 0, name: "external")
        XCTAssertEqual((external.action as? PDFActionURL)?.url?.absoluteString, "https://example.com/files")
    }

    func testPDFValidationRejectsBadInputs() throws {
        let data = try makePDF(pageSizes: [CGSize(width: 120, height: 80)])
        XCTAssertThrowsError(try PDFOperations.read(Data("not a PDF".utf8)))
        XCTAssertThrowsError(try PDFOperations.merge([]))
        XCTAssertThrowsError(try PDFOperations.extract(data, pageIndexes: []))
        XCTAssertThrowsError(try PDFOperations.extract(data, pageIndexes: [-1]))
        XCTAssertThrowsError(try PDFOperations.extract(data, pageIndexes: [1]))
        XCTAssertThrowsError(try PDFOperations.rotate(data, pageIndexes: [0, 0]))
        XCTAssertThrowsError(try PDFOperations.imagesToPDF([]))
        XCTAssertThrowsError(try PDFOperations.addTextAnnotation(data, pageIndex: 0,
                                                               bounds: CGRect(x: 10, y: 10, width: 20, height: 20), text: " "))
        XCTAssertThrowsError(try PDFOperations.addHighlight(data, pageIndex: 0,
                                                          bounds: CGRect(x: 110, y: 10, width: 20, height: 20)))
        XCTAssertThrowsError(try PDFOperations.addHighlight(data, pageIndex: 0,
                                                          bounds: CGRect(x: CGFloat.nan, y: 10, width: 20, height: 20)))
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func sourceType(_ data: Data) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceGetType(source)) as String
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let rowBytes = image.width * 4
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: rowBytes * image.height))
    }

    private func makePDF(pageSizes: [CGSize]) throws -> Data {
        let document = PDFDocument()
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "测试文档"]
        for size in pageSizes {
            let image = try makeImage(width: Int(size.width), height: Int(size.height))
            let page = try XCTUnwrap(PDFPage(image: NSImage(cgImage: image, size: size)))
            document.insert(page, at: document.pageCount)
        }
        return try XCTUnwrap(document.dataRepresentation())
    }

    private func makeLinkedPDF() throws -> Data {
        let document = try PDFOperations.read(makePDF(pageSizes: [CGSize(width: 120, height: 80),
                                                                 CGSize(width: 200, height: 100)]))
        let first = try XCTUnwrap(document.page(at: 0))
        let second = try XCTUnwrap(document.page(at: 1))
        let bounds = CGRect(x: 10, y: 10, width: 30, height: 20)
        let forward = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        forward.contents = "forward"
        let forwardTarget = PDFDestination(page: second, at: CGPoint(x: 20, y: 30))
        forwardTarget.zoom = 1.5
        forward.destination = forwardTarget
        first.addAnnotation(forward)

        let backward = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        backward.contents = "backward"
        let backwardTarget = PDFDestination(page: first, at: CGPoint(x: 11, y: 12))
        backwardTarget.zoom = 2
        backward.action = PDFActionGoTo(destination: backwardTarget)
        second.addAnnotation(backward)

        let external = PDFAnnotation(bounds: CGRect(x: 60, y: 10, width: 30, height: 20), forType: .link, withProperties: nil)
        external.contents = "external"
        external.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/files")))
        first.addAnnotation(external)
        return try XCTUnwrap(document.dataRepresentation())
    }

    private func annotation(in document: PDFDocument, pageIndex: Int, name: String) throws -> PDFAnnotation {
        try XCTUnwrap(document.page(at: pageIndex)?.annotations.first { $0.contents == name })
    }

    private func assertDestination(_ document: PDFDocument, pageIndex: Int, name: String, targetIndex: Int,
                                   point: CGPoint, zoom: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let link = try annotation(in: document, pageIndex: pageIndex, name: name)
        let destination = try XCTUnwrap(link.destination ?? (link.action as? PDFActionGoTo)?.destination, file: file, line: line)
        let target = try XCTUnwrap(destination.page, file: file, line: line)
        XCTAssertEqual(document.index(for: target), targetIndex, file: file, line: line)
        XCTAssertEqual(destination.point, point, file: file, line: line)
        XCTAssertEqual(destination.zoom, zoom, accuracy: 0.001, file: file, line: line)
    }
}
