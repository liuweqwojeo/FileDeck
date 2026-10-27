import AppKit
import PDFKit
import Darwin

/// 同一探针对比旧/新媒体路径。心跳测主队列调度间隔，RSS 是独立进程生命周期高水位，不是 GUI 帧延迟。
@MainActor
private final class MainPulse {
    private var timer: DispatchSourceTimer?
    private var last = DispatchTime.now().uptimeNanoseconds
    private(set) var maximumGapMs = 0.0
    func start() {
        last = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        self.timer = timer; timer.resume()
    }
    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        maximumGapMs = max(maximumGapMs, Double(now - last) / 1_000_000)
        last = now
    }
    func stop() { tick(); timer?.cancel(); timer?.setEventHandler {}; timer = nil }
}

@main
struct MediaPerformance {
    @MainActor static func measure<Value>(_ operation: () async throws -> Value) async throws -> (Value, [String: Any]) {
        let pulse = MainPulse(); pulse.start()
        defer { pulse.stop() }
        try await Task.sleep(for: .milliseconds(15))
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await operation()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        try await Task.sleep(for: .milliseconds(15))
        pulse.stop()
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw failure("getrusage failed") }
        return (value, ["elapsedMs": elapsed, "mainQueueMaxGapMs": pulse.maximumGapMs,
                        "processPeakRSSBytes": usage.ru_maxrss])
    }
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 4, ["image", "pdf"].contains(CommandLine.arguments[2]) else {
            fputs("Usage: media-performance <fixture-directory> <image|pdf> <report.json>\n", stderr); exit(64)
        }
        do {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let scenario = CommandLine.arguments[2]
            let metrics: [String: Any]
            if scenario == "image" { metrics = try await image(directory) }
            else { metrics = try await pdf(directory) }
            let report: [String: Any] = ["scenario": scenario, "optimization": "-O", "uiMounted": false,
                "heartbeatIntervalMs": 5, "rssScope": "independent process lifetime high-water, including fixture generation",
                "metrics": metrics]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func image(_ directory: URL) async throws -> [String: Any] {
        let data: Data = try autoreleasepool {
            let context = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for row in 0..<300 {
                context.setFillColor(CGColor(red: Double(row % 37) / 37, green: Double(row % 61) / 61, blue: 0.6, alpha: 1))
                context.fill(CGRect(x: 0, y: row * 10, width: 4000, height: 10))
            }
            return try ImageOperations.export(context.makeImage()!, format: .png)
        }
        let source = directory.appendingPathComponent("12MP.png")
        try data.write(to: source)
        let (content, open) = try await measure { try await FWImageContent.open(url: source) }
        content.undoManager?.groupsByEvent = false
        let (_, rotate) = try await measure {
            for _ in 0..<2 {
                content.undoManager?.beginUndoGrouping()
                try await content.rotate(clockwise: true)
                content.undoManager?.endUndoGrouping()
            }
        }
        let copy = directory.appendingPathComponent("saved.png")
        try await content.saveAs(to: copy)
        let pixels = try ImageOperations.read(Data(contentsOf: copy))
        guard pixels.width == 4000, pixels.height == 3000, try Data(contentsOf: source) == data, !content.isModified else {
            throw failure("Image benchmark output mismatch")
        }
        content.undo()
        guard content.isModified else { throw failure("Image benchmark undo did not change the saved result") }
        content.redo()
        guard !content.isModified else { throw failure("Image benchmark redo lost baseline") }
        try await content.close()
        return ["width": 4000, "height": 3000, "rotations": 2, "open": open, "rotate": rotate, "saveUndoRedoVerified": true]
    }
    @MainActor static func pdf(_ directory: URL) async throws -> [String: Any] {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 640, height: 800)
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0..<20 {
            context.beginPDFPage(nil)
            context.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
            for row in 0..<12 {
                context.move(to: CGPoint(x: 50, y: 50 + row * 40)); context.addLine(to: CGPoint(x: 450, y: 50 + row * 40))
            }
            context.strokePath(); context.endPDFPage()
        }
        context.closePDF()
        let source = data as Data
        let (_, metric) = try await measure {
            let output: Data
            #if O3_BATCH
            let marks = (0..<120).map { PDFOperations.Highlight(pageIndex: $0 % 20,
                bounds: CGRect(x: 50, y: 50 + ($0 / 20) * 40, width: 400, height: 20)) }
            output = try await Task.detached(priority: .userInitiated) { try PDFOperations.addHighlights(source, highlights: marks) }.value
            #else
            var updated = source
            for index in 0..<120 {
                updated = try PDFOperations.addHighlight(updated, pageIndex: index % 20,
                    bounds: CGRect(x: 50, y: 50 + (index / 20) * 40, width: 400, height: 20))
            }
            output = updated
            #endif
            let document = try PDFOperations.read(output)
            guard document.pageCount == 20, (0..<20).allSatisfy({ document.page(at: $0)?.annotations.count == 6 }) else {
                throw failure("PDF benchmark annotation mismatch")
            }
            try output.write(to: directory.appendingPathComponent("highlights.pdf"))
        }
        return ["pages": 20, "highlights": 120, "batch": metric, "annotationsVerified": true,
                "scope": "highlight model operation + validation/write; excludes controller install/display"]
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "MediaPerformance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
