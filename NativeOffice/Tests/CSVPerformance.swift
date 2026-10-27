import AppKit

/// 只计真实 CSV 控制器的单格提交；文件打开、保存、UI 绘制不混入编辑分位数。
@main
struct CSVPerformance {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: csv-performance <fixture-directory> <report.json>\n", stderr); exit(64)
        }
        do {
            _ = NSApplication.shared
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            var cases: [[String: Any]] = []
            for height in [1_000, 10_000, 100_000] {
                let source = String(repeating: "a,a,a,a,a,a,a,a,a,a\n", count: height)
                let input = root.appendingPathComponent("\(height).csv")
                try Data(source.utf8).write(to: input)
                let openedAt = DispatchTime.now().uptimeNanoseconds
                let content = try await FWCSVContent.open(url: input, encoding: .utf8(bom: false), delimiter: .comma)
                let openMs = Double(DispatchTime.now().uptimeNanoseconds - openedAt) / 1_000_000
                content.undoManager?.groupsByEvent = false
                for value in ["x", "y"] {
                    content.undoManager?.beginUndoGrouping()
                    try content.setCell(value, row: height / 2, column: 5)
                    content.undoManager?.endUndoGrouping()
                }
                var times: [Double] = []
                for index in 0..<21 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    content.undoManager?.beginUndoGrouping()
                    try content.setCell(index.isMultiple(of: 2) ? "x" : "y", row: height / 2, column: 5)
                    content.undoManager?.endUndoGrouping()
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                let copy = root.appendingPathComponent("\(height)-saved.csv")
                try await content.saveAs(to: copy)
                guard try CSVDocument(text: DocumentIO.open(url: copy).text).rows[height / 2][5] == "x",
                      !content.isModified, try Data(contentsOf: input) == Data(source.utf8) else {
                    throw failure("Benchmark save or source preservation failed")
                }
                content.undo()
                guard content.isModified else { throw failure("Benchmark undo lost saved baseline") }
                content.redo()
                guard !content.isModified else { throw failure("Benchmark redo did not restore saved bytes") }
                try await content.close()
                let ordered = times.sorted()
                cases.append(["rows": height, "columns": 10, "inputBytes": source.utf8.count,
                              "samples": times.count, "editMedianMs": ordered[ordered.count / 2],
                              "editP95Ms": ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1],
                              "openMs": openMs, "sampleMs": times, "saveUndoRedoVerified": true])
            }
            let report: [String: Any] = ["cases": cases, "optimization": "-O", "uiMounted": false,
                                       "scope": "native setCell + undo registration + dirty/status; excludes open/save/UI paint"]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func failure(_ detail: String) -> NSError {
        NSError(domain: "FileDeck.CSVPerformance", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
