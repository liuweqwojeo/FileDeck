import AppKit
import QuickLookUI

@MainActor
final class FWQuickLookContent: NSViewController, FWNativeContent {
    let id = UUID()
    let path: URL?
    let kind = WorkbenchFileKind.other
    var contentTitle: String { path?.lastPathComponent ?? "系统预览" }
    var controller: NSViewController { self }
    var onStateChanged: (() -> Void)?
    let isModified = false
    let isReadOnly = true
    private(set) var isBusy = false
    private var closed = false
    private lazy var preview = QLPreviewView(frame: .zero, style: .normal)!
    var availableOperations: Set<FileOperation> { closed || isBusy ? [] : [.open] }

    private init(url: URL) {
        path = url
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("请使用 open(url:)") }

    static func open(url: URL) async throws -> FWQuickLookContent {
        try await validate(url)
        return FWQuickLookContent(url: url)
    }

    override func loadView() {
        preview.autostarts = false
        preview.shouldCloseWithWindow = false
        preview.previewItem = path as NSURL?
        let label = NSTextField(labelWithString: "尝试使用 macOS Quick Look 预览；实际格式支持由系统决定。此标签不支持编辑或保存。")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        view = FWMediaUI.layout(toolbar: NSTextField(labelWithString: "系统预览"), body: preview, status: label)
    }

    func save(overwriteExternalChanges: Bool) async throws { try refuse(.save) }
    func saveAs(to destination: URL, overwriteExternalChanges: Bool) async throws { try refuse(.saveAs) }
    func export(to destination: URL, format: WorkbenchFileKind, overwriteExisting: Bool) async throws { try refuse(.export) }

    func reload(discardChanges: Bool) async throws {
        try requireIdle()
        guard let path else { throw DocumentSessionError.noFileToReload }
        isBusy = true
        onStateChanged?()
        defer { isBusy = false; onStateChanged?() }
        try await Self.validate(path)
        if isViewLoaded { preview.refreshPreviewItem() }
    }

    func close(discardChanges: Bool) async throws {
        if closed { return }
        try requireIdle()
        closed = true
        // 未挂载的标签尚未创建 QLPreviewView；不能关闭一个从未激活的系统预览实例。
        if isViewLoaded { preview.close() }
        onStateChanged?()
    }

    private func refuse(_ operation: FileOperation) throws {
        try requireIdle()
        throw DocumentSessionError.unsupportedOperation(operation)
    }

    private func requireIdle() throws {
        guard !closed else { throw DocumentSessionError.closed }
        guard !isBusy else { throw DocumentSessionError.busy }
    }

    private static func validate(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard url.isFileURL else { throw DocumentIOError.notRegularFile }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
            guard values.isRegularFile == true || FileSystem.isPackageDirectory(url, values: values) else {
                throw DocumentIOError.notRegularFile
            }
        }.value
    }
}
