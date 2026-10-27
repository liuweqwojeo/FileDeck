import Combine
import Darwin
import Foundation
import XCTest
@testable import FileWorkbench

/// 实际 vnode 通知验证 Finder 同类文件操作；闸门控制后台枚举，避免用耗时阈值证明性能。
@MainActor
final class ExternalDirectorySyncTests: XCTestCase {
    func testExternalCreateRenameAndDeletePreserveMultipleSelectionAndNavigation() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", in: root), b = try write("b.md", in: root)
        let store = try await opened(root)
        store.query = ".md"; store.typeFilter = .documents; store.sortByModified = true; store.gridView = true
        store.setSelection([a, b], primary: a)
        let history = store.history, expanded = store.expandedDirectories
        let added = try write("added.md", in: root)
        try await wait { store.entries.contains { $0.url == added } }
        XCTAssertEqual(store.selectedURLs, [a, b])
        let renamed = root.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: a, to: renamed)
        try await wait { store.selectedURL == renamed }
        XCTAssertEqual(store.selectedURLs, [renamed, b])
        try FileManager.default.removeItem(at: renamed)
        try await wait { !store.entries.contains { $0.url == renamed } }
        XCTAssertNil(store.selectedURL)
        XCTAssertEqual(store.selectedURLs, [b])
        XCTAssertEqual(store.currentDirectory, root); XCTAssertEqual(store.rootURL, root)
        XCTAssertEqual(store.history, history); XCTAssertEqual(store.expandedDirectories, expanded)
        XCTAssertEqual(store.query, ".md"); XCTAssertEqual(store.typeFilter, .documents)
        XCTAssertTrue(store.gridView); XCTAssertTrue(store.sortByModified)
    }

    func testAtomicReplacementAndFilteredRenameNeverInheritSelection() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", in: root), store = try await opened(root)
        store.selectedURL = a
        let identity = store.selectedEntry?.identity
        try Data("replacement".utf8).write(to: a, options: .atomic)
        try await wait { store.entries.first?.identity != identity }
        XCTAssertNil(store.selectedURL); XCTAssertTrue(store.selectedURLs.isEmpty)
        store.query = "a.md"; store.selectedURL = a
        try FileManager.default.moveItem(at: a, to: root.appendingPathComponent("b.md"))
        try await wait { store.entries.first?.name == "b.md" }
        XCTAssertEqual(store.query, "a.md"); XCTAssertTrue(store.visibleEntries.isEmpty); XCTAssertNil(store.selectedURL)
    }

    func testHardLinkAmbiguousRenameDoesNotChooseAnotherPath() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", in: root), b = root.appendingPathComponent("b.md")
        try FileManager.default.linkItem(at: a, to: b)
        let store = try await opened(root); store.setSelection([a, b], primary: a)
        let c = root.appendingPathComponent("c.md")
        try FileManager.default.moveItem(at: a, to: c)
        try await wait { store.entries.contains { $0.url == c } }
        XCTAssertEqual(store.selectedURLs, [b]); XCTAssertNil(store.selectedURL)
    }

    func testPassiveReadKeepsListMountedAndCommitsLatestSelection() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", in: root), b = try write("b.md", in: root)
        let probe = ReadGate(); defer { probe.release() }
        let store = try await opened(root, probe: probe); store.selectedURL = a
        let previous = store.entries, revision = store.revision
        var loading = false
        let token = store.$isLoading.dropFirst().sink { loading = loading || $0 }
        defer { token.cancel() }
        probe.block(root)
        let c = try write("c.md", in: root)
        try await wait { probe.isWaiting }
        XCTAssertEqual(store.entries, previous); XCTAssertEqual(store.revision, revision)
        store.query = ".md"; store.selectedURL = b
        probe.release()
        try await wait { store.entries.contains { $0.url == c } && !store.isSynchronizingExternalChanges }
        XCTAssertEqual(store.selectedURL, b); XCTAssertEqual(store.query, ".md"); XCTAssertFalse(loading)
    }

    func testChangesDuringReadScheduleOneTrailingReadWithoutLosingEvents() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("a.md", in: root)
        let probe = ReadGate(); defer { probe.release() }
        let store = try await opened(root, probe: probe), before = probe.calls
        probe.block(root)
        _ = try write("first.md", in: root)
        try await wait { probe.isWaiting }
        for i in 0..<25 { _ = try write("burst-\(i).md", in: root) }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(probe.calls, before + 1, "在途刷新不能为每个事件启动并行枚举")
        probe.release()
        try await wait { store.entries.count == 27 && !store.isSynchronizingExternalChanges }
        XCTAssertEqual(probe.calls, before + 2, "变化版本不能被旧结果清除")
        XCTAssertLessThanOrEqual(probe.maximumActive, 2)
    }

    func testNavigationRejectsOldPassiveResultAndKeepsForwardHistory() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let probe = ReadGate(); defer { probe.release() }
        let store = try await opened(root, probe: probe)
        probe.block(root); _ = try write("old.md", in: root)
        try await wait { probe.isWaiting }
        store.navigate(to: child)
        try await wait { !store.isLoading && store.currentDirectory == child }
        let next = try write("new.md", in: child)
        probe.release()
        try await wait { store.entries.contains { $0.url == next } }
        XCTAssertEqual(store.currentDirectory, child); XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.entries.contains { $0.name == "old.md" })
        store.goBack(); try await wait { !store.isLoading && store.currentDirectory == root }
        XCTAssertTrue(store.canGoForward)
        _ = try write("another.md", in: root)
        try await wait { store.entries.contains { $0.name == "another.md" } }
        XCTAssertTrue(store.canGoForward); XCTAssertEqual(store.history, [root, child])
    }

    func testPreviewDefersEventsAndCloseUsesIdentityProtectedSnapshot() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("draft.md", in: root), store = try await opened(root)
        store.selectedURL = a
        let snapshot = store.capturePreviewSnapshot(source: "external-sync-test"), entries = store.entries
        let renamed = root.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: a, to: renamed)
        let added = try write("added.md", in: root)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(store.entries, entries); XCTAssertEqual(store.selectedURL, a)
        XCTAssertFalse(store.isSynchronizingExternalChanges)
        await store.refreshAfterPreview(snapshot: snapshot)
        try await wait { store.entries.contains { $0.url == added } }
        XCTAssertEqual(store.selectedURL, renamed)
    }

    func testCurrentDirectoryRenamedDuringPreviewRestoresSelectionAfterClose() async throws {
        let base = try makeRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let a = try write("a.md", in: root), store = try await opened(root)
        store.selectedURL = a
        let snapshot = store.capturePreviewSnapshot(source: "renamed-directory-preview")
        let next = base.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: next)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.currentDirectory, root); XCTAssertEqual(store.selectedURL, a)
        await store.refreshAfterPreview(snapshot: snapshot)
        try await wait { store.currentDirectory == next && store.directoryIssue == nil && !store.isSynchronizingExternalChanges }
        XCTAssertEqual(store.selectedURL, next.appendingPathComponent("a.md"))
        XCTAssertEqual(store.history, [next]); XCTAssertFalse(store.isLoading)
    }

    func testPreviewOpenedDuringReadAlsoDefersTheCompletion() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("draft.md", in: root), probe = ReadGate(); defer { probe.release() }
        let store = try await opened(root, probe: probe); store.selectedURL = a
        probe.block(root); let added = try write("added.md", in: root)
        try await wait { probe.isWaiting }
        let snapshot = store.capturePreviewSnapshot(source: "opened-during-read"), previous = store.entries
        probe.release(); try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.entries, previous); XCTAssertEqual(store.selectedURL, a)
        await store.refreshAfterPreview(snapshot: snapshot)
        try await wait { store.entries.contains { $0.url == added } }
    }

    func testExpandedBranchesUpdateAndCollapsedDescendantsAreNotEnumerated() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let probe = ReadGate(), store = try await opened(root, probe: probe)
        store.toggleExpanded(parent); try await wait { store.treeChildren[parent] != nil && store.treeLoading.isEmpty }
        let added = parent.appendingPathComponent("Added", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: false)
        try await wait { store.treeChildren[parent]?.contains { $0.url == added } == true }
        store.toggleExpanded(child); try await wait { store.treeChildren[child] != nil && store.treeLoading.isEmpty }
        store.toggleExpanded(parent)
        try await Task.sleep(for: .milliseconds(550)); let reads = probe.callsAt(child)
        try FileManager.default.createDirectory(at: child.appendingPathComponent("Invisible"), withIntermediateDirectories: false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(probe.callsAt(child), reads)
        XCTAssertTrue(store.expandedDirectories.contains(child)); XCTAssertEqual(store.currentDirectory, root)
    }

    func testRepeatedExternalAncestorRenameRebasesRootHistoryTreeAndSelection() async throws {
        let base = try makeRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Root", isDirectory: true)
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        _ = try write("a.md", in: child)
        let store = try await opened(root)
        store.toggleExpanded(child); store.navigate(to: child)
        try await wait { !store.isLoading && store.treeLoading.isEmpty }
        store.selectedURL = child.appendingPathComponent("a.md")
        for name in ["Renamed", "RenamedAgain"] {
            let previous = store.rootURL!, next = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.moveItem(at: previous, to: next)
            let current = next.appendingPathComponent("Child", isDirectory: true)
            try await wait { store.currentDirectory == current && store.selectedURL == current.appendingPathComponent("a.md") }
            XCTAssertEqual(store.rootURL, next); XCTAssertEqual(store.managedRoots, [next])
            XCTAssertEqual(store.history, [next, current]); XCTAssertTrue(store.expandedDirectories.contains(current))
            XCTAssertFalse(store.isLoading)
            let added = try write("\(name).md", in: current)
            try await wait { store.entries.contains { $0.url == added } }
        }
    }

    func testExternalExpandedChildRenamePreservesExpansionAndFilteredSelection() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let store = try await opened(root)
        store.toggleExpanded(child); try await wait { store.treeLoading.isEmpty && store.treeChildren[child] != nil }
        store.query = "Child"; store.selectedURL = child
        let next = root.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: child, to: next)
        try await wait { store.entries.contains { $0.url == next } && store.expandedDirectories.contains(next) }
        XCTAssertFalse(store.expandedDirectories.contains(child)); XCTAssertNil(store.selectedURL)
        XCTAssertEqual(store.query, "Child"); XCTAssertEqual(store.history, [root])
    }

    func testDeletedDirectoryRetainsLastSnapshotAndRejectsSamePathReplacementUntilExplicitRefresh() async throws {
        let base = try makeRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let a = try write("original.md", in: root), store = try await opened(root)
        store.selectedURL = a; let previous = store.entries
        try FileManager.default.removeItem(at: root)
        try await wait { store.directoryIssue != nil }
        XCTAssertEqual(store.entries, previous); XCTAssertEqual(store.selectedURL, a)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try write("replacement.md", in: root)
        store.checkForExternalChanges()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(store.entries, previous); XCTAssertNotNil(store.directoryIssue)
        store.refresh()
        try await wait { !store.isLoading && store.entries.first?.name == "replacement.md" }
        XCTAssertNil(store.selectedURL); XCTAssertNil(store.directoryIssue)
    }

    func testForegroundNoOpCheckReusesDisplaySnapshotAndSelectionAndOptOutSkipsReads() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", in: root), probe = ReadGate(), store = try await opened(root, probe: probe)
        store.selectedURL = a
        let display = store.displaySnapshot, revision = store.revision, calls = probe.calls
        store.checkForExternalChanges()
        try await wait { probe.calls > calls && !store.isSynchronizingExternalChanges }
        XCTAssertTrue(display === store.displaySnapshot); XCTAssertEqual(store.revision, revision); XCTAssertEqual(store.selectedURL, a)
        let disabled = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        disabled.openRoot(root, remember: false); try await wait { !disabled.isLoading }
        _ = try write("b.md", in: root); disabled.checkForExternalChanges()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(disabled.entries.count, 1)
    }

    func testRemovingManagedRootRetiresNotificationsAndInFlightResults() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ReadGate(); defer { probe.release() }
        let store = try await opened(root, probe: probe)
        probe.block(root); _ = try write("a.md", in: root)
        try await wait { probe.isWaiting }
        store.removeManagedRoot(root); probe.release()
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertNil(store.currentDirectory); XCTAssertTrue(store.entries.isEmpty); XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(store.isSynchronizingExternalChanges)
    }

    func testExternalRenameKeepsShiftSelectionAnchor() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.md", "b.md", "c.md", "d.md"] { _ = try write(name, in: root) }
        let store = try await opened(root)
        store.select(store.orderedEntries[0]); store.select(store.orderedEntries[2], extending: true)
        let renamed = root.appendingPathComponent("aa.md")
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.md"), to: renamed)
        try await wait { store.selectedURLs.contains(renamed) }
        store.select(store.orderedEntries[3], extending: true)
        XCTAssertEqual(store.selectedURLs, Set(store.entries.map(\.url)), "自动同步必须恢复原 Shift 锚点，不能改成主选择")
    }

    func testFileOperationDefersExternalEventsUntilBatchCompletes() async throws {
        let base = try makeRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("IsolatedTrash", isDirectory: true)
        for url in [root, destination] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let a = try write("a.md", in: root), b = try write("b.md", in: root), store = try await opened(root)
        store.selectedURL = b; let previous = store.entries
        let gate = TrashGate(); defer { gate.release() }
        let rows = store.entries.filter { $0.url == a }
        let batch = Task { await store.trashFiles(rows, using: { url in
            gate.wait()
            let target = destination.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
        }) }
        try await wait { gate.started && store.isTrashing }
        let added = try write("added.md", in: root)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.entries, previous); XCTAssertEqual(store.selectedURL, b)
        gate.release(); let result = await batch.value
        XCTAssertEqual(result?.succeeded.count, 1)
        try await wait { !store.isLoading && !store.isSynchronizingExternalChanges && store.entries.contains { $0.url == added } }
        XCTAssertEqual(store.selectedURL, b); XCTAssertFalse(store.entries.contains { $0.url == a })
    }

    func testObserverCapsDescriptorsAndReleasesThemWithOwner() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var targets: [BrowserDirectoryObserver.Target] = []
        for i in 0..<(BrowserDirectoryObserver.maximumSubscriptions + 5) {
            let directory = root.appendingPathComponent("d\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            targets.append(.init(url: directory, identity: try FileSystem.identity(at: directory)))
        }
        let events = EventProbe()
        var observer: BrowserDirectoryObserver? = BrowserDirectoryObserver { events.record($0) }
        observer?.setTargets(targets + targets)
        try await wait { events.urls.count == BrowserDirectoryObserver.maximumSubscriptions }
        XCTAssertEqual(events.urls, Set(targets.prefix(BrowserDirectoryObserver.maximumSubscriptions).map(\.url)))
        observer = nil
        try await Task.sleep(for: .milliseconds(200)); let count = events.count
        _ = try write("retired.md", in: targets[0].url)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(events.count, count, "owner 释放必须取消源，不能让旧通知继续回调")
    }

    func testDirectoryIdentityIsRecheckedAfterAnInFlightRead() async throws {
        let base = try makeRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Root", isDirectory: true)
        let moved = base.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try write("old.md", in: root)
        let identity = try FileSystem.identity(at: root), probe = ReadGate()
        probe.block(root); defer { probe.release() }
        let loader = BrowserDirectoryLoader(read: { try probe.read($0, $1) })
        let pending = Task {
            await withCheckedContinuation { continuation in
                _ = loader.request(root, hidden: false, generation: UUID(), expectedIdentity: identity) {
                    continuation.resume(returning: $0)
                }
            }
        }
        try await wait { probe.isWaiting }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try write("new.md", in: root)
        probe.release()
        let result = await pending.value
        XCTAssertThrowsError(try result.get(), "开始时身份相同不能掩盖枚举期间的目录替换")
    }

    func testDescriptorIdentityMatchesDirectoryAndRejectsFilesAndClosedDescriptors() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = open(root.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(try FileSystem.identity(ofDescriptor: descriptor), try FileSystem.identity(at: root))
        close(descriptor)
        XCTAssertThrowsError(try FileSystem.identity(ofDescriptor: descriptor))
        let file = try write("a.md", in: root), fileDescriptor = open(file.path, O_EVTONLY | O_CLOEXEC)
        defer { close(fileDescriptor) }
        XCTAssertThrowsError(try FileSystem.identity(ofDescriptor: fileDescriptor))
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeck-F2-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @discardableResult private func write(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }
    private func opened(_ root: URL, probe: ReadGate? = nil) async throws -> BrowserStore {
        let store = BrowserStore(restoreLastLocation: false, directoryReader: { url, hidden in
            if let probe { return try probe.read(url, hidden) }
            return try BrowserDirectorySnapshot.read(url, showHidden: hidden)
        })
        store.openRoot(root, remember: false)
        try await wait { !store.isLoading && store.treeLoading.isEmpty }
        // 注册 catch-up 也需完成，后续读次数断言只针对真实外部变动。
        try await Task.sleep(for: .milliseconds(500))
        try await wait { !store.isSynchronizingExternalChanges }
        return store
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("外部目录同步等待超时")
        throw NSError(domain: "ExternalDirectorySyncTests", code: 1)
    }
}

