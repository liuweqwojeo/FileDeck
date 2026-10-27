import Darwin
import Foundation
import XCTest
@testable import FileWorkbench

/// 使用真实独立目录与 owner 文件锁，验证原子副本、占用、配额和清理，不触及用户恢复库。
final class DraftRecoveryStoreTests: XCTestCase {
    func testTextEncodingUnicodeMixedEndingsAndEmptyDraftRoundTrip() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (index, encoding) in [TextFileEncoding.utf8(bom: false), .utf8(bom: true), .utf16LittleEndian, .utf16BigEndian, .gb18030].enumerated() {
            let id = UUID(), text = index == 0 ? "" : "中文😀e\u{301}\r\nsecond\rlast\n"
            try await abandon(root, id: id, capture: capture(text, encoding: encoding))
            let store = DraftRecoveryStore(directory: root)
            let document = try await store.claim(id)
            XCTAssertEqual(document.data, Data(text.utf8)); XCTAssertEqual(document.header.encoding, encoding)
            XCTAssertEqual(document.header.originalPath, "/original/source.md")
            try await store.checkpoint(id: id, generation: 1, capture: nil)
        }
    }
    func testCSVSerializationKeepsDelimiterShortRowsAndMixedOriginalBytes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var model = try CSVDocument(text: "a;b\r\nshort\r\n", delimiter: .semicolon)
        try model.setCell("with;quote", row: 0, column: 1)
        let id = UUID()
        try await abandon(root, id: id, capture: .init(kind: .csv, originalURL: nil, title: "new.csv",
            body: .csv(model, original: nil, encoding: .utf16LittleEndian)))
        let restored = try await DraftRecoveryStore(directory: root).claim(id)
        XCTAssertEqual(restored.data, Data(try model.serialize().utf8))
        XCTAssertEqual(restored.header.delimiter, CSVDelimiter.semicolon.rawValue)
        XCTAssertEqual(restored.header.encoding, .utf16LittleEndian)
        XCTAssertEqual(try CSVDocument(text: String(decoding: restored.data, as: UTF8.self), delimiter: .semicolon).serialize(), try model.serialize())
    }
    func testBinaryPayloadsAreCopiedWithoutDecodingOrReencoding() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for kind in [WorkbenchFileKind.pdf, .png, .jpeg, .heic] {
            let id = UUID(), data = Data([0, 255, 1, 2, 3])
            try await abandon(root, id: id, capture: .init(kind: kind, originalURL: nil, title: kind.rawValue, body: .binary(data)))
            let document = try await DraftRecoveryStore(directory: root).claim(id)
            XCTAssertEqual(document.data, data); XCTAssertEqual(document.header.kind, kind.rawValue)
        }
    }
    func testLiveOwnerCannotBeListedClaimedOrDeletedFromAnotherInstance() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let live = DraftRecoveryStore(directory: root), other = DraftRecoveryStore(directory: root), id = UUID()
        try await live.checkpoint(id: id, generation: 1, capture: capture("live"))
        let items = try await other.items(); XCTAssertTrue(items.isEmpty)
        await expect(.active) { _ = try await other.claim(id) }
        await expect(.active) { try await other.delete(id) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(root, id).path))
    }
    func testReleasedOwnerCanBeClaimedOnceAndFailedOpenCanRelinquish() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); try await abandon(root, id: id, capture: capture("draft"))
        let first = DraftRecoveryStore(directory: root), second = DraftRecoveryStore(directory: root)
        let listed = try await first.items(); XCTAssertEqual(listed.map(\.id), [id])
        _ = try await first.claim(id)
        await expect(.active) { _ = try await second.claim(id) }
        try await first.relinquish(id)
        let document = try await second.claim(id); XCTAssertEqual(String(decoding: document.data, as: UTF8.self), "draft")
    }
    func testLateGenerationCannotResurrectSavedOrDiscardedDraft() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftRecoveryStore(directory: root), id = UUID()
        try await store.checkpoint(id: id, generation: 1, capture: capture("old"))
        try await store.checkpoint(id: id, generation: 3, capture: nil)
        try await store.checkpoint(id: id, generation: 2, capture: capture("late"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(root, id).path))
        try await store.checkpoint(id: id, generation: 4, capture: capture("new"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(root, id).path))
    }
    func testPerDraftLimitRetainsLastValidSnapshotAndCanRetry() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftRecoveryStore(directory: root, limits: .init(perDraft: 5)), id = UUID()
        try await store.checkpoint(id: id, generation: 1, capture: capture("first"))
        let before = try Data(contentsOf: file(root, id))
        await expect(.limit) { try await store.checkpoint(id: id, generation: 2, capture: self.capture("too long")) }
        XCTAssertEqual(try Data(contentsOf: file(root, id)), before)
        try await store.checkpoint(id: id, generation: 3, capture: capture("retry"))
        XCTAssertNotEqual(try Data(contentsOf: file(root, id)), before)
    }
    func testCountLimitNeverEvictsUnexpiredDraftsAndReplacementDoesNotUseNewSlot() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftRecoveryStore(directory: root, limits: .init(count: 1)), first = UUID(), second = UUID()
        try await store.checkpoint(id: first, generation: 1, capture: capture("first"))
        await expect(.limit) { try await store.checkpoint(id: second, generation: 1, capture: self.capture("second")) }
        try await store.checkpoint(id: first, generation: 2, capture: capture("updated"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(root, first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(root, second).path))
    }
    func testTotalLimitIncludesHeadersAndKeepsExistingCopies() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftRecoveryStore(directory: root, limits: .init(total: 1600)), first = UUID(), second = UUID()
        try await store.checkpoint(id: first, generation: 1, capture: capture(String(repeating: "x", count: 600)))
        await expect(.limit) { try await store.checkpoint(id: second, generation: 1, capture: self.capture(String(repeating: "y", count: 600))) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(root, first).path))
    }
    func testExpiryDeletesOnlyUnclaimedOldDraftsAndLeavesLiveOrRecent() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), old = now.addingTimeInterval(-31 * 86400), expired = UUID(), recent = UUID(), active = UUID()
        try await abandon(root, id: expired, capture: capture("expired"), now: old)
        try await abandon(root, id: recent, capture: capture("recent"), now: now)
        let live = DraftRecoveryStore(directory: root)
        try await live.checkpoint(id: active, generation: 1, capture: capture("active"), now: old)
        let listed = try await DraftRecoveryStore(directory: root).items(now: now)
        XCTAssertEqual(listed.map(\.id), [recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(root, expired).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(root, active).path))
    }
    func testCorruptChecksumRefusesRestoreWithoutRemovingOriginalRecord() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); try await abandon(root, id: id, capture: capture("content"))
        var bytes = try Data(contentsOf: file(root, id)); bytes[bytes.count - 1] ^= 1; try bytes.write(to: file(root, id))
        let store = DraftRecoveryStore(directory: root)
        await expect(.invalidRecord) { _ = try await store.claim(id) }
        XCTAssertEqual(try Data(contentsOf: file(root, id)), bytes)
    }
    func testIncompatibleAndBrokenRecordsRemainVisibleForExplicitDeletion() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); try await abandon(root, id: id, capture: capture("content"))
        try rewriteHeader(file(root, id)) { $0["version"] = 2 }
        let store = DraftRecoveryStore(directory: root), listed = try await store.items()
        XCTAssertEqual(listed.count, 1); XCTAssertNotNil(listed[0].problem)
        await expect(.incompatible) { _ = try await store.claim(id) }
        try await store.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(root, id).path))
    }
    func testTruncatedAndOversizedHeaderCannotAllocateUnboundedContent() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for bytes in [Data("truncated".utf8), Data("FWDRFT01".utf8) + Data([255,255,255,255])] {
            let id = UUID(); try bytes.write(to: file(root, id))
            let store = DraftRecoveryStore(directory: root)
            await expect(.invalidRecord) { _ = try await store.claim(id) }
            XCTAssertEqual(try Data(contentsOf: file(root, id)), bytes)
        }
    }
    func testHeaderWhitespaceDoesNotShiftPayloadDuringRestore() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); try await abandon(root, id: id, capture: capture("payload"))
        try rewriteHeader(file(root, id), pretty: true) { _ in }
        let document = try await DraftRecoveryStore(directory: root).claim(id)
        XCTAssertEqual(document.data, Data("payload".utf8))
    }
    func testSymlinkAndHardlinkRecordsDoNotReadOrModifyTheirTargets() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = base.appendingPathComponent("target"); try Data("unchanged".utf8).write(to: target)
        for link in [false,true] {
            let id = UUID()
            if link { try FileManager.default.linkItem(at: target, to: file(root,id)) }
            else { try FileManager.default.createSymbolicLink(at: file(root,id), withDestinationURL: target) }
            let store = DraftRecoveryStore(directory: root)
            await expect(.invalidRecord) { _ = try await store.claim(id) }
            try await store.delete(id)
            XCTAssertEqual(try String(contentsOf: target), "unchanged")
        }
    }
    func testSymlinkRootAndReplacementRootFailWithoutWritingElsewhere() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Store"), other = base.appendingPathComponent("Other"), moved = base.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: other)
        await expect(.invalidStorage) { _ = try await DraftRecoveryStore(directory: root).items() }
        try FileManager.default.removeItem(at: root)
        let store = DraftRecoveryStore(directory: root), id = UUID()
        try await store.checkpoint(id: id, generation: 1, capture: capture("original"))
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        await expect(.invalidStorage) { try await store.checkpoint(id: id, generation: 2, capture: self.capture("later")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(root,id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(moved,id).path))
    }
    func testOrphanWritesAreRemovedAndOwnerLocksAreNotMistakenForDrafts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent(".write-" + UUID().uuidString)
        try Data("partial".utf8).write(to: orphan)
        let store = DraftRecoveryStore(directory: root), listed = try await store.items()
        XCTAssertTrue(listed.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
    func testRecoveryPermissionsArePrivateAndOfficeCannotBeCheckpointed() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftRecoveryStore(directory: root), id = UUID()
        await expect(.incompatible) { try await store.checkpoint(id: id, generation: 1,
            capture: .init(kind: .word, originalURL: nil, title: "word", body: .binary(Data()))) }
        try await store.checkpoint(id: id, generation: 2, capture: capture("private"))
        var metadata = stat(); XCTAssertEqual(lstat(root.path, &metadata), 0); XCTAssertEqual(metadata.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(file(root,id).path, &metadata), 0); XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    }
    func testConcurrentStoresShareTheSameCountBudget() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = DraftRecoveryStore(directory: root, limits: .init(count: 1))
        let second = DraftRecoveryStore(directory: root, limits: .init(count: 1))
        let value = capture("concurrent")
        let successes = await withTaskGroup(of: Bool.self) { group in
            for store in [first,second] {
                group.addTask {
                    do { try await store.checkpoint(id: UUID(), generation: 1, capture: value); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(successes,1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".fwdraft") }.count,1)
    }

    func testNonRegularRecordIsRejectedWithoutWaitingForAFIFOWriter() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), target = file(root,id)
        XCTAssertEqual(mkfifo(target.path,0o600),0)
        let store = DraftRecoveryStore(directory:root)
        await expect(.invalidRecord) { _ = try await store.claim(id) }
        try await store.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeck-F3-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func file(_ directory: URL, _ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".fwdraft") }
    private func capture(_ text: String, encoding: TextFileEncoding = .utf8(bom:false)) -> DraftRecoveryCapture {
        .init(kind: .markdown, originalURL: URL(fileURLWithPath: "/original/source.md"), title: "source.md", body: .text(text,encoding,nil))
    }
    private func abandon(_ directory: URL, id: UUID, capture: DraftRecoveryCapture, now: Date = Date()) async throws {
        let store = DraftRecoveryStore(directory: directory)
        try await store.checkpoint(id: id, generation: 1, capture: capture, now: now)
    }
    private func expect(_ error: DraftRecoveryError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("应拒绝：\(error)") }
        catch let value as DraftRecoveryError { XCTAssertEqual(value,error) }
        catch { XCTFail("错误类型不符：\(error)") }
    }
    private func rewriteHeader(_ url: URL, pretty: Bool = false, change: (inout [String:Any]) -> Void) throws {
        let bytes = try Data(contentsOf:url), count = bytes[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        var header = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes[12..<(12+count)]) as? [String:Any]); change(&header)
        let encoded = try JSONSerialization.data(withJSONObject:header, options: pretty ? [.prettyPrinted] : [.sortedKeys])
        let size = UInt32(encoded.count)
        try (bytes.prefix(8) + Data([UInt8(size >> 24),UInt8((size >> 16)&255),UInt8((size >> 8)&255),UInt8(size&255)]) + encoded + bytes.dropFirst(12+count)).write(to:url)
    }
}
