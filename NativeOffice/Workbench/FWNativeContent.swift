import AppKit

/// 非 Office 内容控制器共同遵守的保存契约；Office 状态仍由原生壳直接查询 CEF。
@MainActor
protocol FWNativeContent: DocumentSession {
    var controller: NSViewController { get }
    var contentTitle: String { get }
    var kind: WorkbenchFileKind { get }
    var onStateChanged: (() -> Void)? { get set }
    func reload(discardChanges: Bool) async throws
    var canFind: Bool { get }
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    func undo()
    func redo()
    func find()
    var canCloseWhileBusy: Bool { get }
    func captureInteraction() async
    func suspendInteraction(_ suspended: Bool) async
    func restoreInteraction() async
    func dispose()
    var recoveryCapture: DraftRecoveryCapture? { get }
}

extension FWNativeContent {
    // 未实现的命令默认不可用，不能仅因标签存在就把空实现显示为可点击菜单。
    var recoveryCapture: DraftRecoveryCapture? { nil }
    var canFind: Bool { false }
    var canUndo: Bool { false }
    var canRedo: Bool { false }
    func undo() {}
    func redo() {}
    func find() {}
    var canCloseWhileBusy: Bool { false }
    func captureInteraction() async {}
    func suspendInteraction(_ suspended: Bool) async {}
    func restoreInteraction() async {}
    func dispose() {}
}

/// 主线程只捕获 COW 文本/表格/字节，正文序列化和磁盘写入交给 store actor。
/// 尾沿 750 ms + 最长 5 s 两个触发器，连续输入也会落盘；并不保证尚未桥接/提交的最后输入。
@MainActor
final class FWDraftCheckpoint {
    let id: UUID
    private let store: DraftRecoveryStore
    private weak var content: (any FWNativeContent)?
    private let original: DraftRecoveryHeader?
    private var generation: UInt64 = 0
    private var debounce: Task<Void, Never>?
    private var maximumDelay: Task<Void, Never>?
    private var finished = false
    private var writing = false
    private var needsFlush = false
    private var hadChanges: Bool
    private(set) var message: String?
    private(set) var isFailure = false
    var onStatusChanged: (() -> Void)?

    init(content: any FWNativeContent, id: UUID = UUID(), original: DraftRecoveryHeader? = nil,
         store: DraftRecoveryStore = .shared) {
        self.content = content; self.id = id; self.original = original; self.store = store
        hadChanges = original != nil
    }
    deinit { debounce?.cancel(); maximumDelay?.cancel() }
    func changed() {
        guard !finished, let content else { return }
        generation &+= 1
        debounce?.cancel()
        if !content.isModified {
            if !isFailure { message = hadChanges ? "正在清理已保存的恢复副本…" : nil }
            maximumDelay?.cancel(); maximumDelay = nil
            if hadChanges { flush() }
            return
        }
        hadChanges = true
        if !isFailure { message = "恢复副本待更新…" }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            self?.flush()
        }
        if maximumDelay == nil {
            maximumDelay = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.flush()
            }
        }
    }
    func flush() {
        guard !finished, let content else { return }
        debounce?.cancel(); debounce = nil
        maximumDelay?.cancel(); maximumDelay = nil
        // 慢盘上最多持有一份在途快照；期间变化仅保留“还需写入”，不排队捕获大量旧图片。
        if writing { needsFlush = true; return }
        var capture = content.recoveryCapture
        if let original, let current = capture {
            capture = DraftRecoveryCapture(kind: current.kind,
                originalURL: original.originalPath.map { URL(fileURLWithPath: $0) }, title: original.title, body: current.body)
        }
        generation &+= 1
        submit(capture: capture, generation: generation)
    }
    private func submit(capture: DraftRecoveryCapture?, generation: UInt64) {
        let store = store, id = id
        writing = true
        Task { [weak self] in
            defer {
                if let self {
                    self.writing = false
                    if self.needsFlush, !self.finished { self.needsFlush = false; self.flush() }
                }
            }
            do {
                try await store.checkpoint(id: id, generation: generation, capture: capture)
                guard let self, self.generation == generation, !self.finished else { return }
                self.isFailure = false
                if capture == nil { self.hadChanges = false }
                self.message = capture == nil ? nil : "恢复副本已更新"
                self.onStatusChanged?()
            } catch {
                guard let self, self.generation == generation, !self.finished else { return }
                self.isFailure = true
                self.message = "恢复副本未更新：" + error.localizedDescription
                self.onStatusChanged?()
            }
        }
    }
    func finish() async throws {
        debounce?.cancel(); debounce = nil
        maximumDelay?.cancel(); maximumDelay = nil
        finished = true; needsFlush = false; generation &+= 1
        try await store.checkpoint(id: id, generation: generation, capture: nil)
    }
}
