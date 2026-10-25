import AppKit
import PDFKit
import XCTest
@testable import FileWorkbench

/// 验证媒体数据经过共享保存路径后仍可读取，并且外部修改不会被后续编辑覆盖。
final class SafeFileIOTests: XCTestCase {
    func testImageAndPDFSaveRoundTripAndConflictProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let png = try ImageOperations.export(XCTUnwrap(context.makeImage()), format: .png)
        let imageURL = directory.appendingPathComponent("中文 图片.png")
        _ = try SafeFileIO.save(png, previous: nil, to: imageURL)
        let imageRead = try SafeFileIO.open(url: imageURL)
        XCTAssertEqual(try ImageOperations.read(imageRead.data).width, 12)

        let pdfURL = directory.appendingPathComponent("图片文档.pdf")
        let pdf = try PDFOperations.imagesToPDF([imageRead.data])
        let initial = try SafeFileIO.save(pdf, previous: nil, to: pdfURL)
        let rotated = try PDFOperations.rotate(pdf, pageIndexes: [0])
        let saved = try SafeFileIO.save(rotated, previous: initial)
        XCTAssertEqual(try PDFOperations.read(SafeFileIO.open(url: pdfURL).data).page(at: 0)?.rotation, 90)

        // 模拟另一个应用覆盖同一路径；本地编辑应保留在内存，让用户选择如何处理冲突。
        try pdf.write(to: pdfURL)
        XCTAssertThrowsError(try SafeFileIO.save(rotated, previous: saved)) { error in
            guard case DocumentIOError.externalModification = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: pdfURL), pdf)
        let copy = directory.appendingPathComponent("副本.pdf")
        _ = try SafeFileIO.save(rotated, previous: saved, to: copy)
        XCTAssertEqual(try PDFOperations.read(Data(contentsOf: copy)).page(at: 0)?.rotation, 90)
    }

    func testCallerSizeLimitRejectsReadAndWriteWithoutChangingOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data([0, 255, 254, 253])
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try SafeFileIO.open(url: url, maximumBytes: 3))
        let snapshot = try SafeFileIO.open(url: url, maximumBytes: 4)
        XCTAssertThrowsError(try SafeFileIO.save(data + Data([252]), previous: snapshot.state, maximumBytes: 4))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testMediaBatchCountsCurrentBufferAndStopsBeforeLaterFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        let missing = directory.appendingPathComponent("not-read")
        try Data([1, 2, 3]).write(to: first)
        try Data([4, 5]).write(to: second)
        XCTAssertEqual(try SafeFileIO.openMediaBatch(urls: [first, second], existingBytes: 2, maximumBytes: 7),
                       [Data([1, 2, 3]), Data([4, 5])])
        for (urls, limit) in [([first, second, missing], 6), ([first, missing], 5)] {
            XCTAssertThrowsError(try SafeFileIO.openMediaBatch(urls: urls, existingBytes: 2, maximumBytes: limit)) { error in
                guard case DocumentIOError.fileTooLarge(let reportedLimit) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(reportedLimit, limit)
            }
        }
        XCTAssertThrowsError(try SafeFileIO.openMediaBatch(urls: [missing], existingBytes: 7, maximumBytes: 7)) { error in
            guard case DocumentIOError.fileTooLarge(limitBytes: 7) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second), Data([4, 5]))
    }

    func testExplicitSaveAsCanRecreateDeletedSourceWithoutWeakeningConflictChecks() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("baseline".utf8).write(to: path)
        let loaded = try SafeFileIO.open(url: path)
        try FileManager.default.removeItem(at: path)
        let draft = Data("confirmed draft".utf8)
        XCTAssertThrowsError(try SafeFileIO.save(draft, previous: loaded.state)) { error in
            guard case DocumentIOError.externalModification = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let saved = try SafeFileIO.save(draft, previous: loaded.state, to: path)
        XCTAssertEqual(try Data(contentsOf: path), draft)
        _ = try SafeFileIO.save(Data("next edit".utf8), previous: saved)
        XCTAssertEqual(try Data(contentsOf: path), Data("next edit".utf8))
        // 同一路径上已经出现其他版本时，显式另存也不能把它当作“缺失文件”覆盖。
        try Data("external version".utf8).write(to: path)
        XCTAssertThrowsError(try SafeFileIO.save(draft, previous: loaded.state, to: path)) { error in
            guard case DocumentIOError.externalModification = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: path), Data("external version".utf8))
    }
}
