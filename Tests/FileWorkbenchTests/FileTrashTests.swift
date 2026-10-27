import Foundation
import XCTest
@testable import FileWorkbench

/// 使用临时隔离目录模拟系统移走动作；身份检查仍调用真实 lstat，不触及用户废纸篓。
@MainActor
final class FileTrashTests: XCTestCase {
    func testContextMenuUsesExplicitListSelectionAndGridFallsBackToClickedItem() async throws {
        try await fixture { root, _, store in
            let rows = store.orderedEntries
            store.setSelection([rows[0].url, rows[1].url], primary: rows[0].url)
            XCTAssertEqual(store.fileActionEntries(for: rows[1]), Array(rows.prefix(2)))
            XCTAssertEqual(store.fileActionEntries(for: rows[2]), [rows[2]])
            XCTAssertEqual(store.fileActionEntries(for: rows[0], contextSelection: [rows[1].url, rows[2].url]), Array(rows.suffix(2)))
            XCTAssertEqual(store.fileActionEntries(for: rows[0], contextSelection: []), [])
            let frozen = store.fileActionEntries(for: rows[1])
            store.selectedURL = rows[2].url
            store.query = "c.txt"
            XCTAssertEqual(frozen.map(\.url), rows.prefix(2).map(\.url))
            XCTAssertEqual(Set(frozen.compactMap(\.identity)).count, 2)
            XCTAssertEqual(store.currentDirectory, root)
        }
    }

