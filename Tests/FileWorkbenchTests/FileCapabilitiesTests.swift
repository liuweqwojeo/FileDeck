import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import FileWorkbench

final class FileCapabilitiesTests: XCTestCase {
    func testRoutesSupportedExtensionsAndCommonSourceNames() {
        let registry = FileCapabilityRegistry()
        let cases: [(String, WorkbenchFileKind, FileEditorBackend)] = [
            ("中文报告.DOCX", .word, .onlyOffice), ("预算.xlsx", .spreadsheet, .onlyOffice),
            ("演示.pptx", .presentation, .onlyOffice), ("notes.MD", .markdown, .markdown),
            ("notes.markdown", .markdown, .markdown), ("notes.mdown", .markdown, .markdown),
            ("文本.txt", .text, .codeMirror), ("errors.log", .text, .codeMirror),
            ("config.json", .json, .codeMirror), ("config.YML", .yaml, .codeMirror),
            ("config.yaml", .yaml, .codeMirror), ("数据.csv", .csv, .csv),
            ("document.pdf", .pdf, .pdfKit), ("image.PNG", .png, .imageIO),
            ("image.jpg", .jpeg, .imageIO), ("image.jpeg", .jpeg, .imageIO),
            ("photo.HEIC", .heic, .imageIO), ("photo.heif", .heic, .imageIO),
            ("main.swift", .code, .codeMirror), ("view.tsx", .code, .codeMirror),
            ("main.py", .code, .codeMirror), ("script.sh", .code, .codeMirror),
            ("Makefile", .code, .codeMirror), ("Dockerfile", .code, .codeMirror),
            (".env.local", .code, .codeMirror), (".gitignore", .code, .codeMirror),
            ("README", .text, .codeMirror), ("data.jsonl", .text, .codeMirror),
            ("data.tsv", .text, .codeMirror)
        ]
        for (name, kind, editor) in cases {
            let result = registry.capabilities(for: url(name))
            XCTAssertEqual(result.kind, kind, name)
            XCTAssertEqual(result.suggestedEditor, editor, name)
        }
    }

    func testDefaultsOnlyExposeExistingReadOnlyPreviewBackends() {
        let registry = FileCapabilityRegistry()
        for kind in WorkbenchFileKind.allCases where kind != .directory {
            let result = registry.capabilities(for: kind)
            XCTAssertEqual(result.operations, [.open], kind.rawValue)
            XCTAssertTrue(result.activeBackend == .textPreview || result.activeBackend == .quickLook)
            XCTAssertTrue(result.saveAsFormats.isEmpty)
            XCTAssertTrue(result.exportFormats.isEmpty)
            XCTAssertEqual(result.isSystemPreviewAttempt, result.activeBackend == .quickLook)
        }
        XCTAssertEqual(registry.capabilities(for: .markdown).activeBackend, .textPreview)
        XCTAssertEqual(registry.capabilities(for: .word).activeBackend, .quickLook)
    }

    func testOnlyExplicitlyRegisteredEditorOperationsBecomeAvailable() {
        var registry = FileCapabilityRegistry()
        registry.register(.codeMirror, operations: [.open, .edit, .save])
        let text = registry.capabilities(for: .json)
        XCTAssertEqual(text.activeBackend, .codeMirror)
        XCTAssertEqual(text.operations, [.open, .edit, .save])
        XCTAssertTrue(text.saveAsFormats.isEmpty)
        // CodeMirror 的基础编辑接入不能替代 Markdown 预览、CSV 表格或 Office 会话的接入。
        XCTAssertEqual(registry.capabilities(for: .markdown).activeBackend, .textPreview)
        XCTAssertEqual(registry.capabilities(for: .csv).activeBackend, .textPreview)
        XCTAssertEqual(registry.capabilities(for: .word).activeBackend, .quickLook)
        registry.register(.codeMirror, operations: Set(FileOperation.allCases), exportFormats: [.pdf])
        XCTAssertEqual(registry.capabilities(for: .text).operations, [.create, .open, .edit, .save, .saveAs])
        XCTAssertEqual(registry.capabilities(for: .text).saveAsFormats, [.text])
        XCTAssertTrue(registry.capabilities(for: .text).exportFormats.isEmpty)
    }

    func testUnavailableUnregisteredAndIncompleteBackendsDoNotEnableOffice() {
        var registry = FileCapabilityRegistry(includeBuiltInPreviews: false)
        XCTAssertNil(registry.capabilities(for: .word).activeBackend)
        registry.register(.onlyOffice, operations: Set(FileOperation.allCases), exportFormats: [.pdf], isAvailable: false)
        XCTAssertTrue(registry.capabilities(for: .word).operations.isEmpty)
        registry.register(.onlyOffice, operations: [.create, .save])
        XCTAssertTrue(registry.capabilities(for: .word).operations.isEmpty)
        registry.register(.onlyOffice, operations: Set(FileOperation.allCases), exportFormats: [.pdf])
        XCTAssertEqual(registry.capabilities(for: .word).operations, Set(FileOperation.allCases))
        XCTAssertEqual(registry.capabilities(for: .presentation).exportFormats, [.pdf])
        XCTAssertFalse(registry.capabilities(for: .spreadsheet).operations.contains(.export))
        registry.unregister(.onlyOffice)
        XCTAssertNil(registry.capabilities(for: .word).activeBackend)
        XCTAssertEqual(registry.capabilities(for: .word).suggestedEditor, .onlyOffice)
    }

