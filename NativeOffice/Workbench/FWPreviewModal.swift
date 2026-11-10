import AppKit
import SwiftUI
@preconcurrency import WebKit

/// 同一原生窗口中的临时工作层。背景 HostingView 和 BrowserStore 始终原位保留。
@MainActor
final class FWPreviewModal: NSObject {
    enum Mode { case file, legacy }
    let mode: Mode
    let source: String
    private(set) var documentHost: FWDocumentHost?
    private(set) var isClosing = false
    var isFullScreen: Bool { overlay?.window?.styleMask.contains(.fullScreen) == true }
    private var windowWasFullScreen = false
    private(set) var overlay: FWModalOverlay!
    private(set) var url: URL?
    private let store: BrowserStore
    private weak var owner: FWBrowserHost?
    private let snapshot: BrowserPreviewSnapshot
    private let previewFiles: [BrowserFileReference]
    private var previewIndex: Int?
    private weak var originalResponder: NSResponder?
    private var scrollPositions: [FWScrollPosition] = []
    private var requestID = UUID()
    private var previewSession = FilePreviewSession()
    private var previewController: NSViewController?
    private var keyboardMonitor: Any?
    private var focusRequestID = UUID()
    private var fileMonitor: Task<Void, Never>?
    private var savedURL: URL?
    private var locationWarning: String?
    private var observedIdentity: FileIdentity?
    private var previewKind: String?
    private var didFinish = false
    private var wantsInitialEditing = false
    private var savingAndReturning = false
    private var openingEditor = false
    private var loadingPreview = false
    private var switchingPreview = false
    private var requestedLine: Int?
    var didClose: (() -> Void)?
    var legacyCommand: ((String) -> Void)?
    private let titleLabel = NSTextField(labelWithString: "正在读取文件…")
    private let detailLabel = NSTextField(labelWithString: "只读预览")
    private let statusLabel = NSTextField(labelWithString: "正在读取文件…")
    private let editButton = NSButton(title: "编辑", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let saveAndReturnItem = NSMenuItem(title: "保存并返回", action: nil, keyEquivalent: "\r")
    private let saveAsItem = NSMenuItem(title: "另存为…", action: nil, keyEquivalent: "s")
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let editingMenuSeparator = NSMenuItem.separator()
    private let expandButton = NSButton()
    private let closeButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let positionLabel = NSTextField(labelWithString: "")
    private let contentView = NSView()
    private var keyboardDocument: FWDocumentHost? { mode == .file ? documentHost : owner?.legacyDocument }

    init(owner: FWBrowserHost, url: URL?, source: String, mode: Mode = .file, initialLine: Int? = nil) {
        self.owner = owner
        self.store = owner.browserStore
        self.url = url
        self.source = source
        self.wantsInitialEditing = source == "edit"
        self.mode = mode
        requestedLine = initialLine
        snapshot = owner.browserStore.capturePreviewSnapshot(source: source)
        // 序列来自用户正在看的排序/筛选快照；搜索命中与编辑入口不混入目录的其他文件。
        previewFiles = mode == .file && source != "search" && source != "edit"
            ? owner.browserStore.orderedEntries.filter { !$0.isBrowsableDirectory }.map { BrowserFileReference(url: $0.url, identity: $0.identity) } : []
        previewIndex = previewFiles.firstIndex { $0.url == url }
        originalResponder = owner.view.window?.firstResponder
        scrollPositions = FWScrollPosition.capture(in: owner.view)
        observedIdentity = url.flatMap { try? FileSystem.identity(at: $0) }
        super.init()
    }

    func present(legacyView: NSView? = nil) {
        guard let owner, let window = owner.view.window else { return }
        // 覆盖整个窗口内容区，连同上游文档标签一起遮住；浏览会话原位保留供返回恢复。
        guard let container = window.contentView else { return }
        windowWasFullScreen = window.styleMask.contains(.fullScreen)
        overlay = FWModalOverlay(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged), name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged), name: NSWindow.didExitFullScreenNotification, object: window)
        owner.setBackgroundInteraction(enabled: false)
        buildChrome()
        window.makeFirstResponder(overlay.dialog)
        installKeyboardMonitor()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        overlay.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.16
            overlay.animator().alphaValue = 1
        }
        if let legacyView {
            mount(legacyView)
            return
        }
        guard let url else { return }
        load(url)
        fileMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self, !self.didFinish else { return }
                await self.checkLocation()
            }
        }
    }

    private func buildChrome() {
        let dialog = overlay.dialog
        dialog.setAccessibilityElement(true)
        dialog.setAccessibilityRole(.group)
        dialog.setAccessibilitySubrole(.dialog)
        dialog.setAccessibilityModal(true)
        dialog.setAccessibilityLabel("文件预览：" + (url?.lastPathComponent ?? "文件编辑"))
        dialog.setAccessibilityIdentifier("FileDeck.preview.dialog")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        configureIcon(expandButton, symbol: "arrow.up.left.and.arrow.down.right", label: "进入全屏（⌃⌘F）", action: #selector(toggleFullScreen))
        expandButton.setAccessibilityIdentifier("FileDeck.preview.fullscreen")
        configureIcon(closeButton, symbol: "chevron.left", label: "返回浏览", action: #selector(closeAction))
        closeButton.title = "返回浏览"; closeButton.imagePosition = .imageLeading
        closeButton.toolTip = "返回浏览（Esc / ⌘W）"
        closeButton.constraints.filter { $0.firstAttribute == .width }.forEach { $0.isActive = false }
        closeButton.widthAnchor.constraint(equalToConstant: 90).isActive = true
        closeButton.setAccessibilityIdentifier("FileDeck.preview.close")
        configureIcon(previousButton, symbol: "chevron.left", label: "预览上一项（⌥←）", action: #selector(previousFile))
        configureIcon(nextButton, symbol: "chevron.right", label: "预览下一项（⌥→）", action: #selector(nextFile))
        previousButton.setAccessibilityIdentifier("FileDeck.preview.previous")
        nextButton.setAccessibilityIdentifier("FileDeck.preview.next")
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.textColor = .secondaryLabelColor
        previousButton.isHidden = true; nextButton.isHidden = true; positionLabel.isHidden = true
        editButton.target = self; editButton.action = #selector(edit)
        editButton.toolTip = "进入源码编辑模式"; editButton.setAccessibilityIdentifier("FileDeck.preview.edit")
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded; saveButton.bezelColor = .controlAccentColor
        saveButton.toolTip = "保存（⌘S）"; saveButton.setAccessibilityIdentifier("FileDeck.preview.save")
        saveAndReturnItem.target = self; saveAndReturnItem.action = #selector(saveAndReturn)
        saveAndReturnItem.identifier = NSUserInterfaceItemIdentifier("FileDeck.preview.save-and-return")
        saveAndReturnItem.toolTip = "保存成功后返回原列表；失败或仍有未保存修改时保留编辑器"
        saveAsItem.target = self; saveAsItem.action = #selector(saveAs)
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.identifier = NSUserInterfaceItemIdentifier("FileDeck.preview.save-as")
        let menu = NSMenu(); menu.autoenablesItems = false
        let menuTitle = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuTitle.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作")
        let revealItem = NSMenuItem(title: "在 Finder 中显示", action: #selector(reveal), keyEquivalent: "")
        revealItem.target = self
        for item in [menuTitle, saveAsItem, saveAndReturnItem, editingMenuSeparator, revealItem] { menu.addItem(item) }
        moreButton.menu = menu; moreButton.bezelStyle = .rounded
        (moreButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        moreButton.toolTip = "更多操作"; moreButton.setAccessibilityLabel("更多操作")
        moreButton.setAccessibilityIdentifier("FileDeck.preview.more")
        moreButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let toolbar = NSStackView(views: [closeButton, titleLabel, detailLabel, spacer, previousButton, positionLabel, nextButton, editButton, saveButton, moreButton, expandButton])
        toolbar.distribution = .fill; toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.setAccessibilityIdentifier("FileDeck.preview.toolbar")
        let divider = NSBox(); divider.boxType = .separator
        let bottomDivider = NSBox(); bottomDivider.boxType = .separator
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("FileDeck.preview.status")
        let footer = NSStackView(views: [statusLabel])
        footer.distribution = .fill
        footer.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)
        for child in [toolbar, divider, contentView, bottomDivider, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false; dialog.addSubview(child)
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: dialog.leadingAnchor), child.trailingAnchor.constraint(equalTo: dialog.trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: dialog.topAnchor), toolbar.heightAnchor.constraint(equalToConstant: 44),
            divider.topAnchor.constraint(equalTo: toolbar.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            contentView.topAnchor.constraint(equalTo: divider.bottomAnchor), contentView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: footer.topAnchor), bottomDivider.heightAnchor.constraint(equalToConstant: 1),
            footer.heightAnchor.constraint(equalToConstant: 24), footer.bottomAnchor.constraint(equalTo: dialog.bottomAnchor)
        ])
        fullScreenChanged()
        updateChrome()
    }

    private func configureIcon(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly; button.bezelStyle = .rounded
        button.target = self; button.action = action; button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func load(_ url: URL) {
        let token = requestID
        let kind = FWDocumentHost.kind(for: url)
        previewKind = kind
        let safeTextKinds = ["text", "code", "json", "yaml", "markdown"]
        if safeTextKinds.contains(kind) || (kind == "csv" && requestedLine != nil) {
            guard !loadingPreview else { return }
            loadingPreview = true
            FWDocumentHost.openPreview(at: url) { [weak self] host, error in
                guard let self, self.requestID == token, !self.didFinish, !self.isClosing else {
                    host?.disposePreview(); return
                }
                self.loadingPreview = false
                if let host {
                    self.mountDocument(host)
                    self.updateChrome()
                } else {
                    // 安全解码失败时仍提供真实只读预览，不把二进制内容送入编辑器。
                    self.mountReadOnly(url)
                    self.locationWarning = error?.localizedDescription
                    self.updateChrome()
                }
            }
        } else { mountReadOnly(url) }
    }

    private func mountReadOnly(_ url: URL) {
        let controller = NSHostingController(rootView: AnyView(FilePreviewView(url: url, session: previewSession)))
        previewController = controller
        owner?.addChild(controller)
        mount(controller.view)
        updateChrome()
    }

    private func mount(_ view: NSView) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview(); view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor), view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    func updateLegacy(title: String, url: URL?, modified: Bool, busy: Bool, canSave: Bool, canSaveAs: Bool) {
        guard mode == .legacy else { return }
        self.url = url; titleLabel.stringValue = title; titleLabel.toolTip = url?.path ?? title
        detailLabel.stringValue = modified ? "编辑 · 未保存" : "文件编辑"
        statusLabel.stringValue = owner?.legacyDocument?.statusText ?? (busy ? "正在处理…" : modified ? "尚未保存修改" : "已保存")
        saveAndReturnItem.isHidden = !(canSave || canSaveAs) && !busy
        saveAndReturnItem.isEnabled = (canSave || canSaveAs) && !busy
        editButton.isHidden = true; saveButton.isHidden = !canSave && !busy; saveAsItem.isHidden = !canSaveAs && !busy
        saveButton.isEnabled = (modified || url == nil) && canSave && !busy; saveAsItem.isEnabled = !busy
        editingMenuSeparator.isHidden = saveAsItem.isHidden && saveAndReturnItem.isHidden
    }

    private func updateChrome() {
        guard overlay != nil else { return }
        titleLabel.stringValue = documentHost?.documentTitle ?? url?.lastPathComponent ?? "文件预览"
        titleLabel.toolTip = documentHost?.documentURL?.path ?? url?.path
        overlay.dialog.setAccessibilityLabel("文件预览：" + titleLabel.stringValue)
        // WK 就绪前不强行切换模式；只消费一次显式编辑请求，状态回调继续驱动原宿主。
        if wantsInitialEditing, documentHost?.canBeginEditing == true {
            wantsInitialEditing = false
            documentHost?.beginEditing()
        }
        if let line = requestedLine, let text = documentHost?.content as? FWTextContent, text.canFind {
            requestedLine = nil
            text.revealLine(line)
        }
        let editing = documentHost?.isEditing == true
        // 序列在打开时固定，位置只在切换时更新；编辑状态刷新不应反复扫描整个大目录。
        let showsNavigation = mode == .file && !editing && previewFiles.count > 1 && previewIndex != nil
        previousButton.isHidden = !showsNavigation; nextButton.isHidden = !showsNavigation; positionLabel.isHidden = !showsNavigation
        previousButton.isEnabled = showsNavigation && previewIndex != 0 && !switchingPreview && !loadingPreview && !openingEditor && !isClosing
        nextButton.isEnabled = showsNavigation && previewIndex != previewFiles.count - 1 && !switchingPreview && !loadingPreview && !openingEditor && !isClosing
        positionLabel.stringValue = previewIndex.map { "\($0 + 1) / \(previewFiles.count)" } ?? ""
        positionLabel.setAccessibilityLabel("当前预览 " + positionLabel.stringValue)
        editButton.isHidden = editing || (documentHost == nil && !canOpenEditor)
        editButton.isEnabled = (documentHost?.canBeginEditing == true || canOpenEditor) && !isClosing && !openingEditor && !switchingPreview
        saveButton.isHidden = !editing
        saveAsItem.isHidden = !editing
        saveAndReturnItem.isHidden = !editing
        saveAndReturnItem.isEnabled = (documentHost?.canSave == true || documentHost?.canSaveAs == true) && !isClosing && !savingAndReturning
        saveButton.isEnabled = documentHost?.canSave == true && (documentHost?.modified == true || documentHost?.documentURL == nil) && !isClosing
        saveAsItem.isEnabled = documentHost?.canSaveAs == true && !isClosing
        editingMenuSeparator.isHidden = !editing
        let labels = ["LOADING": "正在读取", "PREVIEW": "只读预览", "EDITING": "编辑", "DIRTY": "编辑 · 未保存",
                      "SAVING": "正在保存", "SAVE_ERROR": "保存未完成", "LOAD_ERROR": "读取失败", "CONFLICT": "磁盘内容已变化"]
        detailLabel.stringValue = documentHost.flatMap { labels[$0.sessionState] } ?? "只读预览"
        detailLabel.textColor = documentHost?.modified == true ? .systemOrange : .secondaryLabelColor
        if documentHost?.modified == true { detailLabel.stringValue = "● " + detailLabel.stringValue }
        statusLabel.stringValue = openingEditor ? "正在打开编辑器…" : locationWarning ?? documentHost?.statusText ?? "本地只读预览"
        statusLabel.toolTip = statusLabel.stringValue
        statusLabel.textColor = locationWarning != nil || documentHost?.lastError != nil ? .systemOrange : .secondaryLabelColor
    }

    private func checkLocation() async {
        guard let url = documentHost?.documentURL ?? url else { return }
        let token = requestID
        let baseline = observedIdentity
        // 慢卷的属性读取不占用窗口线程；切换文件或保存后的旧检查不能写回新会话。
        let current = await Task.detached(priority: .utility) { try? FileSystem.identity(at: url) }.value
        guard !Task.isCancelled, !didFinish, !isClosing, token == requestID,
              url == (documentHost?.documentURL ?? self.url), baseline == observedIdentity else { return }
        let previousWarning = locationWarning
        if let current {
            if let baseline, current != baseline { locationWarning = "文件状态已变化，请检查磁盘版本后再保存。" }
        } else { locationWarning = "原文件已不存在" }
        if locationWarning != previousWarning { updateChrome() }
    }

    private var canOpenEditor: Bool {
        guard mode == .file, url != nil else { return false }
        // 输入状态回调频繁；已在编辑的宿主直接退出，避免每次键入都读取文件类型元数据。
        guard documentHost == nil || (documentHost?.content is FWTextContent && documentHost?.isEditing == false) else { return false }
        guard let kind = previewKind else { return false }
        let csvSourcePreview = kind == "csv" && documentHost?.content is FWTextContent && documentHost?.isEditing == false
        guard documentHost == nil || csvSourcePreview else { return false }
        return ["word", "spreadsheet", "presentation", "csv", "pdf", "png", "jpeg", "heic"].contains(kind)
    }

    func revealLine(_ line: Int) {
        requestedLine = line
        if documentHost == nil, let url, previewKind == "csv" { load(url) }
        else { updateChrome() }
    }

    private func mountDocument(_ host: FWDocumentHost) {
        previewSession.cancel()
        documentHost?.stateDidChange = nil
        documentHost?.disposePreview()
        documentHost?.removeFromParent()
        if let hosting = previewController as? NSHostingController<AnyView> { hosting.rootView = AnyView(EmptyView()) }
        previewController?.removeFromParent()
        previewController = nil
        documentHost = host
        host.stateDidChange = { [weak self] in self?.updateChrome() }
        owner?.addChild(host)
        mount(host.view)
    }

    @objc private func previousFile() { switchPreview(offset: -1) }
    @objc private func nextFile() { switchPreview(offset: 1) }

    private func switchPreview(offset: Int) {
        guard mode == .file, documentHost?.isEditing != true, !switchingPreview, !loadingPreview,
              !openingEditor, !isClosing, !didFinish, let index = previewIndex,
              previewFiles.indices.contains(index + offset) else { return }
        let file = previewFiles[index + offset]
        switchingPreview = true; updateChrome()
        let token = requestID
        Task { @MainActor [weak self] in
            let identity = await Task.detached(priority: .userInitiated) { try? FileSystem.identity(at: file.url) }.value
            guard let self, self.requestID == token, !self.didFinish, !self.isClosing else { return }
            self.switchingPreview = false
            guard let identity, file.identity == nil || file.identity == identity else {
                self.locationWarning = "目标文件已变化或不存在，请返回列表刷新后重新预览。"
                self.updateChrome(); return
            }
            // 切换只释放只读资源，保留同一模态层、原浏览快照和焦点；迟到读取由 requestID 拒绝。
            self.requestID = UUID(); self.focusRequestID = UUID(); self.previewSession.cancel()
            self.documentHost?.stateDidChange = nil
            self.documentHost?.disposePreview(); self.documentHost?.removeFromParent(); self.documentHost = nil
            if let hosting = self.previewController as? NSHostingController<AnyView> { hosting.rootView = AnyView(EmptyView()) }
            self.previewController?.removeFromParent(); self.previewController = nil
            self.contentView.subviews.forEach { $0.removeFromSuperview() }
            self.url = file.url; self.observedIdentity = identity; self.locationWarning = nil; self.requestedLine = nil
            self.previewIndex = index + offset
            self.owner?.view.window?.makeFirstResponder(self.overlay.dialog)
            self.load(file.url); self.updateChrome()
        }
    }

    @objc private func edit() {
        guard !switchingPreview else { return }
        if let documentHost, !canOpenEditor { documentHost.beginEditing(); updateChrome(); return }
        guard canOpenEditor, !openingEditor, !isClosing, let url, let owner else { return }
        guard let kind = previewKind else { return }
        if ["word", "spreadsheet", "presentation"].contains(kind) {
            // Office 继续复用已有标签与 CEF 保存链；先正常关闭只读层，再打开同一文件。
            requestClose { [weak owner] closed in if closed { owner?.editorBridge.open(url) } }
            return
        }
        openingEditor = true
        loadingPreview = false
        requestedLine = nil
        requestID = UUID() // 显式编辑替代尚在读取的 CSV 文本预览，旧完成回调不能再覆盖新编辑器。
        updateChrome()
        let token = requestID
        FWDocumentHost.openDocument(at: url, kind: kind) { [weak self] host, error in
            guard let self, self.requestID == token, !self.didFinish, !self.isClosing else { host?.disposePreview(); return }
            self.openingEditor = false
            if let host {
                self.mountDocument(host)
            } else { self.locationWarning = error?.localizedDescription ?? "无法打开编辑器，请重试。" }
            self.updateChrome()
        }
    }
    @objc private func save() { performSave(saveAs: false) }
    @objc private func saveAs() { performSave(saveAs: true) }
    @objc private func saveAndReturn() { performSave(saveAs: false, returning: true) }
    /// 成功返回仍经过关闭门禁；失败、另存取消或保存期间新输入均保留同一编辑会话。
    private func performSave(saveAs: Bool, returning: Bool = false) {
        guard !isClosing, !savingAndReturning else { return }
        if mode == .legacy { legacyCommand?(returning ? "saveAndReturn" : saveAs ? "saveAs" : "save"); return }
        guard let host = documentHost, !returning || host.canSave || host.canSaveAs else { return }
        savingAndReturning = returning; updateChrome()
        // HEIC 等格式不能原样编码；保存返回沿用现有另存流程，不能绕过格式与目标确认。
        let requiresSaveAs = saveAs || (returning && !host.canSave && host.canSaveAs)
        let saveGeneration = host.successfulSaveGeneration
        host.save(in: store.currentDirectory, saveAs: requiresSaveAs) { [weak self, weak host] success in
            guard let self, let host else { return }
            self.savingAndReturning = false
            if host.successfulSaveGeneration != saveGeneration {
                self.savedURL = host.documentURL
                self.observedIdentity = self.savedURL.flatMap { try? FileSystem.identity(at: $0) }
                self.locationWarning = nil
                if success && returning && !host.modified && !host.busy { self.requestClose { _ in }; return }
            }
            self.updateChrome()
        }
    }
    @objc private func reveal() { if let url = documentHost?.documentURL ?? url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func closeAction() { requestClose { _ in } }
    @objc func toggleFullScreen() {
        guard let window = overlay.window, !isClosing else { return }
        // 使用系统全屏 Space，不能再用缩放弹窗尺寸模拟全屏。
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }

    @objc private func fullScreenChanged() {
        expandButton.image = NSImage(systemSymbolName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        expandButton.toolTip = isFullScreen ? "退出全屏（⌃⌘F）" : "进入全屏（⌃⌘F）"
        expandButton.setAccessibilityLabel(expandButton.toolTip)
    }

    /// 所有退出入口共用此门：在保存/确认完成前不卸载视图，也不改变工作台快照。
    func requestClose(completion: @escaping (Bool) -> Void) {
        guard !isClosing, !didFinish else { completion(false); return }
        if mode == .legacy { legacyCommand?("close"); completion(false); return }
        if let host = documentHost {
            isClosing = true; updateChrome()
            host.requestClose(in: store.currentDirectory) { [weak self] closed in
                guard let self else { completion(false); return }
                self.isClosing = false
                if closed {
                    self.savedURL = host.lastSavedURL ?? self.savedURL
                    self.finishClose(completion: completion)
                } else { self.updateChrome(); completion(false) }
            }
        } else {
            isClosing = true
            requestID = UUID()
            finishClose(completion: completion)
        }
    }

    /// 上游标签已通过自己的保存保护后，才允许销毁兼容编辑容器。
    func finishLegacyClose() { if mode == .legacy { finishClose { _ in } } }

    private func finishClose(completion: @escaping (Bool) -> Void) {
        guard !didFinish else { completion(false); return }
        isClosing = true; requestID = UUID(); fileMonitor?.cancel(); previewSession.cancel()
        documentHost?.disposePreview()
        Task { @MainActor in
            // 慢目录刷新期间仍保留遮罩与键盘门，不能让用户的新导航被旧快照覆盖。
            if mode == .file { await store.refreshAfterPreview(snapshot: snapshot, savedURL: savedURL) }
            if !self.windowWasFullScreen, self.isFullScreen { self.overlay.window?.toggleFullScreen(nil) }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration; self.overlay.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, !self.didFinish else { completion(false); return }
                    self.didFinish = true
                    self.documentHost?.stateDidChange = nil
                    self.documentHost?.removeFromParent()
                    if let hosting = self.previewController as? NSHostingController<AnyView> { hosting.rootView = AnyView(EmptyView()) }
                    self.previewController?.removeFromParent()
                    self.contentView.subviews.forEach { $0.removeFromSuperview() }
                    self.overlay.removeFromSuperview()
                    NotificationCenter.default.removeObserver(self)
                    if let keyboardMonitor = self.keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
                    self.owner?.setBackgroundInteraction(enabled: true)
                    self.owner?.view.layoutSubtreeIfNeeded()
                    await Task.yield()
                    self.scrollPositions.forEach { $0.restore() }
                    self.restoreFocus()
                    self.didClose?()
                    completion(true)
                }
            })
        }
    }

    private func restoreFocus() {
        guard let owner, let window = owner.view.window else { return }
        if let original = originalResponder as? NSView, original.window === window,
           original.isDescendant(of: owner.view), !original.isHiddenOrHasHiddenAncestor,
           original.acceptsFirstResponder, (original as? NSControl)?.isEnabled != false {
            window.makeFirstResponder(original); return
        }
        let candidates = owner.view.allDescendants.filter { $0 is NSTableView || $0 is NSCollectionView }
        if let list = candidates.last(where: { !$0.isHiddenOrHasHiddenAncestor && $0.acceptsFirstResponder }) { window.makeFirstResponder(list) }
        else { window.makeFirstResponder(owner.backgroundView) }
    }

    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, !self.didFinish, let window = self.owner?.view.window else { return event }
            let fullScreenShortcut = event.type == .keyDown
                && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control]
                && event.charactersIgnoringModifiers?.lowercased() == "f"
            guard event.window === window else { return event }
            // NSAlert/NSSavePanel 是顶层系统模态，键盘只能交给该 sheet。
            guard window.attachedSheet == nil else { return event }
            if self.isClosing { return nil }
            if event.type != .keyDown {
                self.focusRequestID = UUID()
                let point = self.overlay.convert(event.locationInWindow, from: nil)
                if !self.overlay.bounds.contains(point) {
                    // 原窗口标题栏的文档标签也属于背景；仅保留系统窗口按钮与边缘调整。
                    let standardButton = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains { type in
                        guard let button = window.standardWindowButton(type) else { return false }
                        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
                    }
                    let framePoint = window.convertPoint(toScreen: event.locationInWindow)
                    let nearEdge = min(framePoint.x - window.frame.minX, window.frame.maxX - framePoint.x,
                                       framePoint.y - window.frame.minY, window.frame.maxY - framePoint.y) < 8
                    return standardButton || nearEdge ? event : nil
                }
                return event
            }
            let command = event.modifierFlags.contains(.command)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .option,
               [123, 124].contains(event.keyCode), self.mode == .file, self.documentHost?.isEditing != true,
               window.firstResponder === self.overlay.dialog {
                self.switchPreview(offset: event.keyCode == 123 ? -1 : 1); return nil
            }
            if event.keyCode == 53 {
                self.trace("Esc received")
                if let host = self.keyboardDocument {
                    host.consumeEscape { [weak self] consumed in
                        self?.trace("Esc consumed=\(consumed)")
                        if !consumed { self?.requestClose { closed in self?.trace("Esc closed=\(closed)") } }
                    }
                } else { self.requestClose { _ in } }
                return nil
            }
            if fullScreenShortcut {
                self.toggleFullScreen(); return nil
            }
            if command && event.keyCode == 36 { self.saveAndReturn(); return nil }
            if command && key == "e", self.documentHost?.canBeginEditing == true { self.edit(); return nil }
            if event.keyCode == 49, !command, self.mode == .file, self.documentHost?.isEditing != true,
               window.firstResponder === self.overlay.dialog { self.requestClose { _ in }; return nil }
            if command && key == "w" { self.requestClose { _ in }; return nil }
            if command && key == "s" { self.performSave(saveAs: event.modifierFlags.contains(.shift)); return nil }
            // 打开时焦点留在弹窗容器；首次全选显式交给正文，避免被容器吞掉或落到背景文件列表。
            if key == "a", event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               window.firstResponder === self.overlay.dialog {
                if let text = self.keyboardDocument?.content as? FWTextContent, text.selectAll() { return nil }
                if let text = self.contentView.allDescendants.compactMap({ $0 as? NSTextView }).first(where: { $0.isSelectable }) {
                    window.makeFirstResponder(text)
                    text.selectAll(nil)
                    return nil
                }
            }
            if command && ["f", "z"].contains(key), let host = self.keyboardDocument {
                // DOM 才知道 WK 当前焦点属于正文还是查找输入；不要按文档 canUndo 抢走输入框历史。
                if key == "z", let responder = window.firstResponder as? NSView {
                    if responder is NSTextView { return event }
                    if let text = host.content as? FWTextContent, self.contentView.allDescendants.contains(where: {
                       guard let web = $0 as? WKWebView else { return false }
                       return responder === web || responder.isDescendant(of: web)
                    }) {
                        text.handleHistoryKey(redo: event.modifierFlags.contains(.shift)); return nil
                    }
                }
                if key == "f" { host.find() }
                else if event.modifierFlags.contains(.shift) { host.redo() } else { host.undo() }
                return nil
            }
            if event.keyCode == 48 {
                // 普通 Tab 留给正文缩进；Ctrl+Tab 明确离开编辑器，保留可访问的模态焦点环。
                self.advanceFocus(backward: event.modifierFlags.contains(.shift),
                                  allowTextIndent: event.modifierFlags.intersection([.command, .control, .option]).isEmpty)
                return nil
            }
            if let responder = window.firstResponder as? NSView,
               responder !== self.overlay.dialog && !responder.isDescendant(of: self.overlay.dialog) {
                window.makeFirstResponder(self.overlay.dialog)
                return nil
            }
            return event
        }
    }

    private func trace(_ message: String) {
        if ProcessInfo.processInfo.environment["FW_OFFICE_SMOKE_DIR"] != nil {
            print("MODAL", message); fflush(stdout)
        }
    }

    private func advanceFocus(backward: Bool, allowTextIndent: Bool) {
        guard let window = owner?.view.window else { return }
        let request = UUID()
        focusRequestID = request
        if let responder = window.firstResponder as? NSView,
           let web = overlay.dialog.allDescendants.compactMap({ $0 as? WKWebView }).first(where: { responder === $0 || responder.isDescendant(of: $0) }) {
            // WK 是一个原生 key view，但内部仍有模式按钮和查找控件；先走完网页焦点再回到原生环。
            advanceWebFocus(web, backward: backward, entering: false, request: request, allowTextIndent: allowTextIndent) { [weak self] handled in
                if !handled { self?.advanceNativeFocus(backward: backward, request: request) }
            }
        } else { advanceNativeFocus(backward: backward, request: request) }
    }

    private func advanceNativeFocus(backward: Bool, request: UUID) {
        guard let window = owner?.view.window else { return }
        // 独立建立模态键盘环，避免默认 key-view 链走进背景工具栏。
        let controls = overlay.dialog.allDescendants.filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.acceptsFirstResponder && (($0 as? NSControl)?.isEnabled != false)
                && ($0 is NSButton || $0 is WKWebView || $0 is NSTextView || $0 is NSPopUpButton)
        }
        guard !controls.isEmpty else { window.makeFirstResponder(overlay.dialog); return }
        let responder = window.firstResponder as? NSView
        let current = controls.firstIndex { candidate in responder === candidate || responder?.isDescendant(of: candidate) == true }
        let index = current.map { ($0 + (backward ? -1 : 1) + controls.count) % controls.count } ?? (backward ? controls.count - 1 : 0)
        window.makeFirstResponder(controls[index])
        if let web = controls[index] as? WKWebView {
            advanceWebFocus(web, backward: backward, entering: true, request: request) { _ in }
        }
    }

    private func advanceWebFocus(_ web: WKWebView, backward: Bool, entering: Bool, request: UUID, allowTextIndent: Bool = false,
                                 completion: @escaping (Bool) -> Void) {
        Task { @MainActor [weak self, weak web] in
            guard let self, let web, self.focusRequestID == request, !self.isClosing, !self.didFinish else { return }
            let script = """
            if (!entering && allowTextIndent && window.workbench?.indentSelection?.({backward}) === true) return true;
            const nodes = [...document.querySelectorAll('button,input,textarea,select,[contenteditable="true"],[tabindex]')]
              .filter(node => !node.disabled && node.tabIndex >= 0 && node.getClientRects().length > 0);
            const current = nodes.findIndex(node => node === document.activeElement || node.contains(document.activeElement));
            const next = entering || current < 0 ? (backward ? nodes.length - 1 : 0) : current + (backward ? -1 : 1);
            if (next < 0 || next >= nodes.length) return false;
            nodes[next].focus({preventScroll: true});
            return document.activeElement === nodes[next] || nodes[next].contains(document.activeElement);
            """
            let handled = (try? await web.callAsyncJavaScript(script, arguments: ["backward": backward, "entering": entering, "allowTextIndent": allowTextIndent],
                                                              in: nil, contentWorld: .page)) as? Bool ?? false
            // 关闭、点击其他控件或更新的 Tab 已使旧请求失效时，不能再抢走焦点。
            guard self.focusRequestID == request, !self.isClosing, !self.didFinish,
                  let window = self.owner?.view.window, web.window === window, window.attachedSheet == nil else { return }
            completion(handled)
        }
    }
}

