import AppKit
import Foundation
@preconcurrency import WebKit

/// 真实 WebKit 验收宿主：与工作台隔离，仅加载交付资源并在结束时关闭自己的窗口。
/// 后续宿主可复用以下边界：非持久存储、最小文件读取目录、主框架桥接、拒绝后续导航。
@MainActor
final class EditorResourceTests: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let project: URL
    private let output: URL
    private var window: NSWindow?
    private var webView: WKWebView!
    private var initialNavigationStarted = false
    private var pageLoaded = false
    private var bridgeReady = false
    private var started = false
    private var finished = false
    private var checks: [[String: Any]] = []
    private var bridgeMessages: [[String: Any]] = []
    private var violations: [[String: Any]] = []
    private var blockedNavigations: [String] = []
    private var timeoutTask: Task<Void, Never>?
    // 使用非浏览器禁用端口，否则 WebKit 可能先按端口策略拒绝，无法验证导航委托本身。
    private let probeOrigin = "http://127.0.0.1:18765"
    private var indexURL: URL { project.appendingPathComponent("Resources/Editors/index.html") }
    private(set) var succeeded = false

    init(project: URL, output: URL) {
        self.project = project
        self.output = output
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: "workbench")
        configuration.userContentController.add(self, name: "editorTestHarness")
        // instrumentation 由测试宿主注入，页面脚本与探针本身仍接受页面 CSP 检查。
        let instrumentation = """
        document.addEventListener('securitypolicyviolation', event => {
          window.webkit.messageHandlers.editorTestHarness.postMessage({
            type: 'csp', directive: event.effectiveDirective, blockedURI: event.blockedURI,
            disposition: event.disposition, originalPolicy: event.originalPolicy
          });
        });
        """
        configuration.userContentController.addUserScript(WKUserScript(source: instrumentation, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window?.title = "文件工作台 · 编辑器资源验收（完成后自动关闭）"
        window?.isReleasedWhenClosed = false
        window?.contentView = webView
        window?.center()
        window?.orderFront(nil)
        log("启动真实 WKWebView：\(indexURL.path)")
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled, let self, !self.finished else { return }
            self.record("验收未超时", false, "35 秒内未完成；检查 WebKit 进程或资源加载日志。")
            self.finish()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        if message.name == "editorTestHarness", body["type"] as? String == "csp" {
            violations.append(body)
            log("CSP 阻止：\(body["directive"] ?? "") / \(body["blockedURI"] ?? "")")
        } else if message.name == "workbench" {
            bridgeMessages.append(body)
            if body["type"] as? String == "ready" {
                bridgeReady = true
                startIfReady()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        startIfReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !started {
            record("本地页面加载", false, error.localizedDescription)
            finish()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !finished {
            record("WebKit 进程持续运行", false, "WebContent 进程意外终止。")
            finish()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !initialNavigationStarted, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.url?.standardizedFileURL == indexURL.standardizedFileURL {
            initialNavigationStarted = true
            decisionHandler(.allow)
            return
        }
        blockedNavigations.append(navigationAction.request.url?.absoluteString ?? "unknown")
        log("原生导航策略阻止：\(blockedNavigations.last ?? "")")
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        blockedNavigations.append(navigationAction.request.url?.absoluteString ?? "new-window")
        return nil
    }

    private func startIfReady() {
        guard pageLoaded, bridgeReady, !started, !finished else { return }
        started = true
        Task {
            do { try await runChecks() }
            catch { record("JavaScript 验收执行", false, String(describing: error)) }
            finish()
        }
    }

    private func runChecks() async throws {
        record("真实 WKWebView 与原生 bridge 启动", bridgeReady && pageLoaded)
        let source = "{\r\n\"名称\":\"中文文件 😀\",\r\"id\":9223372036854775807,\n\"金额\":1.2300\r\n}"
        _ = try await javascript("return window.workbench.open(document)", arguments: ["document": ["id": "native-json", "text": source, "language": "json", "readOnly": false]])
        let opened = try await javascript("return {text: window.workbench.getText(id), display: getComputedStyle(document.querySelector('.cm-editor')).display, nonce: document.querySelector('meta[name=style-nonce]').content, nonces: Array.from(document.querySelectorAll('style')).map(style => style.nonce)}", arguments: ["id": "native-json"]) as? [String: Any] ?? [:]
        record("中文、emoji 与混合换行无改往返", opened["text"] as? String == source)
        let nonce = opened["nonce"] as? String ?? ""
        record("CodeMirror nonce 样式被真实 CSP 允许", !nonce.isEmpty && (opened["nonces"] as? [String] ?? []).contains(nonce) && opened["display"] as? String == "flex")
        record("初次 open 不发送 dirty/变更", !bridgeMessages.contains { $0["type"] as? String == "change" } && bridgeMessages.filter { $0["type"] as? String == "opened" }.allSatisfy { $0["dirty"] == nil })
        record("正常资源加载无 CSP 违规", violations.isEmpty, "在安全探针注入前核对。")

        let formatted = try await javascript("window.workbench.formatJSON(id); return window.workbench.getText(id)", arguments: ["id": "native-json"]) as? String ?? ""
        record("JSON 排版保留大整数与小数原文", formatted.contains("9223372036854775807") && formatted.contains("1.2300") && formatted.contains("中文文件 😀"))
        let undone = try await javascript("window.workbench.undo(id); return window.workbench.getText(id)", arguments: ["id": "native-json"]) as? String
        record("真实编辑历史撤销恢复原始换行", undone == source)
        let redone = try await javascript("window.workbench.redo(id); return window.workbench.getText(id)", arguments: ["id": "native-json"]) as? String
        record("真实编辑历史重做", redone == formatted)
        let changes = bridgeMessages.filter { $0["type"] as? String == "change" }
        record("桥接回传全文、dirty 与历史状态", changes.count >= 3 && changes.contains { $0["dirty"] as? Bool == false } && changes.allSatisfy { $0["id"] as? String == "native-json" && $0["text"] is String && $0["canUndo"] is Bool && $0["canRedo"] is Bool })

        _ = try await javascript("return window.workbench.open(document)", arguments: ["document": ["id": "native-chinese", "text": "原文", "language": "text", "readOnly": false]])
        _ = try await javascript("document.querySelector('.cm-content').focus(); document.execCommand('selectAll'); return document.execCommand('insertText', false, text)", arguments: ["text": "中文输入检查 😀\n第二行"])
        try await Task.sleep(for: .milliseconds(100))
        let typed = try await javascript("return window.workbench.getText(id)", arguments: ["id": "native-chinese"]) as? String
        record("真实 contenteditable 中文插入回传", typed == "中文输入检查 😀\n第二行", "程序化文本插入；系统输入法组合和候选窗仍需人工验收。")
        let stale = try await javascript("return {text: window.workbench.getText('native-json'), undo: window.workbench.undo('native-json'), format: window.workbench.formatJSON('native-json')}") as? [String: Any] ?? [:]
        record("过期会话不能读写当前标签", stale["text"] is NSNull && stale["undo"] as? Bool == false && stale["format"] as? Bool == false)

        let markdown = "# 中文预览\n\n![remote](\(probeOrigin)/markdown.png)\n\n[链接](\(probeOrigin)/link)\n\n<script>window.__markdownScriptRan=true</script>"
        _ = try await javascript("return window.workbench.open(document)", arguments: ["document": ["id": "native-markdown", "text": markdown, "language": "markdown", "readOnly": false]])
        let updatedMarkdown = markdown.replacingOccurrences(of: "# 中文预览", with: "# 中文预览更新")
        _ = try await javascript("document.querySelector('.cm-content').focus(); document.execCommand('selectAll'); return document.execCommand('insertText', false, text)", arguments: ["text": updatedMarkdown])
        try await Task.sleep(for: .milliseconds(100))
        let hidden = try await javascript("return document.querySelector('#preview').hidden && document.querySelector('#preview').childNodes.length === 0 && window.workbench.getText('native-markdown') === text", arguments: ["text": updatedMarkdown]) as? Bool ?? false
        record("隐藏 Markdown 不生成预览且即时同步最新输入", hidden && bridgeMessages.contains { $0["id"] as? String == "native-markdown" && $0["type"] as? String == "change" && $0["text"] as? String == updatedMarkdown })
        _ = try await javascript("return window.workbench.setMode({mode: 'split'})")
        let preview = try await javascript("return {title: document.querySelector('#preview h1').textContent, active: document.querySelectorAll('#preview img,#preview a,#preview script').length, ran: !!window.__markdownScriptRan, visible: !document.querySelector('#preview').hidden}") as? [String: Any] ?? [:]
        record("真实 Markdown 双栏阻止远程图、链接与 HTML 脚本", preview["title"] as? String == "中文预览更新" && preview["active"] as? Int == 0 && preview["ran"] as? Bool == false && preview["visible"] as? Bool == true)
        let reused = try await javascript("const heading = document.querySelector('#preview h1'); window.workbench.setMode({mode: 'preview'}); window.workbench.setMode({mode: 'source'}); window.workbench.setMode({mode: 'split'}); return heading === document.querySelector('#preview h1')") as? Bool ?? false
        record("相同 Markdown 正文切换显示模式复用预览 DOM", reused)

        let batching = try await javascript("""
        window.workbench.open({id: 'native-batching', text: '# 起点', language: 'markdown', mode: 'split', bridgeMode: 'patch-v1'});
        const preview = document.querySelector('#preview');
        const html = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
        let writes = 0;
        Object.defineProperty(preview, 'innerHTML', {configurable: true, get() { return html.get.call(this); }, set(value) { writes++; html.set.call(this, value); }});
        const content = document.querySelector('.cm-content');
        for (const text of ['# 第一版', '# 第二版', '# 最新正文']) {
            content.focus(); document.execCommand('selectAll'); document.execCommand('insertText', false, text);
            await Promise.resolve();
        }
        const beforeFrame = writes;
        const snapshot = window.workbench.getSnapshot();
        await new Promise(resolve => requestAnimationFrame(resolve));
        const result = {beforeFrame, afterFrame: writes, text: snapshot.text, title: preview.querySelector('h1').textContent};
        delete preview.innerHTML;
        return result;
        """) as? [String: Any] ?? [:]
        record("真实 WK 可见 Markdown 同帧合并且快照立即保留最后输入", batching["beforeFrame"] as? Int == 0 && batching["afterFrame"] as? Int == 1
               && batching["text"] as? String == "# 最新正文" && batching["title"] as? String == "最新正文", String(describing: batching))
        try await Task.sleep(for: .milliseconds(100))
        let patches = bridgeMessages.filter { $0["type"] as? String == "patch" && $0["id"] as? String == "native-batching" }
        record("真实 WK 即时发送带版本差量和撤销状态", patches.count >= 3 && patches.allSatisfy { $0["text"] == nil && $0["edits"] is [[String: Any]] && $0["baseVersion"] is Int && $0["version"] is Int && $0["canUndo"] is Bool }, "patches=\(patches.count)")

        // 使用环回地址做阻止探针；没有真实远程主机，也不要求启动网络服务。
        // 断言 securitypolicyviolation，而不是把连接失败误判成 CSP 生效。
        let cspProbe = """
        window.__inlineProbeRan = false;
        const script = document.createElement('script');
        script.textContent = 'window.__inlineProbeRan = true'; document.head.appendChild(script);
        const badStyle = document.createElement('style');
        badStyle.textContent = 'body { --forbidden-style: executed; }'; document.head.appendChild(badStyle);
        const goodStyle = document.createElement('style');
        goodStyle.nonce = document.querySelector('meta[name=style-nonce]').content;
        goodStyle.textContent = 'body { --allowed-style: permitted; }'; document.head.appendChild(goodStyle);
        const image = new Image(); image.src = origin + '/image.png'; document.body.appendChild(image);
        let fetchBlocked = false;
        try { await fetch(origin + '/connect'); } catch { fetchBlocked = true; }
        await new Promise(resolve => setTimeout(resolve, 120));
        return {scriptRan: window.__inlineProbeRan, badStyle: getComputedStyle(document.body).getPropertyValue('--forbidden-style').trim(), goodStyle: getComputedStyle(document.body).getPropertyValue('--allowed-style').trim(), fetchBlocked};
        """
        let probes = try await javascript(cspProbe, arguments: ["origin": probeOrigin]) as? [String: Any] ?? [:]
        record("CSP 实际阻止内联脚本及无 nonce 样式", probes["scriptRan"] as? Bool == false && probes["badStyle"] as? String == "")
        record("CSP 实际允许匹配 nonce 的本地样式", probes["goodStyle"] as? String == "permitted")
        let directives = Set(violations.compactMap { $0["directive"] as? String })
        record("CSP 明确阻止环回 connect 请求", probes["fetchBlocked"] as? Bool == true && directives.contains("connect-src"))
        record("CSP 明确阻止环回图片请求", directives.contains("img-src"))
        record("CSP 违规事件覆盖脚本和样式", directives.contains { $0.hasPrefix("script-src") } && directives.contains { $0.hasPrefix("style-src") })
        record("CSP 处于 enforce 模式", !violations.isEmpty && violations.allSatisfy { $0["disposition"] as? String == "enforce" })

        _ = try await javascript("window.location.href = destination; return true", arguments: ["destination": probeOrigin + "/navigation"])
        try await Task.sleep(for: .milliseconds(150))
        record("原生 navigation policy 阻止非资源导航", blockedNavigations.contains(probeOrigin + "/navigation") && webView.url?.standardizedFileURL == indexURL.standardizedFileURL)
    }

    private func javascript(_ source: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .page)
    }

    private func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(["name": name, "passed": passed, "detail": detail])
        log("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)")
    }

    private func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        succeeded = !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = [
            "schema": 1, "passed": succeeded, "engine": "macOS WKWebView", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "resource": indexURL.path, "checks": checks, "cspViolations": violations, "blockedNavigations": blockedNavigations,
            "bridgeMessages": bridgeMessages,
            "manualChecks": ["中文拼音/五笔等系统输入法组合、候选窗、切换标签期间输入需人工验收。"],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            succeeded = false
            log("FAIL 无法写入报告：\(error)")
        }
        log("验收完成：\(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count) 通过；报告：\(output.appendingPathComponent("report.json").path)")
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        window?.close()
        NSApplication.shared.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApplication.shared.postEvent(event, atStart: true)
        }
    }
}

@main
enum EditorResourceTestMain {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("用法：editor-tests <项目目录> <报告目录>\n", stderr)
            exit(2)
        }
        let delegate = EditorResourceTests(project: URL(fileURLWithPath: CommandLine.arguments[1]), output: URL(fileURLWithPath: CommandLine.arguments[2]))
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
        exit(delegate.succeeded ? 0 : 1)
    }
}
