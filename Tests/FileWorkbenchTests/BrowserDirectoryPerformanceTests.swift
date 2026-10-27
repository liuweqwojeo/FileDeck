import Foundation
import XCTest
@testable import FileWorkbench

/// 用真实文件验证身份，用可控读取闸门验证慢卷时序；不把机器相关的耗时阈值当正确性断言。
@MainActor
final class BrowserDirectoryPerformanceTests: XCTestCase {
    func testTenThousandSelectionRefreshAndPreviewRestoreReuseDisplaySnapshot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 大表身份来自确定性快照；真实硬链接和原子替换由下方及原快照回归单独覆盖。
        let rows = (0..<10_000).map { index in
            FileEntry(url: root.appendingPathComponent(String(format: "%05d.md", index)), name: "item-\(index).md",
                      isDirectory: false, isPackage: false, isSymbolicLink: false, size: 1,
                      modifiedAt: Date(timeIntervalSince1970: Double(index)), typeIdentifier: "net.daringfireball.markdown",
                      identity: FileIdentity(device: 1, inode: UInt64(index + 1), birthSeconds: 1, birthNanoseconds: 0))
        }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false, directoryReader: { _, _ in
            BrowserDirectorySnapshot(entries: rows, trulyEmpty: false)
        })
        store.openRoot(root, remember: false)
        try await settled(store)
        store.sortByModified = true
        let display = store.displaySnapshot
        let urls = Set(rows.map(\.url))
        store.setSelection(urls, primary: rows[4999].url)
        let snapshot = store.capturePreviewSnapshot(source: "large-directory")
        for _ in 0..<20 {
            XCTAssertTrue(display === store.displaySnapshot)
            XCTAssertEqual(store.visibleEntries.count, 10_000)
            XCTAssertEqual(store.orderedEntries.first?.url, rows.last?.url)
            XCTAssertEqual(store.selectedEntry?.url, rows[4999].url)
        }
        XCTAssertTrue(display === store.displaySnapshot, "选择与视图读取不能重新筛选/排序")
        store.refresh()
        try await settled(store)
        XCTAssertEqual(store.selectedURLs, urls)
        XCTAssertEqual(store.selectedURL, rows[4999].url)
        await store.refreshAfterPreview(snapshot: snapshot)
        XCTAssertEqual(store.selectedURLs, urls)
        XCTAssertEqual(store.selectedURL, rows[4999].url)
        XCTAssertFalse(store.isLoading)
        store.select(store.orderedEntries[0])
        store.select(store.orderedEntries[9999], extending: true)
        XCTAssertEqual(store.selectedURLs, urls)
    }

    func testCacheInvalidatesOnlyForEntriesFilterQueryAndSort() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder", isDirectory: true), withIntermediateDirectories: true)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        let initial = store.displaySnapshot
        store.gridView.toggle()
        store.selectedURL = store.entries[0].url
        XCTAssertTrue(initial === store.displaySnapshot)
        store.query = ".txt"
        let searched = store.displaySnapshot
        XCTAssertFalse(initial === searched)
        XCTAssertEqual(store.visibleEntries.count, 2)
        store.query = ".txt"
        XCTAssertTrue(searched === store.displaySnapshot)
        store.typeFilter = .folders
        XCTAssertTrue(store.visibleEntries.isEmpty)
        XCTAssertNil(store.selectedURL)
        store.query = ""
        XCTAssertEqual(store.visibleEntries.map(\.name), ["Folder"])
        let filtered = store.displaySnapshot
        store.sortByModified.toggle()
        XCTAssertFalse(filtered === store.displaySnapshot)
        let sorted = store.displaySnapshot
        store.refresh()
        try await settled(store)
        XCTAssertFalse(sorted === store.displaySnapshot)
        XCTAssertEqual(store.visibleEntries.map(\.name), ["Folder"])
    }

    func testHardLinkAmbiguityKeepsMatchingPathAndRejectsAmbiguousRename() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("a.txt")
        let link = root.appendingPathComponent("b.txt")
        let renamed = root.appendingPathComponent("c.txt")
        try Data("same inode".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.setSelection([original, link], primary: original)
        let before = store.capturePreviewSnapshot(source: "hard-links")
        await store.refreshAfterPreview(snapshot: before)
        XCTAssertEqual(store.selectedURLs, [original, link])
        let ambiguous = store.capturePreviewSnapshot(source: "hard-links")
        try FileManager.default.moveItem(at: original, to: renamed)
        await store.refreshAfterPreview(snapshot: ambiguous)
        XCTAssertEqual(store.selectedURLs, [link])
        XCTAssertNil(store.selectedURL)
        store.selectedURL = renamed
        let unique = store.capturePreviewSnapshot(source: "hard-links")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.moveItem(at: renamed, to: original)
        await store.refreshAfterPreview(snapshot: unique)
        XCTAssertEqual(store.selectedURL, original)
    }

    func testListAndTreeCoalesceAndRefreshSkipsCollapsedDescendants() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let probe = ReadProbe()
        probe.block([root])
        defer { probe.releaseAll() }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false, directoryReader: { try probe.read($0, $1) })
        store.openRoot(root, remember: false)
        try await wait { probe.calls(root) == 1 }
        XCTAssertEqual(probe.calls(root), 1, "同一代列表与根树只能有一次枚举")
        probe.release(root)
        try await settled(store)
        store.toggleExpanded(parent)
        try await settled(store)
        store.toggleExpanded(child)
        try await settled(store)
        store.toggleExpanded(parent)
        let parentReads = probe.calls(parent), childReads = probe.calls(child)
        store.refresh()
        try await settled(store)
        XCTAssertEqual(probe.calls(root), 2)
        XCTAssertEqual(probe.calls(parent), parentReads)
        XCTAssertEqual(probe.calls(child), childReads)
        XCTAssertNil(store.treeChildren[parent], "收起缓存作废后不应后台重读")
        XCTAssertTrue(store.expandedDirectories.contains(child), "保留后代展开意图")
        store.toggleExpanded(parent)
        try await settled(store)
        XCTAssertEqual(probe.calls(parent), parentReads + 1)
        XCTAssertEqual(probe.calls(child), childReads + 1)
    }

    func testSlowVolumeBoundsConcurrencyPrunesQueuedNavigationAndCollapse() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = try ["A", "B", "C", "D"].map { name -> URL in
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let probe = ReadProbe()
        probe.block([root] + folders)
        defer { probe.releaseAll() }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false, directoryReader: { try probe.read($0, $1) })
        store.openRoot(root, remember: false)
        try await wait { probe.calls(root) == 1 }
        store.toggleExpanded(folders[0])
        try await wait { probe.calls(folders[0]) == 1 }
        store.toggleExpanded(folders[1]) // 排队的树读取，随后收起。
        store.navigate(to: folders[2])   // 排队的列表读取，随后切走。
        store.navigate(to: folders[3])
        store.toggleExpanded(folders[1])
        probe.release(root)
        try await wait { probe.calls(folders[3]) == 1 }
        XCTAssertEqual(probe.calls(folders[1]), 0)
        XCTAssertEqual(probe.calls(folders[2]), 0)
        XCTAssertEqual(probe.maximumActive, 2)
        probe.releaseAll()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, folders[3])
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.treeChildren[folders[0]], "列表取消不能取消仍展开分支的订阅")
        XCTAssertFalse(store.treeLoading.contains(folders[1]))
        XCTAssertNil(store.treeErrors[folders[1]])
    }

    func testRefreshGenerationRejectsOlderRunningResultAndHiddenPolicyDoesNotCoalesce() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".hidden.txt"))
        let probe = ReadProbe()
        probe.block([root])
        defer { probe.releaseAll() }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false, directoryReader: { try probe.read($0, $1) })
        store.openRoot(root, remember: false)
        try await wait { probe.calls(root) == 1 }
        store.showHidden = true
        store.refresh()
        try await wait { probe.calls(root) == 2 }
        XCTAssertEqual(probe.hiddenPolicies, [false, true])
        // 首代已在工作器内得到“不显示隐藏文件”的快照，释放后必须只提交新代。
        probe.releaseAll()
        try await settled(store)
        XCTAssertEqual(store.entries.map(\.name), [".hidden.txt"])
        XCTAssertFalse(store.directoryIsTrulyEmpty)
        XCTAssertEqual(probe.maximumActive, 2)
    }

    func testPreviewCloseRequestsFreshReadAndNavigationCancelsItsWaiter() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("old.txt")
        try Data().write(to: file)
        let probe = ReadProbe()
        defer { probe.releaseAll() }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false, directoryReader: { try probe.read($0, $1) })
        store.openRoot(root, remember: false)
        try await settled(store)
        store.selectedURL = file
        let snapshot = store.capturePreviewSnapshot(source: "slow-close")
        probe.block([root])
        var closeCompleted = false
        let closing = Task {
            await store.refreshAfterPreview(snapshot: snapshot)
            closeCompleted = true
        }
        try await wait { probe.calls(root) == 2 }
        XCTAssertFalse(store.isLoading)
        store.navigate(to: other)
        // 回归时用超时失败触发闸门清理，不能让未恢复的 continuation 挂住整个测试进程。
        try await wait { closeCompleted }
        await closing.value // 不等旧工作器释放，取消也必须唤醒 continuation。
        try await settled(store)
        probe.releaseAll()
        try await wait { probe.activeCount == 0 }
        await Task.yield()
        XCTAssertEqual(store.currentDirectory, other)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.selectedURL)
    }

    func testRapidQuickRootsPruneInvisibleTreesAndCannotReuseOrphanRead() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = try (0..<12).map { index -> URL in
            let url = root.appendingPathComponent("Quick-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let probe = ReadProbe()
        probe.block(folders)
        defer { probe.releaseAll() }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false, directoryReader: { try probe.read($0, $1) })
        store.openQuickLocation(folders[0])
        try await wait { probe.calls(folders[0]) == 1 }
        store.openQuickLocation(folders[1])
        try await wait { probe.calls(folders[1]) == 1 }
        for directory in folders.dropFirst(2) { store.openQuickLocation(directory) }
        probe.release(folders[0])
        try await wait { probe.calls(folders.last!) == 1 }
        XCTAssertTrue(folders[2..<11].allSatisfy { probe.calls($0) == 0 })
        probe.releaseAll()
        try await settled(store)
        XCTAssertEqual(store.currentDirectory, folders.last)
        XCTAssertEqual(probe.maximumActive, 2)
        XCTAssertTrue(store.treeLoading.isEmpty)

        // 同一路径、同一树代次的旧任务已无订阅，重开也必须新读，不能继承其旧快照。
        probe.block([folders.last!])
        store.navigate(to: folders.last!)
        try await wait { probe.calls(folders.last!) == 2 }
        store.navigate(to: folders[0])
        try await settled(store)
        try Data().write(to: folders.last!.appendingPathComponent("new.txt"))
        store.navigate(to: folders.last!)
        try await wait { probe.calls(folders.last!) == 3 }
        probe.releaseAll()
        try await settled(store)
        XCTAssertEqual(store.entries.map(\.name), ["new.txt"])
    }

    func testPreviewRejectsDirectoryReplacedAtSamePath() async throws {
        let root = try makeRoot()
        let moved = root.deletingLastPathComponent().appendingPathComponent("FileDeckO4-moved-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: moved) }
        try Data().write(to: root.appendingPathComponent("old.txt"))
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        store.selectedURL = store.entries[0].url
        let snapshot = store.capturePreviewSnapshot(source: "replaced-root")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("new.txt"))
        await store.refreshAfterPreview(snapshot: snapshot)
        XCTAssertNotNil(store.directoryIssue)
        XCTAssertEqual(store.entries.map(\.name), ["old.txt"], "失败保留最后快照，不安装同路径新目录内容")
        XCTAssertEqual(store.selectedEntry?.identity, snapshot.primarySelection?.identity)
        XCTAssertNotEqual(store.selectedEntry?.identity, try FileSystem.identity(at: root.appendingPathComponent("new.txt")))
    }

    func testRepeatedRefreshKeepsOriginalIdentityWhileListIsEmpty() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.txt")
        try Data("original".utf8).write(to: file)
        let probe = ReadProbe()
        defer { probe.releaseAll() }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false, directoryReader: { try probe.read($0, $1) })
        store.openRoot(root, remember: false)
        try await settled(store)
        store.selectedURL = file
        probe.block([root])
        store.refresh()
        try await wait { probe.calls(root) == 2 }
        XCTAssertTrue(store.entries.isEmpty)
        try Data("replacement".utf8).write(to: file, options: .atomic)
        store.refresh()
        try await wait { probe.calls(root) == 3 }
        probe.releaseAll()
        try await settled(store)
        XCTAssertNil(store.selectedURL, "第二次刷新不能 stat 新 inode 后把原选择转交给同名替换项")
        XCTAssertTrue(store.selectedURLs.isEmpty)
        XCTAssertEqual(try String(contentsOf: file), "replacement")
    }

    func testOnlyHiddenDirectoryIsNotTrulyEmptyAndRefreshErrorsAreRetryable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".hidden"))
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openRoot(root, remember: false)
        try await settled(store)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.directoryIsTrulyEmpty)
        try FileManager.default.removeItem(at: root)
        store.refresh()
        try await wait { !store.isLoading && store.treeLoading.isEmpty }
        XCTAssertNotNil(store.directoryIssue)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store.refresh()
        try await settled(store)
        XCTAssertTrue(store.directoryIsTrulyEmpty)
        XCTAssertNil(store.treeErrors[root])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeckO4-\(UUID())", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: root.path, isDirectory: true)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw NSError(domain: "O4TestTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func settled(_ store: BrowserStore) async throws {
        try await wait { !store.isLoading && store.treeLoading.isEmpty }
        XCTAssertNil(store.directoryError)
    }
}

