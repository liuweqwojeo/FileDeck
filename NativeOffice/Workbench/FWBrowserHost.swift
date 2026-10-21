import AppKit
import Combine
import SwiftUI

/// 工作台常驻；预览/编辑作为同窗口的独立临时会话，关闭不重建导航或文件列表。
@MainActor
@objc(FWBrowserHost)
public final class FWBrowserHost: NSViewController {
    let browserStore: BrowserStore
    let editorBridge: WorkspaceEditorBridge
    private(set) var backgroundView: NSView!
    private(set) var previewModal: FWPreviewModal?
    private var observations = Set<AnyCancellable>()
    private var pendingPreview: (URL, String)?
    private let commandHandler: (String) -> Void
    @objc public var currentDirectory: URL? { browserStore.currentDirectory }
    @objc public var hasFilePreview: Bool { previewModal?.mode == .file }
    @objc public var hasAnyPreview: Bool { previewModal != nil }
    @objc public var previewDocument: FWDocumentHost? { previewModal?.documentHost }
    @objc public var previewBusy: Bool { previewModal?.isClosing == true || previewDocument?.busy == true }

    @objc(initWithEditorView:openHandler:commandHandler:)
    public init(editorView: NSView, openHandler: @escaping (URL, Bool) -> Void,
                commandHandler: @escaping (String) -> Void) {
        browserStore = BrowserStore()
        editorBridge = WorkspaceEditorBridge(nativeView: editorView, openHandler: openHandler, commandHandler: commandHandler)
        self.commandHandler = commandHandler
        super.init(nibName: nil, bundle: nil)
        editorBridge.previewHandler = { [weak self] url, source in self?.openPreview(url, source: source) }
        editorBridge.$isPresented.removeDuplicates().dropFirst().sink { [weak self] visible in
            guard let self else { return }
            if visible { self.showLegacyEditor() }
            else if self.previewModal?.mode == .legacy { self.previewModal?.finishLegacyClose() }
        }.store(in: &observations)
        editorBridge.$isExpanded.removeDuplicates().dropFirst().sink { [weak self] expanded in
            guard let modal = self?.previewModal, modal.mode == .legacy, modal.isExpanded != expanded else { return }
            modal.toggleExpanded()
        }.store(in: &observations)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSView()
        backgroundView = NSHostingView(rootView: ContentView(store: browserStore, editor: editorBridge).preferredColorScheme(.light))
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: root.leadingAnchor), backgroundView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: root.topAnchor), backgroundView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if let pending = pendingPreview {
            pendingPreview = nil
            openPreview(pending.0, source: pending.1)
        } else if editorBridge.isPresented { showLegacyEditor() }
    }

    func setBackgroundInteraction(enabled: Bool) {
        backgroundView.setAccessibilityHidden(!enabled)
        // 指针由遮罩命中；可访问性也必须隐藏背景，不能只处理视觉遮罩。
    }

    @objc(openPreviewURL:source:)
    public func openPreview(_ url: URL, source: String) {
        guard url.isFileURL else { return }
        guard isViewLoaded, view.window != nil else { pendingPreview = (url, source); return }
        if browserStore.startupPhase != .ready { browserStore.skipWelcome() }
        if let modal = previewModal {
            guard modal.mode == .file else { return }
            if modal.url == url, !modal.isClosing { view.window?.makeFirstResponder(modal.overlay.dialog); return }
            pendingPreview = (url, source)
            guard !modal.isClosing else { return }
            modal.requestClose { [weak self] closed in
                guard let self else { return }
                if closed, let next = self.pendingPreview {
                    self.pendingPreview = nil
                    self.presentPreview(next.0, source: next.1)
                } else { self.pendingPreview = nil }
            }
        } else { presentPreview(url, source: source) }
    }

    private func presentPreview(_ url: URL, source: String) {
        let modal = FWPreviewModal(owner: self, url: url, source: source)
        attach(modal)
        modal.present()
    }

    private func attach(_ modal: FWPreviewModal) {
        previewModal = modal
        modal.didClose = { [weak self, weak modal] in
            guard let self, self.previewModal === modal else { return }
            self.previewModal = nil
        }
    }

    private func showLegacyEditor() {
        guard let nativeView = editorBridge.nativeView, editorBridge.hasDocument, view.window != nil else { return }
        if let modal = previewModal {
            if modal.mode == .legacy { updateLegacyChrome(); return }
            // 外部打开/新建也先保护临时会话，不能用标签回调直接替换未保存编辑器。
            modal.requestClose { [weak self] closed in if closed { self?.showLegacyEditor() } }
            return
        }
        let modal = FWPreviewModal(owner: self, url: editorBridge.url, source: "application", mode: .legacy)
        modal.legacyCommand = commandHandler
        attach(modal)
        modal.present(legacyView: nativeView)
        updateLegacyChrome()
    }

    private func updateLegacyChrome() {
        previewModal?.updateLegacy(title: editorBridge.title, url: editorBridge.url, modified: editorBridge.modified,
                                   busy: editorBridge.busy, canSave: editorBridge.canSave, canSaveAs: editorBridge.canSaveAs)
    }

    @objc(requestClosePreviewWithCompletion:)
    public func requestClosePreview(completion: @escaping (Bool) -> Void) {
        guard let modal = previewModal, modal.mode == .file else { completion(true); return }
        pendingPreview = nil
        modal.requestClose(completion: completion)
    }

    @objc(updateEditorWithTitle:url:hasDocument:modified:busy:canSave:canSaveAs:canExport:)
    public func updateEditor(title: String, url: URL?, hasDocument: Bool, modified: Bool, busy: Bool,
                             canSave: Bool, canSaveAs: Bool, canExport: Bool) {
        editorBridge.update(title: title, url: url, hasDocument: hasDocument, modified: modified,
                            busy: busy, canSave: canSave, canSaveAs: canSaveAs, canExport: canExport)
        updateLegacyChrome()
    }

    @objc public func showEditor() {
        if browserStore.startupPhase != .ready { browserStore.skipWelcome() }
        editorBridge.show()
        if editorBridge.isPresented { showLegacyEditor() }
    }
    @objc public func hideEditor() { editorBridge.hide() }
    @objc public func refreshDirectory() {
        // 模态保存只更新磁盘；关闭时统一做局部刷新，避免保存造成背景列表卸载与滚动归零。
        if previewModal == nil { browserStore.refresh() }
    }
    @objc public func openFolder() {
        requestClosePreview { [weak self] closed in if closed { self?.browserStore.chooseFolder() } }
    }
    @objc public func revealFile(_ url: URL) {
        requestClosePreview { [weak self] closed in if closed { self?.browserStore.openFile(url) } }
    }
}
