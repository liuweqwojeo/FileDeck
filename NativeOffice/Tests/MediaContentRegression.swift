import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 真实文件会话回归；独立编译以便不把原生 ONLYOFFICE 窗口代码纳入旧 SwiftPM 应用入口。
@main
struct MediaContentRegression {
    @MainActor static func main() async {
        // 断言失败应给出正常的测试退出码，不能由 async main 的未捕获错误触发系统崩溃报告。
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func run() async throws {
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
        try await csvIncrementalUndoAndBaseline(directory: directory)
        try await newPDF(directory: directory, imagePath: imagePath)
        try await quickLookReadOnly(directory: directory)
        try await mountedViews(imagePath: imagePath, pdfPath: pdfPath, directory: directory)
        try await binaryOutputLimits(directory: directory)
        try await pdfOutputLimits(pdfPath, imagePath: imagePath, directory: directory)
        try await commandCapabilities(imagePath: imagePath, pdfPath: pdfPath, directory: directory)
        try await imageTransformTransactions(directory: directory)
        try await pdfBatchHighlights(pdfPath, directory: directory)
        try await mediaHistoryAndCancellation(imagePath, directory: directory)
        print("PASS: 15 native media/CSV session regressions (real files, no Office runtime)")
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "NativeMediaRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor static func binaryOutputLimits(directory: URL) async throws {
        let path = directory.appendingPathComponent("binary-limit")
        let baseline = Data([1, 2, 3, 4])
        try baseline.write(to: path)
        let loaded = try SafeFileIO.open(url: path, maximumBytes: 8)
        let state = try FWBinaryState(data: loaded.data, fileState: loaded.state, maximumBytes: 8)
        let oversized = Data(repeating: 9, count: 9)
        do { _ = try FWBinaryState(data: oversized, maximumBytes: 8); throw failure("Oversized initial buffer accepted") }
        catch DocumentIOError.fileTooLarge(limitBytes: 8) { }
        for dirty in [false, true] {
            let expected = dirty ? Data([5, 6, 7, 8]) : baseline
            try state.replace(expected)
            do { try state.replace(oversized); throw failure("Oversized replacement accepted") }
            catch DocumentIOError.fileTooLarge(limitBytes: 8) { }
            do { try await state.transform { _ in oversized }; throw failure("Oversized async result accepted") }
            catch DocumentIOError.fileTooLarge(limitBytes: 8) { }
            try expect(state.data == expected && state.path == path && state.isModified == dirty,
                       "Rejected results must preserve buffer, path and saved baseline")
            try expect(!state.isBusy && state.canEdit, "Rejected transform must leave the state usable")
        }
        do {
            try await state.save(to: nil, overwrite: false, encode: { _ in oversized })
            throw failure("Oversized encoded output accepted")
        } catch DocumentIOError.fileTooLarge(limitBytes: 8) { }
        try expect(Data(contentsOf: path) == baseline && state.isModified && !state.isBusy,
                   "Rejected encoding must preserve disk and dirty state")
        let exact = Data(repeating: 7, count: 8)
        try await state.transform { _ in exact }
        try await state.save(to: nil, overwrite: false)
        try expect(Data(contentsOf: path) == exact && !state.isModified, "Exact output limit must remain saveable")
    }

    @MainActor static func pdfOutputLimits(_ source: URL, imagePath: URL, directory: URL) async throws {
        // 小阈值触发真实 PDF 序列化的超限分支，避免用几百 MiB 的分配代替状态语义回归。
        let baseline = try Data(contentsOf: source)
        let rotated = try PDFOperations.rotate(baseline, pageIndexes: [0])
        let limit = max(baseline.count, rotated.count) + 512
        let content = try await FWPDFContent.open(url: source, maximumBytes: limit)
        try mutation(content) { try content.rotate(pageIndexes: [0]) }
        content.undo()
        try expect(!content.isModified && content.canRedo && !content.canUndo, "PDF initial redo branch")
        for dirty in [false, true] {
            if dirty { content.redo() }
            let before = directory.appendingPathComponent("before-limit-\(dirty).pdf")
            try await content.export(to: before, format: .pdf)
            do {
                try content.addTextAnnotation(pageIndex: 0, bounds: CGRect(x: 5, y: 5, width: 20, height: 20),
                                              text: String(repeating: "oversized annotation", count: 4_000))
                throw failure("Oversized PDF installation accepted")
            } catch DocumentIOError.fileTooLarge { }
            do { try await content.merge(urls: [source]); throw failure("Oversized PDF merge accepted") }
            catch DocumentIOError.fileTooLarge { }
            do { try await content.appendImages(urls: [imagePath, imagePath]); throw failure("Oversized PDF append accepted") }
            catch DocumentIOError.fileTooLarge { }
            do {
                try await content.addHighlights(Array(repeating: .init(pageIndex: 0, bounds: CGRect(x: 5, y: 5, width: 20, height: 10)), count: 100))
                throw failure("Oversized batch highlight accepted")
            } catch DocumentIOError.fileTooLarge { }
            let after = directory.appendingPathComponent("after-limit-\(dirty).pdf")
            try await content.export(to: after, format: .pdf)
            try expect(Data(contentsOf: after) == Data(contentsOf: before), "Rejected PDF edits must preserve every buffer byte")
            try expect(content.isModified == dirty && content.canUndo == dirty && content.canRedo == !dirty && !content.isBusy,
                       "Rejected PDF edits must preserve undo/redo branch and dirty state")
        }
        content.undo()
        try expect(!content.isModified, "Undo after rejected edits must still reach original baseline")
        try await content.save()
        try expect(Data(contentsOf: source) == baseline, "PDF failed transformations must not change source")
        try await content.close()
        do {
            _ = try await FWPDFContent.createFromImages(urls: [imagePath], maximumBytes: 1)
            throw failure("Oversized initial image batch accepted")
        } catch DocumentIOError.fileTooLarge { }

        let normal = try await FWPDFContent.open(url: source)
        normal.undoManager?.groupsByEvent = false
        normal.undoManager?.beginUndoGrouping()
        try await normal.merge(urls: [source])
        normal.undoManager?.endUndoGrouping()
        let merged = directory.appendingPathComponent("正常合并.pdf")
        try await normal.export(to: merged, format: .pdf)
        let pages = try PDFOperations.read(baseline).pageCount
        try expect(PDFOperations.read(Data(contentsOf: merged)).pageCount == pages * 2 && normal.canUndo,
                   "Normal PDF batch must merge all pages and create undo")
        normal.undo()
        try expect(!normal.isModified && normal.canRedo, "Normal merge undo must restore baseline")
        normal.undoManager?.beginUndoGrouping()
        try await normal.appendImages(urls: [imagePath])
        normal.undoManager?.endUndoGrouping()
        let appended = directory.appendingPathComponent("正常追加.pdf")
        try await normal.export(to: appended, format: .pdf)
        try expect(PDFOperations.read(Data(contentsOf: appended)).pageCount == pages + 1 && normal.canUndo,
                   "Normal image batch must append a page and create undo")
        normal.undo()
        try expect(!normal.isModified, "Normal image append undo must restore baseline")
        try await normal.close()
    }

    @MainActor static func commandCapabilities(imagePath: URL, pdfPath: URL, directory: URL) async throws {
        let csvPath = directory.appendingPathComponent("commands.csv")
        try Data("a,b\n".utf8).write(to: csvPath)
        let csv = try await FWCSVContent.open(url: csvPath)
        let image = try await FWImageContent.open(url: imagePath)
        let pdf = try await FWPDFContent.open(url: pdfPath)
        let preview = try await FWQuickLookContent.open(url: imagePath)
        try expect(!csv.canFind && !image.canFind && !preview.canFind && !preview.canUndo && !preview.canRedo,
                   "CSV, image and Quick Look must not advertise unimplemented find")
        try expect(pdf.canFind, "PDF text find must be available without editing")
        for content: any FWNativeContent in [csv, image, pdf] {
            try expect(!content.canUndo && !content.canRedo, "Empty history must disable undo and redo")
            try await mutation(content.controller) {
                if let csv = content as? FWCSVContent { try csv.setCell("changed", row: 0, column: 0) }
                if let image = content as? FWImageContent { try await image.rotate(clockwise: true) }
                if let pdf = content as? FWPDFContent { try pdf.rotate(pageIndexes: [0]) }
            }
            try expect(content.canUndo && !content.canRedo, "A committed edit must enable only undo")
            content.undo()
            try expect(!content.canUndo && content.canRedo && !content.isModified, "Undo must expose redo and restore baseline")
            content.redo()
            var busyWasDisabled = false
            content.onStateChanged = {
                if content.isBusy {
                    busyWasDisabled = !content.canFind && !content.canUndo && !content.canRedo
                    content.undo() // 禁用期间的直接调用也不得消耗历史。
                }
            }
            try await content.save()
            content.onStateChanged = nil
            try expect(busyWasDisabled && content.canUndo, "Busy commands must be disabled without consuming history")
            try await content.reload(discardChanges: true)
            try expect(!content.canUndo && !content.canRedo, "Reload must clear menu history capabilities")
            try await content.close(discardChanges: true)
            try expect(!content.canFind && !content.canUndo && !content.canRedo, "Closed content must disable all commands")
        }
        for source in [pdfPath, imagePath, csvPath] {
            let readonlyPath = directory.appendingPathComponent("readonly-commands." + source.pathExtension)
            try Data(contentsOf: source).write(to: readonlyPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readonlyPath.path)
            let readonly: any FWNativeContent
            switch source.pathExtension {
            case "pdf": readonly = try await FWPDFContent.open(url: readonlyPath)
            case "csv": readonly = try await FWCSVContent.open(url: readonlyPath)
            default: readonly = try await FWImageContent.open(url: readonlyPath)
            }
            try expect(readonly.isReadOnly && readonly.canFind == (source.pathExtension == "pdf") && !readonly.canUndo && !readonly.canRedo,
                       "Read-only media and CSV must advertise only supported non-mutating commands")
            try await readonly.close()
        }
    }
    @MainActor static func mutation(_ content: NSViewController, _ body: () throws -> Void) rethrows {
        content.undoManager?.groupsByEvent = false
        content.undoManager?.beginUndoGrouping()
        defer { content.undoManager?.endUndoGrouping() }
        try body()
    }
    @MainActor static func mutation(_ content: NSViewController, _ body: () async throws -> Void) async rethrows {
        content.undoManager?.groupsByEvent = false
        content.undoManager?.beginUndoGrouping()
        defer { content.undoManager?.endUndoGrouping() }
        try await body()
    }
    @MainActor static func imageSaveAndConflict(_ source: URL, directory: URL, original: Data) async throws {
        try await unmodifiedImageSavesPreserveBytes(directory: directory)
        try await editedImagePreservesMetadata(directory: directory)
        let content = try await FWImageContent.open(url: source)
        try expect(!content.isModified && content.kind == .png, "Image initial state")
        try await mutation(content) { try await content.rotate(clockwise: true) }
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
        try await mutation(content) { try await content.rotate(clockwise: false) }
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
    @MainActor static func unmodifiedImageSavesPreserveBytes(directory: URL) async throws {
        for type in [UTType.jpeg, .png] {
            let original = try makeMetadataImage(type: type)
            let source = directory.appendingPathComponent("未修改.\(type.preferredFilenameExtension!)")
            try original.write(to: source)
            let content = try await FWImageContent.open(url: source)
            try await content.save()
            try expect(Data(contentsOf: source) == original, "Unmodified \(type.identifier) save must preserve every byte")
            let destination = directory.appendingPathComponent("未修改副本.\(type.preferredFilenameExtension!)")
            try await content.saveAs(to: destination)
            try expect(Data(contentsOf: destination) == original, "Same-format Save As must preserve every byte")
            // 原样写回仍走快照检查，不能为了避免重编码而绕过外部修改冲突。
            let external = try makePNG()
            try external.write(to: destination)
            do { try await content.save(); throw failure("Unmodified image overwrote an external change") }
            catch DocumentIOError.externalModification { }
            try expect(Data(contentsOf: destination) == external, "Failed unmodified save must preserve external content")
            try await content.close()
        }
    }
    @MainActor static func editedImagePreservesMetadata(directory: URL) async throws {
        let source = directory.appendingPathComponent("带方向与元数据.jpg")
        try makeMetadataImage(type: .jpeg).write(to: source)
        let content = try await FWImageContent.open(url: source)
        // 原始 120×80 像素携带方向 6，读取为 80×120；用户再右转后应为 120×80。
        try await mutation(content) { try await content.rotate(clockwise: true) }
        try await content.save()
        let saved = try Data(contentsOf: source)
        let metadata = try imageProperties(saved)
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        try expect(tiff?[kCGImagePropertyTIFFArtist as String] as? String == "FileDeck metadata author", "Edited JPEG must retain author")
        try expect(tiff?[kCGImagePropertyTIFFImageDescription as String] as? String == "Preserve image description", "Edited JPEG must retain description")
        try expect(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2025:01:02 03:04:05", "Edited JPEG must retain capture date")
        try expect((metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue == 1, "Edited JPEG orientation must be normalized")
        try expect((exif?[kCGImagePropertyExifPixelXDimension as String] as? NSNumber)?.intValue == 120 && (exif?[kCGImagePropertyExifPixelYDimension as String] as? NSNumber)?.intValue == 80, "Edited JPEG metadata must use output dimensions")
        try expect(ImageOperations.read(saved).width == 120 && ImageOperations.read(saved).height == 80, "Reopened JPEG must not apply source orientation twice")
        try await content.save()
        try expect(Data(contentsOf: source) == saved && !content.isModified, "Repeated save must preserve encoded bytes and clean state")
        let destination = directory.appendingPathComponent("已编辑同格式副本.jpg")
        try await content.saveAs(to: destination)
        try expect(Data(contentsOf: destination) == saved, "Same-format Save As after editing must reuse saved bytes")
        try await content.export(to: directory.appendingPathComponent("已编辑导出副本.png"), format: .png)
        try await content.save()
        try expect(Data(contentsOf: destination) == saved, "Exporting another format must not invalidate source encoded bytes")
        try await content.close()
    }
    @MainActor static func imageEditsDuringSave(_ source: URL, directory: URL) async throws {
        let content = try await FWImageContent.open(url: source)
        var changed = false
        var editTask: Task<Void, Error>?
        content.onStateChanged = {
            if content.isBusy && !changed {
                changed = true
                editTask = Task { try await mutation(content) { try await content.rotate(clockwise: true) } }
            }
        }
        let destination = directory.appendingPathComponent("快照.png")
        try await content.saveAs(to: destination)
        try await editTask?.value
        try expect(changed && content.isModified && !content.isBusy, "Image edits during save must remain dirty")
        try expect(ImageOperations.read(Data(contentsOf: destination)).width == 120, "Image save wrote captured snapshot")
        try await content.save()
        try expect(ImageOperations.read(Data(contentsOf: destination)).width == 80 && !content.isModified, "Next image save writes newer edit")
        try await unmodifiedJPEGEditsDuringSave(directory: directory)
    }
    @MainActor static func unmodifiedJPEGEditsDuringSave(directory: URL) async throws {
        let source = directory.appendingPathComponent("原样保存期间编辑.jpg")
        let original = try makeMetadataImage(type: .jpeg)
        try original.write(to: source)
        let content = try await FWImageContent.open(url: source)
        var changed = false
        var editTask: Task<Void, Error>?
        content.onStateChanged = {
            if content.isBusy && !changed {
                changed = true
                editTask = Task { try await mutation(content) { try await content.rotate(clockwise: true) } }
            }
        }
        try await content.save()
        try await editTask?.value
        try expect(changed && content.isModified, "Edits during byte-preserving JPEG save must remain dirty")
        try expect(Data(contentsOf: source) == original, "Byte-preserving save must write its original snapshot")
        try await content.save()
        let saved = try Data(contentsOf: source)
        let tiff = try imageProperties(saved)[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        try expect(!content.isModified && ImageOperations.read(saved).width == 120 && ImageOperations.read(saved).height == 80, "Next JPEG save must write the concurrent edit")
        try expect(tiff?[kCGImagePropertyTIFFArtist as String] as? String == "FileDeck metadata author", "Concurrent edit must retain metadata")
        try await content.close()
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

    @MainActor static func csvIncrementalUndoAndBaseline(directory: URL) async throws {
        let path = directory.appendingPathComponent("增量短行.csv")
        let original = "\"a\";\"b\"\r\n短行\r末行;é\n"
        _ = try DocumentIO.save(DocumentIO.create(text: original, encoding: .utf16LittleEndian), to: path)
        let bytes = try Data(contentsOf: path)
        let content = try await FWCSVContent.open(url: path, encoding: .utf16LittleEndian, delimiter: .semicolon)
        try mutation(content) { try content.setCell("新增\n\"值\"", row: 1, column: 1) }
        try mutation(content) { try content.setCell("e\u{301}", row: 2, column: 1) }
        content.undo()
        try expect(content.isModified, "Partial cell undo must preserve other edits")
        content.undo()
        try expect(!content.isModified, "Cell undo must restore raw optional quotes and ragged field counts")
        let copy = directory.appendingPathComponent("原文撤销副本.csv")
        try await content.saveAs(to: copy)
        try expect(Data(contentsOf: copy) == bytes, "Undo to source must preserve exact encoding and raw bytes")
        content.redo()
        try await content.save()
        let saved = try DocumentIO.open(url: copy)
        try expect(saved.text == "a;b\r\n短行;\"新增\n\"\"值\"\"\"\r末行;é\n", "Incremental edit must retain legacy canonical serialization")
        try mutation(content) { try content.setCell("temporary", row: 0, column: 0) }
        try mutation(content) { try content.setCell("a", row: 0, column: 0) }
        try expect(!content.isModified, "Manual return to saved bytes must clear dirty without relying on undo position")
        try mutation(content) { try content.setCell("new", row: 0, column: 0) }
        let foreign = Data("foreign".utf8)
        try foreign.write(to: copy)
        do { try await content.save(); throw failure("Incremental CSV overwrote external version") }
        catch DocumentIOError.externalModification { }
        try expect(content.isModified && Data(contentsOf: copy) == foreign, "Lazy serialization failure must keep draft and external file")
        try await content.save(overwriteExternalChanges: true)
        try expect(!content.isModified && DocumentIO.open(url: copy).text.hasPrefix("new;b"), "Confirmed overwrite must advance lazy baseline")
        try expect(Data(contentsOf: path) == bytes, "Save As and incremental edits must preserve original source")
        try await content.close()

        let quoted = try await FWCSVContent.open(url: path, encoding: .utf16LittleEndian, delimiter: .semicolon)
        try mutation(quoted) { try quoted.setCell("temporary", row: 0, column: 0) }
        try mutation(quoted) { try quoted.setCell("a", row: 0, column: 0) }
        try expect(quoted.isModified, "Equal model signature must not treat canonical output as identical to optionally quoted original")
        try await quoted.close(discardChanges: true)

        // 挂载表格后交错单格差量与结构快照，防止撤销顺序或局部刷新丢失短行/新列。
        let mixed = try await FWCSVContent.open(url: path, encoding: .utf16LittleEndian, delimiter: .semicolon)
        mixed.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        mixed.view.layoutSubtreeIfNeeded()
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(findTable).first
        }
        guard let table = findTable(mixed.view) else { throw failure("Mounted CSV table missing") }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try mutation(mixed) { try mixed.setCell("delta", row: 1, column: 1) }
        try expect(table.selectedRow == 1 && mixed.tableView(table, objectValueFor: table.tableColumns[1], row: 1) as? String == "delta", "Cell refresh must preserve selection and expose edited value")
        try mutation(mixed) { try mixed.appendColumn() }
        try mutation(mixed) { try mixed.setCell("newcol", row: 1, column: 2) }
        mixed.undo(); mixed.undo()
        try expect(table.numberOfColumns == 2 && mixed.isModified, "Structural undo must restore columns without losing earlier delta")
        mixed.undo()
        try expect(!mixed.isModified, "Interleaved undo must restore exact raw baseline")
        mixed.redo(); mixed.redo(); mixed.redo()
        let mixedCopy = directory.appendingPathComponent("交错撤销.csv")
        try await mixed.saveAs(to: mixedCopy)
        try expect(DocumentIO.open(url: mixedCopy).text == "a;b;\r\n短行;delta;newcol\r末行;é;\n" && !mixed.isModified, "Interleaved redo must save all cell and structure changes")
        try await mixed.close()
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

    @MainActor static func imageTransformTransactions(directory: URL) async throws {
        let source = directory.appendingPathComponent("独立后台变换源图.png")
        try makePNG().write(to: source)
        let original = try Data(contentsOf: source)
        let content = try await FWImageContent.open(url: source)
        _ = content.view
        var sawBusy = false, invalidBusyCommands = false
        content.onStateChanged = {
            if content.isBusy {
                sawBusy = true
                invalidBusyCommands = invalidBusyCommands || content.canUndo || content.canRedo || content.availableOperations.contains(.edit)
            }
        }
        try await mutation(content) { try await content.rotate(clockwise: true) }
        try await mutation(content) { try await content.crop(pixelRect: CGRect(x: 1, y: 2, width: 60, height: 100)) }
        try await mutation(content) { try await content.resize(width: 30, height: 50) }
        content.undo(); content.undo(); content.undo()
        try expect(!content.isModified && content.canRedo && !content.canUndo, "Pixel snapshot undo must restore original encoded bytes")
        do { try await content.crop(pixelRect: CGRect(x: -1, y: 0, width: 10, height: 10)); throw failure("Invalid image crop accepted") }
        catch MediaOperationError.invalidParameter { }
        try expect(!content.isModified && content.canRedo && !content.canUndo && !content.isBusy, "Failed worker must retain pixels, baseline and redo")
        content.redo(); content.redo(); content.redo()
        content.onStateChanged = nil
        let target = directory.appendingPathComponent("后台裁剪缩放.png")
        try await content.saveAs(to: target)
        let saved = try Data(contentsOf: target)
        let pixels = try ImageOperations.read(saved)
        try expect(pixels.width == 30 && pixels.height == 50 && !content.isModified && sawBusy && !invalidBusyCommands,
                   "Background image transforms must install correct pixels and disable commands until complete")
        try Data("broken".utf8).write(to: target)
        do { try await content.reload(discardChanges: false); throw failure("Invalid image reload accepted") }
        catch MediaOperationError.invalidImage { }
        try expect(!content.isModified && !content.isBusy && content.canUndo, "Reload decode failure must preserve current frame and history")
        try saved.write(to: target)
        try await content.reload(discardChanges: false)
        try expect(!content.canUndo && !content.canRedo && !content.isModified, "Successful decoded reload resets history and baseline")
        try expect(Data(contentsOf: source) == original, "Async image edits must preserve source")
        try await content.close()
    }

    @MainActor static func pdfBatchHighlights(_ source: URL, directory: URL) async throws {
        let original = try Data(contentsOf: source)
        let content = try await FWPDFContent.open(url: source)
        _ = content.view
        let marks = (0..<60).map { PDFOperations.Highlight(pageIndex: $0 % 2, bounds: CGRect(x: 5, y: 5 + ($0 % 5) * 12, width: 40, height: 8)) }
        try await mutation(content) { try await content.addHighlights(marks) }
        content.undo()
        try expect(!content.isModified && !content.canUndo && content.canRedo, "One batch must be exactly one undoable transaction")
        do { try await content.addHighlights(marks + [.init(pageIndex: 999, bounds: marks[0].bounds)]); throw failure("Invalid final highlight accepted") }
        catch MediaOperationError.invalidParameter { }
        try expect(!content.isModified && content.canRedo && !content.canUndo && !content.isBusy, "Rejected batch must preserve redo and original bytes")
        content.redo()
        let target = directory.appendingPathComponent("批量高亮.pdf")
        try await content.saveAs(to: target)
        let document = try PDFOperations.read(Data(contentsOf: target))
        try expect(document.pageCount == 2 && (0..<2).allSatisfy { document.page(at: $0)?.annotations.count == 30 }, "Batch save must retain every per-line/page highlight")
        try expect((document.page(at: 0)?.annotations ?? []).allSatisfy { !$0.isReadOnly && $0.quadrilateralPoints?.count == 4 }, "Display read-only flags must not leak to saved annotations")
        try expect(Data(contentsOf: source) == original && !content.isModified, "Batch Save As preserves source and advances baseline")
        try await content.close()

        let textPath = directory.appendingPathComponent("真实多行选区.pdf")
        let textData = try makeTextPDF()
        try textData.write(to: textPath)
        let textContent = try await FWPDFContent.open(url: textPath)
        textContent.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        textContent.view.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        guard let pdfView = views(textContent.view).compactMap({ $0 as? PDFView }).first,
              let selection = pdfView.document?.selectionForEntireDocument,
              let button = views(textContent.view).compactMap({ $0 as? NSButton }).first(where: { $0.title == "高亮选中文字" }) else {
            throw failure("Selectable PDF fixture or highlight toolbar missing")
        }
        let lines = selection.selectionsByLine().count
        try expect(lines >= 4, "Fixture must contain real selectable text on multiple lines")
        pdfView.setCurrentSelection(selection, animate: false)
        textContent.undoManager?.groupsByEvent = false
        textContent.undoManager?.beginUndoGrouping()
        button.performClick(nil)
        for _ in 0..<500 {
            if textContent.isModified && !textContent.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        textContent.undoManager?.endUndoGrouping()
        try expect(textContent.isModified && !textContent.isBusy, "Real selection toolbar must complete background highlight")
        let textCopy = directory.appendingPathComponent("真实选区高亮结果.pdf")
        try await textContent.export(to: textCopy, format: .pdf)
        let marked = try PDFOperations.read(Data(contentsOf: textCopy))
        try expect((0..<marked.pageCount).reduce(0) { $0 + (marked.page(at: $1)?.annotations.count ?? 0) } == lines,
                   "Toolbar must preserve one highlight per selected text line")
        textContent.undo()
        try expect(!textContent.isModified && !textContent.canUndo, "Toolbar multi-line batch must undo to exact baseline in one action")
        try expect(Data(contentsOf: textPath) == textData, "Toolbar batch must leave source bytes intact")
        try await textContent.close()
    }

    @MainActor static func mediaHistoryAndCancellation(_ imagePath: URL, directory: URL) async throws {
        let history = FWMediaHistory(maximumBytes: 10)
        history.manager.groupsByEvent = false
        var value = 0
        func set(_ new: Int, bytes: Int) {
            let before = value
            value = new
            let grouping = !history.manager.isUndoing && !history.manager.isRedoing
            if grouping { history.manager.beginUndoGrouping() }
            history.register(bytes: bytes, name: "测试快照") { set(before, bytes: bytes) }
            if grouping { history.manager.endUndoGrouping() }
        }
        set(1, bytes: 4); set(2, bytes: 4); set(3, bytes: 4)
        try expect(history.retainedBytes == 8, "History must evict oldest entries before exceeding byte budget")
        history.undo(); history.undo()
        try expect(value == 1 && !history.canUndo && history.canRedo && history.retainedBytes <= 10, "Eviction must retain the newest coherent undo/redo path")
        history.redo(); history.redo()
        set(4, bytes: 11)
        try expect(value == 4 && !history.canUndo && !history.canRedo && history.retainedBytes == 0, "Oversized history entry must not allow undo jumping across the new edit")
        history.removeAll()

        let image = try await FWImageContent.open(url: imagePath, historyMaximumBytes: 4096)
        try await mutation(image) { try await image.crop(pixelRect: CGRect(x: 0, y: 0, width: 8, height: 8)) }
        try await mutation(image) { try await image.resize(width: 8, height: 8) }
        try expect(!image.canUndo, "Cropped snapshots must budget shared original backing, not just cropped dimensions")
        try await mutation(image) { try await image.rotate(clockwise: true) }
        try expect(image.canUndo, "A new small owned bitmap should fit the history budget")
        try await mutation(image) { try await image.resize(width: 100, height: 100) }
        image.undo()
        try expect(!image.canRedo && !image.canUndo, "Undo from a large frame must drop an oversized redo snapshot without jumping across edits")
        try await image.close(discardChanges: true)

        let state = try FWBinaryState(data: Data([1, 2, 3]))
        let release = DispatchSemaphore(value: 0)
        let task = Task { try await state.transformWithResult { data in
            guard !Thread.isMainThread else { throw failure("Transform ran on main thread") }
            release.wait()
            return (data + Data([4]), true)
        } }
        defer { release.signal() }
        while !state.isBusy { await Task.yield() }
        do { try state.replace(Data()); throw failure("Edit during transform accepted") } catch DocumentSessionError.busy { }
        do { try state.close(discardChanges: true); throw failure("Close during transform accepted") } catch DocumentSessionError.busy { }
        task.cancel(); release.signal()
        do { _ = try await task.value; throw failure("Canceled transform committed") } catch is CancellationError { }
        try expect(state.data == Data([1, 2, 3]) && !state.isBusy, "Canceled worker must leave buffer and busy state intact")

        // 固定保存工作器的等待窗口，确定性覆盖“保存未完成时后台变换已提交”，不依赖编码速度。
        let path = directory.appendingPathComponent("固定保存竞态.bin")
        let baseline = Data([1, 2, 3]), changed = Data([4, 5, 6])
        try baseline.write(to: path)
        let opened = try SafeFileIO.open(url: path)
        let concurrent = try FWBinaryState(data: opened.data, fileState: opened.state)
        let saveGate = DispatchSemaphore(value: 0)
        let saving = Task { try await concurrent.save(to: nil, overwrite: false) { bytes in saveGate.wait(); return bytes } }
        defer { saveGate.signal() }
        while !concurrent.isBusy { await Task.yield() }
        let _: Bool = try await concurrent.transformWithResult(allowDuringSave: true) { _ in (changed, true) }
        try expect(concurrent.isBusy && concurrent.data == changed && concurrent.isModified, "Transform must commit newer draft while save retains its snapshot")
        do { try await concurrent.transform { _ in baseline }; throw failure("Default transform ran during saving") } catch DocumentSessionError.busy { }
        saveGate.signal(); _ = try await saving.value
        try expect(Data(contentsOf: path) == baseline && concurrent.data == changed && concurrent.isModified && !concurrent.isBusy,
                   "Finishing older save must not clear concurrent transform dirty state")
        try await concurrent.save(to: nil, overwrite: false)
        try expect(Data(contentsOf: path) == changed && !concurrent.isModified, "Next save must persist transformed buffer")
    }
    static func makePNG() throws -> Data {
        let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        return try ImageOperations.export(context.makeImage()!, format: .png)
    }
    @MainActor static func makeTextPDF() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw failure("Cannot create selectable PDF fixture")
        }
        for page in 0..<2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for line in 0..<3 {
                ("Page \(page) selected text line \(line)" as NSString).draw(at: CGPoint(x: 30, y: 50 + line * 40),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
    static func makeMetadataImage(type: UTType) throws -> Data {
        let image = try ImageOperations.read(makePNG())
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "FileDeck metadata author", kCGImagePropertyTIFFImageDescription: "Preserve image description"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:01:02 03:04:05", kCGImagePropertyExifPixelXDimension: 120, kCGImagePropertyExifPixelYDimension: 80]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure("Metadata fixture encoding failed") }
        return data as Data
    }
    static func imageProperties(_ data: Data) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw failure("Image properties are missing")
        }
        return properties
    }
    static func failure(_ text: String) -> Error { NSError(domain: "NativeMediaRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