/// 先读取快照再阻塞回传，使“旧结果晚到”确定发生；锁内只保存计数，不在主线程等待闸门。
private final class ReadProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: Set<URL> = []
    private var records: [(URL, Bool)] = []
    private var active = 0
    private var peak = 0
    var activeCount: Int { condition.lock(); defer { condition.unlock() }; return active }
    var maximumActive: Int { condition.lock(); defer { condition.unlock() }; return peak }
    var hiddenPolicies: [Bool] { condition.lock(); defer { condition.unlock() }; return records.map(\.1) }
    func calls(_ url: URL) -> Int { condition.lock(); defer { condition.unlock() }; return records.filter { $0.0 == url }.count }
    func block(_ urls: [URL]) { condition.lock(); blocked.formUnion(urls); condition.unlock() }
    func release(_ url: URL) { condition.lock(); blocked.remove(url); condition.broadcast(); condition.unlock() }
    func releaseAll() { condition.lock(); blocked = []; condition.broadcast(); condition.unlock() }
    func read(_ url: URL, _ hidden: Bool) throws -> BrowserDirectorySnapshot {
        let result = Result { try BrowserDirectorySnapshot.read(url, showHidden: hidden) }
        condition.lock()
        records.append((url, hidden)); active += 1; peak = max(peak, active)
        while blocked.contains(url) { condition.wait() }
        active -= 1
        condition.unlock()
        return try result.get()
    }
}