private final class EventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BrowserDirectoryObserver.Event] = []
    func record(_ event: BrowserDirectoryObserver.Event) { lock.withLock { events.append(event) } }
    var urls: Set<URL> { lock.withLock { Set(events.map(\.url)) } }
    var count: Int { lock.withLock { events.count } }
}

private final class ReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: URL?
    private var waiting = 0
    private var counts: [URL: Int] = [:]
    private var active = 0
    private var maximum = 0
    var calls: Int { condition.withLock { counts.values.reduce(0, +) } }
    var maximumActive: Int { condition.withLock { maximum } }
    var isWaiting: Bool { condition.withLock { waiting > 0 } }
    func callsAt(_ url: URL) -> Int { condition.withLock { counts[url, default: 0] } }
    func block(_ url: URL) { condition.withLock { blocked = url } }
    func release() { condition.withLock { blocked = nil; condition.broadcast() } }
    func read(_ url: URL, _ hidden: Bool) throws -> BrowserDirectorySnapshot {
        condition.withLock { counts[url, default: 0] += 1; active += 1; maximum = max(maximum, active) }
        defer { condition.withLock { active -= 1 } }
        let snapshot = try BrowserDirectorySnapshot.read(url, showHidden: hidden)
        condition.lock()
        if blocked == url {
            waiting += 1
            while blocked == url { condition.wait() }
            waiting -= 1
        }
        condition.unlock()
        return snapshot
    }
}

private final class TrashGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = true
    private var didStart = false
    var started: Bool { condition.withLock { didStart } }
    func wait() {
        condition.lock(); didStart = true
        while blocked { condition.wait() }
        condition.unlock()
    }
    func release() { condition.withLock { blocked = false; condition.broadcast() } }
}
