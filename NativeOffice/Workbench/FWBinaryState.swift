import AppKit
import UniformTypeIdentifiers

/// PDF/图片的编辑缓冲区与磁盘快照分开管理；保存完成只推进当次快照，不覆盖等待期间的新编辑。
@MainActor
final class FWBinaryState {
    private enum Work { case saving, reloading, transforming }
    private(set) var data: Data
    private var savedData: Data
    private var fileState: FileSaveState?
    private var work: Work?
    private(set) var isClosed = false
    var onChange: (() -> Void)?

    init(data: Data, fileState: FileSaveState? = nil) {
        self.data = data
        savedData = fileState == nil ? Data() : data
        self.fileState = fileState
    }

    var path: URL? { fileState?.sourceURL }
    var isReadOnly: Bool { fileState?.isReadOnly ?? false }
    var isModified: Bool { data != savedData }
    var isBusy: Bool { work != nil }
    var canEdit: Bool { !isClosed && !isReadOnly && (work == nil || work == .saving) }

    func replace(_ data: Data) throws {
        try requireOpen()
        guard work == nil || work == .saving else { throw DocumentSessionError.busy }
        if isReadOnly, let path { throw DocumentIOError.readOnly(path) }
        self.data = data
        onChange?()
    }

    func transform(_ operation: @escaping @Sendable (Data) throws -> Data) async throws {
        try requireIdle()
        if isReadOnly, let path { throw DocumentIOError.readOnly(path) }
        let snapshot = data
        work = .transforming
        onChange?()
        defer { work = nil; onChange?() }
        data = try await Task.detached(priority: .userInitiated) { try operation(snapshot) }.value
    }

    func save(to destination: URL?, overwrite: Bool, adoptDestination: Bool = true,
              encode: @escaping @Sendable (Data) throws -> Data = { $0 }) async throws {
        try requireIdle()
        guard let target = destination ?? path else { throw DocumentIOError.saveLocationRequired }
        let snapshot = data
        let previous = adoptDestination ? fileState : nil
        let replacesSource = target.standardizedFileURL == path?.standardizedFileURL
        work = .saving
        onChange?()
        defer { work = nil; onChange?() }
        let saved = try await Task.detached(priority: .userInitiated) {
            try SafeFileIO.save(encode(snapshot), previous: previous, to: target, overwriteExternalChanges: overwrite)
        }.value
        // 导出副本不改变当前路径；明确导出覆盖当前源文件时更新指纹，避免下一次保存误报自身写入冲突。
        if adoptDestination || replacesSource {
            fileState = saved
            savedData = snapshot
        }
    }

    func reload(discardChanges: Bool, validate: @escaping @Sendable (Data) throws -> Void) async throws {
        try requireIdle()
        guard !isModified || discardChanges else { throw DocumentSessionError.unsavedChanges }
        guard let path else { throw DocumentSessionError.noFileToReload }
        work = .reloading
        onChange?()
        defer { work = nil; onChange?() }
        let loaded = try await Task.detached(priority: .userInitiated) {
            let result = try SafeFileIO.open(url: path)
            try validate(result.data)
            return result
        }.value
        data = loaded.data
        savedData = loaded.data
        fileState = loaded.state
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
}

@MainActor
enum FWMediaUI {
    static func show(_ error: Error, in window: NSWindow?) {
        if error is CancellationError { return }
        let alert = NSAlert(error: error)
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