    func testReadOnlyProvidersCannotAdvertiseSaveOrExport() {
        var registry = FileCapabilityRegistry()
        for backend in [FileEditorBackend.quickLook, .textPreview] {
            registry.register(backend, operations: Set(FileOperation.allCases), exportFormats: Set(WorkbenchFileKind.allCases))
        }
        for kind in WorkbenchFileKind.allCases where kind != .directory {
            let result = registry.capabilities(for: kind)
            XCTAssertEqual(result.operations, [.open])
            XCTAssertTrue(result.saveAsFormats.isEmpty)
            XCTAssertTrue(result.exportFormats.isEmpty)
        }
    }

    func testMediaCapabilitiesRespectImplementedOutputFormats() {
        var registry = FileCapabilityRegistry()
        let allFormats = Set(WorkbenchFileKind.allCases)
        registry.register(.imageIO, operations: Set(FileOperation.allCases), exportFormats: allFormats)
        let heic = registry.capabilities(for: .heic)
        XCTAssertEqual(heic.operations, [.open, .edit, .saveAs, .export])
        XCTAssertEqual(heic.saveAsFormats, [.png, .jpeg])
        XCTAssertEqual(heic.exportFormats, [.png, .jpeg, .pdf])
        for kind in [WorkbenchFileKind.png, .jpeg] {
            XCTAssertTrue(registry.capabilities(for: kind).operations.contains(.save))
            XCTAssertFalse(registry.capabilities(for: kind).operations.contains(.create))
        }
        registry.register(.pdfKit, operations: Set(FileOperation.allCases), exportFormats: allFormats)
        let pdf = registry.capabilities(for: .pdf)
        XCTAssertEqual(pdf.operations, [.open, .edit, .save, .saveAs, .export])
        XCTAssertEqual(pdf.saveAsFormats, [.pdf])
        XCTAssertEqual(pdf.exportFormats, [.pdf])
        registry.register(.imageIO, operations: [.open, .export], exportFormats: [.heic])
        XCTAssertEqual(registry.capabilities(for: .png).operations, [.open])
    }

    func testTypeFallbackOnlyPromotesPreciselySupportedFormats() {
        let registry = FileCapabilityRegistry()
        let cases: [(UTType, WorkbenchFileKind)] = [
            (.pdf, .pdf), (.png, .png), (.jpeg, .jpeg), (.heic, .heic), (.heif, .heic),
            (.json, .json), (.commaSeparatedText, .csv), (.plainText, .text), (.sourceCode, .code),
            (.image, .other), (.tiff, .other), (.spreadsheet, .other)
        ]
        for (type, kind) in cases {
            XCTAssertEqual(registry.capabilities(for: url("unknown.data"), contentType: type).kind, kind, type.identifier)
        }
        let identifiers: [(String, WorkbenchFileKind)] = [
            ("org.openxmlformats.wordprocessingml.document", .word),
            ("org.openxmlformats.spreadsheetml.sheet", .spreadsheet),
            ("org.openxmlformats.presentationml.presentation", .presentation),
            ("net.daringfireball.markdown", .markdown), ("public.yaml", .yaml)
        ]
        for (identifier, kind) in identifiers {
            let type = UTType(importedAs: identifier)
            XCTAssertEqual(registry.capabilities(for: url("unknown.data"), contentType: type).kind, kind)
        }
    }

    func testKnownExtensionsPreserveSpecificAndUnsupportedFormatBoundaries() {
        let registry = FileCapabilityRegistry()
        XCTAssertEqual(registry.capabilities(for: url("file.DOCX"), contentType: .zip).kind, .word)
        XCTAssertEqual(registry.capabilities(for: url("file.json"), contentType: .plainText).kind, .json)
        XCTAssertEqual(registry.capabilities(for: url(".env.png")).kind, .png)
        for ext in ["doc", "xls", "ppt", "docm", "xlsm", "pptm", "rtf", "rtfd", "svg", "pages", "numbers", "key"] {
            let result = registry.capabilities(for: url("sample.\(ext)"), contentType: .plainText)
            XCTAssertEqual(result.kind, .other, ext)
            XCTAssertEqual(result.activeBackend, .quickLook, ext)
            XCTAssertTrue(result.isSystemPreviewAttempt)
        }
    }

    func testDirectoriesPackagesAndRemoteURLsCannotGainEditingCapabilities() throws {
        var registry = FileCapabilityRegistry()
        registry.register(.onlyOffice, operations: Set(FileOperation.allCases), exportFormats: [.pdf])
        for isLink in [false, true] {
            let entry = FileEntry(url: url("folder.docx"), name: "folder.docx", isDirectory: true,
                                  isPackage: false, isSymbolicLink: isLink, size: nil, modifiedAt: nil, typeIdentifier: nil)
            XCTAssertEqual(registry.capabilities(for: entry).kind, .directory)
            XCTAssertTrue(registry.capabilities(for: entry).operations.isEmpty)
        }
        let package = FileEntry(url: url("package.docx"), name: "package.docx", isDirectory: true,
                                isPackage: true, isSymbolicLink: false, size: nil, modifiedAt: nil, typeIdentifier: nil)
        XCTAssertEqual(registry.capabilities(for: package).activeBackend, .quickLook)
        XCTAssertEqual(registry.capabilities(for: package).operations, [.open])
        XCTAssertEqual(registry.capabilities(for: url("folder.docx"), contentType: .folder).kind, .directory)
        XCTAssertEqual(registry.capabilities(for: url("package.docx"), contentType: .package).kind, .other)
        let remote = try XCTUnwrap(URL(string: "https://example.com/file.docx"))
        XCTAssertNil(registry.capabilities(for: remote).activeBackend)
        XCTAssertTrue(registry.capabilities(for: remote).operations.isEmpty)
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/文件 能力测试").appendingPathComponent(name)
    }
}