@MainActor
private final class FWScrollPosition {
    weak var view: NSScrollView?
    let origin: NSPoint
    init(_ view: NSScrollView) { self.view = view; origin = view.contentView.bounds.origin }
    static func capture(in view: NSView) -> [FWScrollPosition] { view.allDescendants.compactMap { ($0 as? NSScrollView).map(FWScrollPosition.init) } }
    func restore() {
        guard let view, view.window != nil else { return }
        view.contentView.scroll(to: origin); view.reflectScrolledClipView(view.contentView)
    }
}

@MainActor
final class FWModalDialogView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { /* 未绑定的按键不传到背景工作台。 */ }
}

@MainActor
final class FWModalOverlay: NSView {
    let dialog = FWModalDialogView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dialog.wantsLayer = true
        addSubview(dialog)
        updateBackground()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            dialog.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
    override func layout() {
        super.layout()
        // 工作层默认贴合整个窗口内容区；不再保留弹窗边距、遮罩和圆角。
        dialog.frame = bounds
    }
    override func mouseDown(with event: NSEvent) { }
    override func rightMouseDown(with event: NSEvent) { }
    override func scrollWheel(with event: NSEvent) { }
}

extension NSView {
    var allDescendants: [NSView] { subviews.flatMap { [$0] + $0.allDescendants } }
}