    func testActionTargetsFollowSelectionFilterSortAndRefreshedIdentity() async throws {
        try await fixture { _, _, store in
            let rows = store.orderedEntries
            for (index, row) in rows.enumerated() {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: row.url.path)
            }
            store.refresh()
            try await settled(store)
            store.setSelection([rows[0].url, rows[1].url], primary: rows[0].url)
            XCTAssertEqual(store.fileActionEntries(for: rows[0]).map(\.url), [rows[0].url, rows[1].url])
            store.sortByModified = true
            XCTAssertEqual(store.fileActionEntries(for: rows[0]).map(\.url), [rows[1].url, rows[0].url])
            store.query = "a.txt"
            XCTAssertEqual(store.selectedFileEntries.map(\.url), [rows[0].url])
            store.resetFilters()
            store.setSelection([rows[0].url, rows[1].url], primary: rows[0].url)
            let frozen = store.fileActionEntries(for: rows[0])
            try Data("replaced".utf8).write(to: rows[1].url, options: .atomic)
            store.refresh()
            try await settled(store)
            XCTAssertEqual(store.selectedFileEntries.map(\.url), [rows[0].url])
            XCTAssertEqual(frozen.count, 2)
            XCTAssertNotEqual(frozen.first { $0.url == rows[1].url }?.identity,
                              store.entries.first { $0.url == rows[1].url }?.identity)
        }
    }

    func testWholeBatchMovesOnceAndClearsOnlyRemovedSelection() async throws {
        try await fixture { root, destination, store in
            let rows = store.orderedEntries
            store.setSelection(Set(rows.prefix(2).map(\.url)), primary: rows[0].url)
            let probe = TrashProbe(destination)
            let value = await store.trashFiles(Array(rows.prefix(2)) + [rows[0]], using: { try probe.trash($0) })
            let result = try XCTUnwrap(value)
            try await settled(store)
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result.succeeded, Array(rows.prefix(2)))
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertNil(result.failureSummary)
            XCTAssertEqual(probe.calls, rows.prefix(2).map(\.url))
            XCTAssertEqual(store.entries.map(\.url), [rows[2].url])
            XCTAssertTrue(store.selectedURLs.isEmpty)
            XCTAssertNil(store.selectedURL)
            XCTAssertNil(store.actionError)
            XCTAssertFalse(store.isTrashing)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.txt").path))
        }
    }

    func testPartialFailureContinuesAndRetainsFailedSelectionWithCountsAndReason() async throws {
        try await fixture { _, destination, store in
            let rows = store.orderedEntries
            store.setSelection(Set(rows.map(\.url)), primary: rows[1].url)
            let probe = TrashProbe(destination, denied: [rows[1].url])
            let value = await store.trashFiles(rows, using: { try probe.trash($0) })
            let result = try XCTUnwrap(value)
            try await settled(store)
            XCTAssertEqual(result.succeeded.map(\.url), [rows[0].url, rows[2].url])
            XCTAssertEqual(result.failures.map(\.file.url), [rows[1].url])
            XCTAssertEqual(probe.calls, rows.map(\.url), "中间一项失败也应继续后项")
            XCTAssertEqual(store.selectedURLs, [rows[1].url])
            XCTAssertEqual(store.selectedURL, rows[1].url)
            XCTAssertEqual(try String(contentsOf: rows[1].url), "b.txt")
            let summary = try XCTUnwrap(store.actionError)
            XCTAssertTrue(summary.contains("2 个项目移到废纸篓，1 个项目未完成（共 3 个）"))
            XCTAssertTrue(summary.contains("b.txt"))
            XCTAssertTrue(summary.contains("测试拒绝"))
        }
    }

    func testMissingAndReplacedFilesNeverReachTrashOperationAndDoNotStopValidItem() async throws {
        try await fixture { _, destination, store in
            let rows = store.orderedEntries
            store.setSelection(Set(rows.map(\.url)), primary: rows[1].url)
            try FileManager.default.removeItem(at: rows[0].url)
            try Data("replacement".utf8).write(to: rows[1].url, options: .atomic)
            let probe = TrashProbe(destination)
            let value = await store.trashFiles(rows, using: { try probe.trash($0) })
            let result = try XCTUnwrap(value)
            try await settled(store)
            XCTAssertEqual(probe.calls, [rows[2].url])
            XCTAssertEqual(result.failures.map(\.file.url), rows.prefix(2).map(\.url))
            XCTAssertEqual(result.succeeded.map(\.url), [rows[2].url])
            XCTAssertEqual(try String(contentsOf: rows[1].url), "replacement")
            XCTAssertTrue(store.selectedURLs.isEmpty, "新 inode 不能继承失败旧项目的选择")
            XCTAssertTrue(try XCTUnwrap(result.failureSummary).contains("2 个项目未完成（共 3 个）"))
        }
    }

    func testIdentityIsRecheckedImmediatelyBeforeEachItemRatherThanOnlyBatchStart() async throws {
        try await fixture { _, destination, store in
            let rows = store.orderedEntries
            let first = rows[0].url, changed = rows[1].url
            let value = await store.trashFiles(rows, using: { url in
                try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
                if url == first { try Data("changed during batch".utf8).write(to: changed, options: .atomic) }
            })
            let result = try XCTUnwrap(value)
            try await settled(store)
            XCTAssertEqual(result.succeeded.map(\.url), [rows[0].url, rows[2].url])
            XCTAssertEqual(result.failures.map(\.file.url), [changed])
            XCTAssertEqual(try String(contentsOf: changed), "changed during batch")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("b.txt").path))
        }
    }

    func testMissingIdentityAndNonFileURLAreRejectedWithoutInventingCurrentIdentity() async throws {
        try await fixture { _, destination, store in
            let row = store.orderedEntries[0]
            func entry(_ url: URL, _ identity: FileIdentity?) -> FileEntry {
                FileEntry(url: url, name: "invalid", isDirectory: false, isPackage: false, isSymbolicLink: false,
                          size: nil, modifiedAt: nil, typeIdentifier: nil, identity: identity)
            }
            let probe = TrashProbe(destination)
            let value = await store.trashFiles([entry(row.url, nil), entry(URL(string: "https://example.invalid/item")!, row.identity)], using: { try probe.trash($0) })
            let result = try XCTUnwrap(value)
            try await settled(store)
            XCTAssertEqual(result.succeeded.count, 0)
            XCTAssertEqual(result.failures.count, 2)
            XCTAssertTrue(probe.calls.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: row.url.path))
            XCTAssertTrue(try XCTUnwrap(result.failureSummary).contains("共 2 个"))
        }
    }

    func testHardLinksSymlinkAndPackageAreSeparateDirectoryEntries() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("isolated-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.txt")
        try Data("target must remain".utf8).write(to: target)
        let original = source.appendingPathComponent("original.txt")
        try Data("hard link".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: source.appendingPathComponent("hard-link.txt"))
        let link = source.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let package = source.appendingPathComponent("Document.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("package content".utf8).write(to: package.appendingPathComponent("content.txt"))
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(source, remember: false)
        try await settled(store)
        let rows = store.entries
        let probe = TrashProbe(destination)
        let value = await store.trashFiles(rows, using: { try probe.trash($0) })
        let result = try XCTUnwrap(value)
        try await settled(store)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.succeeded.count, 4, "不能按 inode 去重硬链接")
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try String(contentsOf: target), "target must remain")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link.txt").path), target.path)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Document.rtfd/content.txt")), "package content")
    }

    func testFrozenBatchIgnoresLaterSelectionAndBlocksSecondTrashAndImport() async throws {
        try await fixture { _, destination, store in
            let rows = store.orderedEntries
            store.setSelection(Set(rows.prefix(2).map(\.url)), primary: rows[0].url)
            let frozen = store.fileActionEntries(for: rows[0])
            let probe = TrashProbe(destination, blocked: true)
            defer { probe.release() }
            let operation = Task { await store.trashFiles(frozen, using: { try probe.trash($0) }) }
            try await wait { !probe.calls.isEmpty }
            XCTAssertTrue(store.isTrashing)
            XCTAssertTrue(store.isFileOperationBusy)
            store.selectedURL = rows[2].url
            let refused = await store.trashFiles([rows[2]], using: { try probe.trash($0) })
            XCTAssertNil(refused)
            store.importFiles([rows[2].url])
            XCTAssertFalse(store.isImporting)
            XCTAssertNotNil(store.actionError)
            probe.release()
            _ = await operation.value
            try await settled(store)
            XCTAssertEqual(probe.calls, frozen.map(\.url))
            XCTAssertEqual(store.selectedURLs, [rows[2].url])
            XCTAssertTrue(FileManager.default.fileExists(atPath: rows[2].url.path))
            XCTAssertFalse(store.isFileOperationBusy)
        }
    }

    func testCompletionRefreshesLatestDirectoryWithoutRestoringOldNavigationOrQuery() async throws {
        try await fixture { root, destination, store in
            let frozen = [store.orderedEntries[0]]
            let other = root.appendingPathComponent("Other", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let survivor = other.appendingPathComponent("other.txt")
            try Data("other".utf8).write(to: survivor)
            let probe = TrashProbe(destination, blocked: true)
            defer { probe.release() }
            let operation = Task { await store.trashFiles(frozen, using: { try probe.trash($0) }) }
            try await wait { !probe.calls.isEmpty }
            store.navigate(to: other, selecting: survivor)
            try await settled(store)
            store.query = "other"
            let history = store.history
            probe.release()
            _ = await operation.value
            try await settled(store)
            XCTAssertEqual(store.currentDirectory, other)
            XCTAssertEqual(store.query, "other")
            XCTAssertEqual(store.history, history)
            XCTAssertEqual(store.selectedURLs, [survivor])
        }
    }

    func testAllFailuresReleaseBusyStateAndCanRetryWithoutLosingSelection() async throws {
        try await fixture { _, destination, store in
            let rows = store.orderedEntries
            store.setSelection(Set(rows.map(\.url)), primary: rows[0].url)
            let denied = TrashProbe(destination, denied: Set(rows.map(\.url)))
            let first = await store.trashFiles(rows, using: { try denied.trash($0) })
            try await settled(store)
            XCTAssertEqual(first?.failures.count, 3)
            XCTAssertFalse(store.isFileOperationBusy)
            XCTAssertEqual(store.selectedURLs, Set(rows.map(\.url)))
            XCTAssertTrue(try XCTUnwrap(store.actionError).contains("0 个项目移到废纸篓，3 个项目未完成"))
            let retry = TrashProbe(destination)
            let second = await store.trashFiles(store.fileActionEntries(for: rows[0]), using: { try retry.trash($0) })
            try await settled(store)
            XCTAssertEqual(second?.succeeded.count, 3)
            XCTAssertNil(store.actionError)
            XCTAssertTrue(store.selectedURLs.isEmpty)
        }
    }

    func testImportInProgressRejectsTrashAndEmptyBatchDoesNothing() async throws {
        try await fixture { root, destination, store in
            let probe = TrashProbe(destination)
            let empty = await store.trashFiles([], using: { try probe.trash($0) })
            XCTAssertNil(empty)
            XCTAssertFalse(store.isFileOperationBusy)
            XCTAssertNil(store.actionError)
            let file = root.deletingLastPathComponent().appendingPathComponent("FileDeckF1-import-\(UUID()).txt")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data("import".utf8).write(to: file)
            store.importFiles([file])
            XCTAssertTrue(store.isImporting)
            let refused = await store.trashFiles(store.entries, using: { try probe.trash($0) })
            XCTAssertNil(refused)
            XCTAssertTrue(probe.calls.isEmpty)
            try await wait { !store.isImporting && !store.isLoading && store.treeLoading.isEmpty }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file.lastPathComponent).path))
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeckF1-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: root.path, isDirectory: true)
    }
    private func fixture(_ body: (URL, URL, BrowserStore) async throws -> Void) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("isolated-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(source, remember: false)
        try await settled(store)
        try await body(source, destination, store)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw NSError(domain: "F1TestTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    private func settled(_ store: BrowserStore) async throws {
        try await wait { !store.isLoading && store.treeLoading.isEmpty }
        XCTAssertNil(store.directoryError)
    }
}

/// 后端只把项目移到测试目录；可控失败/等待用于证明逐项校验、冻结范围与忙碌门禁。
private final class TrashProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let destination: URL
    private let denied: Set<URL>
    private var blocked: Bool
    private var recorded: [URL] = []
    init(_ destination: URL, denied: Set<URL> = [], blocked: Bool = false) {
        self.destination = destination; self.denied = denied; self.blocked = blocked
    }
    var calls: [URL] { condition.lock(); defer { condition.unlock() }; return recorded }
    func release() { condition.lock(); blocked = false; condition.broadcast(); condition.unlock() }
    func trash(_ url: URL) throws {
        condition.lock()
        recorded.append(url)
        while blocked { condition.wait() }
        condition.unlock()
        if denied.contains(url) { throw NSError(domain: "FileDeckF1.Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试拒绝"]) }
        try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
    }
}
