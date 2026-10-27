import Foundation
import XCTest
@testable import FileWorkbench

/// 工作区测试使用独立 UserDefaults 与临时目录，避免修改真实管理列表和启动状态。
@MainActor
final class WorkspaceStateTests: XCTestCase {
    func testEveryLaunchWaitsForExplicitContinueEvenAfterSkippingWelcome() async throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = BrowserStore(observesExternalChanges: false, defaults: defaults)
        XCTAssertEqual(first.startupPhase, .welcome)
        XCTAssertNil(first.currentDirectory)
        XCTAssertTrue(first.managedRoots.isEmpty)
        first.skipWelcome()
        XCTAssertEqual(first.startupPhase, .ready)
        let restored = BrowserStore(observesExternalChanges: false, defaults: defaults)
        XCTAssertEqual(restored.startupPhase, .welcome)
        XCTAssertNil(restored.currentDirectory)
        restored.skipWelcome()
        XCTAssertEqual(restored.startupPhase, .restoring)
        try await settled(restored)
        XCTAssertEqual(restored.startupPhase, .ready)
        XCTAssertNil(restored.currentDirectory)
        XCTAssertTrue(restored.managedRoots.isEmpty)
    }

    func testMultipleRootsCurrentDirectoryAndExpansionPersist() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let child = first.appendingPathComponent("Child", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BrowserStore(observesExternalChanges: false, defaults: defaults)
        store.openRoot(first)
        try await settled(store)
        store.toggleExpanded(child)
        store.openRoot(second)
        try await settled(store)
        store.navigate(to: child)
        try await settled(store)
        XCTAssertEqual(store.managedRoots, [first, second])
        XCTAssertEqual(store.rootURL, first)
        let restored = BrowserStore(observesExternalChanges: false, defaults: defaults)
        XCTAssertEqual(restored.startupPhase, .welcome)
        XCTAssertNil(restored.currentDirectory)
        restored.skipWelcome()
        try await settled(restored)
        XCTAssertEqual(restored.managedRoots, [first, second])
        XCTAssertEqual(restored.currentDirectory, child)
        XCTAssertTrue(restored.expandedDirectories.contains(child))
        XCTAssertTrue(restored.expandedDirectories.contains(first))
        XCTAssertNil(restored.selectedURL)
    }

    func testQuickLocationDoesNotBecomeManagedRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openQuickLocation(root)
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, root)
        XCTAssertEqual(store.rootURL, root)
        XCTAssertTrue(store.managedRoots.isEmpty)
    }

    func testWelcomeDoesNotReadSavedDirectoryOrRewriteWorkspace() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = BrowserStore(observesExternalChanges: false, defaults: defaults)
        first.openRoot(root)
        try await settled(first)
        let previous = defaults.data(forKey: "FileWorkbench.workspace.v1")
        try FileManager.default.removeItem(at: root)

        let relaunched = BrowserStore(observesExternalChanges: false, defaults: defaults)
        await Task.yield()
        XCTAssertEqual(relaunched.startupPhase, .welcome)
        XCTAssertTrue(relaunched.hasPreviousWorkspace)
        XCTAssertNil(relaunched.currentDirectory)
        XCTAssertNil(relaunched.directoryIssue)
        XCTAssertTrue(relaunched.treeLoading.isEmpty)
        XCTAssertFalse(relaunched.isLoading)
        XCTAssertEqual(defaults.data(forKey: "FileWorkbench.workspace.v1"), previous)

        relaunched.skipWelcome()
        try await settled(relaunched)
        XCTAssertEqual(relaunched.directoryIssue, .unavailable)
        XCTAssertEqual(relaunched.managedRoots, [root])
    }

    func testExplicitOpenFromWelcomeKeepsSavedRootsAndUsesRequestedFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = other.appendingPathComponent("file.txt")
        try Data("hello".utf8).write(to: file)
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = BrowserStore(observesExternalChanges: false, defaults: defaults)
        first.openRoot(root)
        try await settled(first)

        let relaunched = BrowserStore(observesExternalChanges: false, defaults: defaults)
        relaunched.openFile(file)
        try await settled(relaunched)
        XCTAssertEqual(relaunched.startupPhase, .ready)
        XCTAssertEqual(relaunched.currentDirectory, other)
        XCTAssertEqual(relaunched.selectedURL, file)
        XCTAssertEqual(relaunched.managedRoots, [root, other])
    }

    func testCommandLineOpenBypassesWelcomeWithoutChangingRememberedWorkspace() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/remembered", forKey: "FileWorkbench.lastRoot")
        let store = BrowserStore(observesExternalChanges: false, defaults: defaults, arguments: ["FileWorkbench", "--open", root.path])
        try await settled(store)
        XCTAssertEqual(store.startupPhase, .ready)
        XCTAssertEqual(store.currentDirectory, root)
        XCTAssertEqual(defaults.string(forKey: "FileWorkbench.lastRoot"), "/remembered")
        XCTAssertNil(defaults.data(forKey: "FileWorkbench.workspace.v1"))
    }

    func testRapidNavigationKeepsExpandedTreeLoadingIndependentFromCancelledList() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let child = first.appendingPathComponent("Child", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)

        // 不让异步列表返回：在同一主线程回合内展开后立即切走，复现原先丢失树结果的时序。
        store.navigate(to: first)
        store.toggleExpanded(first)
        store.navigate(to: second)
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, second)
        XCTAssertTrue(store.expandedDirectories.contains(first))
        XCTAssertEqual(store.treeChildren[first]?.map(\.url), [child])
        XCTAssertFalse(store.treeLoading.contains(first))
    }

    func testRemovalInvalidatesPendingResultsAndNeverDeletesDiskContents() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BrowserStore(observesExternalChanges: false, defaults: defaults)
        store.openRoot(root)
        store.removeManagedRoot(root)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(store.currentDirectory)
        XCTAssertNil(store.rootURL)
        XCTAssertTrue(store.managedRoots.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.treeChildren.isEmpty)
        XCTAssertFalse(store.isLoading)
        let restored = BrowserStore(observesExternalChanges: false, defaults: defaults)
        XCTAssertEqual(restored.startupPhase, .welcome)
        XCTAssertNil(restored.currentDirectory)
        restored.skipWelcome()
        try await settled(restored)
        XCTAssertTrue(restored.managedRoots.isEmpty)
        XCTAssertNil(restored.currentDirectory)
    }

    func testUnavailableRootIsRetainedAndDoesNotBlockRestoration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("disconnected", isDirectory: true)
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BrowserStore(observesExternalChanges: false, defaults: defaults)
        store.openRoot(missing)
        try await settled(store)
        XCTAssertEqual(store.directoryIssue, .unavailable)
        XCTAssertEqual(store.managedRoots, [missing])
        let restored = BrowserStore(observesExternalChanges: false, defaults: defaults)
        XCTAssertEqual(restored.startupPhase, .welcome)
        XCTAssertNil(restored.currentDirectory)
        restored.skipWelcome()
        try await settled(restored)
        XCTAssertEqual(restored.startupPhase, .ready)
        XCTAssertEqual(restored.directoryIssue, .unavailable)
        XCTAssertEqual(restored.managedRoots, [missing])
        XCTAssertNotNil(restored.treeErrors[missing])
        restored.openQuickLocation(root)
        try await settled(restored)
        XCTAssertNil(restored.directoryIssue)
        XCTAssertEqual(restored.managedRoots, [missing])
    }

    func testRelocationReplacesReferenceWithoutRemovingEitherFolder() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(original, remember: false)
        try await settled(store)
        store.replaceManagedRoot(original, with: replacement)
        try await settled(store)
        XCTAssertEqual(store.managedRoots, [replacement])
        XCTAssertEqual(store.currentDirectory, replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testHiddenOnlyFolderIsNotReportedAsTrulyEmpty() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.directoryIsTrulyEmpty)
        XCTAssertTrue(store.hasActiveFilters)
        store.showHidden = true
        store.refresh()
        try await settled(store)
        XCTAssertEqual(store.visibleEntries.count, 1)
        XCTAssertFalse(store.directoryIsTrulyEmpty)
    }

    func testFilterClearsPreviewAndResetRestoresAllEntries() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: file)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.selectedURL = file
        store.typeFilter = .folders
        XCTAssertNil(store.selectedURL)
        XCTAssertTrue(store.visibleEntries.isEmpty)
        store.query = "no match"
        store.resetFilters()
        XCTAssertEqual(store.visibleEntries.map(\.url), [file])
        XCTAssertNil(store.selectedURL)
        XCTAssertEqual(store.query, "")
    }

    func testCreateFolderRejectsTraversalAndExistingNameWithoutOverwriting() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.createFolder(named: "../escape")
        XCTAssertNotNil(store.actionError)
        store.actionError = nil
        store.createFolder(named: "new")
        try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path) }
        try await settled(store)
        store.createFolder(named: "new")
        try await waitUntil { store.actionError != nil }
        XCTAssertNotNil(store.actionError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
    }

    func testClearCurrentDirectoryCancelsPendingPreviewAndPersistsEmptySelection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("keep".utf8).write(to: file)
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BrowserStore(observesExternalChanges: false, defaults: defaults)
        store.openRoot(root)
        store.selectedURL = file
        store.clearCurrentDirectory()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(store.currentDirectory)
        XCTAssertNil(store.selectedEntry)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.managedRoots, [root])
        let restored = BrowserStore(observesExternalChanges: false, defaults: defaults)
        XCTAssertEqual(restored.startupPhase, .welcome)
        XCTAssertNil(restored.currentDirectory)
        restored.skipWelcome()
        try await settled(restored)
        XCTAssertNil(restored.currentDirectory)
        XCTAssertEqual(restored.managedRoots, [root])
    }

    func testDirectoryIdentityAcceptsPathURLWithoutTrailingSlash() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathOnly = URL(fileURLWithPath: root.path, isDirectory: false)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.openRoot(pathOnly, remember: false)
        try await settled(store)
        XCTAssertEqual(store.managedRoots, [root])
        store.removeManagedRoot(pathOnly)
        XCTAssertTrue(store.managedRoots.isEmpty)
        XCTAssertNil(store.currentDirectory)
    }

    func testQuickLocationHistorySurvivesSwitchAndReplacesForwardBranch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        let third = root.appendingPathComponent("Third", isDirectory: true)
        for folder in [first, second, third] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openQuickLocation(first)
        store.openQuickLocation(second)
        try await settled(store)
        XCTAssertTrue(store.canGoBack)
        store.goBack()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, first)
        XCTAssertEqual(store.rootURL, first)
        XCTAssertTrue(store.canGoForward)
        store.openQuickLocation(third)
        try await settled(store)
        XCTAssertEqual(store.history, [first, third])
        XCTAssertFalse(store.canGoForward)
        XCTAssertTrue(store.managedRoots.isEmpty)
    }

    func testDroppedFilesCopyWithoutOverwritingOrRemovingSources() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let target = root.appendingPathComponent("Target", isDirectory: true)
        for folder in [source, target] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let duplicate = source.appendingPathComponent("exists.txt")
        let new = source.appendingPathComponent("new.txt")
        let existing = target.appendingPathComponent("exists.txt")
        try Data("source".utf8).write(to: duplicate)
        try Data("new".utf8).write(to: new)
        try Data("preserve".utf8).write(to: existing)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openQuickLocation(target)
        try await settled(store)
        store.importFiles([duplicate, new])
        try await waitUntil { !store.isImporting && !store.isLoading }
        XCTAssertEqual(try String(contentsOf: existing), "preserve")
        XCTAssertEqual(try String(contentsOf: duplicate), "source")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("new.txt")), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        XCTAssertNotNil(store.actionError)
        XCTAssertEqual(Set(store.entries.map(\.name)), ["exists.txt", "new.txt"])
    }

    func testDroppedAncestorAndSelfAreRejectedAndNavigationDoesNotJumpBack() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openQuickLocation(target)
        try await settled(store)
        store.importFiles([root, target])
        store.clearCurrentDirectory()
        try await waitUntil { !store.isImporting }
        XCTAssertNil(store.currentDirectory)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.actionError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testPermissionAndUnavailableErrorsHaveDifferentRecoveryKinds() {
        XCTAssertEqual(BrowserStore.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), .permission)
        XCTAssertEqual(BrowserStore.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .permission)
        XCTAssertEqual(BrowserStore.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)), .unavailable)
        XCTAssertEqual(BrowserStore.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))), .readFailure)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "WorkspaceStateTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceStateTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.path, isDirectory: true)
    }

    private func settled(_ store: BrowserStore) async throws {
        try await waitUntil { !store.isLoading && store.treeLoading.isEmpty && store.startupPhase != .restoring }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline { XCTFail("异步操作超时"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
