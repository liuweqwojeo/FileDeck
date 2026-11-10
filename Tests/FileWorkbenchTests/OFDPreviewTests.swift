import AppKit
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import FileWorkbench

/// 使用系统 ZIP 工具生成独立票据，再调用打包内核的真实 x2t，避免以 mock 替代格式兼容性。
@MainActor
final class OFDPreviewTests: XCTestCase {
    func testOFDRoutesToDedicatedPreviewAndStaysReadOnly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("电子行程单.OFD")
        try Data([0x50, 0x4b, 3, 4]).write(to: url)
        guard case .success(.ofd) = await TextPreviewLoader.prepare(url: url) else {
            return XCTFail("OFD 应进入专用预览，不依赖系统 Quick Look。")
        }
        var registry = FileCapabilityRegistry()
        registry.register(.codeMirror, operations: Set(FileOperation.allCases))
        let capabilities = registry.capabilities(for: url, contentType: .plainText)
        XCTAssertEqual(capabilities.kind, .other)
        XCTAssertEqual(capabilities.operations, [.open])
        let entry = FileEntry(url: url, name: url.lastPathComponent, isDirectory: false, isPackage: false,
                              isSymbolicLink: false, size: 4, modifiedAt: nil, typeIdentifier: nil)
        XCTAssertTrue(FileTypeFilter.documents.includes(entry))
    }

    func testMissingComponentShowsFailureWithoutStartingProcess() {
        let preview = OFDPreviewController(converterURL: nil)
        preview.load(url: URL(fileURLWithPath: "/tmp/电子行程单.ofd"))
        XCTAssertTrue(preview.failureMessage?.contains("完整 FileDeck") == true)
        XCTAssertFalse(preview.isLoading)
        XCTAssertNil(preview.process)
        XCTAssertNil(preview.pdfView.document)
        preview.stop()
    }

    func testRealConversionPreservesChinesePagesAndSourceBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try itinerary(in: directory)
        let original = try Data(contentsOf: url)
        let preview = OFDPreviewController(converterURL: try converter())
        defer { preview.stop() }
        preview.view.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        preview.load(url: url)
        let workingDirectory = try XCTUnwrap(preview.process?.currentDirectoryURL)
        try await settle(preview)
        XCTAssertNil(preview.failureMessage)
        let document = try XCTUnwrap(preview.pdfView.document)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("航空运输电子客票行程单") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("第二页") == true)
        XCTAssertEqual(document.page(at: 0)!.bounds(for: .mediaBox).width, 210 * 72 / 25.4, accuracy: 1)
        XCTAssertTrue(preview.pdfView.autoScales)
        // 只验证可提取文字会漏掉 Alpha 未初始化造成的“文字全透明”；同时检查真实栅格结果。
        let thumbnail = document.page(at: 0)!.thumbnail(of: NSSize(width: 420, height: 280), for: .mediaBox)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(thumbnail.tiffRepresentation)))
        var darkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent < 0.5, color.greenComponent < 0.5, color.blueComponent < 0.5 {
                    darkPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(darkPixels, 100, "默认不透明度的中文文字必须实际可见。")
        preview.view.layoutSubtreeIfNeeded()
        let fittedScale = preview.pdfView.scaleFactor
        try button("放大", in: preview).performClick(nil)
        XCTAssertGreaterThan(preview.pdfView.scaleFactor, fittedScale)
        let enlargedScale = preview.pdfView.scaleFactor
        try button("缩小", in: preview).performClick(nil)
        XCTAssertLessThan(preview.pdfView.scaleFactor, enlargedScale)
        try button("适合窗口", in: preview).performClick(nil)
        XCTAssertTrue(preview.pdfView.autoScales)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["package", url.lastPathComponent].sorted())
    }

    func testDamagedFileCanRetryAfterReplacingContents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("损坏.ofd")
        try Data("not an OFD".utf8).write(to: url)
        let preview = OFDPreviewController(converterURL: try converter())
        defer { preview.stop() }
        preview.load(url: url)
        let workingDirectory = try XCTUnwrap(preview.process?.currentDirectoryURL)
        try await settle(preview)
        XCTAssertNotNil(preview.failureMessage)
        XCTAssertNil(preview.pdfView.document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.path))
        let valid = try itinerary(in: directory)
        try Data(contentsOf: valid).write(to: url)
        try button("重试", in: preview).performClick(nil)
        try await settle(preview)
        XCTAssertNil(preview.failureMessage)
        XCTAssertEqual(preview.pdfView.document?.pageCount, 2)
    }

    func testStopAndSwitchReleaseConversionWithoutPublishingOldDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try itinerary(in: directory)
        let preview = OFDPreviewController(converterURL: try converter())
        defer { preview.stop() }
        preview.load(url: url)
        let previous = try XCTUnwrap(preview.process)
        let workingDirectory = try XCTUnwrap(previous.currentDirectoryURL)
        preview.stop()
        XCTAssertNil(preview.currentURL)
        XCTAssertNil(preview.pdfView.document)
        XCTAssertFalse(preview.isLoading)
        let damaged = directory.appendingPathComponent("下一份.ofd")
        try Data("broken".utf8).write(to: damaged)
        preview.load(url: damaged)
        try await settle(preview)
        for _ in 0..<200 {
            if !previous.isRunning && !FileManager.default.fileExists(atPath: workingDirectory.path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(previous.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.path))
        XCTAssertEqual(preview.currentURL, damaged)
        XCTAssertNotNil(preview.failureMessage)
        XCTAssertNil(preview.pdfView.document)
    }

    private func converter() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("build/FileDeck.app/Contents/Resources/converter/x2t")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("真实 OFD 转换验收需要先按仓库流程构建完整 FileDeck 应用。")
        }
        return url
    }

    private func button(_ title: String, in preview: OFDPreviewController) throws -> NSButton {
        try XCTUnwrap(preview.view.subviews.compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func settle(_ preview: OFDPreviewController) async throws {
        for _ in 0..<400 {
            if !preview.isLoading { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("OFD 转换未在测试预算内完成。")
        throw CancellationError()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OFD测试 & " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func itinerary(in directory: URL) throws -> URL {
        let package = directory.appendingPathComponent("package")
        let files = [
            "OFD.xml": "<ofd:OFD xmlns:ofd=\"http://www.ofdspec.org/2016\" Version=\"1.0\" DocType=\"OFD\"><ofd:DocBody><ofd:DocInfo><ofd:DocID>FileDeck-Test</ofd:DocID></ofd:DocInfo><ofd:DocRoot>Doc_0/Document.xml</ofd:DocRoot></ofd:DocBody></ofd:OFD>",
            "Doc_0/Document.xml": "<ofd:Document xmlns:ofd=\"http://www.ofdspec.org/2016\"><ofd:CommonData><ofd:MaxUnitID>100</ofd:MaxUnitID><ofd:PageArea><ofd:PhysicalBox>0 0 210 140</ofd:PhysicalBox></ofd:PageArea><ofd:PublicRes>PublicRes.xml</ofd:PublicRes></ofd:CommonData><ofd:Pages><ofd:Page ID=\"1\" BaseLoc=\"Pages/Page_0/Content.xml\"/><ofd:Page ID=\"2\" BaseLoc=\"Pages/Page_1/Content.xml\"/></ofd:Pages></ofd:Document>",
            "Doc_0/PublicRes.xml": "<ofd:Res xmlns:ofd=\"http://www.ofdspec.org/2016\" BaseLoc=\"Res\"><ofd:Fonts><ofd:Font ID=\"10\" FontName=\"楷体\" FamilyName=\"楷体\"/></ofd:Fonts></ofd:Res>"
        ]
        for (name, xml) in files {
            let path = package.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: path)
        }
        for (index, title) in ["航空运输电子客票行程单", "第二页 航班信息"].enumerated() {
            let xml = "<ofd:Page xmlns:ofd=\"http://www.ofdspec.org/2016\"><ofd:Content><ofd:Layer ID=\"20\"><ofd:TextObject ID=\"30\" Boundary=\"15 15 180 20\" Font=\"10\" Size=\"6\"><ofd:TextCode X=\"0\" Y=\"8\" DeltaX=\"g 20 6\">\(title)</ofd:TextCode></ofd:TextObject></ofd:Layer></ofd:Content></ofd:Page>"
            let path = package.appendingPathComponent("Doc_0/Pages/Page_\(index)/Content.xml")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: path)
        }
        let output = directory.appendingPathComponent("电子 行程单 & <测试>.OFD")
        let archive = Process()
        archive.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        archive.arguments = ["-qr", output.path, "."]
        archive.currentDirectoryURL = package
        try archive.run()
        archive.waitUntilExit()
        XCTAssertEqual(archive.terminationStatus, 0)
        return output
    }
}
