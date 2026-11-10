import Foundation
import XCTest
@testable import FileWorkbench

/// 验证真实目录的排序、导航和预览恢复；高亮断言检查展示属性，不复制搜索算法。
@MainActor
final class WorkspaceInteractionPolishTests: XCTestCase {
    func testSortColumnsToggleDirectionKeepFoldersFirstAndSelection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        for (name, size, date) in [("a.txt", 1, 300.0), ("b.txt", 9, 100.0), ("c.json", 4, 200.0)] {
            let file = root.appendingPathComponent(name)
            try Data(repeating: 65, count: size).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: file.path)
        }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false); try await settled(store)
        let selected = root.appendingPathComponent("b.txt")
        store.selectedURL = selected
        store.sort(by: .size)
        XCTAssertEqual(store.orderedEntries.map(\.name), ["Folder", "b.txt", "c.json", "a.txt"])
        store.sort(by: .size)
        XCTAssertEqual(store.orderedEntries.map(\.name), ["Folder", "a.txt", "c.json", "b.txt"])
        store.sort(by: .modified)
        XCTAssertEqual(store.orderedEntries.map(\.name), ["Folder", "a.txt", "c.json", "b.txt"])
        store.sort(by: .modified)
        XCTAssertEqual(store.orderedEntries.map(\.name), ["Folder", "b.txt", "c.json", "a.txt"])
        store.sort(by: .name); store.sort(by: .name)
        XCTAssertEqual(store.orderedEntries.map(\.name), ["Folder", "c.json", "b.txt", "a.txt"])
        store.sort(by: .type)
        let ascendingTypes = store.orderedEntries.dropFirst().map(\.typeLabel)
        store.sort(by: .type)
        XCTAssertEqual(store.orderedEntries.first?.name, "Folder")
        XCTAssertEqual(store.orderedEntries.dropFirst().map(\.typeLabel), Array(ascendingTypes.reversed()))
        XCTAssertEqual(store.selectedURLs, [selected])
    }

    func testBreadcrumbNavigationStaysInsideRootAndResetsFilters() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("项目", isDirectory: true)
        let child = parent.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false); try await settled(store)
        store.navigate(to: child); try await settled(store)
        XCTAssertEqual(store.breadcrumbDirectories.map(\.path), [root.path, parent.path, child.path])
        store.query = "old"; store.typeFilter = .images
        store.navigate(to: store.breadcrumbDirectories[1]); try await settled(store)
        XCTAssertEqual(store.currentDirectory?.path, parent.path)
        XCTAssertEqual(store.breadcrumbDirectories.map(\.path), [root.path, parent.path])
        XCTAssertEqual(store.query, ""); XCTAssertEqual(store.typeFilter, .all)
    }

    func testPreviewRestoresFullSortAndFilterState() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("text".utf8).write(to: root.appendingPathComponent("sample.txt"))
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false); try await settled(store)
        store.sortKey = .size; store.sortAscending = false
        store.typeFilter = .documents; store.query = "sample"
        let snapshot = store.capturePreviewSnapshot(source: "space")
        await store.refreshAfterPreview(snapshot: snapshot)
        XCTAssertEqual(store.sortKey, .size); XCTAssertFalse(store.sortAscending)
        XCTAssertEqual(store.typeFilter, .documents); XCTAssertEqual(store.query, "sample")
    }

    func testSortPreferencesMigrateAndPersistColumnAndDirection() {
        let suite = "FileDeck-polish-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "FileWorkbench.sortByModified")
        let legacy = BrowserStore(observesExternalChanges: false, defaults: defaults, arguments: [])
        XCTAssertEqual(legacy.sortKey, .modified); XCTAssertFalse(legacy.sortAscending)
        legacy.sort(by: .type); legacy.sort(by: .type)
        let restored = BrowserStore(observesExternalChanges: false, defaults: defaults, arguments: [])
        XCTAssertEqual(restored.sortKey, .type); XCTAssertFalse(restored.sortAscending)
    }

    func testSearchHighlightPreservesUnicodeAndHonorsCaseSensitivity() {
        let value = "中文😀 Needle needle e\u{301}"
        let insensitive = WorkspaceSearchHighlight.text(value, term: "needle", caseSensitive: false)
        XCTAssertEqual(String(insensitive.characters), value)
        XCTAssertEqual(insensitive.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.count, 2)
        let sensitive = WorkspaceSearchHighlight.text(value, term: "Needle", caseSensitive: true)
        XCTAssertEqual(sensitive.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.count, 1)
        let emoji = WorkspaceSearchHighlight.text(value, term: "中文😀", caseSensitive: false)
        XCTAssertEqual(String(emoji.characters), value)
        XCTAssertEqual(emoji.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.count, 1)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeck-polish-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func settled(_ store: BrowserStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading || !store.treeLoading.isEmpty {
            guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.directoryError)
    }
}
