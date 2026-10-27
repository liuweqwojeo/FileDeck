import AppKit
import SwiftUI

/// 浏览页面只切换呈现；原生协调器继续持有文档、保存目标和未保存关闭流程。
@MainActor
final class WorkspaceEditorBridge: ObservableObject {
    let nativeView: NSView?
    private let openHandler: (URL, Bool) -> Void
    private let commandHandler: (String) -> Void
    var previewHandler: ((URL, String, Int?) -> Void)?
    @Published private(set) var title = "文件编辑"
    @Published private(set) var url: URL?
    @Published private(set) var hasDocument = false
    @Published private(set) var modified = false
    @Published private(set) var busy = false
    @Published private(set) var canSave = false
    @Published private(set) var canSaveAs = false
    @Published private(set) var canExport = false
    @Published private(set) var isPresented = false
    @Published var isExpanded = false
    @Published var isPreviewPresented = false
    private var presentedURL: URL?

    var isAvailable: Bool { nativeView != nil }

    init(nativeView: NSView? = nil, openHandler: @escaping (URL, Bool) -> Void = { _, _ in },
         commandHandler: @escaping (String) -> Void = { _ in }) {
        self.nativeView = nativeView
        self.openHandler = openHandler
        self.commandHandler = commandHandler
    }

    func supportsEditing(_ entry: FileEntry) -> Bool {
        guard isAvailable else { return false }
        let kind = FileCapabilityRegistry().capabilities(for: entry).kind
        return kind != .other && kind != .directory
    }

    func open(_ url: URL) {
        guard isAvailable else { return }
        // 显式编辑始终固定标签，避免下次浏览替换尚在编辑的文档。
        openHandler(url, true)
    }

    func command(_ name: String) { if isAvailable { commandHandler(name) } }

    func preview(_ url: URL, source: String, line: Int? = nil) { previewHandler?(url, source, line) }

    func update(title: String, url: URL?, hasDocument: Bool, modified: Bool, busy: Bool,
                canSave: Bool, canSaveAs: Bool, canExport: Bool) {
        self.title = title
        self.url = url
        self.hasDocument = hasDocument
        self.modified = modified
        self.busy = busy
        self.canSave = canSave
        self.canSaveAs = canSaveAs
        self.canExport = canExport
        if !hasDocument { hide() }
    }

    func show() {
        guard isAvailable, hasDocument else { return }
        if !isPresented || presentedURL != url {
            let kind = url.map { FileCapabilityRegistry().capabilities(for: $0).kind }
            isExpanded = url == nil || kind == .word || kind == .spreadsheet || kind == .presentation
        }
        presentedURL = url
        isPresented = true
    }

    func hide() { isPresented = false }
}

/// 始终挂载同一个 NSTabView；SwiftUI 的选择、搜索和分栏变化不能重建 CEF/WK 编辑会话。
struct WorkspaceNativeEditorView: NSViewRepresentable {
    let editorView: NSView
    let visible: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        editorView.removeFromSuperview()
        editorView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editorView)
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: container.topAnchor),
            editorView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        editorView.isHidden = !visible
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        editorView.isHidden = !visible
    }
}
