import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 真实文件会话回归；独立编译以便不把原生 ONLYOFFICE 窗口代码纳入旧 SwiftPM 应用入口。
@main
struct MediaContentRegression {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fw-media-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try makePNG()
        let imagePath = directory.appendingPathComponent("源图 中文.png")
        try png.write(to: imagePath)
        let pdf = try PDFOperations.imagesToPDF([png, png])
        let pdfPath = directory.appendingPathComponent("源文档.pdf")
        try pdf.write(to: pdfPath)
        try await imageSaveAndConflict(imagePath, directory: directory, original: png)
        try await imageEditsDuringSave(imagePath, directory: directory)
        try await pdfSaveAndUndo(pdfPath, directory: directory, original: pdf)
        try await pdfEditsDuringSave(pdfPath, directory: directory)
        try await csvSaveAndEncoding(directory: directory)
        try await newPDF(directory: directory, imagePath: imagePath)
        try await quickLookReadOnly(directory: directory)
        try await mountedViews(imagePath: imagePath, pdfPath: pdfPath, directory: directory)
        print("PASS: 8 native media/CSV session regressions (real files, no Office runtime)")
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "NativeMediaRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func mutation(_ content: NSViewController, _ body: () throws -> Void) rethrows {
        content.undoManager?.groupsByEvent = false
        content.undoManager?.beginUndoGrouping()
        defer { content.undoManager?.endUndoGrouping() }
        try body()
    }
    @MainActor static func imageSaveAndConflict(_ source: URL, directory: URL, original: Data) async throws {
        let content = try await FWImageContent.open(url: source)
        try expect(!content.isModified && content.kind == .png, "Image initial state")
        try mutation(content) { try content.rotate(clockwise: true) }
        try expect(content.isModified, "Image rotation must mark dirty")
        content.undo(); try expect(!content.isModified, "Image undo must restore exact baseline")
        content.redo(); try expect(content.isModified, "Image redo must restore edit")
        let destination = directory.appendingPathComponent("旋转.jpg")
        try await content.saveAs(to: destination)
        let saved = try Data(contentsOf: destination)
        try expect(content.path == destination && !content.isModified && content.kind == .jpeg, "Image Save As adoption")
        try expect(CGImageSourceGetType(CGImageSourceCreateWithData(saved as CFData, nil)!) as String? == UTType.jpeg.identifier, "JPEG output type")
        try expect(ImageOperations.read(saved).width == 80 && ImageOperations.read(saved).height == 120, "Image rotated dimensions")
        try expect(Data(contentsOf: source) == original, "Image Save As must preserve source")
        try mutation(content) { try content.rotate(clockwise: false) }
        try original.write(to: destination)
        do { try await content.save(); throw failure("Image external change unexpectedly overwritten") }
        catch DocumentIOError.externalModification { }
        try expect(Data(contentsOf: destination) == original && content.isModified, "Image conflict must preserve disk and buffer")
        try await content.save(overwriteExternalChanges: true)
        try expect(!content.isModified, "Confirmed image overwrite should save")
        let export = directory.appendingPathComponent("图片转PDF.pdf")
        try await content.export(to: export, format: .pdf)
        try expect(PDFOperations.read(Data(contentsOf: export)).pageCount == 1, "Image PDF export")
        try expect(content.path == destination, "Export must not retarget image")
        try await content.close()
    }
    @MainActor static func imageEditsDuringSave(_ source: URL, directory: URL) async throws {
        let content = try await FWImageContent.open(url: source)
        var changed = false
        var editError: Error?
        content.onStateChanged = {
            if content.isBusy && !changed {
                changed = true
                do { try mutation(content) { try content.rotate(clockwise: true) } } catch { editError = error }
            }
        }
        let destination = directory.appendingPathComponent("快照.png")
        try await content.saveAs(to: destination)
        if let editError { throw editError }
        try expect(changed && content.isModified && !content.isBusy, "Image edits during save must remain dirty")
        try expect(ImageOperations.read(Data(contentsOf: destination)).width == 120, "Image save wrote captured snapshot")
        try await content.save()
        try expect(ImageOperations.read(Data(contentsOf: destination)).width == 80 && !content.isModified, "Next image save writes newer edit")
    }
    @MainActor static func pdfSaveAndUndo(_ source: URL, directory: URL, original: Data) async throws {
        let content = try await FWPDFContent.open(url: source)
        try mutation(content) {
            try content.rotate(pageIndexes: [0])
            try content.addTextAnnotation(pageIndex: 0, bounds: CGRect(x: 10, y: 10, width: 20, height: 20), text: "工作台中文批注")
            try content.addHighlight(pageIndex: 1, bounds: CGRect(x: 10, y: 10, width: 40, height: 10))
        }
        try expect(content.isModified, "PDF annotations must mark dirty")
        let destination = directory.appendingPathComponent("批注文档.pdf")
        try await content.saveAs(to: destination)
        let document = try PDFOperations.read(Data(contentsOf: destination))
        try expect(document.pageCount == 2 && document.page(at: 0)?.rotation == 90, "PDF save rotation/pages")
        try expect(document.page(at: 0)?.annotations.first?.contents == "工作台中文批注", "PDF annotation text")
        try expect(document.page(at: 1)?.annotations.first?.type == "Highlight", "PDF highlight")
        try expect(Data(contentsOf: source) == original, "PDF Save As preserves source")
        try mutation(content) { try content.extract(pageIndexes: [1]) }
        let export = directory.appendingPathComponent("提取副本.pdf")
        try await content.export(to: export, format: .pdf)
        try expect(PDFOperations.read(Data(contentsOf: export)).pageCount == 1 && content.isModified, "PDF export copy must keep dirty")
        do { try await content.close(); throw failure("Dirty PDF closed") } catch DocumentSessionError.unsavedChanges { }
        content.undo(); try expect(!content.isModified, "PDF undo returns saved baseline")
        try original.write(to: destination)
        do { try await content.save(); throw failure("PDF external change overwritten") } catch DocumentIOError.externalModification { }
        try expect(Data(contentsOf: destination) == original, "PDF failed save preserves disk")
        try await content.reload(discardChanges: true)
        try expect(!content.isModified, "PDF reload baseline")
    }
    @MainActor static func pdfEditsDuringSave(_ source: URL, directory: URL) async throws {
        let content = try await FWPDFContent.open(url: source)
        var changed = false
        var editError: Error?
        content.onStateChanged = {
            if content.isBusy && !changed {
                changed = true
                do { try mutation(content) { try content.rotate(pageIndexes: [1]) } } catch { editError = error }
            }
        }
        let destination = directory.appendingPathComponent("PDF快照.pdf")
        try await content.saveAs(to: destination)
        if let editError { throw editError }
        try expect(content.isModified && !content.isBusy, "PDF edits during save remain dirty")
        try expect(PDFOperations.read(Data(contentsOf: destination)).page(at: 1)?.rotation == 0, "PDF snapshot before concurrent edit")
        try await content.save()
        try expect(PDFOperations.read(Data(contentsOf: destination)).page(at: 1)?.rotation == 90 && !content.isModified, "PDF second save")
    }
    @MainActor static func csvSaveAndEncoding(directory: URL) async throws {
        let source = directory.appendingPathComponent("编码.csv")
        let original = "\"原值\";\"多\r\n行\"\r\n第二;项\r\n"
        _ = try DocumentIO.save(DocumentIO.create(text: original, encoding: .utf16LittleEndian), to: source)
        let content = try await FWCSVContent.open(url: source, encoding: .utf16LittleEndian, delimiter: .semicolon)
        try content.setCell("原值", row: 0, column: 0)
        try expect(!content.isModified, "Unchanged CSV cell must preserve optional original quotes")
        try mutation(content) { try content.setCell("e\u{301}", row: 0, column: 0) }
        let destination = directory.appendingPathComponent("编码副本.csv")
        try await content.saveAs(to: destination)
        let saved = try DocumentIO.open(url: destination)
        try expect(saved.encoding == .utf16LittleEndian && saved.text.contains("\r\n"), "CSV encoding/newline preservation")
        let table = try CSVDocument(text: saved.text, delimiter: .semicolon)
        try expect(table.rows[0][0].utf8.elementsEqual("e\u{301}".utf8) && table.rows[0][1] == "多\r\n行", "CSV unicode and multiline values")
        try expect(DocumentIO.open(url: source).text.utf8.elementsEqual(original.utf8), "CSV Save As must preserve source")
        var changed = false
        var editError: Error?
        content.onStateChanged = {
            if content.isBusy && !changed {
                changed = true
                do { try mutation(content) { try content.setCell("保存期间修改", row: 1, column: 1) } } catch { editError = error }
            }
        }
        try await content.save()
        if let editError { throw editError }
        try expect(content.isModified, "CSV edit during save must remain dirty")
        try await content.save()
        try expect(DocumentIO.open(url: destination).text.contains("保存期间修改") && !content.isModified, "CSV second save")
    }
    @MainActor static func newPDF(directory: URL, imagePath: URL) async throws {
        let content = try await FWPDFContent.createFromImages(urls: [imagePath, imagePath])
        try expect(content.path == nil && content.isModified, "New generated PDF is unsaved")
        do { try await content.save(); throw failure("Untitled PDF saved without path") } catch DocumentIOError.saveLocationRequired { }
        let destination = directory.appendingPathComponent("图片合集.pdf")
        try await content.saveAs(to: destination)
        try expect(PDFOperations.read(Data(contentsOf: destination)).pageCount == 2 && !content.isModified, "Images to PDF save")
    }
    @MainActor static func quickLookReadOnly(directory: URL) async throws {
        let source = directory.appendingPathComponent("other.unknown")
        try Data([1, 2, 3]).write(to: source)
        let content = try await FWQuickLookContent.open(url: source)
        try expect(content.isReadOnly && content.availableOperations == [.open], "Quick Look operation capabilities")
        do { try await content.save(); throw failure("Quick Look save accepted") } catch DocumentSessionError.unsupportedOperation(.save) { }
        try await content.close()
        try expect(content.availableOperations.isEmpty, "Closed Quick Look capabilities")
    }
    @MainActor static func mountedViews(imagePath: URL, pdfPath: URL, directory: URL) async throws {
        let image = try await FWImageContent.open(url: imagePath)
        let pdf = try await FWPDFContent.open(url: pdfPath)
        let csv = try FWCSVContent.create()
        for content in [image as NSViewController, pdf as NSViewController, csv as NSViewController] {
            content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            content.view.layoutSubtreeIfNeeded()
            try expect(!content.view.subviews.isEmpty, "Native editor must create visible controls")
        }
    }
    static func makePNG() throws -> Data {
        let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        return try ImageOperations.export(context.makeImage()!, format: .png)
    }
    static func failure(_ text: String) -> Error { NSError(domain: "NativeMediaRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
