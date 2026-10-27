import Foundation
import XCTest
@testable import FileWorkbench

/// 直接执行浏览器实际重命名命令，验证磁盘结果与工作区引用一起提交。
@MainActor
final class BrowserRenameTests: XCTestCase {
    func testRenamingDirectoryRebasesNestedRootsHistoryExpansionAndSelection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Old", isDirectory: true)
        let managed = source.appendingPathComponent("Managed", isDirectory: true)
        let child = managed.appendingPathComponent("Child", isDirectory: true)
        let sibling = root.appendingPathComponent("sibling.txt")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("unchanged".utf8).write(to: sibling)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        let entry = try XCTUnwrap(store.entries.first { $0.url == source })
        store.openRoot(source, remember: false)
        try await settled(store)
        store.openRoot(managed, remember: false)
        try await settled(store)
        store.navigate(to: child)
        store.toggleExpanded(child)
        try await settled(store)
        store.navigate(to: root)
        try await settled(store)
        store.setSelection([source, sibling], primary: source)

        let destination = try await store.rename(entry, to: "New")
        try await settled(store)
        let movedManaged = destination.appendingPathComponent("Managed", isDirectory: true)
        let movedChild = movedManaged.appendingPathComponent("Child", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedChild.path))
        XCTAssertEqual(store.managedRoots, [root, destination, movedManaged])
        XCTAssertEqual(store.currentDirectory, root)
        XCTAssertEqual(store.rootURL, root)
        XCTAssertEqual(store.history, [root, destination, movedManaged, movedChild, root])
        XCTAssertEqual(store.selectedURLs, [destination, sibling])
        XCTAssertEqual(store.selectedURL, destination)
        XCTAssertTrue(store.expandedDirectories.isSuperset(of: [destination, movedManaged, movedChild]))
        XCTAssertFalse(store.treeChildren.keys.contains { $0.path.hasPrefix(source.path) })
        XCTAssertFalse(store.treeErrors.keys.contains { $0.path.hasPrefix(source.path) })

        // 后退不仅要进入新路径，还必须保留该历史项当时关联的嵌套管理根。
        store.goBack()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, movedChild)
        XCTAssertEqual(store.rootURL, movedManaged)
        store.goForward()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, root)
        XCTAssertEqual(store.rootURL, root)
    }

    func testRenamingAncestorPersistsRebasedCurrentDirectoryAndBookmarks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Old", isDirectory: true)
        let child = source.appendingPathComponent("Child", isDirectory: true)
        let file = child.appendingPathComponent("selected.txt")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: file)
        let suite = "BrowserRenameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserStore(observesExternalChanges: false, defaults: defaults, arguments: [])
        store.openRoot(root)
        try await settled(store)
        let entry = try XCTUnwrap(store.entries.first { $0.url == source })
        store.openRoot(source)
        try await settled(store)
        store.navigate(to: child, selecting: file)
        store.toggleExpanded(child)
        try await settled(store)

        let destination = try await store.rename(entry, to: "New")
        try await settled(store)
        let movedChild = destination.appendingPathComponent("Child", isDirectory: true)
        XCTAssertEqual(store.currentDirectory, movedChild)
        XCTAssertEqual(store.rootURL, destination)
        XCTAssertEqual(store.selectedURL, movedChild.appendingPathComponent("selected.txt"))

        let data = try XCTUnwrap(defaults.data(forKey: "FileWorkbench.workspace.v1"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let roots = try XCTUnwrap(saved["roots"] as? [[String: Any]])
        XCTAssertEqual(roots.compactMap { $0["path"] as? String }, [root.path, destination.path])
        XCTAssertEqual(saved["currentPath"] as? String, movedChild.path)
        XCTAssertFalse((saved["expandedPaths"] as? [String] ?? []).contains { $0.hasPrefix(source.path) })

        // 真正重新创建 store 并解析保存的书签，避免只验证内存中的路径映射。
        let restored = BrowserStore(observesExternalChanges: false, defaults: defaults, arguments: [])
        restored.skipWelcome()
        try await settled(restored)
        XCTAssertEqual(restored.managedRoots, [root, destination])
        XCTAssertEqual(restored.currentDirectory, movedChild)
        XCTAssertEqual(restored.rootURL, destination)
        XCTAssertTrue(restored.expandedDirectories.isSuperset(of: [destination, movedChild]))
    }

    func testRenameConflictLeavesDiskAndWorkspaceSnapshotUnchanged() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Old", isDirectory: true)
        let occupied = root.appendingPathComponent("Occupied", isDirectory: true)
        for directory in [source, occupied] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let suite = "BrowserRenameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserStore(observesExternalChanges: false, defaults: defaults, arguments: [])
        store.openRoot(root)
        try await settled(store)
        let entry = try XCTUnwrap(store.entries.first { $0.url == source })
        store.openRoot(source)
        try await settled(store)
        store.navigate(to: root, selecting: source)
        try await settled(store)
        let previousEntries = store.entries
        let previousHistory = store.history
        let previousExpanded = store.expandedDirectories
        let previousRevision = store.revision
        let previousSaved = defaults.data(forKey: "FileWorkbench.workspace.v1")

        do {
            try await store.rename(entry, to: "Occupied")
            XCTFail("同名目录必须拒绝覆盖")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("同名"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.path))
        XCTAssertEqual(store.managedRoots, [root, source])
        XCTAssertEqual(store.currentDirectory, root)
        XCTAssertEqual(store.rootURL, root)
        XCTAssertEqual(store.selectedURL, source)
        XCTAssertEqual(store.entries, previousEntries)
        XCTAssertEqual(store.history, previousHistory)
        XCTAssertEqual(store.expandedDirectories, previousExpanded)
        XCTAssertEqual(store.revision, previousRevision)
        XCTAssertEqual(defaults.data(forKey: "FileWorkbench.workspace.v1"), previousSaved)
        XCTAssertFalse(store.isLoading)
    }

    func testRenameIntoUnavailableManagedRootPrefersMovedDirectoryBookmark() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Old", isDirectory: true)
        let destination = root.appendingPathComponent("New", isDirectory: true)
        for directory in [source, destination] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Child", isDirectory: true), withIntermediateDirectories: true)
        }
        let file = source.appendingPathComponent("retained.txt")
        try Data("moved directory".utf8).write(to: file)
        let suite = "BrowserRenameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserStore(observesExternalChanges: false, defaults: defaults, arguments: [])
        store.openRoot(root)
        try await settled(store)
        let entry = try XCTUnwrap(store.entries.first { $0.url == source })
        store.openRoot(source)
        try await settled(store)
        store.navigate(to: source.appendingPathComponent("Child", isDirectory: true))
        try await settled(store)
        // 先从父管理根访问旧目标子目录，再把旧目标设为管理根，制造不同的历史根归属。
        store.navigate(to: destination.appendingPathComponent("Child", isDirectory: true))
        try await settled(store)
        XCTAssertEqual(store.rootURL, root)
        store.openRoot(destination)
        try await settled(store)
        store.navigate(to: root)
        try await settled(store)
        let previousData = try XCTUnwrap(defaults.data(forKey: "FileWorkbench.workspace.v1"))
        let previousWorkspace = try XCTUnwrap(JSONSerialization.jsonObject(with: previousData) as? [String: Any])
        let previousRoots = try XCTUnwrap(previousWorkspace["roots"] as? [[String: Any]])
        let staleBookmark = try XCTUnwrap(previousRoots.first { $0["path"] as? String == destination.path }?["bookmark"] as? String)

        // 失效的管理引用应被保留供用户修复；同名真实目录被删除后，重命名可以合法占用该路径。
        try FileManager.default.removeItem(at: destination)
        let renamed = try await store.rename(entry, to: "New")
        try await settled(store)
        XCTAssertEqual(renamed, destination)
        XCTAssertEqual(store.managedRoots, [root, destination], "迁移后只保留首个同路径管理位置")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("retained.txt")), "moved directory")
        let savedData = try XCTUnwrap(defaults.data(forKey: "FileWorkbench.workspace.v1"))
        let savedWorkspace = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        let savedRoots = try XCTUnwrap(savedWorkspace["roots"] as? [[String: Any]])
        XCTAssertEqual(savedRoots.compactMap { $0["path"] as? String }, [root.path, destination.path])
        let movedBookmark = try XCTUnwrap(savedRoots.first { $0["path"] as? String == destination.path }?["bookmark"] as? String)
        XCTAssertNotEqual(movedBookmark, staleBookmark, "旧目标根的书签不能覆盖真实迁移对象的新书签")
        store.goBack()
        try await settled(store)
        store.goBack()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, destination.appendingPathComponent("Child", isDirectory: true))
        XCTAssertEqual(store.rootURL, destination, "同路径历史冲突时使用真实迁移子树的根归属")

        let restored = BrowserStore(observesExternalChanges: false, defaults: defaults, arguments: [])
        restored.skipWelcome()
        try await settled(restored)
        XCTAssertEqual(restored.managedRoots, [root, destination])
        restored.navigate(to: destination)
        try await settled(restored)
        XCTAssertEqual(Set(restored.entries.map(\.name)), ["Child", "retained.txt"])
    }

    func testReplacedSourceCannotBeRenamedUsingStaleEntry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        let entry = try XCTUnwrap(store.entries.first)
        store.selectedURL = source
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("preserved.txt"))
        try Data("replacement".utf8).write(to: source)
        let previousRevision = store.revision

        do {
            try await store.rename(entry, to: "renamed.txt")
            XCTFail("旧快照不能重命名同名替换文件")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("文件已发生变化"))
        }
        XCTAssertEqual(try String(contentsOf: source), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path))
        XCTAssertEqual(store.selectedURL, source)
        XCTAssertEqual(store.revision, previousRevision)
    }

    func testNavigationAfterRenameStartsIsNotReplacedByCompletion() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Old", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        for directory in [source, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        let entry = try XCTUnwrap(store.entries.first { $0.url == source })
        var started = false
        let operation = Task { @MainActor in
            started = true
            return try await store.rename(entry, to: "New")
        }
        while !started { await Task.yield() }
        store.navigate(to: other)
        _ = try await operation.value
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, other)
        XCTAssertEqual(store.history.last, other)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("New").path))
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserRenameTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.path, isDirectory: true)
    }

    private func settled(_ store: BrowserStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading || !store.treeLoading.isEmpty || store.startupPhase == .restoring {
            if Date() >= deadline { XCTFail("目录读取超时"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.directoryError)
    }
}
