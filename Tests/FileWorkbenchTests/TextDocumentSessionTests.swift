import Foundation
import XCTest
@testable import FileWorkbench

@MainActor
final class TextDocumentSessionTests: XCTestCase {
    func testNewSessionRequiresSaveLocationAndRejectsUnsupportedExport() async throws {
        try await withDirectory { directory in
            let session = TextDocumentSession.create(text: "未保存内容")
            XCTAssertNil(session.path)
            XCTAssertTrue(session.isModified)
            XCTAssertFalse(session.isReadOnly)
            XCTAssertNotEqual(session.id, TextDocumentSession.create().id)
            let abstraction: any DocumentSession = session
            do {
                try await abstraction.save()
                XCTFail("首次保存必须选择位置")
            } catch DocumentIOError.saveLocationRequired { }
            let exportURL = directory.appendingPathComponent("not-created.pdf")
            await assertSessionError(.unsupportedOperation(.export)) {
                try await abstraction.export(to: exportURL, format: .pdf)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
            XCTAssertEqual(session.text, "未保存内容")
            XCTAssertFalse(session.isBusy)
            await assertSessionError(.unsavedChanges) { try await abstraction.close() }
            XCTAssertFalse(session.isClosed)
            try await abstraction.close(discardChanges: true)
            XCTAssertTrue(session.isClosed)
            XCTAssertTrue(abstraction.availableOperations.isEmpty)
            await assertSessionError(.closed) { try await abstraction.saveAs(to: exportURL) }
            XCTAssertThrowsError(try session.replaceText("禁止修改"))
            try await abstraction.close()
        }
    }

    func testCompleteOpenAndSavePreserveEncodingAndMixedLineEndings() async throws {
        try await withDirectory { directory in
            let url = directory.appendingPathComponent("完整 中文 文本.txt")
            let initial = String(repeating: "x", count: TextPreviewLoader.maximumBytes + 10) + "\r\n中文\r尾部\n"
            // 无 BOM 的 UTF-16 不能被会话保存时擅自补 BOM，且内容必须超过只读预览截断点。
            try XCTUnwrap(initial.data(using: .utf16LittleEndian)).write(to: url)
            let session = try await TextDocumentSession.open(url: url, encoding: .utf16LittleEndian)
            XCTAssertEqual(session.text, initial)
            XCTAssertFalse(session.isModified)
            XCTAssertEqual(session.encoding, .utf16LittleEndian)
            let changed = initial + "新增e\u{0301}\r\n"
            try session.replaceText(changed)
            try await session.save()
            XCTAssertEqual(try Data(contentsOf: url), changed.data(using: .utf16LittleEndian))
            XCTAssertEqual(session.text, changed)
            XCTAssertFalse(session.isModified)
            XCTAssertFalse(session.isBusy)
        }
    }

    func testUnicodeEditsAndRestorationCompareExactBytes() async throws {
        try await withDirectory { directory in
            let url = directory.appendingPathComponent("unicode.txt")
            let composed = "\u{00E9}\n"
            let decomposed = "e\u{0301}\n"
            try Data(composed.utf8).write(to: url)
            let session = try await TextDocumentSession.open(url: url)
            try session.replaceText(decomposed)
            XCTAssertTrue(session.isModified)
            try session.replaceText(composed)
            XCTAssertFalse(session.isModified)
            try session.replaceText(decomposed)
            try await session.save()
            XCTAssertEqual(try Data(contentsOf: url), Data(decomposed.utf8))
            XCTAssertFalse(session.isModified)
        }
    }

    func testConflictPreservesContentsAndSaveAsUpdatesOnlySelectedPath() async throws {
        try await withDirectory { directory in
            let original = directory.appendingPathComponent("original.txt")
            let copy = directory.appendingPathComponent("副本.txt")
            try Data("original".utf8).write(to: original)
            let session = try await TextDocumentSession.open(url: original)
            try session.replaceText("my changes")
            try Data("external changes".utf8).write(to: original)
            do {
                try await session.save()
                XCTFail("不能覆盖外部改动")
            } catch DocumentIOError.externalModification { }
            XCTAssertEqual(session.text, "my changes")
            XCTAssertEqual(session.path, original)
            XCTAssertTrue(session.isModified)
            XCTAssertFalse(session.isBusy)
            try await session.saveAs(to: copy)
            XCTAssertEqual(session.path, copy)
            XCTAssertFalse(session.isModified)
            try session.replaceText("copy updated")
            try await session.save()
            XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "copy updated")
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "external changes")
        }
    }

    func testSaveAsCollisionAndExplicitOverwrite() async throws {
        try await withDirectory { directory in
            let destination = directory.appendingPathComponent("existing.txt")
            try Data("existing".utf8).write(to: destination)
            let session = TextDocumentSession.create(text: "new content")
            do {
                try await session.saveAs(to: destination)
                XCTFail("另存不得默认覆盖已有文件")
            } catch DocumentIOError.destinationExists { }
            XCTAssertNil(session.path)
            XCTAssertTrue(session.isModified)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")
            try await session.saveAs(to: destination, overwriteExternalChanges: true)
            XCTAssertEqual(session.path, destination)
            XCTAssertFalse(session.isModified)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new content")
            try session.replaceText("explicit replacement")
            try Data("second external edit".utf8).write(to: destination)
            try await session.save(overwriteExternalChanges: true)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "explicit replacement")
        }
    }

    func testSaveKeepsNewEditsAndRejectsConcurrentOperations() async throws {
        try await withDirectory { directory in
            let original = directory.appendingPathComponent("source.txt")
            let extra = directory.appendingPathComponent("extra.txt")
            try Data("baseline".utf8).write(to: original)
            let gate = SessionSaveGate()
            let session = try await TextDocumentSession.open(url: original, storage: gatedStorage(gate))
            try session.replaceText("saved snapshot")
            let saving = Task { try await session.save() }
            defer { Task { await gate.release() } }
            await gate.waitUntilStarted()
            XCTAssertTrue(session.isBusy)
            XCTAssertEqual(session.availableOperations, [.edit])
            try session.replaceText("new edit during save")
            await assertSessionError(.busy) { try await session.save() }
            await assertSessionError(.busy) { try await session.saveAs(to: extra) }
            await assertSessionError(.busy) { try await session.reload(discardChanges: true) }
            await assertSessionError(.busy) { try await session.close(discardChanges: true) }
            await gate.release()
            try await saving.value
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "saved snapshot")
            XCTAssertEqual(session.text, "new edit during save")
            XCTAssertTrue(session.isModified)
            XCTAssertFalse(session.isBusy)
            XCTAssertFalse(FileManager.default.fileExists(atPath: extra.path))
            try await session.save()
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "new edit during save")
            XCTAssertFalse(session.isModified)
        }
    }

    func testSaveCompletionRecomputesDirtyWhenBufferReturnsToOldDiskContents() async throws {
        try await withDirectory { directory in
            let url = directory.appendingPathComponent("revert.txt")
            try Data("old disk content".utf8).write(to: url)
            let gate = SessionSaveGate()
            let session = try await TextDocumentSession.open(url: url, storage: gatedStorage(gate))
            try session.replaceText("snapshot being saved")
            let saving = Task { try await session.save() }
            defer { Task { await gate.release() } }
            await gate.waitUntilStarted()
            try session.replaceText("old disk content")
            XCTAssertFalse(session.isModified)
            await gate.release()
            try await saving.value
            // 虽然用户撤回到旧基线，但本次保存已改变磁盘；不能保留保存之前的 false 状态。
            XCTAssertTrue(session.isModified)
            XCTAssertEqual(session.text, "old disk content")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "snapshot being saved")
        }
    }

    func testSaveFailureKeepsEditsMadeWhileWaiting() async throws {
        try await withDirectory { directory in
            let url = directory.appendingPathComponent("conflict.txt")
            try Data("initial".utf8).write(to: url)
            let gate = SessionSaveGate()
            let session = try await TextDocumentSession.open(url: url, storage: gatedStorage(gate))
            try session.replaceText("first edit")
            let saving = Task { try await session.save() }
            defer { Task { await gate.release() } }
            await gate.waitUntilStarted()
            try session.replaceText("latest edit")
            try Data("external replacement".utf8).write(to: url)
            await gate.release()
            do {
                try await saving.value
                XCTFail("保存快照必须检测实际文件冲突")
            } catch DocumentIOError.externalModification { }
            XCTAssertEqual(session.text, "latest edit")
            XCTAssertTrue(session.isModified)
            XCTAssertFalse(session.isBusy)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external replacement")
        }
    }

    func testReloadRequiresDiscardAndFailedReloadKeepsBuffer() async throws {
        try await withDirectory { directory in
            let url = directory.appendingPathComponent("reload.txt")
            try Data("initial".utf8).write(to: url)
            let session = try await TextDocumentSession.open(url: url)
            try session.replaceText("draft")
            try Data("changed outside".utf8).write(to: url)
            await assertSessionError(.unsavedChanges) { try await session.reload() }
            XCTAssertEqual(session.text, "draft")
            try await session.reload(discardChanges: true)
            XCTAssertEqual(session.text, "changed outside")
            XCTAssertFalse(session.isModified)
            try session.replaceText("draft kept after failure")
            try FileManager.default.removeItem(at: url)
            do {
                try await session.reload(discardChanges: true)
                XCTFail("已经删除的文件不能重载")
            } catch DocumentIOError.system(_) { }
            XCTAssertEqual(session.text, "draft kept after failure")
            XCTAssertTrue(session.isModified)
            XCTAssertFalse(session.isBusy)
            try await session.close(discardChanges: true)
            await assertSessionError(.closed) { try await session.reload(discardChanges: true) }
            let empty = TextDocumentSession.create()
            await assertSessionError(.noFileToReload) { try await empty.reload() }
            try await empty.close()
        }
    }

    func testReadOnlySourceCanBeCopiedThenEdited() async throws {
        try await withDirectory { directory in
            let original = directory.appendingPathComponent("readonly.txt")
            let copy = directory.appendingPathComponent("writable.txt")
            try Data("read only".utf8).write(to: original)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: original.path)
            let session = try await TextDocumentSession.open(url: original)
            XCTAssertTrue(session.isReadOnly)
            XCTAssertEqual(session.availableOperations, [.saveAs])
            XCTAssertThrowsError(try session.replaceText("blocked"))
            try await session.saveAs(to: copy)
            XCTAssertFalse(session.isReadOnly)
            XCTAssertFalse(session.isModified)
            try session.replaceText("editable copy")
            try await session.save()
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "read only")
            XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "editable copy")
        }
    }

    private func gatedStorage(_ gate: SessionSaveGate) -> TextDocumentSession.Storage {
        TextDocumentSession.Storage(open: TextDocumentSession.Storage.fileSystem.open, save: { document, destination, overwrite in
            await gate.pause()
            return try await TextDocumentSession.Storage.fileSystem.save(document, destination, overwrite)
        })
    }

    private func assertSessionError(_ expected: DocumentSessionError, file: StaticString = #filePath, line: UInt = #line,
                                    operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("应拒绝操作：\(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DocumentSessionError, expected, file: file, line: line)
        }
    }

    private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileWorkbenchSession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}

/// 不依赖 sleep 或文件体积制造竞争；暂停真正的磁盘保存，让测试精确插入用户编辑和冲突。
private actor SessionSaveGate {
    private var started = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var saveWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        if released { return }
        await withCheckedContinuation { saveWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        released = true
        saveWaiter?.resume()
        saveWaiter = nil
    }
}
