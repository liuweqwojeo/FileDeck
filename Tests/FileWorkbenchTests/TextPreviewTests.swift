import CoreFoundation
import AVFoundation
import Foundation
import XCTest
@testable import FileWorkbench

@MainActor
final class TextPreviewTests: XCTestCase {
    func testUTF8AndUTF16ChineseText() throws {
        let text = "文件工作台\n第二行 😀"
        let utf8 = try TextPreviewLoader.decode(Data(text.utf8), truncated: false)
        XCTAssertEqual(utf8.text, text)
        XCTAssertEqual(utf8.encodingName, "UTF-8")

        let utf16Data = Data([0xFF, 0xFE]) + (try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        let utf16 = try TextPreviewLoader.decode(utf16Data, truncated: false)
        XCTAssertEqual(utf16.text, text)
        XCTAssertEqual(utf16.encodingName, "UTF-16 LE")
    }

    func testGB18030ChineseText() throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let text = "中文文件内容与标点。"
        let data = try XCTUnwrap(text.data(using: encoding))
        let document = try TextPreviewLoader.decode(data, truncated: false)
        XCTAssertEqual(document.text, text)
        XCTAssertEqual(document.encodingName, "GB18030")
    }

    func testTruncatedUTF8DropsOnlyIncompleteTrailingCharacter() throws {
        var data = Data("完整文本".utf8)
        data.append(contentsOf: [0xF0, 0x9F, 0x98])
        let document = try TextPreviewLoader.decode(data, truncated: true)
        XCTAssertEqual(document.text, "完整文本")
        XCTAssertTrue(document.isTruncated)
    }

    func testBinaryWithTextExtensionIsRejected() {
        XCTAssertThrowsError(try TextPreviewLoader.decode(Data([0x41, 0, 0x42]), truncated: false)) { error in
            guard case FilePreviewFailure.binaryContent = error else {
                return XCTFail("Expected binary-content failure, got \(error)")
            }
        }
    }

