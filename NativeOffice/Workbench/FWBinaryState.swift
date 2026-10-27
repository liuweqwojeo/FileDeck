import AppKit
import UniformTypeIdentifiers

/// PDF/图片的编辑缓冲区与磁盘快照分开管理；保存完成只推进当次快照，不覆盖等待期间的新编辑。
@MainActor
final class FWBinaryState {
    private enum Work { case saving, reloading }
    private(set) var data: Data
    private var recoveredUnsaved = false
    private var savedData: Data
    private var fileState: FileSaveState?
    let maximumBytes: Int
    private var work: Work?
    private var transforming = false
    private(set) var isClosed = false
    var onChange: (() -> Void)?

    init(data: Data, fileState: FileSaveState? = nil, maximumBytes: Int = SafeFileIO.maximumMediaBytes) throws {
        precondition(maximumBytes > 0 && maximumBytes < Int.max)
        guard data.count <= maximumBytes else { throw DocumentIOError.fileTooLarge(limitBytes: maximumBytes) }
        self.data = data
        self.maximumBytes = maximumBytes
        savedData = fileState == nil ? Data() : data
        self.fileState = fileState
    }

    func markRecovered() { recoveredUnsaved = true }

    var path: URL? { fileState?.sourceURL }
    var isReadOnly: Bool { fileState?.isReadOnly ?? false }
    var isModified: Bool { recoveredUnsaved || data != savedData }
    var isBusy: Bool { work != nil || transforming }
    var canEdit: Bool { !isClosed && !isReadOnly && !transforming && (work == nil || work == .saving) }

    func replace(_ data: Data) throws {
        try requireOpen()
        guard !transforming, work == nil || work == .saving else { throw DocumentSessionError.busy }
        if isReadOnly, let path { throw DocumentIOError.readOnly(path) }
        try validateSize(data)
        self.data = data
        onChange?()
    }

    func transform(_ operation: @escaping @Sendable (Data) throws -> Data) async throws {
        let _: Bool = try await transformWithResult { (try operation($0), true) }
    }

    /// 像素等不可变结果随编码字节一起返回；校验失败前不提交，且允许图片沿用保存期间编辑语义。
    func transformWithResult<Result: Sendable>(allowDuringSave: Bool = false,
        _ operation: @escaping @Sendable (Data) throws -> (Data, Result)) async throws -> Result {
        try requireOpen()
        guard !transforming, work == nil || (allowDuringSave && work == .saving) else { throw DocumentSessionError.busy }
        if isReadOnly, let path { throw DocumentIOError.readOnly(path) }
        let snapshot = data
        transforming = true
        onChange?()
        defer { transforming = false; onChange?() }
        let result = try await Task.detached(priority: .userInitiated) { try operation(snapshot) }.value
        // 先校验再提交，失败时不推进内容/保存基线，也不触发控制器注册新的撤销项。
        try Task.checkCancellation()
        try validateSize(result.0)
        data = result.0
        return result.1
    }

    @discardableResult
    func save(to destination: URL?, overwrite: Bool, adoptDestination: Bool = true,
              encode: @escaping @Sendable (Data) throws -> Data = { $0 }) async throws -> (source: Data, encoded: Data) {
        try requireIdle()
        guard let target = destination ?? path else { throw DocumentIOError.saveLocationRequired }
        let snapshot = data
        let previous = adoptDestination ? fileState : nil
        let replacesSource = target.standardizedFileURL == path?.standardizedFileURL
        let maximumBytes = self.maximumBytes
        work = .saving
        onChange?()
        defer { work = nil; onChange?() }
        let saved = try await Task.detached(priority: .userInitiated) {
            let encoded = try encode(snapshot)
            let fileState = try SafeFileIO.save(encoded, previous: previous, to: target, maximumBytes: maximumBytes,
                                              overwriteExternalChanges: overwrite)
            return (state: fileState, data: encoded)
        }.value
        // 导出副本不改变当前路径；明确导出覆盖当前源文件时更新指纹，避免下一次保存误报自身写入冲突。
        if adoptDestination || replacesSource {
            fileState = saved.state
            savedData = snapshot
            recoveredUnsaved = false
        }
        // 图片编码可能有损且输出包含编码器元数据；把实际落盘结果交给调用方复用，避免无修改时重复编码。
        return (source: snapshot, encoded: saved.data)
    }

    @discardableResult
    func reload<Result: Sendable>(discardChanges: Bool, validate: @escaping @Sendable (Data) throws -> Result) async throws -> Result {
        try requireIdle()
        guard !isModified || discardChanges else { throw DocumentSessionError.unsavedChanges }
        guard let path else { throw DocumentSessionError.noFileToReload }
        work = .reloading
        onChange?()
        defer { work = nil; onChange?() }
        let maximumBytes = self.maximumBytes
        let loaded = try await Task.detached(priority: .userInitiated) {
            let result = try SafeFileIO.open(url: path, maximumBytes: maximumBytes)
            return (result, try validate(result.data))
        }.value
        try Task.checkCancellation()
        data = loaded.0.data
        savedData = loaded.0.data
        recoveredUnsaved = false
        fileState = loaded.0.state
        return loaded.1
    }

