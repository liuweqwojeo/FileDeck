import AppKit
@preconcurrency import WebKit

/// 只操作本进程的隔离窗口与临时样本，使用真实 WK、NSAlert、NSSavePanel 和文件系统。
@MainActor
final class ModalDocumentTests: NSObject, NSApplicationDelegate {
    let output: URL
    init(output: URL) { self.output = output; super.init() }
    var window: NSWindow!
    var checks: [[String: Any]] = []
    var finished = false
    var activity: NSObjectProtocol?
    enum Failed: Error { case assertion(String) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 自动验收不依赖用户持续激活测试窗口，避免 App Nap 合并桥接与等待计时器。
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                        reason: "FileDeck 隔离文档关闭验收")
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do { try await run(); finish(true) }
            catch {
                let detail = String(describing: error)
                trace("FAIL " + detail)
                checks.append(["check": "执行", "passed": false, "detail": detail])
                finish(false)
            }
        }
        Task { try? await Task.sleep(for: .seconds(90)); if !finished { finish(false) } }
    }
    func trace(_ title: String) { print("STEP \(title)"); fflush(stdout) }
    func check(_ title: String, _ passed: Bool) throws {
        checks.append(["check": title, "passed": passed])
        print("\(passed ? "PASS" : "FAIL") \(title)")
        fflush(stdout)
        writeReport(passed: false, status: "running")
        if !passed { throw Failed.assertion(title) }
    }
    func wait(_ name: String, attempts: Int = 250, _ condition: () -> Bool) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        trace(name + "超时；当前 sheet=" + String(describing: window.attachedSheet)
              + " buttons=" + (window.attachedSheet?.contentView.map { buttons(in: $0).joined(separator: ",") } ?? "无"))
        throw Failed.assertion(name + "超时")
    }
    func web(in view: NSView) -> WKWebView? {
        if let result = view as? WKWebView { return result }
        return view.subviews.lazy.compactMap { self.web(in: $0) }.first
    }
    func button(in view: NSView, title: String) -> NSButton? {
        if let result = view as? NSButton, result.title == title { return result }
        return view.subviews.lazy.compactMap { self.button(in: $0, title: title) }.first
    }
    func buttons(in view: NSView) -> [String] {
        (view as? NSButton).map { [$0.title] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    func press(_ title: String) async throws {
        try await wait("确认按钮 \(title)") { self.window.attachedSheet?.contentView.flatMap { self.button(in: $0, title: title) } != nil }
        trace("点击确认按钮：" + title)
        button(in: window.attachedSheet!.contentView!, title: title)!.performClick(nil)
        trace("确认按钮返回：" + title)
    }
    func js(_ view: WKWebView, _ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
    }
    func open(_ url: URL) async throws -> FWDocumentHost {
        let host: FWDocumentHost = try await withCheckedThrowingContinuation { continuation in
            FWDocumentHost.openPreview(at: url) { host, error in
                if let host { continuation.resume(returning: host) }
                else { continuation.resume(throwing: error ?? Failed.assertion("未建立预览") as NSError) }
            }
        }
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        // 应用启动回调发生时尚无测试窗口；在真实窗口可见后激活，才能实际验收键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        try await wait("测试窗口成为活动窗口") { NSApp.isActive && self.window.isKeyWindow }
        try await wait("预览加载") { !host.busy && host.sessionState == "PREVIEW" }
        return host
    }
    func edit(_ host: FWDocumentHost, text: String) async throws -> WKWebView {
        host.beginEditing()
        try await wait("进入编辑") { host.isEditing && !host.busy && host.canSave }
        guard let editor = web(in: host.view) else { throw Failed.assertion("没有真实 WK") }
        window.makeFirstResponder(editor)
        let inserted = try await js(editor, """
        const element = document.querySelector('.cm-content');
        element.focus(); document.execCommand('selectAll');
        return document.execCommand('insertText', false, text);
        """, ["text": text]) as? Bool
        guard inserted == true else { throw Failed.assertion("WK 拒绝真实输入") }
        try await wait("输入回传") { host.modified }
        return editor
    }
    func close(_ host: FWDocumentHost) async -> Bool {
        await withCheckedContinuation { continuation in host.requestClose(in: output) { continuation.resume(returning: $0) } }
    }
    func state(_ editor: WKWebView) async throws -> [String: Any] {
        try await js(editor, "return window.workbench.getInteractionState()") as? [String: Any] ?? [:]
    }
    func run() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "FileDeck 文档关闭验收（自动关闭）"
        window.isReleasedWhenClosed = false
        let testCase = ProcessInfo.processInfo.environment["FW_MODAL_DOCUMENT_TEST_CASE"]
        if testCase == "incremental-bridge" {
            try await incrementalBridge()
            try await bridgeSnapshotRace()
            return
        }
        if testCase == "save-panel" {
            try await deletionAndSaveAs()
            return
        }
        if testCase == "menu-capabilities" {
            try await menuCapabilities()
            return
        }
        if testCase == "webkit-recovery" {
            try await webKitRecovery()
            try await webKitFailureAfterWrite()
            return
        }
        if testCase != "yaml-preview" {
            trace("JSON 美化预览")
            try await jsonPreview()
        }
        if testCase == "json-preview" { return }
        trace("YAML 彩色预览")
        try await yamlPreview()
        if testCase == "yaml-preview" || testCase == "structured-preview" { return }
        // 系统远程保存面板确认可在无人值守环境阻塞；独立选择其余场景，不把本分组报告成完整面板验收。
        if testCase != "non-panel" {
            trace("删除与另存为")
            try await deletionAndSaveAs()
        }
        trace("取消与保存")
        try await cancelAndSave()
        trace("真实权限失败")
        try await saveFailure()
        trace("外部冲突")
        try await conflictAndDiscard()
        trace("载入期间关闭")
        try await closeDuringLoading()
        trace("WebKit 故障草稿恢复")
        try await webKitRecovery()
        try await webKitFailureAfterWrite()
        try await menuCapabilities()
        try await incrementalBridge()
        try await bridgeSnapshotRace()
    }

    /// 丢一条真实 WK 差量后继续输入，验证自动重同步；随后故障另存不能依靠网页补取正文。
    func incrementalBridge() async throws {
        trace("差量桥接与版本恢复")
        let source = output.appendingPathComponent("版本桥接.json")
        let baseline = "{\r\n\"emoji\":\"😀e\u{301}\",\r\"n\":9223372036854775807\n}"
        try Data(baseline.utf8).write(to: source)
        let host = try await open(source)
        host.beginEditing()
        try await wait("差量文档进入编辑") { host.isEditing && !host.busy }
        let editor = web(in: host.view)!
        guard let content = host.children.first as? FWTextContent else { throw Failed.assertion("缺少文本内容") }
        let snapshot = try await js(editor, """
        const handler = window.webkit.messageHandlers.workbench;
        window.__forwardPatch = handler.postMessage.bind(handler);
        window.__patches = [];
        handler.postMessage = message => {
            if (message.type === 'patch') {
                window.__patches.push(message);
                if (window.__patches.length === 1) return;
            }
            window.__forwardPatch(message);
        };
        window.workbench.formatJSON();
        const content = document.querySelector('.cm-content');
        content.focus(); document.execCommand('selectAll');
        document.execCommand('insertText', false, '最新😀é 草稿');
        await Promise.resolve();
        return window.workbench.getSnapshot();
        """) as? [String: Any] ?? [:]
        let expected = snapshot["text"] as? String
        try check("真实 WK 使用版本差量而非逐字全文", (snapshot["version"] as? Int ?? 0) >= 2 && expected?.contains("最新😀") == true)
        try await wait("缺失差量自动完整重同步") { host.modified && host.canSave && host.canUndo }
        try check("差量缺口恢复完整正文及真实撤销能力", host.modified && host.canUndo && content.loadError == nil)
        _ = try await js(editor, "window.__forwardPatch(window.__patches[0]); window.__forwardPatch(window.__patches.at(-1)); return true")
        try await Task.sleep(for: .milliseconds(100))
        try check("过期及重复差量不回退版本或使编辑器故障", host.modified && host.canSave && content.loadError == nil)
        content.webViewWebContentProcessDidTerminate(editor)
        _ = try await js(editor, "window.workbench = null; return true")
        let copy = output.appendingPathComponent("版本恢复草稿.txt")
        try await content.saveAs(to: copy)
        try check("版本恢复后故障另存保留最后输入和来源字节", (try String(contentsOf: copy, encoding: .utf8)) == expected
                  && (try Data(contentsOf: source)) == Data(baseline.utf8) && !host.modified)
        try await content.close()
    }

    /// 全文请求正在等待时继续输入，旧快照返回后也不能覆盖已接收的新差量。
    func bridgeSnapshotRace() async throws {
        let source = output.appendingPathComponent("快照竞态.txt")
        try Data("原文".utf8).write(to: source)
        let host = try await open(source)
        host.beginEditing()
        try await wait("快照竞态进入编辑") { host.isEditing && !host.busy }
        let editor = web(in: host.view)!
        _ = try await js(editor, """
        const originalSnapshot = window.workbench.getSnapshot;
        let first = true;
        window.workbench = {...window.workbench, getSnapshot: async id => {
            const old = originalSnapshot(id);
            if (first) {
                first = false;
                const content = document.querySelector('.cm-content');
                content.focus(); document.execCommand('selectAll');
                document.execCommand('insertText', false, '等待快照时的最后输入😀');
                await new Promise(resolve => setTimeout(resolve, 100));
            }
            return old;
        }};
        return true;
        """)
        guard let content = host.children.first as? FWTextContent else { throw Failed.assertion("缺少文本内容") }
        let copy = output.appendingPathComponent("快照竞态另存.txt")
        try await content.saveAs(to: copy)
        try check("异步旧快照不能覆盖后到的新差量且保存基线正确", (try String(contentsOf: copy, encoding: .utf8)) == "等待快照时的最后输入😀"
                  && (try Data(contentsOf: source)) == Data("原文".utf8) && !host.modified && host.documentURL == copy)
        try await content.close()
    }

    /// 使用真实 WK 历史、宿主门面和标准 responder 菜单校验，避免只断言布尔值的静态接线。
    func menuCapabilities() async throws {
        let source = output.appendingPathComponent("菜单能力.txt")
        try Data("磁盘基线".utf8).write(to: source)
        let host = try await open(source)
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
        let findItem = NSMenuItem(title: "Find", action: Selector(("performFindPanelAction:")), keyEquivalent: "")
        try check("只读文本预览可查找且没有撤销重做", host.canFind && !host.canUndo && !host.canRedo
                  && host.validateUserInterfaceItem(findItem) && !host.validateUserInterfaceItem(undoItem)
                  && !host.validateUserInterfaceItem(redoItem))
        let editor = try await edit(host, text: "编辑后的菜单草稿")
        try await wait("菜单收到真实撤销能力") { host.canUndo }
        try check("真实输入启用撤销", host.validateUserInterfaceItem(undoItem) && !host.validateUserInterfaceItem(redoItem))
        host.undo()
        try await wait("撤销后启用重做") { !host.modified && host.canRedo && !host.canUndo }
        try check("菜单撤销恢复真实正文", try await js(editor, "return window.workbench.getText()") as? String == "磁盘基线")
        host.redo()
        try await wait("重做恢复草稿") { host.modified && host.canUndo && !host.canRedo }
        guard let content = host.children.first as? FWTextContent else { throw Failed.assertion("缺少文本内容") }
        let forwardState = content.onStateChanged
        var busyDisabledCommands = false
        content.onStateChanged = {
            forwardState?()
            if host.busy {
                busyDisabledCommands = !host.canFind && !host.canUndo && !host.canRedo
                host.undo()
            }
        }
        try await content.reload(discardChanges: true)
        try await wait("重新读取后编辑器就绪") { !host.busy && host.canFind }
        try check("载入禁用命令且重新读取清除旧历史", busyDisabledCommands && !host.canUndo && !host.canRedo && !host.modified)
        content.onStateChanged = forwardState
        content.webViewWebContentProcessDidTerminate(editor)
        try check("WK 故障禁用查找撤销重做", !host.canFind && !host.canUndo && !host.canRedo
                  && !host.validateUserInterfaceItem(findItem))
        try check("关闭后所有编辑命令保持禁用", await close(host) && !host.canFind && !host.canUndo && !host.canRedo)
    }

    /// 注入公开的进程终止委托回调；正文仍经真实 WK 输入/桥接，恢复与另存均操作真实对象和文件。
    func webKitRecovery() async throws {
        let source = output.appendingPathComponent("故障恢复.md")
        let baseline = "# 磁盘基线\r\n保留原文件\r\n"
        try Data(baseline.utf8).write(to: source)
        let host = try await open(source)
        let oldEditor = try await edit(host, text: "# 未保存草稿\n中文 e\u{301} 与 emoji 🌱")
        guard let content = host.children.first as? FWTextContent,
              let draft = try await js(oldEditor, "return window.workbench.getText()") as? String else {
            throw Failed.assertion("没有可故障注入的文本内容")
        }
        content.webViewWebContentProcessDidTerminate(oldEditor)
        try check("进程终止后只开放草稿另存且明确恢复范围", host.modified && !host.busy && !host.canSave && host.canSaveAs
                  && host.statusText.contains("最近已同步"))
        let closing = Task { await close(host) }
        try await press("取消")
        try check("故障后取消关闭仍保留草稿", !(await closing.value) && host.modified && host.canSaveAs)

        let existing = output.appendingPathComponent("不可覆盖的恢复目标.md")
        try Data("目标原文".utf8).write(to: existing)
        do {
            try await content.saveAs(to: existing)
            throw Failed.assertion("恢复另存静默覆盖已有目标")
        } catch DocumentIOError.destinationExists { }
        try check("故障另存失败保留原目标、来源和草稿", host.modified && !host.busy && host.documentURL == source
                  && (try String(contentsOf: existing, encoding: .utf8)) == "目标原文")

        guard let recover = button(in: host.view, title: "恢复编辑器") else { throw Failed.assertion("缺少恢复编辑器入口") }
        recover.performClick(nil)
        try await wait("从内存重建 WK") { !host.busy && host.canSave && self.web(in: host.view) !== oldEditor }
        let recovered = web(in: host.view)!
        let restored = try await js(recovered, "return window.workbench.getText()") as? String
        let dirtyLabel = try await js(recovered, "return document.querySelector('#status').textContent") as? String
        try check("重建编辑器保留草稿、原保存基线和磁盘", restored == draft && host.modified && dirtyLabel == "未保存"
                  && (try Data(contentsOf: source)) == Data(baseline.utf8))
        content.webViewWebContentProcessDidTerminate(oldEditor)
        try check("旧 WK 延迟终止回调不污染新编辑器", host.canSave && host.sessionState == "DIRTY")
        try check("新 WK 恢复后可继续输入", try await js(recovered, """
        const element = document.querySelector('.cm-content');
        element.focus(); document.execCommand('selectAll');
        return document.execCommand('insertText', false, '恢复后继续修改');
        """) as? Bool == true)
        // 再次通过真实编辑事务与完整同步，确保故障前最后一条输入已进入 session。
        try await content.replaceTextForSmoke("恢复后继续修改")
        let latest = try await js(recovered, "return window.workbench.getText()") as? String
        content.webViewWebContentProcessDidTerminate(recovered)
        // 注入回调不会真的杀死 WebKit；移除 JS API，证明抢救写盘不依赖仍能调用的旧网页。
        _ = try await js(recovered, "window.workbench = null; return true")
        guard let rescue = button(in: host.view, title: "另存内存草稿…") else { throw Failed.assertion("缺少草稿另存入口") }
        // 单独验证按钮派发和真实存储：系统 NSSavePanel 的远程确认在无人值守环境可能挂起。
        // 此回归显式选择临时路径，不把它当作系统面板键鼠端到端验收。
        var recoveryRequested = false
        let chooseDestination = content.onSaveRecoveryDraft
        content.onSaveRecoveryDraft = { recoveryRequested = true }
        rescue.performClick(nil)
        content.onSaveRecoveryDraft = chooseDestination
        try check("故障另存按钮派发选择目标请求", recoveryRequested)
        let saved = output.appendingPathComponent("故障恢复-恢复草稿.md")
        try await content.saveAs(to: saved)
        try check("无 WebKit 时另存草稿保留源文件并更新保存基线", host.documentURL == saved && !host.modified
                  && (try String(contentsOf: saved, encoding: .utf8)) == latest
                  && (try Data(contentsOf: source)) == Data(baseline.utf8))
        try check("已抢救草稿可正常关闭并释放故障 WK", await close(host) && host.sessionState == "CLOSED" && web(in: host.view) == nil)
    }

    func webKitFailureAfterWrite() async throws {
        let source = output.appendingPathComponent("写盘后桥接故障.md")
        try Data("原文".utf8).write(to: source)
        let host = try await open(source)
        let editor = try await edit(host, text: "本次实际写盘内容")
        let expected = try await js(editor, "return window.workbench.getText()") as? String
        // 保留写入前的 getText，只让写盘完成后的异步确认失败，确定性覆盖该时间窗口。
        _ = try await js(editor, """
        window.workbench = { ...window.workbench, markSaved: async () => {
            throw new Error('regression: bridge failed after disk save');
        }};
        return true;
        """)
        let saved = await withCheckedContinuation { continuation in
            host.save(in: output, saveAs: false) { continuation.resume(returning: $0) }
        }
        try check("写盘后桥接失败不误报磁盘保存失败", saved && host.lastError == nil && host.lastSavedURL == source
                  && !host.modified && host.sessionState == "LOAD_ERROR"
                  && (try String(contentsOf: source, encoding: .utf8)) == expected)
        try check("写盘后桥接故障仍提供恢复入口", host.canSaveAs && button(in: host.view, title: "恢复编辑器")?.isEnabled == true)
        try check("已落盘故障文档可安全关闭", await close(host))
    }
    func jsonPreview() async throws {
        let url = output.appendingPathComponent("美化预览.json")
        let source = "{\r\n\"id\":9223372036854775807,\"items\":[true,null,{\"名称\":\"中文\"}]}"
        try Data(source.utf8).write(to: url)
        let host = try await open(url)
        let editor = web(in: host.view)!
        let pretty = try await js(editor, "return document.querySelector('.cm-content').textContent") as? String ?? ""
        try check("JSON 只读预览自动缩进并保留大整数", pretty.contains("  \"id\": 9223372036854775807,")
                  && pretty.contains("    true,") && host.readOnly && !host.modified && !host.canSave)
        let colors = try await js(editor, """
        const kinds = ['key', 'string', 'number', 'bool', 'null'];
        const colors = kinds.map(kind => {
            const token = document.querySelector('.fw-json-' + kind);
            return token ? getComputedStyle(token).color : null;
        });
        return colors.every(Boolean) && new Set(colors).size === kinds.length;
        """) as? Bool
        try check("JSON 键名与各类值在真实 WK 中呈现不同颜色", colors == true)
        let previewSource = try await js(editor, "return window.workbench.getText()") as? String
        try check("JSON 美化预览不改源码或磁盘文件", previewSource == source && (try Data(contentsOf: url)) == Data(source.utf8))
        host.beginEditing()
        try await wait("JSON 进入编辑") { host.isEditing && !host.busy }
        let editingSource = try await js(editor, "return window.workbench.getText()") as? String
        let canUndo = try await js(editor, "return window.workbench.getInteractionState().canUndo") as? Bool
        try check("JSON 进入编辑恢复原文且不产生草稿或撤销项", editingSource == source && !host.modified && canUndo == false)
        let closed = await close(host)
        try check("JSON 美化预览关闭不提示保存", closed && window.attachedSheet == nil && (try Data(contentsOf: url)) == Data(source.utf8))
    }
    func yamlPreview() async throws {
        let source = "# 配置说明\r\ndefaults: &defaults\r\n  title: \"中文\"\r\n  host: localhost\r\n  code: !!str 42\r\nservice: *defaults\r\n"
        for ext in ["yaml", "yml"] {
            let url = output.appendingPathComponent("彩色预览." + ext)
            try Data(source.utf8).write(to: url)
            let host = try await open(url)
            let editor = web(in: host.view)!
            // 原生会话 ready 与异步语法加载分别完成，等 token 出现再检查实际颜色。
            var colored = false
            for _ in 0..<100 {
                colored = try await js(editor, """
                const colors = ['key', 'string', 'comment', 'anchor', 'type', 'punctuation'].map(kind => {
                    const token = document.querySelector('.fw-yaml-' + kind);
                    return token ? getComputedStyle(token).color : null;
                });
                return colors.every(Boolean) && new Set(colors).size === colors.length;
                """) as? Bool == true
                if colored { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(ext + " 键名、文本、注释、锚点、类型及分隔符实际分色", colored && host.readOnly && !host.modified)
            let original = try await js(editor, "return window.workbench.getText()") as? String
            try check(ext + " 配色保留缩进、注释、CRLF 和磁盘内容", original == source && (try Data(contentsOf: url)) == Data(source.utf8))
            host.beginEditing()
            try await wait(ext + " 进入编辑") { host.isEditing && !host.busy }
            let editable = try await js(editor, "return !!document.querySelector('.fw-yaml-key') && document.querySelector('.cm-content').getAttribute('contenteditable') === 'true' && !window.workbench.getInteractionState().canUndo") as? Bool
            try check(ext + " 编辑沿用彩色高亮且不产生草稿或撤销项", editable == true && !host.modified)
            let closed = await close(host)
            try check(ext + " 关闭不提示保存或改写文件", closed && window.attachedSheet == nil && (try Data(contentsOf: url)) == Data(source.utf8))
        }
    }
    func cancelAndSave() async throws {
        let url = output.appendingPathComponent("确认取消.md")
        let baseline = "# 原文\n" + (0..<150).map { "第 \($0) 行" }.joined(separator: "\n")
        try Data(baseline.utf8).write(to: url)
        let host = try await open(url)
        let preview = web(in: host.view)!
        let readOnly = try await js(preview, "return document.querySelector('.cm-content').getAttribute('contenteditable') === 'false' && document.querySelector('#editor').hidden && !document.querySelector('#preview').hidden && document.activeElement !== document.querySelector('.cm-content')") as? Bool
        try check("Markdown 默认真实只读阅读且不自动聚焦输入", readOnly == true && !host.canSave)
        let requestedDraft = baseline + "\n尚未保存的正文"
        let editor = try await edit(host, text: requestedDraft)
        // WebKit 的多段 insertText 会追加终止换行；以真实编辑器已接收的内容作为关闭前基准。
        guard let draft = try await js(editor, "return window.workbench.getText()") as? String,
              draft.contains(requestedDraft) else { throw Failed.assertion("编辑器未接收完整多行输入") }
        let initialState = try await state(editor)
        try check("主动编辑复用同一 WK 且默认源码模式", editor === preview && initialState["mode"] as? String == "source")
        _ = try await js(editor, """
        window.workbench.setMode({ mode: 'split' });
        const selection = window.getSelection();
        selection.modify('move', 'backward', 'character');
        selection.modify('extend', 'backward', 'character');
        document.querySelector('.cm-scroller').scrollTop = 230;
        """)
        try await Task.sleep(for: .milliseconds(120))
        let before = try await state(editor)
        let firstClose = Task { await close(host) }
        try await wait("未保存确认") { self.window.attachedSheet != nil }
        let duplicate = await close(host)
        try check("重复关闭只显示一个确认且拒绝重复保存", !duplicate && window.sheets.count == 1 && host.busy)
        try await press("取消")
        let cancelled = await firstClose.value
        let after = try await state(editor)
        let restoredText = try await js(editor, "return window.workbench.getText()") as? String
        let selectionEqual = (before["selection"] as? NSDictionary) == (after["selection"] as? NSDictionary)
        // 用户可在验收期间切到其他应用；此时应保留逻辑焦点，不能要求测试窗口抢回全局焦点。
        let domFocus = try await js(editor, "return document.activeElement === document.querySelector('.cm-content');") as? Bool == true
        let responder = window.firstResponder as? NSView
        let nativeFocus = responder === editor || responder?.isDescendant(of: editor) == true
        let focusRestored = domFocus && nativeFocus && (!NSApp.isActive || !window.isKeyWindow || after["focusedEditor"] as? Bool == true)
        let restored = !cancelled && host.modified && editor === web(in: host.view)
                  && selectionEqual && before["editorTop"] as? Double == after["editorTop"] as? Double
                  && after["mode"] as? String == "split" && focusRestored
                  && restoredText == draft
        if !restored {
            trace("取消诊断 before=" + String(describing: before) + " after=" + String(describing: after)
                  + " textEqual=" + String(restoredText == draft) + " active=" + String(NSApp.isActive)
                  + " key=" + String(window.isKeyWindow) + " nativeResponder=" + String(describing: window.firstResponder))
        }
        try check("取消保留正文、光标选择、滚动、模式与编辑器焦点", restored)
        host.undo()
        try await wait("原撤销历史") { !host.modified }
        host.redo()
        try await wait("原重做历史") { host.modified }
        try check("取消确认后撤销重做历史仍然有效", (try await js(editor, "return window.workbench.getText()")) as? String == draft)
        let save = Task { await close(host) }
        try await press("保存")
        let savedClose = await save.value
        try check("关闭确认保存真实写盘后才释放 WK", savedClose && host.sessionState == "CLOSED"
                  && host.lastSavedURL == url && (try String(contentsOf: url, encoding: .utf8)) == draft && web(in: host.view) == nil)
    }
    func saveFailure() async throws {
        let directory = output.appendingPathComponent("不可写父目录", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("权限失败.md")
        try Data("磁盘原文".utf8).write(to: url)
        let host = try await open(url)
        let editor = try await edit(host, text: "内存中的重要草稿")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let closing = Task { await close(host) }
        try await press("保存")
        try await press("知道了")
        trace("权限错误提示已处理")
        let result = await closing.value
        trace("权限失败关闭回调已返回")
        let preservedText = try await js(editor, "return window.workbench.getText()") as? String
        try check("真实写入权限失败保留弹窗草稿并报告原因", !result && host.modified && host.sessionState == "SAVE_ERROR"
                  && host.lastError?.contains("写入权限") == true && host.lastSavedURL == nil
                  && (try String(contentsOf: url, encoding: .utf8)) == "磁盘原文"
                  && preservedText == "内存中的重要草稿")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let discard = Task { await close(host) }
        try await press("不保存")
        try check("明确不保存才释放失败后的草稿", await discard.value && host.sessionState == "CLOSED")
    }
    func deletionAndSaveAs() async throws {
        let url = output.appendingPathComponent("已删除.md")
        try Data("旧文件".utf8).write(to: url)
        let host = try await open(url)
        let editor = try await edit(host, text: "删除后保留的草稿")
        try FileManager.default.removeItem(at: url)
        let cancelled = Task { await close(host) }
        try await press("保存")
        try await press("取消")
        let cancelledResult = await cancelled.value
        let preservedText = try await js(editor, "return window.workbench.getText()") as? String
        try check("删除后取消保存不重建原路径且保留内存内容", !cancelledResult && !FileManager.default.fileExists(atPath: url.path)
                  && host.modified && preservedText == "删除后保留的草稿")
        let saving = Task { await close(host) }
        try await press("保存")
        try await press("另存为…")
        try await wait("真实另存面板") { self.window.attachedSheet is NSSavePanel }
        let panel = window.attachedSheet as! NSSavePanel
        trace("另存面板已附着")
        try await Task.sleep(for: .milliseconds(200))
        try check("系统另存面板确认前不自动重建已删除路径", !FileManager.default.fileExists(atPath: url.path)
                  && host.modified && host.lastSavedURL == nil)
        // 远程面板必须由外部操作者确认；本进程投递键盘事件或同步调用 ok 都可能阻塞。
        // 进度文件只报告实际面板，不接受 URL/结果回传；生产保存仍等待系统完成回调。
        guard panel.directoryURL?.standardizedFileURL == output.standardizedFileURL,
              panel.nameFieldStringValue == url.lastPathComponent,
              let token = ProcessInfo.processInfo.environment["FW_MODAL_DOCUMENT_TEST_TOKEN"] else {
            throw Failed.assertion("系统面板默认目标或测试令牌不匹配")
        }
        let checkpoint: [String: Any] = ["schemaVersion": 1, "token": token, "phase": "awaiting-save",
                                         "pid": ProcessInfo.processInfo.processIdentifier, "directory": output.path,
                                         "expectedFileName": url.lastPathComponent, "expectedPath": url.path,
                                         "panelTitle": panel.title, "panelWindowNumber": panel.windowNumber]
        try JSONSerialization.data(withJSONObject: checkpoint, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("save-panel-checkpoint.json"), options: .atomic)
        trace("等待外部确认真实系统保存按钮")
        try await wait("系统另存完成回调", attempts: 1_000) { host.sessionState == "CLOSED" || !host.busy }
        let saved = await saving.value
        try check("删除后明确确认系统默认路径才真实另存并关闭", saved && host.sessionState == "CLOSED"
                  && panel.url?.standardizedFileURL == url.standardizedFileURL
                  && host.documentURL?.standardizedFileURL == url.standardizedFileURL
                  && host.lastSavedURL?.standardizedFileURL == url.standardizedFileURL
                  && (try String(contentsOf: url, encoding: .utf8)) == "删除后保留的草稿")
    }
    func conflictAndDiscard() async throws {
        let url = output.appendingPathComponent("外部冲突.md")
        try Data("原文".utf8).write(to: url)
        let host = try await open(url)
        let editor = try await edit(host, text: "本地草稿")
        try Data("其他应用修改".utf8).write(to: url)
        let attempt = Task { await close(host) }
        try await press("保存")
        try await press("取消")
        let cancelledResult = await attempt.value
        let preservedText = try await js(editor, "return window.workbench.getText()") as? String
        try check("外部修改禁止静默覆盖并保留草稿", !cancelledResult && host.modified && host.sessionState == "CONFLICT"
                  && (try String(contentsOf: url, encoding: .utf8)) == "其他应用修改"
                  && preservedText == "本地草稿")
        let discard = Task { await close(host) }
        try await press("不保存")
        try check("冲突后明确放弃不改磁盘外部版本", await discard.value && (try String(contentsOf: url, encoding: .utf8)) == "其他应用修改")
    }
    func closeDuringLoading() async throws {
        let url = output.appendingPathComponent("快速关闭.md")
        try Data("# 立即关闭".utf8).write(to: url)
        let host: FWDocumentHost = try await withCheckedThrowingContinuation { continuation in
            FWDocumentHost.openPreview(at: url) { host, error in
                if let host { continuation.resume(returning: host) }
                else { continuation.resume(throwing: error ?? Failed.assertion("载入") as NSError) }
            }
        }
        window.contentViewController = host
        let result = await close(host)
        try await Task.sleep(for: .milliseconds(300))
        try check("WK 初始化期间关闭使异步结果失效且不重新出现", result && host.sessionState == "CLOSED" && web(in: host.view) == nil)
    }
    func finish(_ passed: Bool) {
        guard !finished else { return }
        finished = true
        writeReport(passed: passed, status: "completed")
        if let sheet = window?.attachedSheet {
            window?.endSheet(sheet, returnCode: .abort)
            sheet.orderOut(nil)
        }
        window?.orderOut(nil)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        fflush(stdout)
        exit(passed ? 0 : 1)
    }
    func writeReport(passed: Bool, status: String) {
        let report: [String: Any] = ["passed": passed, "status": status, "checks": checks,
                                   "selection": ProcessInfo.processInfo.environment["FW_MODAL_DOCUMENT_TEST_CASE"] ?? "full",
                                   "realWebKit": true, "realFilesystem": true, "realNativeDialogs": true]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
    }
}

@main
struct ModalDocumentTestMain {
    static func main() {
        // 验收应用只能由隔离脚本启动；Finder 双击没有样本目录时正常退出，不访问参数下标。
        guard CommandLine.arguments.count == 2,
              ProcessInfo.processInfo.environment["FW_MODAL_DOCUMENT_TEST_DIR"] == CommandLine.arguments[1] else {
            fputs("请通过 scripts/test-modal-documents.sh 运行隔离验收。\n", stderr)
            exit(64)
        }
        let application = NSApplication.shared
        let delegate = ModalDocumentTests(output: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
