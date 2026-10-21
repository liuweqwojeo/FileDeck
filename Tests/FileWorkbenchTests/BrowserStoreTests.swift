import Foundation
import XCTest
@testable import FileWorkbench

/// 使用临时目录验证导航与刷新，不依赖 UI 自动化或用户上次打开的文件夹。
@MainActor
final class BrowserStoreTests: XCTestCase {
    func testRefreshPreservesExpandedTreeAndCurrentDirectory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = BrowserStore(restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.toggleExpanded(parent)
        try await settled(store)
        store.toggleExpanded(child)
        store.navigate(to: child)
        try await settled(store)

        try Data("new".utf8).write(to: child.appendingPathComponent("new.txt"))
        store.refresh()
        try await settled(store)

        XCTAssertTrue(store.expandedDirectories.contains(parent))
        XCTAssertTrue(store.expandedDirectories.contains(child))
        XCTAssertEqual(store.currentDirectory, child)
        XCTAssertEqual(store.entries.map(\.name), ["new.txt"])
    }

    func testBackForwardAndNewNavigationReplaceForwardHistory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = BrowserStore(restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.navigate(to: first)
        try await settled(store)
        store.goBack()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, root)
        XCTAssertFalse(store.canGoUp)
        XCTAssertTrue(store.canGoForward)
        store.goForward()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, first)
        store.goBack()
        store.navigate(to: second)
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, second)
        XCTAssertFalse(store.canGoForward)
        XCTAssertEqual(store.history, [root, second])
    }

    func testFilterClearsHiddenSelection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hello.txt")
        try Data("preview".utf8).write(to: file)
        let store = BrowserStore(restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.selectedURL = file
        XCTAssertNotNil(store.selectedEntry)
        store.query = "no-match"
        store.updateSearchSelection()
        XCTAssertNil(store.selectedURL)
        XCTAssertTrue(store.visibleEntries.isEmpty)
    }

    func testOpeningFileChangesDirectoryClearsSearchAndPreservesSelectionOnRefresh() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent("Previous", isDirectory: true)
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("selected.txt")
        try Data("preview".utf8).write(to: file)
        let store = BrowserStore(restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.navigate(to: previous)
        try await settled(store)
        store.query = "old-search"

        store.openFile(file, remember: false)
        try await settled(store)

        XCTAssertEqual(store.rootURL, target)
        XCTAssertEqual(store.currentDirectory, target)
        XCTAssertEqual(store.history, [root, previous, target])
        XCTAssertEqual(store.query, "")
        XCTAssertEqual(store.selectedEntry?.url, file)
        XCTAssertNil(store.actionError)
        store.refresh()
        try await settled(store)
        XCTAssertEqual(store.selectedEntry?.url, file)
    }

    func testLatestOpenOrNavigationWinsOverPendingFileSelection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("First", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("Second", isDirectory: true)
        let child = firstDirectory.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("first.txt")
        let second = secondDirectory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let store = BrowserStore(restoreLastLocation: false)

        // 不等待第一次枚举，验证后续打开与导航都会使旧请求失效。
        store.openFile(first, remember: false)
        store.openFile(second, remember: false)
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, secondDirectory)
        XCTAssertEqual(store.selectedEntry?.url, second)
        XCTAssertEqual(store.entries.map(\.url), [second])

        store.openFile(first, remember: false)
        store.navigate(to: child)
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, child)
        XCTAssertNil(store.selectedURL)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.history, [firstDirectory, secondDirectory, firstDirectory, child])
    }

    func testOpeningHiddenFileSurvivesSearchAndVisibilityCallbacks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".hidden.txt")
        try Data("hidden".utf8).write(to: file)
        let store = BrowserStore(restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        XCTAssertTrue(store.entries.isEmpty)
        store.query = "old-search"

        store.openFile(file, remember: false)
        // 模拟搜索词清空和显示隐藏文件变更触发的 SwiftUI 回调；此时目录仍在读取。
        store.updateSearchSelection()
        store.refresh()
        try await settled(store)

        XCTAssertTrue(store.showHidden)
        XCTAssertEqual(store.query, "")
        XCTAssertEqual(store.selectedEntry?.url, file)
        XCTAssertEqual(store.visibleEntries.map(\.url), [file])
    }

    func testOpeningPackageAndSymbolicLinksPreservesListedFileIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Documents", isDirectory: true)
        let package = parent.appendingPathComponent("Document.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("original.txt")
        let fileLink = parent.appendingPathComponent("shortcut.txt")
        let parentLink = root.appendingPathComponent("LinkedDocuments", isDirectory: true)
        try Data("content".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: parent)
        let store = BrowserStore(restoreLastLocation: false)

        store.openFile(package, remember: false)
        try await settled(store)
        XCTAssertEqual(store.selectedEntry?.url, package)
        XCTAssertEqual(store.selectedEntry?.isPackage, true)
        XCTAssertEqual(store.selectedEntry?.isBrowsableDirectory, false)

        store.openFile(fileLink, remember: false)
        try await settled(store)
        XCTAssertEqual(store.selectedEntry?.url, fileLink)
        XCTAssertEqual(store.selectedEntry?.isSymbolicLink, true)

        store.openFile(parentLink.appendingPathComponent("original.txt"), remember: false)
        try await settled(store)
        XCTAssertEqual(store.rootURL, parent)
        XCTAssertEqual(store.currentDirectory, parent)
        XCTAssertEqual(store.selectedEntry?.url, file)
    }

    func testInvalidFileSelectionLeavesExistingNavigationUnchanged() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Folder", isDirectory: true)
        let file = root.appendingPathComponent("selected.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: file)
        let store = BrowserStore(restoreLastLocation: false)
        store.openFile(file, remember: false)
        try await settled(store)
        store.query = "selected"
        let previousEntries = store.entries

        for invalid in [root.appendingPathComponent("missing.txt"), directory] {
            store.openFile(invalid, remember: false)
            XCTAssertNotNil(store.actionError)
            XCTAssertEqual(store.rootURL, root)
            XCTAssertEqual(store.currentDirectory, root)
            XCTAssertEqual(store.history, [root])
            XCTAssertEqual(store.historyIndex, 0)
            XCTAssertEqual(store.query, "selected")
            XCTAssertEqual(store.selectedEntry?.url, file)
            XCTAssertEqual(store.entries, previousEntries)
            XCTAssertFalse(store.isLoading)
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserStoreTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: root.path, isDirectory: true)
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
