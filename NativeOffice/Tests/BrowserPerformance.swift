import AppKit

/// 同一真实万文件目录比较状态层工作；不挂载窗口，耗时不等同于完整列表绘制或慢卷延迟。
@main
struct BrowserPerformance {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: browser-performance <fixture-directory> <report.json>\n", stderr); exit(64)
        }
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            // 普通启动偏好与探针隔离；读取真实用户的排序/网格设置会污染基线。
            let defaults = UserDefaults(suiteName: "local.fileworkbench.benchmark-" + UUID().uuidString)!
            let store = BrowserStore(restoreLastLocation: false, defaults: defaults)
            var cases: [[String: Any]] = []
            var start = DispatchTime.now().uptimeNanoseconds
            store.openRoot(root, remember: false)
            try await settled(store)
            cases.append(["name": "open", "elapsedMs": elapsed(start)])
            guard store.entries.count == 10_000 else { throw failure("Incorrect fixture count") }
            store.sortByModified = true
            let urls = Set(store.entries.map(\.url))
            let primary = store.entries[4999].url
            store.setSelection(urls, primary: primary)
            start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<12 {
                guard store.visibleEntries.count == 10_000, store.orderedEntries.count == 10_000,
                      store.selectedEntry?.url == primary else { throw failure("Display mismatch") }
            }
            cases.append(["name": "displayRead12", "elapsedMs": elapsed(start)])
            start = DispatchTime.now().uptimeNanoseconds
            let snapshot = store.capturePreviewSnapshot(source: "benchmark")
            cases.append(["name": "capture10000", "elapsedMs": elapsed(start)])
            guard snapshot.selection.count == 10_000 else { throw failure("Snapshot lost selection") }
            start = DispatchTime.now().uptimeNanoseconds
            store.refresh()
            try await settled(store)
            cases.append(["name": "refresh10000", "elapsedMs": elapsed(start)])
            guard store.selectedURLs == urls, store.selectedURL == primary else { throw failure("Refresh lost selection") }
            start = DispatchTime.now().uptimeNanoseconds
            await store.refreshAfterPreview(snapshot: snapshot)
            cases.append(["name": "previewClose10000", "elapsedMs": elapsed(start)])
            guard store.selectedURLs == urls, store.selectedURL == primary, !store.isLoading else { throw failure("Close lost selection") }
            let report: [String: Any] = ["cases": cases, "entries": 10_000, "selected": 10_000,
                "optimization": "-O", "uiMounted": false, "restoredSelectionVerified": true,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "scope": "real local directory + BrowserStore; excludes file creation, window mounting and UI paint; one nonexclusive sample"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    @MainActor static func settled(_ store: BrowserStore) async throws {
        let deadline = Date().addingTimeInterval(180)
        while store.isLoading || !store.treeLoading.isEmpty {
            guard Date() < deadline else { throw failure("Directory timed out") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        if let error = store.directoryError { throw failure(error) }
    }
    static func failure(_ text: String) -> NSError {
        NSError(domain: "FileDeck.BrowserPerformance", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
