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
    func wait(_ name: String, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
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
        trace("删除与另存为")
        try await deletionAndSaveAs()
        trace("取消与保存")
        try await cancelAndSave()
        trace("真实权限失败")
        try await saveFailure()
        trace("外部冲突")
        try await conflictAndDiscard()
        trace("载入期间关闭")
        try await closeDuringLoading()
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
        let restored = !cancelled && host.modified && editor === web(in: host.view)
                  && selectionEqual && before["editorTop"] as? Double == after["editorTop"] as? Double
                  && after["mode"] as? String == "split" && after["focusedEditor"] as? Bool == true
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
        // 保留产品展示前配置的目录与原文件名，通过面板自己的 Return 确认明确选择该路径。
        // 这允许重新创建用户刚刚确认的原路径；不注入 URL、不绕过系统面板，也不伪造完成回调。
        panel.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil,
                                              characters: "\r", charactersIgnoringModifiers: "\r",
                                              isARepeat: false, keyCode: 36) else {
                throw Failed.assertion("无法创建系统面板确认事件")
            }
            NSApp.postEvent(event, atStart: false)
        }
        trace("已向系统另存面板投递 Return 确认")
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
