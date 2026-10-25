import AppKit
@preconcurrency import WebKit

/// 每个固定标签保留自己的 WebKit 编辑器与 TextDocumentSession；切换标签不重建撤销历史。
@MainActor
final class FWTextContent: NSViewController, FWNativeContent, WKNavigationDelegate, WKUIDelegate {
    let kind: WorkbenchFileKind
    private let session: TextDocumentSession
    var onStateChanged: (() -> Void)?
    var onSaveRecoveryDraft: (() -> Void)?
    var controller: NSViewController { self }
    var id: UUID { session.id }
    var path: URL? { session.path }
    var contentTitle: String { path?.lastPathComponent ?? "未命名." + FWDocumentHost.fileExtension(for: kind) }
    var isModified: Bool { session.isModified }
    var isReadOnly: Bool { session.isReadOnly || !isEditing }
    private(set) var isEditing: Bool
    var canBeginEditing: Bool { !isEditing && !session.isReadOnly && editorReady && failure == nil && !isBusy }
    var canCloseWhileBusy: Bool { loading && !operationInFlight && !session.isBusy }
    var statusText: String { status.stringValue }
    var loadError: String? { failure?.localizedDescription }
    var isLoading: Bool { loading }
    var isBusy: Bool { operationInFlight || loading || session.isBusy }
    var availableOperations: Set<FileOperation> {
        guard !disposed, !operationInFlight, isEditing else { return [] }
        // 进程故障后只能显式另存最近已同步的草稿，避免把可能缺少最后输入的快照直接覆盖原文。
        if failure != nil { return session.availableOperations.intersection([.saveAs]) }
        guard editorReady else { return [] }
        return session.availableOperations
    }

