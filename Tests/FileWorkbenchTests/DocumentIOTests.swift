import CoreFoundation
import Foundation
import XCTest
@testable import FileWorkbench

final class DocumentIOTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentIOTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testEncodingAndMixedNewlinesRoundTripWithoutByteChanges() throws {
        let text = "中文\r\n第二行\r第三行\n末尾 😀"
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let cases: [(TextFileEncoding, String.Encoding, [UInt8])] = [
            (.utf8(bom: false), .utf8, []), (.utf8(bom: true), .utf8, [0xEF, 0xBB, 0xBF]),
            (.utf16LittleEndian, .utf16LittleEndian, [0xFF, 0xFE]),
            (.utf16BigEndian, .utf16BigEndian, [0xFE, 0xFF]), (.gb18030, gb, [])
        ]
        for (index, item) in cases.enumerated() {
            let original = Data(item.2) + (try XCTUnwrap(text.data(using: item.1)))
            let url = try makeFile("中文 file \(index).txt", data: original)
            let opened = try DocumentIO.open(url: url)
            XCTAssertEqual(opened.text, text)
            XCTAssertEqual(opened.encoding, item.0)
            let saved = try DocumentIO.save(opened)
            XCTAssertEqual(try Data(contentsOf: url), original)
            var edited = saved
            edited.text += "\r\n追加"
            _ = try DocumentIO.save(edited)
            XCTAssertEqual(try Data(contentsOf: url), Data(item.2) + (try XCTUnwrap(edited.text.data(using: item.1))))
        }
    }

    func testNewDocumentDefaultsToUTF8AndRequiresLocation() throws {
        let document = DocumentIO.create(text: "新文档\n")
        XCTAssertNil(document.sourceURL)
        XCTAssertEqual(document.encoding, .utf8(bom: false))
        XCTAssertThrowsError(try DocumentIO.save(document)) { error in
            guard case DocumentIOError.saveLocationRequired = error else { return XCTFail("\(error)") }
        }
        let url = directory.appendingPathComponent("new.txt")
        let saved = try DocumentIO.save(document, to: url)
        XCTAssertEqual(saved.sourceURL, url.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data(document.text.utf8))
    }

    func testOverLimitNeverReturnsTruncatedEditableDocument() throws {
        let url = try makeFile("large.txt", data: Data(repeating: 0x41, count: DocumentIO.maximumEditableBytes + 1))
        XCTAssertThrowsError(try DocumentIO.open(url: url)) { error in
            guard case DocumentIOError.fileTooLarge = error else { return XCTFail("\(error)") }
        }
        let original = try makeFile("original.txt", data: Data("保留".utf8))
        var document = try DocumentIO.open(url: original)
        document.text = String(repeating: "a", count: DocumentIO.maximumEditableBytes + 1)
        XCTAssertThrowsError(try DocumentIO.save(document))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "保留")
    }

    func testFullReadBeyondPreviewLimit() throws {
        let data = Data(repeating: 0x41, count: TextPreviewLoader.maximumBytes + 1)
        let url = try makeFile("full.txt", data: data)
        let document = try DocumentIO.open(url: url)
        XCTAssertEqual(document.text.utf8.count, data.count)
        _ = try DocumentIO.save(document)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testExternalEditWithSameLengthAndRestoredModificationDateIsRejected() throws {
        let url = try makeFile("conflict.txt", data: Data("original".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var document = try DocumentIO.open(url: url)
        document.text = "local"
        try Data("external".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes[.modificationDate])], ofItemAtPath: url.path)
        XCTAssertThrowsError(try DocumentIO.save(document)) { error in
            guard case DocumentIOError.externalModification = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        _ = try DocumentIO.save(document, overwriteExternalChanges: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "local")
    }

    func testExternalRemovalAndExistingSaveAsTargetRequireExplicitOverwrite() throws {
        let url = try makeFile("deleted.txt", data: Data("old".utf8))
        let document = try DocumentIO.open(url: url)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try DocumentIO.save(document)) { error in
            guard case DocumentIOError.externalModification = error else { return XCTFail("\(error)") }
        }
        let other = try makeFile("other.txt", data: Data("other".utf8))
        XCTAssertThrowsError(try DocumentIO.save(document, to: other)) { error in
            guard case DocumentIOError.destinationExists = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "other")
    }

    func testSymbolicLinkIdentityAndTargetPermissionsArePreserved() throws {
        let target = try makeFile("target.txt", data: Data("before".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: link.path)
        var document = try DocumentIO.open(url: link)
        document.text = "after"
        _ = try DocumentIO.save(document)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: link.path)[.systemFileNumber] as? NSNumber,
                       linkAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "after")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber, 0o640)
    }

    func testRetargetedSymbolicLinkIsRejectedEvenWithOverwrite() throws {
        let first = try makeFile("first.txt", data: Data("first".utf8))
        let second = try makeFile("second.txt", data: Data("second".utf8))
        let link = directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        var document = try DocumentIO.open(url: link)
        document.text = "local"
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        XCTAssertThrowsError(try DocumentIO.save(document, overwriteExternalChanges: true)) { error in
            guard case DocumentIOError.symbolicLinkChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    func testReadOnlyFileAndDirectoryFailuresPreserveOriginalAndLeaveNoTemporaryFiles() throws {
        let url = try makeFile("protected.txt", data: Data("original".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        var document = try DocumentIO.open(url: url)
        XCTAssertTrue(document.isReadOnly)
        document.text = "local"
        XCTAssertThrowsError(try DocumentIO.save(document, overwriteExternalChanges: true)) { error in
            guard case DocumentIOError.readOnly = error else { return XCTFail("\(error)") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        document = try DocumentIO.open(url: url)
        document.text = "local"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try DocumentIO.save(document)) { error in
            guard case DocumentIOError.readOnly = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["protected.txt"])
    }

    func testMalformedBOMAndBinaryContentDoNotBecomeEditable() throws {
        for (name, data) in [("broken.txt", Data([0xEF, 0xBB, 0xBF, 0xFF])),
                             ("binary.txt", Data([0x41, 0x00, 0x42])),
                             ("broken-utf16.txt", Data([0xFF, 0xFE, 0x41]))] {
            let url = try makeFile(name, data: data)
            XCTAssertThrowsError(try DocumentIO.open(url: url))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        XCTAssertThrowsError(try DocumentIO.open(url: directory))
    }

    func testMalformedUTF16SurrogatesAndLegacyGB18030AliasesCannotBeSilentlyReencoded() throws {
        // Foundation 能解码这些输入，但会替换孤立代理项或把旧的单字节欧元符号改写成 A2 E3。
        let inputs: [[UInt8]] = [
            [0xFF, 0xFE, 0x00, 0xD8], [0xFF, 0xFE, 0x00, 0xDC],
            [0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x41], [0x80, 0x41]
        ]
        for (index, bytes) in inputs.enumerated() {
            let data = Data(bytes)
            let url = try makeFile("non-roundtrip-\(index).txt", data: data)
            XCTAssertThrowsError(try DocumentIO.open(url: url)) { error in
                guard case DocumentIOError.nonRoundTrippableEncoding = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testExplicitEncodingReadsBOMlessUTF16AndPreservesItsOriginalBytes() throws {
        let text = "名称,数值\r\n苹果,12\r\n"
        for (index, item) in [(TextFileEncoding.utf16LittleEndian, String.Encoding.utf16LittleEndian),
                             (.utf16BigEndian, .utf16BigEndian)].enumerated() {
            let data = try XCTUnwrap(text.data(using: item.1))
            let url = try makeFile("bomless-\(index).csv", data: data)
            var document = try DocumentIO.open(url: url, encoding: item.0)
            XCTAssertEqual(document.text, text)
            document = try DocumentIO.save(document)
            XCTAssertEqual(try Data(contentsOf: url), data)
            document.text += "香蕉,34\r\n"
            _ = try DocumentIO.save(document)
            XCTAssertEqual(try Data(contentsOf: url), try XCTUnwrap(document.text.data(using: item.1)))
        }
    }

    func testExplicitEncodingCanResolveAmbiguousBytesAndTranscodeOnSave() throws {
        let url = try makeFile("ambiguous.csv", data: Data([0xC2, 0xA3, 0x2C, 0x31]))
        let automatic = try DocumentIO.open(url: url)
        XCTAssertEqual(automatic.encoding, .utf8(bom: false))
        let explicit = try DocumentIO.open(url: url, encoding: .gb18030)
        XCTAssertEqual(explicit.encoding, .gb18030)
        XCTAssertNotEqual(explicit.text, automatic.text)
        _ = try DocumentIO.save(explicit)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xC2, 0xA3, 0x2C, 0x31]))
        let saved = try DocumentIO.save(try DocumentIO.open(url: url, encoding: .gb18030), encoding: .utf8(bom: true))
        XCTAssertEqual(saved.encoding, .utf8(bom: true))
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF]) + Data(explicit.text.utf8))
        XCTAssertEqual(try DocumentIO.open(url: url).text, explicit.text)

        let fresh = DocumentIO.create(text: "名称,金额", encoding: .gb18030)
        let createdURL = directory.appendingPathComponent("created.csv")
        _ = try DocumentIO.save(fresh, to: createdURL)
        XCTAssertEqual(try DocumentIO.open(url: createdURL, encoding: .gb18030).text, fresh.text)
    }

    func testExplicitOpenKeepsActualBOMAndRejectsConflictingByteOrder() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("中文,12".utf8)
        let url = try makeFile("bom.csv", data: data)
        let document = try DocumentIO.open(url: url, encoding: .utf8(bom: false))
        _ = try DocumentIO.save(document)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertThrowsError(try DocumentIO.open(url: url, encoding: .utf16BigEndian))
    }

    func testExplicitOverwriteDoesNotBypassOversizedExternalFileProtection() throws {
        let url = try makeFile("grown.txt", data: Data("original".utf8))
        var document = try DocumentIO.open(url: url)
        document.text = "local"
        let external = Data(repeating: 0x42, count: DocumentIO.maximumEditableBytes + 1)
        try external.write(to: url)
        XCTAssertThrowsError(try DocumentIO.save(document, overwriteExternalChanges: true)) { error in
            guard case DocumentIOError.fileTooLarge = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), external)
        let copy = directory.appendingPathComponent("local-copy.txt")
        _ = try DocumentIO.save(document, to: copy)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "local")
    }

    private func makeFile(_ name: String, data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
