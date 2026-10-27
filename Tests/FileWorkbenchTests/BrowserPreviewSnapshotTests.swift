import Foundation
import XCTest
@testable import FileWorkbench

/// 使用真实目录与磁盘身份验证恢复，不以同路径或模拟文件事件代替实际文件变化。
@MainActor
final class BrowserPreviewSnapshotTests: XCTestCase {
    func testCloseKeepsDirectoryFiltersTreeViewAndMultipleSelectionWithoutLoadingState() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let first = try write("one.md", in: root)
        let second = try write("two.md", in: root)
        let store = try await opened(root)
        store.toggleExpanded(folder)
        store.query = ".md"
        store.typeFilter = .documents
        store.sortByModified = true
        store.gridView = true
        store.setSelection([first, second], primary: first)
        let before = store.capturePreviewSnapshot(source: "space")
        let history = store.history
        let entries = store.entries

        let closing = Task { await store.refreshAfterPreview(snapshot: before) }
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.entries, entries)
        await closing.value

        XCTAssertEqual(store.currentDirectory, root)
        XCTAssertEqual(store.history, history)
        XCTAssertEqual(store.query, ".md")
        XCTAssertEqual(store.typeFilter, .documents)
        XCTAssertEqual(store.selectedURLs, [first, second])
        XCTAssertEqual(store.selectedURL, first)
        XCTAssertEqual(store.expandedDirectories, before.expandedDirectories)
        XCTAssertTrue(store.gridView)
        XCTAssertTrue(store.sortByModified)
        XCTAssertEqual(before.source, "space")
    }

    func testDeletedFileClearsOnlyInvalidSelection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deleted = try write("deleted.md", in: root)
        let retained = try write("retained.md", in: root)
        let store = try await opened(root)
        store.setSelection([deleted, retained], primary: deleted)
        let snapshot = store.capturePreviewSnapshot(source: "doubleClick")
        try FileManager.default.removeItem(at: deleted)

        await store.refreshAfterPreview(snapshot: snapshot)

        XCTAssertEqual(store.selectedURLs, [retained])
        XCTAssertNil(store.selectedURL, "原主选择删除后不能自动选中其他文件")
        XCTAssertEqual(store.entries.map(\.url), [retained])
        XCTAssertEqual(store.currentDirectory, root)
    }

    func testSameNameReplacementDoesNotInheritSelection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try write("document.md", in: root)
        let replacement = try write("replacement.md", in: root)
        let store = try await opened(root)
        store.selectedURL = original
        let snapshot = store.capturePreviewSnapshot(source: "contextMenu")
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: replacement, to: original)

        await store.refreshAfterPreview(snapshot: snapshot)

        XCTAssertNil(store.selectedURL)
        XCTAssertTrue(store.selectedURLs.isEmpty)
        XCTAssertEqual(store.entries.map(\.url), [original])
        XCTAssertNotEqual(store.entries.first?.identity, snapshot.primarySelection?.identity)
    }

    func testReliableRenameFollowsIdentityButDoesNotChangeFilter() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try write("original.md", in: root)
        let renamed = root.appendingPathComponent("renamed.md")
        let store = try await opened(root)
        store.query = ".md"
        store.selectedURL = original
        let snapshot = store.capturePreviewSnapshot(source: "doubleClick")
        try FileManager.default.moveItem(at: original, to: renamed)
        await store.refreshAfterPreview(snapshot: snapshot)
        XCTAssertEqual(store.selectedURL, renamed)
        XCTAssertEqual(store.selectedEntry?.identity, snapshot.primarySelection?.identity)
        XCTAssertEqual(store.query, ".md")

        store.query = "renamed"
        let filtered = store.capturePreviewSnapshot(source: "space")
        let hidden = root.appendingPathComponent("different.md")
        try FileManager.default.moveItem(at: renamed, to: hidden)
        await store.refreshAfterPreview(snapshot: filtered)
        XCTAssertEqual(store.query, "renamed")
        XCTAssertNil(store.selectedURL)
        XCTAssertTrue(store.visibleEntries.isEmpty)
    }

    func testOnlyExplicitSuccessfulSaveCanRebindAtomicReplacementIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("saved.md", in: root)
        let store = try await opened(root)
        store.selectedURL = file
        let snapshot = store.capturePreviewSnapshot(source: "space")
        try Data("saved content".utf8).write(to: file, options: .atomic)

        await store.refreshAfterPreview(snapshot: snapshot, savedURL: file)

        XCTAssertEqual(store.selectedURL, file)
        XCTAssertNotEqual(store.selectedEntry?.identity, snapshot.primarySelection?.identity)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "saved content")
    }

    func testOldModalResultCannotRestoreAfterNewSessionOrNavigation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("a.md", in: root)
        let second = try write("b.md", in: root)
        let store = try await opened(root)
        store.selectedURL = first
        let stale = store.capturePreviewSnapshot(source: "space")
        store.selectedURL = second
        let latest = store.capturePreviewSnapshot(source: "space")
        await store.refreshAfterPreview(snapshot: stale)
        XCTAssertEqual(store.selectedURL, second)
        await store.refreshAfterPreview(snapshot: latest)
        XCTAssertEqual(store.selectedURL, second)

        let folder = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let beforeNavigation = store.capturePreviewSnapshot(source: "space")
        store.navigate(to: folder)
        try await settled(store)
        await store.refreshAfterPreview(snapshot: beforeNavigation)
        XCTAssertEqual(store.currentDirectory, folder)
        XCTAssertNil(store.selectedURL)

        store.navigate(to: root)
        try await settled(store)
        store.selectedURL = first
        await store.refreshAfterPreview(snapshot: beforeNavigation)
        XCTAssertEqual(store.selectedURL, first, "导航后即使返回同一路径，旧弹窗快照也已失效")
    }

    func testShiftAndCommandSelectionUseDisplayedOrderWithoutOpeningFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.md", "b.md", "c.md", "d.md"] { _ = try write(name, in: root) }
        let store = try await opened(root)
        let rows = store.orderedEntries
        store.select(rows[0])
        store.select(rows[2], extending: true)
        XCTAssertEqual(store.selectedURLs, Set(rows.prefix(3).map(\.url)))
        store.select(rows[1], toggling: true)
        XCTAssertEqual(store.selectedURLs, [rows[0].url, rows[2].url])
        XCTAssertEqual(store.currentDirectory, root)
        XCTAssertEqual(store.history, [root])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeckPreview-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return URL(fileURLWithPath: root.path, isDirectory: true)
    }

    private func write(_ name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(name.utf8).write(to: file)
        return file
    }

    private func opened(_ directory: URL) async throws -> BrowserStore {
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openQuickLocation(directory)
        try await settled(store)
        return store
    }

    private func settled(_ store: BrowserStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading || !store.treeLoading.isEmpty {
            if Date() >= deadline { XCTFail("目录读取超时"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.directoryError)
    }
}