    private var webView: WKWebView!
    private let editorContainer = NSView()
    private let status = NSTextField(labelWithString: "正在加载编辑器…")
    private let findButton = NSButton(title: "查找与替换", target: nil, action: nil)
    private let formatButton = NSButton(title: "格式化 JSON", target: nil, action: nil)
    private let recoverySaveButton = NSButton(title: "另存内存草稿…", target: nil, action: nil)
    private let recoveryEditorButton = NSButton(title: "恢复编辑器", target: nil, action: nil)
    private var initialNavigationStarted = false
    private var pageLoaded = false
    private var bridgeReady = false
    private var editorReady = false
    private var loading = true
    private var operationInFlight = false
    private var failure: Error?
    private var disposed = false
    private weak var capturedResponder: NSResponder?
    private var bridgeSessionID = UUID().uuidString
    private var timeoutTask: Task<Void, Never>?
    private var indexURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("FileWorkbenchEditors/index.html")
    }

    static func open(url: URL, kind: WorkbenchFileKind, preview: Bool = false) async throws -> FWTextContent {
        let session = try await TextDocumentSession.open(url: url)
        return FWTextContent(session: session, kind: kind, editing: !preview)
    }

    static func create(kind: WorkbenchFileKind) -> FWTextContent {
        FWTextContent(session: .create(), kind: kind)
    }

    private init(session: TextDocumentSession, kind: WorkbenchFileKind, editing: Bool = true) {
        self.session = session
        self.kind = kind
        isEditing = editing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        findButton.target = self
        findButton.action = #selector(findAction)
        formatButton.target = self
        formatButton.action = #selector(formatJSON)
        formatButton.isHidden = kind != .json
        recoverySaveButton.target = self
        recoverySaveButton.action = #selector(saveRecoveryDraft)
        recoveryEditorButton.target = self
        recoveryEditorButton.action = #selector(recoverEditor)
        recoveryEditorButton.toolTip = "恢复最近已同步的正文；原编辑器的撤销历史无法恢复。"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [status, spacer, recoverySaveButton, recoveryEditorButton, findButton, formatButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for child in [toolbar, editorContainer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        loadEditor()
    }

    /// 仅重建网页渲染层；TextDocumentSession、磁盘指纹和未保存内容始终留在原会话。
    private func loadEditor() {
        guard !disposed else { return }
        releaseEditor()
        failure = nil
        initialNavigationStarted = false
        pageLoaded = false
        bridgeReady = false
        editorReady = false
        loading = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(FWTextMessageHandler(owner: self), name: "workbench")
        let editor = FWEditorWebView(frame: .zero, configuration: configuration)
        editor.owner = self
        editor.navigationDelegate = self
        editor.uiDelegate = self
        editor.allowsLinkPreview = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            editor.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor)
        ])
        webView = editor
        changed()
        guard let indexURL, FileManager.default.fileExists(atPath: indexURL.path) else {
            fail(NSError(domain: "FileWorkbench.Editor", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "应用包缺少本地编辑器资源，请重新构建应用。"]), fatal: true)
            return
        }
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, !self.editorReady else { return }
            self.fail(NSError(domain: "FileWorkbench.Editor", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "本地编辑器加载超时，未修改原文件。"]), fatal: true)
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !disposed, failure == nil, message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == indexURL?.standardizedFileURL,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { bridgeReady = true; initializeIfReady(); return }
        guard body["id"] as? String == bridgeSessionID else { return }
        if type == "change" || type == "state", editorReady, let text = body["text"] as? String {
            do {
                // dirty 只由完整文本会话与真实保存基线计算，不能直接相信页面提供的布尔值。
                if !isReadOnly { try session.replaceText(text) }
                changed()
            } catch { fail(error) }
        } else if type == "error" {
            fail(NSError(domain: "FileWorkbench.Editor", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: body["message"] as? String ?? "编辑操作未完成。"] ))
        }
    }

    private func initializeIfReady() {
        guard !disposed, pageLoaded, bridgeReady, !editorReady, failure == nil else { return }
        bridgeReady = false // 防止 ready 与 didFinish 重复建立会话。
        let token = UUID().uuidString
        bridgeSessionID = token
        Task {
            do {
                _ = try await javascript("return window.workbench.open(document)", arguments: ["document": [
                    "id": token, "text": session.text, "language": language, "readOnly": isReadOnly,
                    "mode": !isEditing && kind == .markdown ? "preview" : "source"
                ]])
                guard !disposed, bridgeSessionID == token else { return }
                // open 默认把正文当作基线；恢复的是草稿时，应恢复实际落盘基线而非清除 dirty。
                if session.isModified {
                    _ = try await javascript("return window.workbench.markSaved(document)", arguments: ["document": [
                        "id": token, "text": session.savedText
                    ]])
                    guard !disposed, bridgeSessionID == token else { return }
                }
                editorReady = true
                loading = false
                webView.isHidden = false
                timeoutTask?.cancel()
                changed()
            } catch { if !disposed, bridgeSessionID == token { fail(error, fatal: true) } }
        }
    }

    private var language: String {
        switch kind {
        case .markdown: return "markdown"
        case .json: return "json"
        case .yaml: return "yaml"
        case .code: return path?.pathExtension.isEmpty == false ? path!.pathExtension : path?.lastPathComponent ?? "text"
        default: return "text"
        }
    }

    private func javascript(_ source: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard !disposed, let webView else { throw DocumentSessionError.closed }
        return try await webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .page)
    }

    func beginEditing() {
        guard canBeginEditing else { return }
        operationInFlight = true
        let token = bridgeSessionID
        Task {
            defer { operationInFlight = false; changed() }
            do {
                _ = try await javascript("return window.workbench.setEditing({id, enabled: true})", arguments: ["id": token])
                guard !disposed, token == bridgeSessionID else { return }
                isEditing = true
            } catch { if !disposed, token == bridgeSessionID { fail(error) } }
        }
    }

    func captureInteraction() async {
        capturedResponder = webView?.window?.firstResponder
        guard editorReady else { return }
        _ = try? await javascript("return window.workbench.captureInteraction(id)", arguments: ["id": bridgeSessionID])
    }

    func suspendInteraction(_ suspended: Bool) async {
        guard editorReady else { return }
        _ = try? await javascript("return window.workbench.suspend({id, suspended})", arguments: ["id": bridgeSessionID, "suspended": suspended])
    }

    func restoreInteraction() async {
        guard !disposed else { return }
        if let window = webView?.window, let responder = capturedResponder {
            if let view = responder as? NSView, view.window === window { window.makeFirstResponder(view) }
        }
        guard editorReady else { return }
        _ = try? await javascript("return window.workbench.restoreInteraction(id)", arguments: ["id": bridgeSessionID])
        capturedResponder = nil
    }

    func consumeEscape() async -> Bool {
        guard editorReady, !disposed else { return false }
        return (try? await javascript("return window.workbench.consumeEscape(id)", arguments: ["id": bridgeSessionID])) as? Bool ?? false
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        releaseEditor()
        loading = false
        onSaveRecoveryDraft = nil
    }

    private func releaseEditor() {
        bridgeSessionID = UUID().uuidString
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "workbench")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        capturedResponder = nil
    }

    @objc private func saveRecoveryDraft() {
        guard failure != nil, availableOperations.contains(.saveAs) else { return }
        onSaveRecoveryDraft?()
    }

    @objc private func recoverEditor() {
        guard !disposed, failure != nil, !isBusy, !session.isClosed, view.window?.attachedSheet == nil else { return }
        loadEditor()
    }

    private func synchronizeText() async throws {
        guard editorReady, failure == nil else { throw failure ?? DocumentSessionError.busy }
        let token = bridgeSessionID
        guard let text = try await javascript("return window.workbench.getText(id)", arguments: ["id": token]) as? String,
              token == bridgeSessionID else { throw DocumentSessionError.busy }
        if !isReadOnly { try session.replaceText(text) }
    }

    /// 仅由门面经过显式 Smoke 环境门禁后调用，输入经过真实 contenteditable/CodeMirror 事务。
    func replaceTextForSmoke(_ text: String) async throws {
        guard editorReady, !isBusy, !isReadOnly, failure == nil else { throw DocumentSessionError.busy }
        // WebKit 的 insertText 会把 CRLF 拆成两个换行；DOM 使用 LF，原始分隔符由既有映射恢复。
        let input = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let result = try await javascript("""
        const content = document.querySelector('.cm-content');
        if (!content) return false;
        content.focus();
        document.execCommand('selectAll');
        return document.execCommand('insertText', false, text);
        """, arguments: ["text": input])
        guard result as? Bool == true else {
            throw NSError(domain: "FileWorkbench.Editor", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "真实编辑器未接受验收输入。"])
        }
        try await synchronizeText()
        changed()
    }

    func save(overwriteExternalChanges: Bool) async throws {
        try await persist(to: nil, overwrite: overwriteExternalChanges)
    }

    func saveAs(to destination: URL, overwriteExternalChanges: Bool) async throws {
        try await persist(to: destination, overwrite: overwriteExternalChanges)
    }

    private func persist(to destination: URL?, overwrite: Bool) async throws {
        guard !isBusy else { throw DocumentSessionError.busy }
        operationInFlight = true
        changed()
        defer { operationInFlight = false; changed() }
        if let failure {
            guard isEditing, let destination else { throw failure }
            try await session.saveAs(to: destination, overwriteExternalChanges: overwrite)
            return
        }
        try await synchronizeText()
        let savedText = session.text
        if let destination { try await session.saveAs(to: destination, overwriteExternalChanges: overwrite) }
        else { try await session.save(overwriteExternalChanges: overwrite) }
        // 写盘期间进程也可能终止；已成功持久化的快照不应因无法回调网页而被误报为写盘失败。
        guard failure == nil, editorReady else { return }
        // 保存等待期间的新输入仍是未保存内容；仅确认实际落盘的快照，不重新 open 或清空历史。
        do {
            _ = try await javascript("return window.workbench.markSaved(document)", arguments: [
                "document": ["id": bridgeSessionID, "text": savedText]
            ])
            try await synchronizeText()
        } catch {
            // JS await 期间也可能崩溃：保存基线已经推进，保留后续输入的 dirty，单独进入网页恢复态。
            if failure == nil {
                fail(NSError(domain: "FileWorkbench.Editor", code: 6,
                             userInfo: [NSLocalizedDescriptionKey: "文件已写入，但编辑器同步中断。可另存最近已同步的内容或恢复编辑器；尚未同步的最后输入可能缺失。"]), fatal: true)
            }
        }
    }

    func reload(discardChanges: Bool) async throws {
        guard !isBusy else { throw DocumentSessionError.busy }
        let wasReady = editorReady
        loading = true
        editorReady = false
        webView.isHidden = true
        changed()
        do {
            try await session.reload(discardChanges: discardChanges)
            if failure != nil { loadEditor() }
            else {
                bridgeReady = true
                initializeIfReady()
            }
        } catch {
            loading = false
            editorReady = wasReady && failure == nil
            webView.isHidden = false
            changed()
            throw error
        }
    }

    func export(to destination: URL, format: WorkbenchFileKind, overwriteExisting: Bool) async throws {
        throw DocumentSessionError.unsupportedOperation(.export)
    }

    func close(discardChanges: Bool) async throws {
        if !discardChanges, editorReady { try await synchronizeText() }
        try await session.close(discardChanges: discardChanges)
        dispose()
    }

    func undo() { command("undo") }
    func redo() { command("redo") }
    func find() { command("search") }
    @objc private func findAction() { find() }
    @objc private func formatJSON() { command("formatJSON") }

    private func command(_ name: String) {
        guard editorReady, failure == nil else { return }
        let token = bridgeSessionID
        Task {
            do { _ = try await javascript("return window.workbench[command](id)", arguments: ["command": name, "id": token]) }
            catch { if !disposed, token == bridgeSessionID { fail(error) } }
        }
    }

    private func changed(statusMessage: String? = nil) {
        guard !disposed else { return }
        if let statusMessage {
            status.stringValue = statusMessage
            status.toolTip = statusMessage
        } else if failure == nil {
            status.stringValue = loading ? "正在加载编辑器…" : session.encoding.name + (isReadOnly ? " · 只读" : "") + (isModified ? " · 未保存" : "")
            status.toolTip = status.stringValue
        }
        findButton.isEnabled = editorReady && failure == nil
        formatButton.isEnabled = editorReady && failure == nil && !isReadOnly
        recoverySaveButton.isHidden = failure == nil || !isEditing
        recoverySaveButton.isEnabled = availableOperations.contains(.saveAs)
        recoveryEditorButton.isHidden = failure == nil
        recoveryEditorButton.isEnabled = !isBusy && !session.isClosed
        onStateChanged?()
    }

    private func fail(_ error: Error, fatal: Bool = false) {
        guard !disposed else { return }
        if fatal {
            failure = error
            loading = false
            editorReady = false
            bridgeSessionID = UUID().uuidString
            timeoutTask?.cancel()
        }
        changed(statusMessage: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        pageLoaded = true
        initializeIfReady()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        fail(error, fatal: true)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        fail(error, fatal: true)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        fail(NSError(domain: "FileWorkbench.Editor", code: 4,
                     userInfo: [NSLocalizedDescriptionKey: "编辑器已停止，最近已同步的内容仍在内存中，可另存草稿或恢复编辑器；尚未同步的最后输入可能缺失。"]), fatal: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView === self.webView, !initialNavigationStarted, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.url?.standardizedFileURL == indexURL?.standardizedFileURL {
            initialNavigationStarted = true
            decisionHandler(.allow)
        } else { decisionHandler(.cancel) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

/// WKUserContentController 强持有 handler，使用弱代理避免关闭标签后编辑器及全文一直驻留。
@MainActor
private final class FWTextMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: FWTextContent?
    init(owner: FWTextContent) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

/// 菜单的 first-responder 撤销使用 CodeMirror 历史，与编辑器内快捷键保持同一份历史。
@MainActor
private final class FWEditorWebView: WKWebView {
    weak var owner: FWTextContent?
    @objc(undo:) func performUndo(_ sender: Any?) { owner?.undo() }
    @objc(redo:) func performRedo(_ sender: Any?) { owner?.redo() }
    @objc(performFindPanelAction:) func performFind(_ sender: Any?) { owner?.find() }
}
