import AppKit
import XCTest
@testable import FileWorkbench

/// 全部磁盘样本位于 UUID 临时目录；废纸篓替身保留原件内容，不接触用户废纸篓。
@MainActor
final class FileOperationTests: XCTestCase {
    func testCopyCancellationBeforeStartLeavesEverythingUntouched() throws {
        try fixture { source, target, files in
            let control = FileOperationControl(title: "复制", total: 3)
            control.cancel()
            let result = try transfer(files, target, control: control)
            XCTAssertEqual(result.unattempted, 3)
            XCTAssertEqual(control.progress.completed, 0)
            XCTAssertTrue(result.undo.isEmpty)
            XCTAssertEqual(try names(target), [])
            XCTAssertEqual(try names(source), ["a.txt", "b.txt", "c.txt"])
        }
    }

    func testCancelDuringCopyCleansCurrentPrivatePayloadAndKeepsEarlierUndo() throws {
        try fixture { _, target, files in
            let control = FileOperationControl(title: "复制", total: 3)
            var io = WorkspaceFileTransfer.IO()
            io.copy = { source, payload in
                try FileManager.default.copyItem(at: source, to: payload)
                if source.lastPathComponent == "b.txt" { control.cancel() }
            }
            let result = try transfer(files, target, control: control, io: io)
            XCTAssertEqual(result.succeeded, 1)
            XCTAssertEqual(result.unattempted, 2)
            XCTAssertEqual(control.progress.completed, 1)
            XCTAssertEqual(control.progress.current, "b.txt")
            XCTAssertEqual(result.undo.count, 1)
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(try names(target), ["a.txt"])
        }
    }

    func testFailedPartialCopyCleansOnlyStagingAndContinuesOtherFiles() throws {
        try fixture { _, target, files in
            let occupied = target.appendingPathComponent("a.txt")
            try Data("keep".utf8).write(to: occupied)
            var io = WorkspaceFileTransfer.IO()
            io.copy = { source, payload in
                if source.lastPathComponent == "b.txt" {
                    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
                    try Data("partial".utf8).write(to: payload.appendingPathComponent("partial"))
                    throw WorkspaceFileTransfer.failure("模拟磁盘写入失败")
                }
                try FileManager.default.copyItem(at: source, to: payload)
            }
            let result = try transfer(files, target, io: io)
            XCTAssertEqual(result.succeeded, 1)
            XCTAssertEqual(result.failures.count, 2)
            XCTAssertTrue(result.failures.joined().contains("模拟磁盘写入失败"))
            XCTAssertEqual(try names(target), ["a.txt", "c.txt"])
            XCTAssertEqual(try String(contentsOf: occupied), "keep")
            XCTAssertEqual(result.undo.map(\.current.lastPathComponent), ["c.txt"])
        }
    }

