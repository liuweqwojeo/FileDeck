import AppKit
import XCTest
@testable import FileWorkbench

/// 新建需写出可解码的格式，并且不能覆盖文件或沿失效目录身份写入。
final class NewFileTemplateTests: XCTestCase {
    func testSelectedTypeAppendsMissingExtensionWithoutOverwritingOrChangingCustomNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try FileSystem.identity(at: root)
        let file = try NewFileCreator.create(template: .rust, name: "  main  ", directory: root, expectedDirectoryIdentity: identity)
        XCTAssertEqual(file.lastPathComponent, "main.rs")
        XCTAssertThrowsError(try NewFileCreator.create(template: .rust, name: "main", directory: root, expectedDirectoryIdentity: identity))
        XCTAssertThrowsError(try NewFileCreator.create(template: .rust, name: "wrong.py", directory: root, expectedDirectoryIdentity: identity))
        let custom = try NewFileCreator.create(template: .custom, name: ".env", directory: root, expectedDirectoryIdentity: identity)
        XCTAssertEqual(custom.lastPathComponent, ".env")
        let folder = try NewFileCreator.create(template: .folder, name: "project", directory: root, expectedDirectoryIdentity: identity)
        XCTAssertEqual(folder.lastPathComponent, "project")
    }
    func testCommonProgrammingTemplatesCreateEditableCodeFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try FileSystem.identity(at: root)
        var registry = FileCapabilityRegistry()
        registry.register(.codeMirror, operations: [.open, .edit, .save, .saveAs])
        let cases: [(NewFileTemplate, String)] = [
            (.jsx, "jsx"), (.tsx, "tsx"), (.vue, "vue"), (.svelte, "svelte"),
            (.scss, "scss"), (.less, "less"), (.sass, "sass"),
            (.c, "c"), (.cpp, "cpp"), (.cHeader, "h"), (.cppHeader, "hpp"), (.csharp, "cs"),
            (.go, "go"), (.rust, "rs"), (.kotlin, "kt"), (.kotlinScript, "kts"),
            (.objectiveC, "m"), (.objectiveCpp, "mm"), (.php, "php"), (.ruby, "rb"),
            (.dart, "dart"), (.lua, "lua"), (.r, "r"), (.perl, "pl"), (.scala, "scala"),
            (.groovy, "groovy"), (.julia, "jl"), (.powershell, "ps1"), (.fsharp, "fs"),
            (.visualBasic, "vb"), (.clojure, "clj"), (.erlang, "erl")
        ]
        for (template, ext) in cases {
            let file = try NewFileCreator.create(template: template, name: template.defaultName,
                                                 directory: root, expectedDirectoryIdentity: identity)
            XCTAssertEqual(file.pathExtension, ext, template.title)
            XCTAssertTrue(template.isAvailable(resourceDirectory: nil), template.title)
            XCTAssertTrue(TextPreviewLoader.isTextFile(file), template.title)
            let capabilities = registry.capabilities(for: file)
            XCTAssertEqual(capabilities.kind, .code, template.title)
            XCTAssertEqual(capabilities.activeBackend, .codeMirror, template.title)
            XCTAssertTrue(capabilities.operations.isSuperset(of: [.open, .edit, .save]), template.title)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "", template.title)
        }
    }

    func testLanguageExtensionVariantsStayEditableAndRejectDifferentSyntax() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try FileSystem.identity(at: root)
        let cases: [(NewFileTemplate, [String])] = [
            (.javascript, ["mjs", "cjs"]), (.typescript, ["mts", "cts"]),
            (.cpp, ["cc", "cxx", "c++"]), (.cppHeader, ["hh", "hxx", "h++"]),
            (.python, ["pyw", "pyi"]), (.php, ["phtml"]), (.shell, ["bash", "zsh"]),
            (.perl, ["pm"]), (.scala, ["sbt"]), (.groovy, ["gradle"]),
            (.powershell, ["psm1", "psd1"]), (.fsharp, ["fsx", "fsi"]), (.clojure, ["cljc"])
        ]
        for (template, extensions) in cases {
            for ext in extensions {
                let file = try NewFileCreator.create(template: template, name: "sample.\(ext.uppercased())",
                                                     directory: root, expectedDirectoryIdentity: identity)
                XCTAssertTrue(TextPreviewLoader.isTextFile(file), file.lastPathComponent)
                XCTAssertEqual(FileCapabilityRegistry().capabilities(for: file).kind, .code, file.lastPathComponent)
                if template == .shell {
                    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "#!/bin/\(ext)\n")
                }
            }
        }
        for (template, name) in [(NewFileTemplate.javascript, "wrong.jsx"), (.typescript, "wrong.tsx"),
                                 (.c, "wrong.h"), (.kotlin, "wrong.kts")] {
            XCTAssertThrowsError(try NewFileCreator.create(template: template, name: name,
                                                          directory: root, expectedDirectoryIdentity: identity))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    func testCreatesEveryLocalTemplateAndDecodesStructuredFormats() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try FileSystem.identity(at: root)
        for template in NewFileTemplate.allCases where ![.word, .spreadsheet, .presentation, .custom].contains(template) {
            let url = try NewFileCreator.create(template: template, name: template.defaultName, directory: root,
                                                expectedDirectoryIdentity: identity, resourceDirectory: nil)
            if template == .folder {
                XCTAssertTrue(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
                continue
            }
            let data = try Data(contentsOf: url)
            switch template {
            case .pdf:
                let document = try PDFOperations.read(data)
                XCTAssertEqual(document.pageCount, 1)
                XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).width, 595)
            case .png, .jpeg:
                let image = try ImageOperations.read(data)
                XCTAssertEqual(image.width, 800)
                XCTAssertEqual(image.height, 600)
            case .json:
                XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            case .xml, .svg:
                XCTAssertTrue(XMLParser(data: data).parse())
            case .rtf:
                XCTAssertNotNil(NSAttributedString(rtf: data, documentAttributes: nil))
            default:
                XCTAssertNotNil(String(data: data, encoding: .utf8))
            }
        }
    }

    func testDuplicateFilesFoldersAndDanglingLinksAreNeverOverwritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try FileSystem.identity(at: root)
        let existing = root.appendingPathComponent("existing.txt")
        try Data("保留内容".utf8).write(to: existing)
        XCTAssertThrowsError(try NewFileCreator.create(template: .text, name: "existing.txt", directory: root,
                                                        expectedDirectoryIdentity: identity))
        XCTAssertEqual(try String(contentsOf: existing), "保留内容")
        let folder = try NewFileCreator.create(template: .folder, name: "现有目录", directory: root,
                                               expectedDirectoryIdentity: identity)
        XCTAssertThrowsError(try NewFileCreator.create(template: .folder, name: "现有目录", directory: root,
                                                        expectedDirectoryIdentity: identity))
        XCTAssertTrue(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let link = root.appendingPathComponent("link.txt")
        let missing = root.appendingPathComponent("missing.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        XCTAssertThrowsError(try NewFileCreator.create(template: .text, name: "link.txt", directory: root,
                                                        expectedDirectoryIdentity: identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), missing.path)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".file-workbench-") })
    }

    func testReplacedAndSymbolicLinkDirectoriesAreRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let originalIdentity = try FileSystem.identity(at: target)
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: target, to: moved)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try NewFileCreator.create(template: .text, name: "new.txt", directory: target,
                                                        expectedDirectoryIdentity: originalIdentity))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
        XCTAssertThrowsError(try NewFileCreator.create(template: .folder, name: "new", directory: target,
                                                        expectedDirectoryIdentity: FileSystem.identity(at: target)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testInvalidNamesAndMismatchedExtensionsDoNotCreateAnything() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try FileSystem.identity(at: root)
        for name in ["", " ", ".", "..", "../escape.txt", "a:b", "null\0.txt"] {
            XCTAssertThrowsError(try NewFileCreator.create(template: .custom, name: name, directory: root,
                                                            expectedDirectoryIdentity: identity))
        }
        XCTAssertThrowsError(try NewFileCreator.create(template: .json, name: "bad.pdf", directory: root,
                                                        expectedDirectoryIdentity: identity))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCustomExtensionsUseKnownTemplatesAndRejectFalseBinaryFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try FileSystem.identity(at: root)
        let config = try NewFileCreator.create(template: .custom, name: ".env", directory: root,
                                               expectedDirectoryIdentity: identity)
        XCTAssertEqual(try Data(contentsOf: config), Data())
        let json = try NewFileCreator.create(template: .custom, name: "配置.JSON", directory: root,
                                             expectedDirectoryIdentity: identity)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        let pdf = try NewFileCreator.create(template: .custom, name: "空白.pdf", directory: root,
                                            expectedDirectoryIdentity: identity)
        XCTAssertEqual(try PDFOperations.read(Data(contentsOf: pdf)).pageCount, 1)
        for ext in ["doc", "xls", "ppt", "mp4", "zip", "heic"] {
            XCTAssertThrowsError(try NewFileCreator.create(template: .custom, name: "不能伪造.\(ext)", directory: root,
                                                            expectedDirectoryIdentity: identity))
        }
    }

    func testMissingAndInvalidOfficeTemplatesFailWithoutCreatingDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try FileSystem.identity(at: root)
        for template in [NewFileTemplate.word, .spreadsheet, .presentation] {
            XCTAssertFalse(template.isAvailable(resourceDirectory: nil))
            XCTAssertThrowsError(try NewFileCreator.create(template: template, name: template.defaultName, directory: root,
                                                            expectedDirectoryIdentity: identity, resourceDirectory: nil))
        }
        let resources = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }
        let templateFolder = resources.appendingPathComponent("converter/empty/en-US")
        try FileManager.default.createDirectory(at: templateFolder, withIntermediateDirectories: true)
        try Data().write(to: templateFolder.appendingPathComponent("new.docx"))
        XCTAssertThrowsError(try NewFileCreator.create(template: .word, name: "invalid.docx", directory: root,
                                                        expectedDirectoryIdentity: identity, resourceDirectory: resources))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("new-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
