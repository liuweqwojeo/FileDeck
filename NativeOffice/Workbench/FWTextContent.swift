import AppKit
@preconcurrency import WebKit

/// 每个固定标签保留自己的 WebKit 编辑器与 TextDocumentSession；切换标签不重建撤销历史。
@MainActor
final class FWTextContent: NSViewController, FWNativeContent, WKNavigationDelegate, WKUIDelegate {
    let kind: WorkbenchFileKind
    private let session: TextDocumentSession
    var onStateChanged: (() -> Void)?
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
        guard editorReady, failure == nil, !operationInFlight else { return [] }
        guard isEditing else { return [] }
        return session.availableOperations
    }

    private var webView: WKWebView!
    private let status = NSTextField(labelWithString: "正在加载编辑器…")
    private let formatButton = NSButton(title: "格式化 JSON", target: nil, action: nil)
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
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(FWTextMessageHandler(owner: self), name: "workbench")
        let editor = FWEditorWebView(frame: .zero, configuration: configuration)
        editor.owner = self
        webView = editor
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false

        let findButton = NSButton(title: "查找与替换", target: self, action: #selector(findAction))
        formatButton.target = self
        formatButton.action = #selector(formatJSON)
        formatButton.isHidden = kind != .json
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [status, spacer, findButton, formatButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for child in [toolbar, webView!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
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
        guard !disposed, message.webView === webView, message.frameInfo.isMainFrame,
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
            } catch { if !disposed { fail(error) } }
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
        bridgeSessionID = UUID().uuidString
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "workbench")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        loading = false
        capturedResponder = nil
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
        try await synchronizeText()
        let savedText = session.text
        if let destination { try await session.saveAs(to: destination, overwriteExternalChanges: overwrite) }
        else { try await session.save(overwriteExternalChanges: overwrite) }
        // 保存等待期间的新输入仍是未保存内容；仅确认实际落盘的快照，不重新 open 或清空历史。
        _ = try await javascript("return window.workbench.markSaved(document)", arguments: [
            "document": ["id": bridgeSessionID, "text": savedText]
        ])
        try await synchronizeText()
    }

    func reload(discardChanges: Bool) async throws {
        guard !isBusy else { throw DocumentSessionError.busy }
        loading = true
        editorReady = false
        webView.isHidden = true
        changed()
        do {
            try await session.reload(discardChanges: discardChanges)
            failure = nil
            bridgeReady = true
            initializeIfReady()
        } catch {
            loading = false
            editorReady = true
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
            catch { fail(error) }
        }
    }

    private func changed() {
        guard !disposed else { return }
        if failure == nil {
            status.stringValue = loading ? "正在加载编辑器…" : session.encoding.name + (isReadOnly ? " · 只读" : "") + (isModified ? " · 未保存" : "")
            status.toolTip = status.stringValue
        }
        formatButton.isEnabled = editorReady && !isReadOnly
        onStateChanged?()
    }

    private func fail(_ error: Error, fatal: Bool = false) {
        guard !disposed else { return }
        if fatal { failure = error; loading = false; editorReady = false; timeoutTask?.cancel() }
        status.stringValue = error.localizedDescription
        status.toolTip = error.localizedDescription
        onStateChanged?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoaded = true; initializeIfReady() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error, fatal: true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error, fatal: true) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(NSError(domain: "FileWorkbench.Editor", code: 4,
                     userInfo: [NSLocalizedDescriptionKey: "编辑器进程已停止，内存中的文本仍保留。请勿丢弃未保存内容。"]), fatal: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !initialNavigationStarted, navigationAction.targetFrame?.isMainFrame == true,
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