    func close(discardChanges: Bool) throws {
        if isClosed { return }
        try requireIdle()
        guard !isModified || discardChanges else { throw DocumentSessionError.unsavedChanges }
        isClosed = true
        onChange?()
    }

    func requireIdle() throws {
        try requireOpen()
        guard !isBusy else { throw DocumentSessionError.busy }
    }

    private func requireOpen() throws {
        guard !isClosed else { throw DocumentSessionError.closed }
    }

    private func validateSize(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw DocumentIOError.fileTooLarge(limitBytes: maximumBytes) }
    }
}

/// UndoManager 仍负责分组/重做；独立票据允许按快照字节预算移除最旧动作，同时释放捕获的像素。
@MainActor
final class FWMediaHistory {
    nonisolated static let defaultMaximumBytes = 128 * 1_048_576
    let manager = UndoManager()
    let maximumBytes: Int
    private(set) var retainedBytes = 0
    private final class Entry {
        let bytes: Int
        let redo: Bool
        var action: (() -> Void)?
        init(bytes: Int, redo: Bool, action: @escaping () -> Void) { self.bytes = bytes; self.redo = redo; self.action = action }
    }
    private var entries: [Entry] = []
    private var consumedActions = 0
    var canUndo: Bool { manager.canUndo && entries.contains { !$0.redo } }
    var canRedo: Bool { manager.canRedo && entries.contains(where: \.redo) }
    init(maximumBytes: Int = defaultMaximumBytes) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
        manager.levelsOfUndo = 12
    }
    func register(bytes: Int, name: String, action: @escaping () -> Void) {
        if !manager.isUndoing && !manager.isRedoing {
            for entry in entries.filter(\.redo) { remove(entry) }
        }
        // 当前修改无法撤销时清空旧分支，避免下一次撤销跨过它，造成看似丢失当前内容。
        guard bytes >= 0, bytes <= maximumBytes else { removeAll(); return }
        while retainedBytes > maximumBytes - bytes || entries.count >= 12 { remove(entries[0]) }
        let entry = Entry(bytes: bytes, redo: manager.isUndoing, action: action)
        entries.append(entry); retainedBytes += bytes
        manager.registerUndo(withTarget: entry) { [weak self] entry in
            MainActor.assumeIsolated {
                guard let self, let action = entry.action else { return }
                self.consumedActions &+= 1
                self.remove(entry, removeAction: false)
                action()
            }
        }
        manager.setActionName(name)
    }
    private func remove(_ entry: Entry, removeAction: Bool = true) {
        if removeAction { manager.removeAllActions(withTarget: entry) }
        if let index = entries.firstIndex(where: { $0 === entry }) {
            entries.remove(at: index); retainedBytes -= entry.bytes
        }
        entry.action = nil
    }
    func removeAll() {
        // removeAllActions 会关闭调用方仍持有的 Cocoa 组；预算淘汰期间只移除票据，保留组配对。
        for entry in entries { remove(entry) }
        if manager.groupingLevel == 0 && !manager.isUndoing && !manager.isRedoing { manager.removeAllActions() }
    }
    // 移除某票据后 Cocoa 可能留下空组；能力来自保留动作，并跳过空组，不暴露无效撤销菜单。
    func undo() {
        let before = consumedActions
        while canUndo && consumedActions == before { manager.undo() }
    }
    func redo() {
        let before = consumedActions
        while canRedo && consumedActions == before { manager.redo() }
    }
}

@MainActor
enum FWMediaUI {
    static func show(_ error: Error, in window: NSWindow?) {
        if error is CancellationError { return }
        let alert = NSAlert(error: error)
        if case DocumentIOError.fileTooLarge = error {
            alert.informativeText += "\n请减少本次合并或追加的文件，拆分处理后重试。原编辑内容保持不变。"
        }
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func fields(title: String, labels: [String], values: [String]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        var inputs: [NSTextField] = []
        for (label, value) in zip(labels, values) {
            let field = NSTextField(string: value)
            field.frame.size.width = 300
            inputs.append(field)
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        stack.frame = CGRect(x: 0, y: 0, width: 320, height: max(64, labels.count * 55))
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map(\.stringValue)
    }

    static func files(title: String, types: [UTType]) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    static func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "重新读取会丢弃未保存内容"
        alert.addButton(withTitle: "丢弃并重新读取")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func layout(toolbar: NSView, body: NSView, status: NSTextField) -> NSView {
        let root = NSView()
        for item in [toolbar, body, status] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            body.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor), body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        return root
    }

    static func requireExtension(_ url: URL, allowed: Set<String>) throws {
        guard url.isFileURL, allowed.contains(url.pathExtension.lowercased()) else {
            throw MediaOperationError.invalidParameter("目标扩展名须为 \(allowed.sorted().joined(separator: "、"))。")
        }
    }
}