    func testReadsAtMostOneMiBAndReportsTruncation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.txt")
        try Data(repeating: 0x41, count: TextPreviewLoader.maximumBytes + 20).write(to: file)
        let result = await TextPreviewLoader.prepare(url: file)
        guard case .success(.text(let document)) = result else {
            return XCTFail("Expected text preview, got \(result)")
        }
        XCTAssertEqual(document.bytesRead, TextPreviewLoader.maximumBytes)
        XCTAssertEqual(document.text.utf8.count, TextPreviewLoader.maximumBytes)
        XCTAssertTrue(document.isTruncated)
    }

    func testDirectoryProducesClearFailure() async {
        let result = await TextPreviewLoader.prepare(url: FileManager.default.temporaryDirectory)
        guard case .failure(.directory) = result else {
            return XCTFail("Expected directory failure, got \(result)")
        }
    }

    func testDocumentPackageUsesQuickLook() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try Data("{\\rtf1 Preview}".utf8).write(to: package.appendingPathComponent("TXT.rtf"))
        let result = await TextPreviewLoader.prepare(url: package)
        guard case .success(.quickLook) = result else {
            return XCTFail("Expected document package to use Quick Look, got \(result)")
        }
    }

    func testDeletedFileIsReadFailureRatherThanUnsupportedFormat() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("temporary".utf8).write(to: file)
        try FileManager.default.removeItem(at: file)
        let result = await TextPreviewLoader.prepare(url: file)
        guard case .failure(let failure) = result else {
            return XCTFail("Expected missing-file failure, got \(result)")
        }
        XCTAssertFalse(failure.isUnsupported)

        try Data("恢复内容".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let retryResult = await TextPreviewLoader.prepare(url: file)
        guard case .success(.text(let document)) = retryResult else {
            return XCTFail("Expected recovered file to load on retry, got \(retryResult)")
        }
        XCTAssertEqual(document.text, "恢复内容")
    }

    func testBinaryTextIsUnsupportedWithoutClaimingReadFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data([0x41, 0, 0x42]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await TextPreviewLoader.prepare(url: file)
        guard case .failure(.binaryContent) = result else {
            return XCTFail("Expected unsupported binary text, got \(result)")
        }
        XCTAssertTrue(FilePreviewFailure.binaryContent.isUnsupported)
        XCTAssertFalse(FilePreviewFailure.permissionDenied.isUnsupported)
    }

    func testLateRealFileReadCannotReplaceNewPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("A.txt")
        let secondURL = directory.appendingPathComponent("B.txt")
        try Data("旧文件 A".utf8).write(to: firstURL)
        try Data("当前文件 B".utf8).write(to: secondURL)
        let gate = PreviewReadGate()
        let session = FilePreviewSession()
        // 让实际磁盘读取晚于 B 返回，且不依赖底层读取一定响应取消。
        let first = Task {
            await session.load(url: firstURL) { url in
                await Task.detached {
                    await gate.wait()
                    return await TextPreviewLoader.prepare(url: url)
                }.value
            }
        }
        await gate.waitUntilStarted()
        await session.load(url: secondURL)
        await gate.release()
        await first.value
        XCTAssertEqual(session.url, secondURL)
        guard case .success(.text(let document)) = session.preparation else { return XCTFail("Expected current file B") }
        XCTAssertEqual(document.text, "当前文件 B")
    }

    func testCloseInvalidatesLateReadAndReleasesResourcesOnce() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("关闭后不应重新出现".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = PreviewReadGate()
        let session = FilePreviewSession()
        let loading = Task {
            await session.load(url: file) { url in
                await Task.detached {
                    await gate.wait()
                    return await TextPreviewLoader.prepare(url: url)
                }.value
            }
        }
        await gate.waitUntilStarted()
        var releaseCount = 0
        _ = session.registerCleanup { releaseCount += 1 }
        session.cancel()
        session.cancel()
        await gate.release()
        await loading.value
        XCTAssertNil(session.url)
        XCTAssertNil(session.preparation)
        XCTAssertEqual(releaseCount, 1)
    }

    func testMediaSwitchAndCloseDetachActualPlayerItem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("A.wav")
        let secondURL = directory.appendingPathComponent("B.wav")
        try Self.silentWAV().write(to: firstURL)
        try Self.silentWAV().write(to: secondURL)
        guard case .success(.media) = await TextPreviewLoader.prepare(url: firstURL) else {
            return XCTFail("Expected native media preview")
        }
        let controller = FileMediaPreviewController()
        controller.load(url: firstURL)
        let firstPlayer = try XCTUnwrap(controller.player)
        XCTAssertEqual(firstPlayer.rate, 0, "Opening media must not start playback")
        XCTAssertEqual((firstPlayer.currentItem?.asset as? AVURLAsset)?.url, firstURL)
        controller.load(url: secondURL)
        XCTAssertNil(firstPlayer.currentItem, "Switch must release the first file")
        XCTAssertEqual(controller.currentURL, secondURL)
        let secondPlayer = try XCTUnwrap(controller.player)
        XCTAssertEqual((secondPlayer.currentItem?.asset as? AVURLAsset)?.url, secondURL)
        let session = FilePreviewSession()
        _ = session.registerCleanup { controller.stop() }
        session.cancel()
        session.cancel()
        XCTAssertEqual(secondPlayer.rate, 0)
        XCTAssertNil(secondPlayer.currentItem)
        XCTAssertNil(controller.player)
        XCTAssertNil(controller.playerView.player)
        XCTAssertNil(controller.currentURL)
    }

    private static func silentWAV() -> Data {
        let sampleCount: UInt32 = 8_000
        let bytes = sampleCount * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36) + bytes)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(bytes)
        data.append(Data(repeating: 0, count: Int(bytes)))
        return data
    }
}

private actor PreviewReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() { continuation?.resume(); continuation = nil }
}