    func testCleanupFailureReportsExactResidualAndNeverDeletesSource() throws {
        try fixture { _, target, files in
            let control = FileOperationControl(title: "复制", total: 1)
            var io = WorkspaceFileTransfer.IO()
            io.copy = { source, payload in
                try FileManager.default.copyItem(at: source, to: payload)
                control.cancel()
            }
            io.remove = { _ in throw WorkspaceFileTransfer.failure("模拟清理失败") }
            let result = try transfer([files[0]], target, control: control, io: io)
            XCTAssertEqual(result.failures.count, 1)
            let residual = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).first)
            XCTAssertTrue(result.failures[0].contains(target.appendingPathComponent(residual.lastPathComponent).path), "message=\(result.failures[0]); residual=\(residual.path)")
            XCTAssertTrue(result.failures[0].contains("清理失败"))
            XCTAssertEqual(try String(contentsOf: files[0].url), "a.txt")
            XCTAssertEqual(try String(contentsOf: residual.appendingPathComponent("payload")), "a.txt")
            XCTAssertTrue(result.undo.isEmpty)
        }
    }

    func testCommittedCopyWithCleanupFailureStillHasUndoAndWarning() throws {
        try fixture { _, target, files in
            var io = WorkspaceFileTransfer.IO()
            io.remove = { _ in throw WorkspaceFileTransfer.failure("模拟清理失败") }
            let result = try transfer([files[0]], target, io: io)
            XCTAssertEqual(result.succeeded, 1)
            XCTAssertEqual(result.undo.count, 1)
            XCTAssertEqual(result.warnings.count, 1)
            XCTAssertTrue(result.warnings[0].contains(target.path + "/.FileDeck-transfer-"))
            XCTAssertTrue(result.failures.isEmpty)
        }
    }

    func testReplacedStagingIsNeverCleaned() throws {
        try fixture { _, target, files in
            var io = WorkspaceFileTransfer.IO()
            io.copy = { _, payload in
                let staging = payload.deletingLastPathComponent()
                try FileManager.default.moveItem(at: staging, to: staging.appendingPathExtension("original"))
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                try Data("replacement".utf8).write(to: staging.appendingPathComponent("keep"))
                throw WorkspaceFileTransfer.failure("中途替换")
            }
            let result = try transfer([files[0]], target, io: io)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertTrue(result.failures[0].contains("身份已变化"))
            let replacement = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).first { $0.pathExtension != "original" }!
            XCTAssertEqual(try String(contentsOf: replacement.appendingPathComponent("keep")), "replacement")
        }
    }

    func testCopyConflictNamesAndUndoTrashPreserveOriginalAndEditedCopy() throws {
        try fixture { source, target, files in
            let occupied = target.appendingPathComponent("a.txt")
            try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: target.appendingPathComponent("missing"))
            let result = try transfer([files[0], files[0]], target, rename: true)
            XCTAssertEqual(result.succeeded, 1)
            let record = try XCTUnwrap(result.undo.first)
            XCTAssertEqual(record.current.lastPathComponent, "a 副本.txt")
            try Data("edited after copy".utf8).write(to: record.current)
            let trash = source.appendingPathComponent("isolated-trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            let undone = FileOperationUndo.perform(result.undo, control: .init(title: "撤销", total: 1), trash: { url in
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
            XCTAssertEqual(undone.succeeded, 1)
            XCTAssertEqual(try String(contentsOf: files[0].url), "a.txt")
            XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("a 副本.txt")), "edited after copy")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path), target.appendingPathComponent("missing").path)
        }
    }

    func testMoveCancellationFinishesCurrentAndUndoRestoresOnlyCompletedItem() throws {
        try fixture { _, target, files in
            let control = FileOperationControl(title: "移动", total: 3)
            var io = WorkspaceFileTransfer.IO()
            let rename = io.rename
            io.rename = { source, destination in try rename(source, destination); control.cancel() }
            let result = try transfer(files, target, move: true, control: control, io: io)
            XCTAssertEqual(result.succeeded, 1)
            XCTAssertEqual(result.unattempted, 2)
            XCTAssertEqual(control.progress.completed, 1)
            let undone = FileOperationUndo.perform(result.undo, control: .init(title: "撤销", total: 1))
            XCTAssertEqual(undone.succeeded, 1)
            XCTAssertTrue(undone.remaining.isEmpty)
            XCTAssertEqual(try names(target), [])
            for file in files { XCTAssertEqual(try String(contentsOf: file.url), file.url.lastPathComponent) }
        }
    }

    func testUndoCollisionRetainsFailedRecordAndCanRetryWithoutOverwrite() throws {
        try fixture { _, target, files in
            let result = try transfer(files, target, move: true)
            try Data("new original".utf8).write(to: files[1].url)
            let undo = FileOperationUndo.perform(result.undo, control: .init(title: "撤销", total: 3))
            XCTAssertEqual(undo.succeeded, 2)
            XCTAssertEqual(undo.remaining.count, 1)
            XCTAssertEqual(undo.failures.count, 1)
            XCTAssertEqual(try String(contentsOf: files[1].url), "new original")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("b.txt")), "b.txt")
            try FileManager.default.removeItem(at: files[1].url)
            let retry = FileOperationUndo.perform(undo.remaining, control: .init(title: "撤销", total: 1))
            XCTAssertEqual(retry.succeeded, 1)
            XCTAssertEqual(try String(contentsOf: files[1].url), "b.txt")
        }
    }

    func testUndoRejectsReplacedItemAndReplacedOriginalParent() throws {
        try fixture { source, target, files in
            let result = try transfer(files, target, move: true)
            try Data("replacement".utf8).write(to: result.undo[0].current, options: .atomic)
            let old = source.appendingPathExtension("old")
            try FileManager.default.moveItem(at: source, to: old)
            defer { try? FileManager.default.removeItem(at: old) }
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let undo = FileOperationUndo.perform(result.undo, control: .init(title: "撤销", total: 3))
            XCTAssertEqual(undo.succeeded, 0)
            XCTAssertEqual(undo.failures.count, 3)
            XCTAssertEqual(undo.remaining.count, 3)
            XCTAssertEqual(try String(contentsOf: result.undo[0].current), "replacement")
            XCTAssertEqual(try names(source), [])
        }
    }

    func testCrossVolumeFallbackCommitsCopyAndReportsSourceRemovalFailure() throws {
        try fixture { _, target, files in
            var io = WorkspaceFileTransfer.IO()
            let rename = io.rename
            io.rename = { source, destination in
                if source == files[0].url { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)) }
                try rename(source, destination)
            }
            io.remove = { url in
                if url == files[0].url { throw WorkspaceFileTransfer.failure("模拟原件删除失败") }
                try FileManager.default.removeItem(at: url)
            }
            let result = try transfer([files[0]], target, move: true, io: io)
            XCTAssertEqual(result.succeeded, 0)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertTrue(result.failures[0].contains("跨卷副本已保留"))
            XCTAssertTrue(result.failures[0].contains(files[0].url.path))
            XCTAssertTrue(result.failures[0].contains(target.appendingPathComponent("a.txt").path))
            XCTAssertEqual(try String(contentsOf: files[0].url), "a.txt")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.txt")), "a.txt")
            XCTAssertTrue(result.undo.isEmpty)
        }
    }

    func testTrashCancelAndUndoUseReturnedLocationAndProtectNewOriginal() throws {
        try fixture { _, target, files in
            let entries = try FileSystem.entries(at: files[0].url.deletingLastPathComponent(), showHidden: false)
            let control = FileOperationControl(title: "废纸篓", total: 3)
            let result = WorkspaceFileTrash.perform(entries, trashAndLocate: { url in
                let location = target.appendingPathComponent("system-renamed-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: location)
                control.cancel()
                return location
            }, control: control)
            XCTAssertEqual(result.succeeded.count, 1)
            XCTAssertEqual(result.unattempted, 2)
            XCTAssertEqual(result.count, 3)
            let record = try XCTUnwrap(result.undo.first)
            XCTAssertTrue(record.current.lastPathComponent.hasPrefix("system-renamed-"))
            try Data("new original".utf8).write(to: record.original)
            let blocked = FileOperationUndo.perform(result.undo, control: .init(title: "撤销", total: 1))
            XCTAssertEqual(blocked.failures.count, 1)
            XCTAssertEqual(try String(contentsOf: record.original), "new original")
            try FileManager.default.removeItem(at: record.original)
            let done = FileOperationUndo.perform(blocked.remaining, control: .init(title: "撤销", total: 1))
            XCTAssertEqual(done.succeeded, 1)
            XCTAssertEqual(try String(contentsOf: record.original), record.original.lastPathComponent)
        }
    }

    func testUndoCancelledBeforeStartKeepsWholeBatchForRetry() throws {
        try fixture { _, target, files in
            let result = try transfer(files, target, move: true)
            let control = FileOperationControl(title: "撤销", total: 3)
            control.cancel()
            let undo = FileOperationUndo.perform(result.undo, control: control)
            XCTAssertEqual(undo.remaining.map(\.current), result.undo.map(\.current))
            XCTAssertEqual(undo.succeeded, 0)
            XCTAssertEqual(control.progress.completed, 0)
            XCTAssertEqual(try names(target), ["a.txt", "b.txt", "c.txt"])
        }
    }

    func testStorePublishesCancellationSummaryAndClearsUndoOnNextBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeck-F4-store-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("target", isDirectory: true)
        try Data("source".utf8).write(to: source)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(target, remember: false)
        try await settled(store)
        store.importFiles([source])
        XCTAssertEqual(store.fileOperationProgress?.title, "复制")
        XCTAssertEqual(store.fileOperationProgress?.total, 1)
        store.cancelFileOperation()
        XCTAssertTrue(store.fileOperationProgress?.cancellationRequested == true)
        try await settled(store)
        XCTAssertTrue(try XCTUnwrap(store.fileOperationSummary).contains("未执行 1"))
        XCTAssertTrue(store.fileOperationUndo.isEmpty)
        store.importFiles([source])
        try await settled(store)
        XCTAssertEqual(store.fileOperationUndo.count, 1)
        store.dismissFileOperationSummary()
        XCTAssertNil(store.fileOperationSummary)
        XCTAssertEqual(store.fileOperationUndo.count, 1)
        store.importFiles([source]) // 同名失败仍开始新批次，旧批次撤销到此失效。
        XCTAssertTrue(store.fileOperationUndo.isEmpty)
        try await settled(store)
        XCTAssertTrue(try XCTUnwrap(store.fileOperationSummary).contains("失败 1"))
    }

    func testStoreMoveUndoRebasesNavigationAndPreservesLatestQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeck-F4-path-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("managed", isDirectory: true)
        let child = source.appendingPathComponent("child", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        for url in [child, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(source, remember: false)
        try await settled(store)
        store.navigate(to: child)
        try await settled(store)
        let token = store.beginFileDrag(source, includingSelection: false)
        store.dropActiveDrag(token: token, into: target, copy: false)
        try await settled(store)
        store.query = "keep search"
        await store.undoLastFileOperation()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, child)
        XCTAssertEqual(store.managedRoots, [source])
        XCTAssertTrue(store.history.contains(child))
        XCTAssertEqual(store.query, "keep search")
        XCTAssertTrue(store.fileOperationUndo.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.fileOperationSummary).contains("成功 1"))
    }

    func testUndoCancellationBetweenItemsRetainsUnattemptedRecords() throws {
        try fixture { source, target, files in
            let result = try transfer(files, target)
            let trash = source.appendingPathComponent("isolated-trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            let control = FileOperationControl(title: "撤销", total: 3)
            let undo = FileOperationUndo.perform(result.undo, control: control, trash: { url in
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                control.cancel()
                return destination
            })
            XCTAssertEqual(undo.succeeded, 1)
            XCTAssertEqual(control.progress.completed, 1)
            XCTAssertEqual(undo.remaining.map(\.current.lastPathComponent), ["a.txt", "b.txt"])
            XCTAssertEqual(try names(target), ["a.txt", "b.txt"])
            XCTAssertEqual(try names(trash), ["c.txt"])
        }
    }

    func testReplacedCommittedCopyIsNotAdoptedByUndoRecord() throws {
        try fixture { _, target, files in
            var io = WorkspaceFileTransfer.IO()
            let rename = io.rename
            io.rename = { source, destination in
                try rename(source, destination)
                try Data("replacement after commit".utf8).write(to: destination, options: .atomic)
            }
            let result = try transfer([files[0]], target, io: io)
            XCTAssertEqual(result.succeeded, 1)
            XCTAssertTrue(result.undo.isEmpty)
            XCTAssertEqual(result.warnings.count, 1)
            XCTAssertTrue(result.warnings[0].contains("已被替换"))
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.txt")), "replacement after commit")
        }
    }

    func testStagedCopyPreservesSymlinkAndPackageContents() throws {
        try fixture { source, target, files in
            let link = source.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files[0].url)
            let package = source.appendingPathComponent("document.rtfd", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try Data("package".utf8).write(to: package.appendingPathComponent("content"))
            let references = try [link, package].map { BrowserFileReference(url: $0, identity: try FileSystem.identity(at: $0)) }
            let result = try transfer(references, target)
            XCTAssertEqual(result.succeeded, 2)
            XCTAssertEqual(result.undo.count, 2)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link.txt").path), files[0].url.path)
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("document.rtfd/content")), "package")
            XCTAssertEqual(try names(target), ["document.rtfd", "link.txt"])
            XCTAssertEqual(try String(contentsOf: files[0].url), "a.txt")
        }
    }

    func testCrossVolumeFallbackSuccessUsesCopiedIdentityForUndo() throws {
        try fixture { _, target, files in
            var io = WorkspaceFileTransfer.IO()
            let rename = io.rename
            io.rename = { source, destination in
                if source == files[0].url { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)) }
                try rename(source, destination)
            }
            let result = try transfer([files[0]], target, move: true, io: io)
            XCTAssertEqual(result.succeeded, 1)
            XCTAssertEqual(result.undo.count, 1)
            XCTAssertNotEqual(result.undo.first?.identity, files[0].identity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].url.path))
            let undo = FileOperationUndo.perform(result.undo, control: .init(title: "撤销", total: 1))
            XCTAssertEqual(undo.succeeded, 1)
            XCTAssertEqual(try String(contentsOf: files[0].url), "a.txt")
        }
    }

    private func transfer(_ files: [BrowserFileReference], _ target: URL, move: Bool = false, rename: Bool = false,
                          control: FileOperationControl? = nil, io: WorkspaceFileTransfer.IO = .init()) throws -> WorkspaceFileTransfer.Result {
        WorkspaceFileTransfer.perform(files, into: target, expectedIdentity: try FileSystem.identity(at: target),
                                      move: move, renameConflicts: rename, control: control, io: io)
    }
    private func names(_ directory: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }
    private func fixture(_ body: (URL, URL, [BrowserFileReference]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeck-F4-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true), target = root.appendingPathComponent("target", isDirectory: true)
        for url in [source, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let files = try ["a.txt", "b.txt", "c.txt"].map { name -> BrowserFileReference in
            let url = source.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return BrowserFileReference(url: url, identity: try FileSystem.identity(at: url))
        }
        try body(source, target, files)
    }
    private func settled(_ store: BrowserStore) async throws {
        let deadline = Date().addingTimeInterval(10)
        while store.isFileOperationBusy || store.isLoading || !store.treeLoading.isEmpty {
            guard Date() < deadline else { throw WorkspaceFileTransfer.failure("测试等待超时") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
