import AppKit
import SwiftUI
@preconcurrency import WebKit

/// 编译全部真实浏览页与原生宿主，验证 WK 输入、同页编辑、会话保存及关闭保护。
@MainActor
final class NativeTextTests: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var records: [[String: Any]] = []
    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
    var finished = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); finish(true) }
            catch { records.append(["check": "执行", "passed": false, "detail": String(describing: error)]); finish(false) }
        }
        Task { try? await Task.sleep(for: .seconds(150)); if !finished { finish(false) } }
    }
    enum Failed: Error { case assertion(String) }
    /// NotificationCenter 明确投递到主队列；菜单引用也只在主 actor 读取，避免跨线程传递 NSMenu。
    @MainActor final class MenuCapture { var menu: NSMenu? }
    func check(_ name: String, _ result: Bool) throws {
        records.append(["check": name, "passed": result])
        print("\(result ? "PASS" : "FAIL") \(name)")
        if !result { throw Failed.assertion(name) }
    }
    func settle(_ content: FWTextContent) async throws {
        for _ in 0..<200 {
            if !content.isBusy && content.availableOperations.contains(.save) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failed.assertion("编辑器就绪超时")
    }
    func findWeb(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = findWeb(child) { return web } }
        return nil
    }
    func text(_ web: WKWebView) async throws -> String {
        try await web.callAsyncJavaScript("return window.workbench.getText()", arguments: [:], in: nil, contentWorld: .page) as? String ?? ""
    }
    func edit(_ web: WKWebView, _ value: String) async throws {
        _ = try await web.callAsyncJavaScript("document.querySelector('.cm-content').focus(); document.execCommand('selectAll'); return document.execCommand('insertText', false, text)", arguments: ["text": value], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(120))
    }
    func host(at url: URL) async throws -> FWDocumentHost {
        try await withCheckedThrowingContinuation { continuation in
            FWDocumentHost.openDocument(at: url, kind: "text") { host, error in
                if let host { continuation.resume(returning: host) }
                else { continuation.resume(throwing: error ?? Failed.assertion("未创建宿主") as NSError) }
            }
        }
    }
    func settle(_ host: FWDocumentHost) async throws {
        for _ in 0..<200 {
            if !host.busy && host.canSave { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failed.assertion("门面编辑器就绪超时")
    }
    func waitUntil(_ name: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failed.assertion(name + "超时")
    }
    func replace(_ host: FWDocumentHost, _ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            host.smokeReplaceText(text) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func save(_ host: FWDocumentHost) async -> Bool {
        await withCheckedContinuation { continuation in
            host.save(in: output, saveAs: false) { continuation.resume(returning: $0) }
        }
    }
    func button(_ view: NSView, title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews { if let found = button(child, title: title) { return found } }
        return nil
    }
    func pressSheet(_ title: String) async throws {
        // 仅操作本验收窗口的 sheet，不查找或操作其他应用/用户窗口。
        for _ in 0..<200 {
            if let view = window.attachedSheet?.contentView, let button = button(view, title: title) {
                button.performClick(nil)
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failed.assertion("未出现预期验收面板按钮：" + title)
    }
    func run() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let driver = ProcessInfo.processInfo.environment["FW_NATIVE_HOST_MOUSE_DRIVER"], driver != "cgevent" {
            throw Failed.assertion("未知鼠标驱动：" + driver)
        }
        if let selected = ProcessInfo.processInfo.environment["FW_NATIVE_HOST_TEST_CASE"] {
            if selected == "interaction-fixes" {
                try await interactionFixChecks()
                return
            }
            if selected == "languages" {
                window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "常见编程语言验收（自动关闭）"
                window.makeKeyAndOrderFront(nil)
                try await languageChecks()
                return
            }
            guard ["trash", "external-sync", "file-operations", "search", "text-selection", "interaction", "icons", "icons-interaction"].contains(selected) else { throw Failed.assertion("未知原生宿主专项：" + selected) }
            let browser = FWBrowserHost(editorView: NSTabView(frame: .zero), openHandler: { _, _ in }, commandHandler: { _ in })
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentViewController = browser
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if selected == "icons" { try await fileIconChecks(browser) }
            else if selected == "interaction" || selected == "icons-interaction" { try await interactionChecks(browser, checksDirectoryPanel: selected == "interaction") }
            else if selected == "trash" { try await trashMenuChecks(browser) }
            else if selected == "external-sync" { try await externalSyncChecks(browser) }
            else if selected == "file-operations" { try await fileOperationChecks(browser) }
            else if selected == "search" { try await directorySearchChecks(browser) }
            else { try await textSelectionChecks(browser) }
            return
        }
        let source = output.appendingPathComponent("源 中文.json")
        let initial = "{\r\n\"名称\":\"中文😀\",\r\"id\":9223372036854775807,\n\"decimal\":1.2300\r\n}"
        try Data(initial.utf8).write(to: source)
        let content = try await FWTextContent.open(url: source, kind: .json)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "原生文本会话验收（自动关闭）"
        window.contentViewController = content
        window.makeKeyAndOrderFront(nil)
        try await settle(content)
        guard let web = findWeb(content.view) else { throw Failed.assertion("没有真实WKWebView") }
        try check("加载混合换行及中文而不触发脏状态", try await text(web) == initial && !content.isModified)
        _ = try await web.callAsyncJavaScript("return window.workbench.formatJSON()", arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(100))
        try check("格式化桥接进入原生未保存状态", content.isModified)
        content.undo()
        try await Task.sleep(for: .milliseconds(100))
        try check("原生undo恢复原始字节换行和干净状态", try await text(web) == initial && !content.isModified)
        content.redo()
        try await Task.sleep(for: .milliseconds(100))
        let formatted = try await text(web)
        try check("原生redo保留数值精度", content.isModified && formatted.contains("9223372036854775807") && formatted.contains("1.2300"))
        try await content.save(overwriteExternalChanges: false)
        try check("真实保存完整文本并更新基线", try String(contentsOf: source, encoding: .utf8) == formatted && !content.isModified)
        try await edit(web, "本地中文待保存")
        let copy = output.appendingPathComponent("另存 副本.json")
        try await content.saveAs(to: copy, overwriteExternalChanges: false)
        try check("另存更新会话路径且保留原文档", content.path?.standardizedFileURL == copy.standardizedFileURL && String(contentsOf: source, encoding: .utf8) == formatted)
        try await edit(web, "本地新编辑")
        try Data("外部变化".utf8).write(to: copy)
        do { try await content.save(overwriteExternalChanges: false); throw Failed.assertion("未阻止外部修改") }
        catch DocumentIOError.externalModification { try check("外部修改拒绝覆盖且保留dirty", content.isModified && String(contentsOf: copy, encoding: .utf8) == "外部变化") }
        do { try await content.close(discardChanges: false); throw Failed.assertion("未保护关闭") }
        catch DocumentSessionError.unsavedChanges { try check("关闭拒绝丢失文本且恢复编辑视图", !web.isHidden && content.isModified) }
        try await content.reload(discardChanges: true)
        try await settle(content)
        try check("明确重新加载恢复磁盘全文与干净状态", try await text(web) == "外部变化" && !content.isModified)
        try await content.close(discardChanges: false)
        try check("干净会话正常关闭", true)
        try await browserChecks()
        try await hostChecks()
    }
    func languageChecks() async throws {
        let identity = try FileSystem.identity(at: output)
        let cases: [(NewFileTemplate, String, String)] = [
            (.rust, "main.rs", "fn main() { println!(\"中文\"); }\r\n"),
            (.kotlin, "main.kt", "fun main() { println(\"中文\") }\r\n"),
            (.kotlinScript, "build.gradle.kts", "val message = \"中文\"\r\n"),
            (.cHeader, "sample.h", "#define VALUE 42\r\n"),
            (.cppHeader, "sample.hpp", "class Example {};\r\n"),
            (.objectiveC, "sample.m", "@interface Example\r\n@end\r\n"),
            (.objectiveCpp, "sample.mm", "@interface Example\r\n@end\r\n"),
            (.javascript, "module.mjs", "export const message = \"中文\";\r\n"),
            (.svelte, "App.svelte", "<script>let name = \"中文\";</script>\r\n<h1>{name}</h1>\r\n"),
            (.julia, "main.jl", "function greet()\r\n  return \"中文\"\r\nend\r\n"),
            (.powershell, "script.ps1", "$message = \"中文\"\r\n"),
            (.custom, "Dockerfile", "FROM alpine:3\r\nRUN echo hello\r\n")
        ]
        for (template, filename, source) in cases {
            let file = try NewFileCreator.create(template: template, name: filename, directory: output,
                                                 expectedDirectoryIdentity: identity)
            try Data(source.utf8).write(to: file)
            let content = try await FWTextContent.open(url: file, kind: .code)
            window.contentViewController = content
            try await settle(content)
            guard let web = findWeb(content.view) else { throw Failed.assertion("缺少真实 WKWebView") }
            // 通过真实原生宿主传递文件名，等待交付 bundle 产生 token，覆盖 Swift 到 JS 的完整路径。
            let highlighted = try await web.callAsyncJavaScript("""
                for (let attempt = 0; attempt < 100; attempt++) {
                  if (document.querySelector('.cm-content .cm-line span[class]')) return true;
                  await new Promise(resolve => setTimeout(resolve, 20));
                }
                return false;
                """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
            let loaded = try await text(web)
            try check("\(filename) 原生文件名映射高亮且保留 CRLF", highlighted && !content.isModified && loaded == source)
            let modified = source + "\r\n"
            // contenteditable 的 insertText 按逻辑 LF 输入；CRLF 的落盘还原由编辑器换行模型负责。
            try await edit(web, modified.replacingOccurrences(of: "\r\n", with: "\n"))
            try await content.save(overwriteExternalChanges: false)
            try check("\(filename) 高亮编辑后保存原始换行", try Data(contentsOf: file) == Data(modified.utf8) && !content.isModified)
            try await content.close(discardChanges: false)
        }
    }
    func hostChecks() async throws {
        let saveDirectory = output.appendingPathComponent("写入权限验收", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let firstURL = saveDirectory.appendingPathComponent("路由 A.txt")
        let secondURL = saveDirectory.appendingPathComponent("路由 B.txt")
        try Data("初始内容\r\n".utf8).write(to: firstURL)
        try Data("文件 B".utf8).write(to: secondURL)
        let first = try await host(at: firstURL)
        window.contentViewController = first
        try await settle(first)
        try await replace(first, "真实中文标记\r\n")
        try check("门面Smoke真实输入保留未保存CRLF", first.modified && String(contentsOf: firstURL, encoding: .utf8) == "初始内容\r\n")
        let second = try await host(at: secondURL)
        window.contentViewController = second
        try await settle(second)
        let saved = await save(first)
        try check("切换宿主后保存仍写入捕获的原会话", saved && String(contentsOf: firstURL, encoding: .utf8) == "真实中文标记\r\n" && String(contentsOf: secondURL, encoding: .utf8) == "文件 B")
        window.contentViewController = first
        try await replace(first, "关闭前仍未保存\r\n")
        let previewClosed = await withCheckedContinuation { continuation in
            first.closeCleanPreview { continuation.resume(returning: $0) }
        }
        try check("预览替换同步真实全文并拒绝丢弃", !previewClosed && first.modified)
        let cancelInteraction = Task { try await pressSheet("取消") }
        let cancelledClose = await withCheckedContinuation { continuation in
            first.requestClose(in: output) { continuation.resume(returning: $0) }
        }
        try await cancelInteraction.value
        try check("取消关闭保留真实编辑视图及未保存内容", !cancelledClose && first.modified && first.view.window === window
                  && String(contentsOf: firstURL, encoding: .utf8) == "真实中文标记\r\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: saveDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: saveDirectory.path) }
        let interaction = Task { try await pressSheet("保存"); try await pressSheet("知道了") }
        let closed = await withCheckedContinuation { continuation in
            first.requestClose(in: output) { continuation.resume(returning: $0) }
        }
        try await interaction.value
        try check("关闭时保存失败保留标签内容与dirty", !closed && first.modified && String(contentsOf: firstURL, encoding: .utf8) == "真实中文标记\r\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: saveDirectory.path)
        try check("失败后恢复权限仍可保存原会话", await save(first) && String(contentsOf: firstURL, encoding: .utf8) == "关闭前仍未保存\r\n")
    }
    func closePreview(_ browser: FWBrowserHost) async -> Bool {
        await withCheckedContinuation { continuation in browser.requestClosePreview { continuation.resume(returning: $0) } }
    }
    func event(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) async throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: keyCode) else { throw Failed.assertion("键盘事件创建失败") }
        print("STEP posted key", keyCode)
        NSApp.postEvent(event, atStart: false)
        try await Task.sleep(for: .milliseconds(180))
        print("STEP key returned", keyCode)
    }

    func textSelectionChecks(_ browser: FWBrowserHost) async throws {
        let directory = output.appendingPathComponent("text-selection", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 正文远超视口，防止全选/复制仅覆盖 CodeMirror 当前渲染的行。
        let source = directory.appendingPathComponent("只读中文.txt")
        let original = "中文😀 e\u{301}\n" + String(repeating: "跨视口的正文\n", count: 2_000)
        try Data(original.utf8).write(to: source)
        let store = browser.browserStore
        store.openRoot(directory, remember: false)
        try await waitUntil("TXT 目录读取") { !store.isLoading }
        store.selectedURL = source
        browser.openPreview(source, source: "text-selection")
        try await waitUntil("TXT 只读预览就绪") { browser.previewDocument?.canBeginEditing == true }
        guard let modal = browser.previewModal, let host = browser.previewDocument, let web = findWeb(host.view) else {
            throw Failed.assertion("没有 TXT 预览")
        }
        try check("TXT 打开后仍由弹窗容器持有焦点", window.firstResponder === modal.overlay.dialog)
        try await event("a", keyCode: 0, flags: .command)
        let selection = try await web.callAsyncJavaScript("return window.workbench.getInteractionState()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let ranges = (selection?["selection"] as? [String: Any])?["ranges"] as? [[String: Any]]
        try check("TXT 打开后 Command+A 选中完整正文", ranges?.first?["anchor"] as? Int == 0
                  && ranges?.first?["head"] as? Int == original.utf16.count && selection?["focusedEditor"] as? Bool == true)

        // 真实系统复制使用通用剪贴板；仅在仍持有本次写入时恢复原内容，避免覆盖用户并发复制。
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in result[type] = item.data(forType: type) }
        } ?? []
        var copiedChange: Int?
        defer {
            if let copiedChange, pasteboard.changeCount == copiedChange {
                pasteboard.clearContents()
                let items = previous.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(items)
            }
        }
        let menu = NSMenu(), editMenu = NSMenu(title: "编辑"), editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu; menu.addItem(editItem)
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        NSApp.mainMenu = menu
        let beforeCopy = pasteboard.changeCount
        try await event("c", keyCode: 8, flags: .command)
        if pasteboard.changeCount != beforeCopy { copiedChange = pasteboard.changeCount }
        try check("TXT Command+C 实际复制全部 Unicode 正文", pasteboard.string(forType: .string) == original)
        try await event("\u{7f}", keyCode: 51)
        let afterDelete = try await text(web)
        try check("TXT 全选后删除仍保持只读与磁盘原文", afterDelete == original && !host.modified && !host.isEditing
                  && (try Data(contentsOf: source)) == Data(original.utf8) && store.selectedURLs == [source])
        let point = try await web.callAsyncJavaScript("""
        const line = [...document.querySelectorAll('.cm-line')].find(node => {
          const rect = node.getBoundingClientRect(); return rect.top >= 0 && rect.bottom < innerHeight;
        });
        const rect = line.getBoundingClientRect(); return {x: rect.left + 16, y: (rect.top + rect.bottom) / 2};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Double]
        guard let point, let x = point["x"], let y = point["y"] else { throw Failed.assertion("没有可点击的正文行") }
        try await mouseClick(at: web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil))
        let clicked = try await web.callAsyncJavaScript("return window.workbench.getInteractionState().focusedEditor", arguments: [:], in: nil, contentWorld: .page) as? Bool
        try check("TXT 点击只读正文可获得键盘焦点", clicked == true)
        try await event("a", keyCode: 0, flags: .command)
        let selectedAll = try await web.callAsyncJavaScript("""
        const state = window.workbench.getInteractionState(); const range = state.selection.ranges[0];
        return state.focusedEditor && range.anchor === 0 && range.head === window.workbench.getText().length;
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        try check("TXT 点击正文后 Command+A 仍选中完整正文", selectedAll == true)
        try check("TXT 只读全选后可正常关闭", await closePreview(browser))

        let large = directory.appendingPathComponent("大文件.txt")
        try Data(repeating: 0x41, count: DocumentIO.maximumEditableBytes + 1).write(to: large)
        browser.openPreview(large, source: "text-selection-large")
        try await waitUntil("TXT 大文件有界预览就绪") {
            browser.previewModal?.overlay.dialog.allDescendants.contains { ($0 as? NSTextView)?.string.count == TextPreviewLoader.maximumBytes } == true
        }
        guard let nativeText = browser.previewModal?.overlay.dialog.allDescendants.compactMap({ $0 as? NSTextView }).first(where: { $0.isSelectable }) else {
            throw Failed.assertion("没有大文件只读正文")
        }
        try await event("a", keyCode: 0, flags: .command)
        try check("TXT 大文件 Command+A 仅全选已加载的只读预览", window.firstResponder === nativeText && !nativeText.isEditable
                  && nativeText.selectedRange() == NSRange(location: 0, length: TextPreviewLoader.maximumBytes))
        try check("TXT 大文件预览全选后可正常关闭", await closePreview(browser))
    }

    /// 固定隔离夹具使用 1040×760 窗口与默认 260 pt 侧栏；坐标由 browser-1040.png 与实际根行 frame 核验。
    /// SwiftUI 子行仅绘制、不暴露 NSView/进程内 AX 节点，因此从根行 {{16,359},{228,34}} 按 36 pt 行距推导。
    func directoryControlFrame(index: Int, expanding: Bool) -> NSRect {
        let row = NSRect(x: 16, y: 359 - CGFloat(index) * 36, width: 228, height: 34)
        let indentation: CGFloat = index == 0 ? 0 : 16
        return expanding
            ? NSRect(x: row.minX + 4 + indentation, y: row.minY, width: 24, height: row.height)
            : NSRect(x: row.minX + 28 + indentation, y: row.minY, width: row.width - 28 - indentation, height: row.height)
    }

    func captureBrowser(_ browser: FWBrowserHost, name: String) throws {
        browser.view.layoutSubtreeIfNeeded()
        guard let bitmap = browser.view.bitmapImageRepForCachingDisplay(in: browser.view.bounds) else {
            throw Failed.assertion("无法生成工作台验收截图")
        }
        browser.view.cacheDisplay(in: browser.view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failed.assertion("无法编码工作台验收截图") }
        try data.write(to: output.appendingPathComponent(name))
    }

    func clickDirectory(_ url: URL, in browser: FWBrowserHost, expanding: Bool = false,
                        xFraction: CGFloat, yFraction: CGFloat = 0.5) async throws {
        guard let root = browser.browserStore.managedRoots.first, browser.browserStore.managedRoots.count == 1 else {
            throw Failed.assertion("目录点击验收需要单根夹具")
        }
        // 顺序取自本夹具截图中明确可见的根、第二个展开目录、展开子目录；导航结果仍由真实鼠标事件产生。
        let displayed = [root, root.appendingPathComponent("第二个展开目录", isDirectory: true),
                         root.appendingPathComponent("展开子目录", isDirectory: true)]
        guard let index = displayed.firstIndex(of: url) else { throw Failed.assertion("目录不在验收夹具中") }
        let frame = directoryControlFrame(index: index, expanding: expanding)
        let point = NSPoint(x: frame.minX + frame.width * xFraction, y: frame.minY + frame.height * yFraction)
        try await mouseClick(at: point)
    }

    func mouseClick(at point: NSPoint, right: Bool = false, clickCount: Int = 1) async throws {
        if ProcessInfo.processInfo.environment["FW_NATIVE_HOST_MOUSE_DRIVER"] == "cgevent" {
            // 备用真实事件只允许打到当前测试进程的前台内容区；失焦或窗口变化时直接拒绝。
            guard NSApp.isActive, window.isKeyWindow, window.contentView?.frame.contains(point) == true,
                  let primary = NSScreen.screens.first else { throw Failed.assertion("测试窗口不是活动目标，拒绝 CGEvent：active=\(NSApp.isActive), key=\(window.isKeyWindow), point=\(point), content=\(String(describing: window.contentView?.frame))") }
            let screenPoint = window.convertPoint(toScreen: point)
            let location = CGPoint(x: screenPoint.x, y: primary.frame.maxY - screenPoint.y)
            for type: CGEventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                guard NSApp.isActive, window.isKeyWindow,
                      let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
                                          mouseButton: right ? .right : .left) else { throw Failed.assertion("测试窗口失焦或无法创建 CGEvent") }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(40))
            }
        } else {
            for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: clickCount, pressure: 1) else {
                    throw Failed.assertion("无法创建鼠标事件")
                }
                NSApp.postEvent(event, atStart: false)
            }
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    func directoryClickChecks(_ browser: FWBrowserHost, directory: URL, child: URL, secondChild: URL) async throws {
        // 目录/欢迎页切换与窗口缩放后恢复本验收窗口焦点；实际点击仍逐次检查前台与 KeyWindow。
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(120))
        let store = browser.browserStore
        try await clickDirectory(child, in: browser, xFraction: 0.94)
        try await waitUntil("点击目录行空白后进入子目录") { store.currentDirectory == child && !store.isLoading }
        try check("目录行文字右侧空白可单击导航", store.currentDirectory == child)

        let wasExpanded = store.expandedDirectories.contains(child)
        try await clickDirectory(child, in: browser, expanding: true, xFraction: 0.12, yFraction: 0.18)
        try check("展开箭头边缘可点击且不改变当前目录", store.expandedDirectories.contains(child) != wasExpanded && store.currentDirectory == child)
        try await clickDirectory(child, in: browser, expanding: true, xFraction: 0.88, yFraction: 0.82)
        try check("展开箭头另一边缘可再次切换", store.expandedDirectories.contains(child) == wasExpanded && store.currentDirectory == child)

        for target in [secondChild, child, directory, secondChild, directory] {
            try await clickDirectory(target, in: browser, xFraction: 0.94)
            try await waitUntil("连续目录点击：" + target.lastPathComponent) { store.currentDirectory == target && !store.isLoading }
        }
        try check("连续切换后目录行空白仍可导航", store.currentDirectory == directory)
    }

    func menuItem(named title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        menu.update()
        for (index, item) in menu.items.enumerated() {
            if item.title == title { return (menu, index) }
            if let submenu = item.submenu, let found = menuItem(named: title, in: submenu) { return found }
        }
        return nil
    }

    func contextCreationCheck(_ browser: FWBrowserHost, directory: URL) async throws {
        let capturedMenu = MenuCapture()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let menu = note.object as? NSMenu, capturedMenu.menu == nil { capturedMenu.menu = menu }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let chooseTemplate = Task { @MainActor in
            try await waitUntil("右键新建菜单") { capturedMenu.menu != nil }
            guard let menu = capturedMenu.menu, let (submenu, index) = menuItem(named: "文本文件 (.txt)", in: menu) else {
                capturedMenu.menu?.cancelTrackingWithoutAnimation()
                throw Failed.assertion("右键菜单缺少文本文件模板")
            }
            let titles = menu.items.map(\.title)
            try JSONSerialization.data(withJSONObject: titles, options: [.prettyPrinted])
                .write(to: output.appendingPathComponent("context-menu.json"))
            menu.cancelTrackingWithoutAnimation()
            submenu.performActionForItem(at: index)
        }
        let rootFrame = directoryControlFrame(index: 0, expanding: false)
        try await mouseClick(at: NSPoint(x: rootFrame.maxX - 10, y: rootFrame.midY), right: true)
        try await chooseTemplate.value
        try await waitUntil("新建文件命名弹窗") { self.window.attachedSheet != nil }
        guard let sheet = window.attachedSheet,
              let field = sheet.contentView?.allDescendants.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.isEnabled }) else {
            throw Failed.assertion("新建弹窗没有可编辑名称框")
        }
        field.selectText(nil)
        guard let fieldEditor = sheet.firstResponder as? NSTextView else { throw Failed.assertion("名称框未获得输入焦点") }
        let name = "右键新建验收.txt"
        fieldEditor.selectAll(nil)
        fieldEditor.insertText(name, replacementRange: fieldEditor.selectedRange())
        try await event("\r", keyCode: 36)
        let destination = directory.appendingPathComponent(name)
        // 创建完成后会异步刷新列表；等待其选中状态落定，避免下一段验收设置的选择被旧回调覆盖。
        try await waitUntil("右键新建真实落盘") {
            FileManager.default.fileExists(atPath: destination.path) && self.window.attachedSheet == nil
                && !browser.browserStore.isLoading && browser.browserStore.selectedURL == destination
        }
        try check("右键选择文本模板并命名后真实创建文件", try Data(contentsOf: destination).isEmpty && browser.browserStore.currentDirectory == directory)
        try captureBrowser(browser, name: "context-created.png")
    }

    /// 仅操作本次 UUID 样本；检查系统废纸篓中的真实身份，再恢复原位置，绝不扫描/清空用户废纸篓。
    func trashMenuChecks(_ browser: FWBrowserHost) async throws {
        let store = browser.browserStore
        let directory = output.appendingPathComponent("F1-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = "FileDeck-F1-" + UUID().uuidString
        let files = ["a", "b", "c"].map { directory.appendingPathComponent(prefix + "-" + $0 + ".txt") }
        for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
        let trashDirectory = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        let originals = try files.map { (url: $0, identity: try FileSystem.identity(at: $0)) }
        func restoreSamples() throws {
            for item in originals {
                let trashed = trashDirectory.appendingPathComponent(item.url.lastPathComponent)
                if (try? FileSystem.identity(at: trashed)) == item.identity {
                    guard !FileManager.default.fileExists(atPath: item.url.path) else { throw Failed.assertion("临时恢复目标已存在") }
                    try FileManager.default.moveItem(at: trashed, to: item.url)
                }
            }
        }
        defer { try? restoreSamples() }
        store.openQuickLocation(directory)
        store.gridView = false
        try await waitUntil("F1 样本列表") { !store.isLoading && store.entries.count == 3 }
        browser.view.layoutSubtreeIfNeeded()
        for replacing in [false, true] {
            // refresh 会通过加载态重建原生 List，不能继续选择上轮已经脱离窗口的 NSTableView。
            try await waitUntil("F1 当前列表已挂载") {
                browser.view.allDescendants.compactMap { $0 as? NSTableView }
                    .contains { $0.window === self.window && $0.numberOfRows == 3 }
            }
            guard let table = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).last,
                  table.window === window else { throw Failed.assertion("F1 没有挂载的真实文件列表") }
            let rows = files.prefix(2).compactMap { file in store.orderedEntries.firstIndex { $0.url == file } }
            guard rows.count == 2 else { throw Failed.assertion("F1 多选行缺失") }
            table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            window.makeFirstResponder(table)
            try await waitUntil("F1 原生列表多选") { store.selectedURLs == Set(files.prefix(2)) }
            let capturedMenu = MenuCapture()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if let menu = note.object as? NSMenu, capturedMenu.menu == nil { capturedMenu.menu = menu }
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let chooseTrash = Task { @MainActor in
                try await waitUntil("F1 右键菜单") { capturedMenu.menu != nil }
                guard let menu = capturedMenu.menu, let (owner, index) = menuItem(named: "移到废纸篓（2 个项目）", in: menu) else {
                    capturedMenu.menu?.cancelTrackingWithoutAnimation()
                    throw Failed.assertion("F1 菜单没有冻结 2 项")
                }
                try check(replacing ? "替换前菜单仍显示原多选数量" : "原生右键菜单显示2项废纸篓操作", owner.items[index].isEnabled)
                if replacing {
                    // 菜单已生成再替换第二项/改变选择；按钮必须继续使用原二项快照。
                    try Data("F1 replacement must survive".utf8).write(to: files[1], options: .atomic)
                    store.selectedURL = files[2]
                }
                menu.cancelTrackingWithoutAnimation()
                owner.performActionForItem(at: index)
            }
            let rect = table.rect(ofRow: rows[0])
            let point = table.convert(NSPoint(x: rect.minX + 110, y: rect.midY), to: nil)
            // 上一段关闭预览可能将焦点交还调用方；仅激活本测试窗口后进入真实菜单。
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(120))
            try await mouseClick(at: point, right: true)
            try await chooseTrash.value
            try await waitUntil("F1 系统废纸篓完成") {
                !store.isFileOperationBusy && !store.isLoading
                    && !FileManager.default.fileExists(atPath: files[0].path)
            }
            let removed = replacing ? Array(originals.prefix(1)) : Array(originals.prefix(2))
            for item in removed {
                let target = trashDirectory.appendingPathComponent(item.url.lastPathComponent)
                try check("系统废纸篓包含样本原身份：" + item.url.lastPathComponent,
                          (try? FileSystem.identity(at: target)) == item.identity)
            }
            if replacing {
                let summary = store.actionError ?? ""
                try check("同名替换拒绝且部分失败按数量汇总", summary.contains("1 个项目移到废纸篓，1 个项目未完成（共 2 个）")
                          && summary.contains(files[1].lastPathComponent)
                          && (try String(contentsOf: files[1])) == "F1 replacement must survive")
                try check("菜单打开后新选择没有被移走", store.selectedURL == files[2]
                          && FileManager.default.fileExists(atPath: files[2].path))
                try await pressSheet("知道了")
            } else {
                try check("多选成功仅移走两项且未选项保留", store.actionError == nil && store.selectedURLs.isEmpty
                          && FileManager.default.fileExists(atPath: files[2].path))
            }
            try restoreSamples()
            store.refresh()
            try await waitUntil("F1 样本恢复后列表") { !store.isLoading && store.entries.count == 3 }
        }
        try JSONSerialization.data(withJSONObject: ["files": files.map(\.path), "restored": true], options: [.prettyPrinted])
            .write(to: output.appendingPathComponent("trash-samples.json"))
    }

    /// SwiftUI 子按钮不暴露进程内 AX 子树。取消坐标由 file-operation-progress.png 核验，
    /// 取消中心为内容顶部 72 pt、右侧 28 pt；撤销中心为顶部 72 pt、右侧 154 pt，
    /// 后者由 file-operation-result.png 核验。真正点击仍经过前台/KeyWindow/内容区门禁。
    func pressFileOperationButton(_ identifier: String, in browser: FWBrowserHost) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(160))
        browser.view.layoutSubtreeIfNeeded()
        let inset: CGFloat
        if identifier == "file-operation-cancel", browser.browserStore.fileOperationProgress != nil { inset = 28 }
        else if identifier == "file-operation-undo", browser.browserStore.fileOperationUndo.count == 1,
                browser.browserStore.fileOperationProgress == nil { inset = 154 }
        else { throw Failed.assertion("按钮状态与已核验夹具不符，拒绝点击：" + identifier) }
        let point = browser.view.convert(NSPoint(x: browser.view.bounds.maxX - inset, y: browser.view.bounds.maxY - 72), to: nil)
        try await mouseClick(at: point)
    }

    /// 等待仅发生在后台系统调用之前，让真实浏览页可确定地展示取消中的状态。
    final class FileOperationGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var waiting = false
        private var released = false
        var entered: Bool { condition.lock(); defer { condition.unlock() }; return waiting }
        func wait() { condition.lock(); waiting = true; while !released { condition.wait() }; condition.unlock() }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }
    func fileOperationChecks(_ browser: FWBrowserHost) async throws {
        let store = browser.browserStore
        let directory = output.appendingPathComponent("F4-" + UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let prefix = "FileDeck-F4-" + UUID().uuidString
        let files = ["a", "b", "c"].map { directory.appendingPathComponent(prefix + "-" + $0 + ".txt") }
        for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
        // 仅保留系统返回的 UUID 项目的精确位置，失败退出也尽力恢复，绝不枚举用户废纸篓。
        var cleanupRecords: [FileOperationUndo] = []
        var copyRecovery: (original: URL, trash: URL, identity: FileIdentity)?
        defer {
            _ = FileOperationUndo.perform(cleanupRecords, control: .init(title: "样本恢复", total: cleanupRecords.count))
            if let copyRecovery, (try? FileSystem.identity(at: copyRecovery.trash)) == copyRecovery.identity {
                _ = try? WorkspaceFileTransfer.move(copyRecovery.trash, to: copyRecovery.original, expectedIdentity: copyRecovery.identity)
            }
        }
        store.resetFilters()
        store.gridView = false
        window.setContentSize(NSSize(width: 1440, height: 900))
        store.openQuickLocation(directory)
        try await waitUntil("F4 列表") { !store.isLoading && store.entries.count == 4 }
        let frozen = files.compactMap { url in store.entries.first { $0.url == url } }
        let gate = FileOperationGate()
        defer { gate.release() }
        let operation = Task { await store.trashFiles(frozen, trashAndLocate: { url in
            gate.wait()
            return try WorkspaceFileTrash.systemTrash(url)
        }) }
        let result: WorkspaceFileTrash.Result?
        do {
            try await waitUntil("F4 当前项等待") { gate.entered && store.fileOperationProgress?.current != nil }
            try check("文件操作显示当前文件及数量进度", store.fileOperationProgress?.total == 3
                      && store.fileOperationProgress?.completed == 0 && store.fileOperationProgress?.current == files[0].lastPathComponent)
            try await Task.sleep(for: .milliseconds(160))
            try captureBrowser(browser, name: "file-operation-progress.png")
            try await pressFileOperationButton("file-operation-cancel", in: browser)
            try check("真实取消按钮请求停止且当前调用继续持有门禁", store.fileOperationProgress?.cancellationRequested == true && store.isFileOperationBusy)
            try captureBrowser(browser, name: "file-operation-cancelling.png")
            store.selectedURL = files[2]
            gate.release()
            result = await operation.value
        } catch {
            store.cancelFileOperation()
            gate.release()
            cleanupRecords = await operation.value?.undo ?? []
            throw error
        }
        cleanupRecords = result?.undo ?? []
        try await waitUntil("F4 废纸篓取消落定") { !store.isFileOperationBusy && !store.isLoading }
        try check("取消废纸篓只完成当前项并保留后两项", result?.succeeded.count == 1 && result?.unattempted == 2
                  && FileManager.default.fileExists(atPath: files[1].path) && FileManager.default.fileExists(atPath: files[2].path))
        try check("取消结果保留当前选择和成功项撤销", store.selectedURL == files[2] && store.fileOperationUndo.count == 1
                  && (store.fileOperationSummary?.contains("未执行 2") == true))
        try captureBrowser(browser, name: "file-operation-result.png")
        try await pressFileOperationButton("file-operation-undo", in: browser)
        try await waitUntil("F4 系统废纸篓撤销") { !store.isFileOperationBusy && !store.isLoading && FileManager.default.fileExists(atPath: files[0].path) }
        cleanupRecords = []
        try check("真实撤销按钮从系统返回位置恢复废纸篓样本", store.fileOperationUndo.isEmpty && (try String(contentsOf: files[0])) == files[0].lastPathComponent)

        let token = store.beginFileDrag(files[0], includingSelection: false)
        store.dropActiveDrag(token: token, into: destination, copy: false)
        try await waitUntil("F4 移动") { !store.isFileOperationBusy && !store.isLoading }
        try check("移动完成可撤销且源路径已迁移", store.fileOperationUndo.count == 1 && !FileManager.default.fileExists(atPath: files[0].path))
        try await pressFileOperationButton("file-operation-undo", in: browser)
        try await waitUntil("F4 移动撤销") { !store.isFileOperationBusy && !store.isLoading && FileManager.default.fileExists(atPath: files[0].path) }
        try check("移动撤销恢复原路径且目标清空", (try FileManager.default.contentsOfDirectory(atPath: destination.path)).isEmpty)

        store.importFiles([files[0]], into: destination)
        try await waitUntil("F4 复制") { !store.isFileOperationBusy && !store.isLoading }
        let copied = destination.appendingPathComponent(files[0].lastPathComponent)
        let copiedIdentity = try FileSystem.identity(at: copied)
        try check("复制完成显示成功数量且原件保留", store.fileOperationUndo.count == 1 && (store.fileOperationSummary?.contains("成功 1") == true)
                  && (try String(contentsOf: files[0])) == files[0].lastPathComponent)
        // 已知唯一 UUID 名称和原身份；只检查该精确 URL，不扫描废纸篓。
        let trashDirectory = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: copied, create: true)
        let trashCopy = trashDirectory.appendingPathComponent(copied.lastPathComponent)
        copyRecovery = (copied, trashCopy, copiedIdentity)
        try await pressFileOperationButton("file-operation-undo", in: browser)
        try await waitUntil("F4 复制撤销") { !store.isFileOperationBusy && !store.isLoading && !FileManager.default.fileExists(atPath: copied.path) }
        if (try? FileSystem.identity(at: trashCopy)) == copiedIdentity {
            try FileManager.default.moveItem(at: trashCopy, to: copied)
        } else { throw Failed.assertion("复制撤销样本不在预期唯一废纸篓位置，拒绝猜测清理") }
        cleanupRecords = []
        copyRecovery = nil
        try check("复制撤销把副本放入废纸篓且原件不变", (try String(contentsOf: copied)) == files[0].lastPathComponent
                  && (try String(contentsOf: files[0])) == files[0].lastPathComponent && store.fileOperationUndo.isEmpty)
        try JSONSerialization.data(withJSONObject: ["files": files.map(\.path), "copyRestoredFromTrash": copied.path,
                                                   "scope": "real progress/cancel/undo controls; real system Trash; UUID samples only"], options: [.prettyPrinted])
            .write(to: output.appendingPathComponent("file-operation-samples.json"))
    }

    func captureSearchSheet(_ name: String) throws {
        guard let view = window.attachedSheet?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failed.assertion("没有真实搜索面板") }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failed.assertion("搜索截图失败") }
        try data.write(to: output.appendingPathComponent(name))
    }
    func typeSearchTerm(_ text: String) async throws {
        let sheet = window.attachedSheet ?? window!
        guard let field = sheet.contentView?.allDescendants.compactMap({ $0 as? NSTextField })
            .first(where: { $0.placeholderString == "输入搜索词（字面子串）" }) else { throw Failed.assertion("没有搜索词输入框") }
        sheet.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        field.selectText(nil)
        guard let editor = sheet.firstResponder as? NSTextView else { throw Failed.assertion("搜索输入框未获得焦点") }
        editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(120))
    }
    func searchSheetKey(_ text: String, code: UInt16) async throws {
        let parent = window!
        guard let sheet = parent.attachedSheet else { throw Failed.assertion("搜索面板已关闭") }
        window = sheet
        defer { window = parent }
        try await event(text, keyCode: code)
    }
    func clickSearchSheet(x: CGFloat, top: CGFloat) async throws {
        let parent = window!
        guard let sheet = parent.attachedSheet, let view = sheet.contentView else { throw Failed.assertion("搜索面板已关闭") }
        window = sheet
        defer { window = parent }
        sheet.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(100))
        try await mouseClick(at: view.convert(NSPoint(x: x, y: view.isFlipped ? top : view.bounds.maxY - top), to: nil))
    }
    func locateFirstSearchResult() async throws {
        guard let sheet = window.attachedSheet, let content = sheet.contentView,
              content.bounds.width == 850, content.bounds.height == 620,
              content.allDescendants.compactMap({ $0 as? NSTableView }).contains(where: { $0.numberOfRows == 1 }) else {
            throw Failed.assertion("搜索结果没有已核验尺寸的唯一真实列表行")
        }
        // 由 search-name-results.png 核验：850×620 面板唯一名称行的定位按钮中心为 (804, 298)。
        // List 的 AppKit 包装表与 SwiftUI 行布局边界不相同，因此不用包装表 rect 推测按钮位置。
        try await clickSearchSheet(x: 804, top: 298)
        if window.attachedSheet != nil { try captureSearchSheet("search-location-after.png") }
    }
    /// 正式工具栏入口与正式 SwiftUI 搜索面板均参与验收；阻塞闸门只替换后台工作器，不改按钮处理。
    /// 使用正式浏览根和工作层；只在本次 UUID 夹具中写文件，验证可见快捷键及返回路径。
    /// 使用正式列表/网格绘制真实夹具；只检查装饰、选择命中与快照边界，不解析伪造的文档正文。
    func fileIconChecks(_ browser: FWBrowserHost) async throws {
        let directory = output.appendingPathComponent("文件图标样本", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appendingPathComponent("01 项目资料", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let names = ["02 项目说明.docx", "03 费用明细.xlsx", "04 项目汇报.pptx", "05 产品手册.pdf", "06 阅读说明.md",
                     "07 数据样例.json", "08 应用配置.yaml", "09 界面组件.swift", "10 待办事项.txt", "11 设计参考.png",
                     "12 现场照片.jpg", "13 会议录音.mp3", "14 操作演示.mp4", "15 项目归档.zip", "16 原始数据.unknown"]
        for name in names { try Data().write(to: directory.appendingPathComponent(name)) }
        let link = directory.appendingPathComponent("17 资料链接")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let application = directory.appendingPathComponent("18 示例应用.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName":"示例应用", "CFBundleIdentifier":"local.fileworkbench.icon-fixture", "CFBundlePackageType":"APPL"], format: .xml, options: 0)
            .write(to: application.appendingPathComponent("Contents/Info.plist"))
        let store = browser.browserStore
        store.openRoot(directory, remember: false)
        try await waitUntil("图标样本载入") { !store.isLoading && store.entries.count == names.count + 3 }
        try check("应用包保留系统图标", store.entries.first(where: { $0.url == application }).map { WorkspaceFileIconDescriptor(entry: $0).kind == .system } == true)
        try check("符号链接保留快照箭头标识", store.entries.first(where: { $0.name == link.lastPathComponent }).map { $0.isSymbolicLink && WorkspaceFileIconDescriptor(entry: $0).isSymbolicLink } == true)
        window.setContentSize(NSSize(width: 1200, height: 940))
        window.appearance = NSAppearance(named: .aqua)
        store.gridView = false
        try await Task.sleep(for: .milliseconds(200))
        guard let table = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).last,
              let row = store.orderedEntries.firstIndex(where: { $0.name == "06 阅读说明.md" }) else { throw Failed.assertion("缺少图标列表") }
        table.scrollRowToVisible(row)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await mouseClick(at: table.convert(NSPoint(x: 31, y: table.rect(ofRow: row).midY), to: nil))
        try await waitUntil("图标区域单击选中") { store.selectedURL?.lastPathComponent == "06 阅读说明.md" }
        try check("点击图标仅选择文件并保留浏览焦点", browser.previewModal == nil && window.firstResponder === table)
        try captureBrowser(browser, name: "file-icons-list-light.png")
        store.gridView = true
        window.setContentSize(NSSize(width: 1200, height: 720))
        try await Task.sleep(for: .milliseconds(180))
        try captureBrowser(browser, name: "file-icons-grid-light.png")
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(200))
        try captureBrowser(browser, name: "file-icons-grid-dark.png")
        store.gridView = false
        window.setContentSize(NSSize(width: 1200, height: 940))
        try await Task.sleep(for: .milliseconds(180))
        try captureBrowser(browser, name: "file-icons-list-dark.png")
        try check("切换视图及浅深色保持同一文件选择", store.selectedURL?.lastPathComponent == "06 阅读说明.md" && browser.previewModal == nil)
    }

    func interactionChecks(_ browser: FWBrowserHost, checksDirectoryPanel: Bool = true) async throws {
        let store = browser.browserStore
        let directory = output.appendingPathComponent("FileDeck 示例工作区", isDirectory: true)
        let nested = directory.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("工作说明.md")
        let hit = nested.appendingPathComponent("needle.txt")
        try Data("# 原始内容\n".utf8).write(to: source)
        try Data("第一行\n正文关键字\n".utf8).write(to: hit)
        if checksDirectoryPanel {
            // 系统授权入口取消必须保持初始状态；选择确认后的业务路径用同一 openRoot 验证。
            try await waitUntil("授权前窗口就绪") { NSApp.keyWindow === self.window }
            store.chooseFolder()
            try await waitUntil("系统目录授权面板") { self.window.attachedSheet != nil }
            // 系统授权面板的远程视图不接收 NSApp.postEvent；只在本测试的活动 sheet 上投递 Escape。
            guard NSApp.isActive, let panel = window.attachedSheet, panel.isKeyWindow else { throw Failed.assertion("系统授权面板不是本测试的活动窗口") }
            for down in [true, false] {
                // Escape 的 keyDown 可能已关闭远程面板；keyUp 只要求仍是本测试应用，避免误判正常关闭。
                guard NSApp.isActive, (!down || (window.attachedSheet === panel && panel.isKeyWindow)),
                      let key = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down) else { throw Failed.assertion("授权面板失去焦点，拒绝投递键盘事件") }
                key.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(30))
            }
            try await waitUntil("授权面板取消") { self.window.attachedSheet == nil }
            try check("目录授权取消不添加管理根", store.managedRoots.isEmpty)
        }
        store.openRoot(directory, remember: true)
        try await waitUntil("交互目录载入") { !store.isLoading && store.entries.count == 2 }
        if let suite = ProcessInfo.processInfo.environment["FW_WORKBENCH_TEST_SUITE"], let defaults = UserDefaults(suiteName: suite) {
            let resumed = BrowserStore(defaults: defaults)
            try check("已有工作区可从欢迎页继续", resumed.hasPreviousWorkspace)
            resumed.skipWelcome()
            try await waitUntil("恢复上次目录") { resumed.startupPhase == .ready && !resumed.isLoading }
            try check("继续工作区恢复原管理根和目录", resumed.managedRoots.contains(directory) && resumed.currentDirectory == directory)
        }
        store.gridView = false; store.selectedURL = source
        try await Task.sleep(for: .milliseconds(200))
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1040, height: 760))
        try await Task.sleep(for: .milliseconds(180))
        try captureBrowser(browser, name: "interaction-light.png")
        window.setContentSize(NSSize(width: 860, height: 660))
        try await Task.sleep(for: .milliseconds(180))
        try captureBrowser(browser, name: "interaction-compact.png")
        try check("窄窗保持原列表和文件选择", window.contentLayoutRect.width >= 860 && store.selectedURL == source)
        if let directoryField = browser.view.allDescendants.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "搜索目录…" }) {
            directoryField.selectText(nil)
            try await event("s", keyCode: 1, flags: [.command, .option])
            try await event("j", keyCode: 38)
            try check("折叠侧栏后输入交给可见筛选框", store.query == "j" && directoryField.stringValue.isEmpty)
            store.query = ""
            store.selectedURL = source
        } else { throw Failed.assertion("缺少侧栏搜索框") }
        try await Task.sleep(for: .milliseconds(150))
        try captureBrowser(browser, name: "interaction-sidebar-collapsed.png")
        try await event("s", keyCode: 1, flags: [.command, .option])
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(200))
        try captureBrowser(browser, name: "interaction-dark.png")
        try check("工作区没有强制浅色外观", browser.backgroundView.appearance == nil && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        guard let table = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).last else { throw Failed.assertion("没有正式文件列表") }
        window.makeFirstResponder(table)
        try await event("e", keyCode: 14, flags: .command)
        try await waitUntil("选区快捷键直接进入编辑") { browser.previewDocument?.isEditing == true && browser.previewDocument?.canSave == true }
        guard let doc = browser.previewDocument, let modal = browser.previewModal else { throw Failed.assertion("没有直接编辑会话") }
        try check("直接编辑只创建同一原生工作层", modal.source == "edit" && window.attachedSheet == nil && doc.documentURL == source)
        try await event("x", keyCode: 7)
        try await waitUntil("直接键入正文") { doc.modified }
        try check("进入编辑后无需再点击即可输入正文", try await text(findWeb(doc.view)!).contains("x"))
        try await replace(doc, "# 保存并返回的新内容\n")
        try check("编辑前原件保持不变", (try String(contentsOf: source)) == "# 原始内容\n" && doc.modified)
        try await Task.sleep(for: .milliseconds(200))
        try captureBrowser(browser, name: "interaction-editing-dark.png")
        try await event("\r", keyCode: 36, flags: .command)
        try await waitUntil("保存并返回完成") { browser.previewModal == nil }
        try check("保存并返回保留列表选择和原焦点", (try String(contentsOf: source)) == "# 保存并返回的新内容\n" && store.selectedURL == source && window.firstResponder === table)
        browser.openPreview(source, source: "edit")
        try await waitUntil("再次直接编辑") { browser.previewDocument?.isEditing == true && browser.previewDocument?.canSave == true }
        guard let dirty = browser.previewDocument else { throw Failed.assertion("未创建第二次编辑会话") }
        try await replace(dirty, "未保存内容必须保留\n")
        let cancel = Task { try await pressSheet("取消") }
        let closed = await closePreview(browser); try await cancel.value
        try check("返回浏览取消后保留未保存会话", !closed && browser.previewDocument === dirty && dirty.modified)
        try Data("外部修改版本\n".utf8).write(to: source)
        guard let saveReturn = browser.previewModal?.overlay.dialog.allDescendants.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "FileDeck.preview.save-and-return" || $0.title == "保存并返回" }) else { throw Failed.assertion("没有保存并返回按钮") }
        let cancelConflict = Task { try await pressSheet("取消") }
        saveReturn.performClick(nil); try await cancelConflict.value
        try await waitUntil("冲突取消后结束保存") { !dirty.busy }
        try check("保存并返回遇外部冲突保留编辑和磁盘版本", browser.previewDocument === dirty && dirty.modified && (try String(contentsOf: source)) == "外部修改版本\n")
        let discard = Task { try await pressSheet("不保存") }
        let discarded = await closePreview(browser); try await discard.value
        try check("冲突后明确丢弃才返回浏览", discarded && browser.previewModal == nil)
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(180))
        try await event("f", keyCode: 3, flags: [.command, .shift])
        try captureBrowser(browser, name: "interaction-search-entry.png")
        print("SEARCH ENTRY active=\(NSApp.isActive) key=\(window.isKeyWindow) modal=\(browser.previewModal != nil) sheet=\(window.attachedSheet != nil) responder=\(String(describing: window.firstResponder))")
        try await waitUntil("正式搜索输入框") {
            browser.view.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "输入搜索词（字面子串）" }
        }
        try check("递归搜索就在原窗口内容区", window.attachedSheet == nil && store.currentDirectory == directory)
        try await typeSearchTerm("needle")
        try await event("\r", keyCode: 36)
        try await Task.sleep(for: .milliseconds(500))
        try captureBrowser(browser, name: "interaction-search-results.png")
        try check("正式内容区显示真实搜索结果", browser.view.allDescendants.compactMap({ $0 as? NSTableView }).contains { $0.numberOfRows == 1 })
        // 1440×900 正式工作区，唯一结果行按钮由 interaction-search-results.png 核验。
        try await mouseClick(at: browser.view.convert(NSPoint(x: 1344, y: browser.view.bounds.maxY - 326), to: nil))
        try await waitUntil("搜索结果预览") { browser.previewDocument?.canBeginEditing == true }
        try check("搜索预览不改变原浏览位置", browser.previewModal?.url == hit && store.currentDirectory == directory)
        try await event(" ", keyCode: 49)
        try await waitUntil("空格关闭只读搜索预览") { browser.previewModal == nil }
        try check("关闭预览回到同一搜索结果", browser.view.allDescendants.compactMap({ $0 as? NSTableView }).contains { $0.numberOfRows == 1 })
        try await mouseClick(at: browser.view.convert(NSPoint(x: 1396, y: browser.view.bounds.maxY - 326), to: nil))
        try await waitUntil("定位搜索结果") { !store.isLoading && store.selectedURL == hit }
        try check("内容区定位进入原父目录并选中文件", store.currentDirectory == nested && store.query.isEmpty)
        store.openQuickLocation(directory)
        try await waitUntil("搜索返回原夹具") { !store.isLoading }
        store.selectedURL = source
        try await event("f", keyCode: 3, flags: [.command, .shift])
        try await typeSearchTerm("正文关键字")
        try await mouseClick(at: browser.view.convert(NSPoint(x: 408, y: browser.view.bounds.maxY - 139), to: nil))
        try await event("\r", keyCode: 36)
        try await Task.sleep(for: .milliseconds(500))
        try captureBrowser(browser, name: "interaction-content-results.png")
        try check("正文搜索在同一内容区显示结果", browser.view.allDescendants.compactMap({ $0 as? NSTableView }).contains { $0.numberOfRows == 1 })
        try await event("\u{1b}", keyCode: 53)
        try await Task.sleep(for: .milliseconds(150))
        try check("搜索返回保留原目录选区与源文件", store.currentDirectory == directory && store.selectedURL == source && (try String(contentsOf: hit)) == "第一行\n正文关键字\n")
    }

    func directorySearchChecks(_ browser: FWBrowserHost) async throws {
        let store = browser.browserStore
        let directory = output.appendingPathComponent("F5-" + UUID().uuidString, isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        let excluded = directory.appendingPathComponent("node_modules", isDirectory: true)
        let package = directory.appendingPathComponent("Doc.rtfd", isDirectory: true)
        for folder in [nested, excluded, package] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let keep = directory.appendingPathComponent("keep.txt")
        let found = nested.appendingPathComponent("needle.txt")
        let contentFile = nested.appendingPathComponent("content.txt")
        let body = "第一行\r\n第二行 秘密关键字😀\n"
        try Data("keep".utf8).write(to: keep)
        try Data("name result".utf8).write(to: found)
        try Data(body.utf8).write(to: contentFile)
        for folder in [excluded, package] { try Data("秘密关键字😀".utf8).write(to: folder.appendingPathComponent("needle.txt")) }
        store.resetFilters(); store.gridView = false; store.openQuickLocation(directory)
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await waitUntil("F5 浏览目录") { !store.isLoading && store.entries.count == 4 }
        store.query = "keep"; store.selectedURL = keep
        let history = store.history, selection = store.selectedURLs
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(180))
        try captureBrowser(browser, name: "search-toolbar.png")
        try await event("f", keyCode: 3, flags: [.command, .shift])
        try await waitUntil("F5 工具栏打开内嵌搜索") {
            browser.view.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "输入搜索词（字面子串）" && !$0.isHiddenOrHasHiddenAncestor }
        }
        try check("搜索在主内容区呈现，不新建 sheet", window.attachedSheet == nil)
        try captureBrowser(browser, name: "search-entry.png")
        try await event("\u{1b}", keyCode: 53)
        try await Task.sleep(for: .milliseconds(150))
        try check("递归搜索入口实际打开且关闭不改变浏览状态", store.currentDirectory == directory && store.history == history
                  && store.selectedURLs == selection && store.query == "keep")

        let gate = FileOperationGate()
        defer { gate.release() }
        let session = DirectorySearchSession(worker: { request, control in gate.wait(); return DirectorySearchEngine.run(request, control: control) })
        func present() async throws {
            window.contentViewController = NSHostingController(rootView: DirectorySearchAcceptanceRoot(store: store, session: session))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await waitUntil("F5 正式搜索视图呈现") { self.window.attachedSheet != nil }
        }
        try await present()
        try await typeSearchTerm("needle")
        try await searchSheetKey("\r", code: 36)
        try await waitUntil("F5 真正开始搜索") { gate.entered && session.isRunning }
        try check("真实输入及搜索按钮冻结名称词和限定目录", session.snapshot?.request.term == "needle" && session.snapshot?.request.mode == .name
                  && session.snapshot?.request.root == directory && store.selectedURLs == selection)
        try captureSearchSheet("search-running.png")
        guard let sheetWidth = window.attachedSheet?.contentView?.bounds.width else { throw Failed.assertion("搜索面板尺寸缺失") }
        try await clickSearchSheet(x: sheetWidth - 40, top: 93)
        try check("取消按钮在后台等待时仍可响应且保留工作器门禁", session.isRunning && session.isStopping)
        gate.release()
        try await waitUntil("F5 取消落定") { !session.isRunning }
        try check("取消不改导航筛选或选择且不把未执行搜索说成完成", session.snapshot?.end == .cancelled
                  && store.currentDirectory == directory && store.history == history && store.selectedURLs == selection && store.query == "keep")
        try await searchSheetKey("\r", code: 36)
        try await waitUntil("F5 名称结果") { !session.isRunning && session.snapshot?.end == .completed && session.snapshot?.hits.count == 1 }
        try check("真实名称搜索命中嵌套路径并排除依赖目录和包", session.snapshot?.hits.first?.id == "nested/needle.txt"
                  && session.snapshot?.skipped[.excluded] == 1 && session.snapshot?.skipped[.package] == 1)
        try captureSearchSheet("search-name-results.png")
        try await locateFirstSearchResult()
        try await waitUntil("F5 定位结果") { self.window.attachedSheet == nil && !store.isLoading && store.selectedURL == found }
        try check("定位按钮实际返回匹配项父目录并选中原身份", store.currentDirectory == nested && store.selectedURL == found)

        store.openQuickLocation(directory)
        try await waitUntil("F5 内容搜索前浏览状态") { !store.isLoading }
        store.query = "keep"; store.selectedURL = keep
        let contentHistory = store.history
        try await present()
        try await typeSearchTerm("秘密关键字😀")
        try await clickSearchSheet(x: 150, top: 93)
        try await searchSheetKey("\r", code: 36)
        try await waitUntil("F5 内容结果") { !session.isRunning && session.snapshot?.request.mode == .content && session.snapshot?.hits.count == 1 }
        try check("实际切换文本搜索显示首命中行和中文摘要", session.snapshot?.hits.first?.id == "nested/content.txt"
                  && session.snapshot?.hits.first?.line == 2 && (session.snapshot?.hits.first?.excerpt?.contains("秘密关键字😀") == true))
        try captureSearchSheet("search-content-results.png")
        try await searchSheetKey("\u{1b}", code: 53)
        try await waitUntil("F5 内容结果关闭") { self.window.attachedSheet == nil }
        try check("关闭内容搜索保留原浏览位置与当前选择", store.currentDirectory == directory && store.selectedURL == keep
                  && store.query == "keep" && store.history == contentHistory)
        try check("递归名称及内容搜索没有修改源文件", (try String(contentsOf: contentFile)) == body && (try String(contentsOf: found)) == "name result")
        window.contentViewController = browser
        window.makeKeyAndOrderFront(nil)
        try JSONSerialization.data(withJSONObject: ["root": directory.path, "nameResult": found.path, "contentResult": contentFile.path,
            "scope": "real toolbar/sheet/input/mode/cancel/location; isolated worker gate for cancellation; real fd search after release"], options: [.prettyPrinted])
            .write(to: output.appendingPathComponent("search-samples.json"))
    }

    /// 从独立进程修改 UUID 夹具，产生与 Finder 相同的内核目录事件；不把它标记为 Finder UI 验收。
    func externalSyncChecks(_ browser: FWBrowserHost) async throws {
        let directory = output.appendingPathComponent("F2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 0..<120 {
            try Data("# original \(i)\n".utf8).write(to: directory.appendingPathComponent(String(format: "%03d.md", i)))
        }
        func external(_ executable: String, _ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failed.assertion("F2 外部进程失败") }
        }
        let store = browser.browserStore
        store.openQuickLocation(directory); store.gridView = false; store.query = ".md"; store.typeFilter = .documents
        try await waitUntil("F2 列表读取") { !store.isLoading && store.entries.count == 120 }
        try await Task.sleep(for: .milliseconds(550))
        try await waitUntil("F2 原生列表挂载") {
            browser.view.allDescendants.compactMap { $0 as? NSTableView }
                .contains { $0.window === self.window && $0.numberOfRows == 120 }
        }
        guard let table = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).last,
              let scroll = table.enclosingScrollView else { throw Failed.assertion("F2 未找到原生列表") }
        let original = directory.appendingPathComponent("060.md"), retained = directory.appendingPathComponent("061.md")
        let rows = [original, retained].compactMap { file in store.orderedEntries.firstIndex { $0.url == file } }
        table.scrollRowToVisible(rows[0]); table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        window.makeFirstResponder(table)
        try await waitUntil("F2 真实列表多选") { store.selectedURLs == [original, retained] }
        // 明确主选择，不依赖 AppKit 在两个选中行之间选哪个作为主行。
        store.setSelection([original, retained], primary: original)
        try await Task.sleep(for: .milliseconds(120))
        let list = browser.backgroundView, origin = scroll.contentView.bounds.origin, history = store.history
        let added = directory.appendingPathComponent("zzz-added.md")
        try external("/usr/bin/touch", [added.path])
        try await waitUntil("F2 外部新增自动出现") { store.entries.contains { $0.url == added } }
        try check("F2 外部新增自动同步且保留多选筛选导航", store.selectedURLs == [original, retained]
                  && store.query == ".md" && store.typeFilter == .documents && store.history == history && !store.isLoading)
        try await Task.sleep(for: .milliseconds(120))
        try check("F2 自动同步保留原列表滚动和键盘焦点", browser.backgroundView === list && table.window === window
                  && window.firstResponder === table && abs(scroll.contentView.bounds.origin.y - origin.y) < 1)
        let renamed = directory.appendingPathComponent("060-renamed.md")
        try external("/bin/mv", [original.path, renamed.path])
        try await waitUntil("F2 外部文件改名跟随身份") { store.selectedURL == renamed }
        try check("F2 外部重命名按身份保留多选", store.selectedURLs == [renamed, retained] && store.currentDirectory == directory)
        try external("/bin/rm", [renamed.path])
        try await waitUntil("F2 外部删除自动移除") { !store.entries.contains { $0.url == renamed } }
        try check("F2 外部删除只清理失效项且不替选主项", store.selectedURLs == [retained] && store.selectedURL == nil)
        store.selectedURL = retained
        browser.openPreview(retained, source: "F2-external-sync")
        try await waitUntil("F2 草稿编辑器就绪") { browser.previewDocument?.canBeginEditing == true }
        guard let editing = browser.previewDocument, let web = findWeb(editing.view) else { throw Failed.assertion("F2 草稿缺少 WK") }
        editing.beginEditing(); try await waitUntil("F2 进入编辑") { editing.isEditing && editing.canSave }
        try await replace(editing, "# F2 unsaved draft\nkeep this exact content\n")
        let draft = try await text(web), before = store.entries
        let pending = directory.appendingPathComponent("zzz-pending.md")
        try external("/usr/bin/touch", [pending.path])
        try external("/bin/rm", [added.path])
        try await Task.sleep(for: .milliseconds(600))
        let deferredDraft = try await text(web)
        try check("F2 外部通知延后且保留同一未保存WK草稿", store.entries == before && browser.previewDocument === editing
                  && editing.modified && deferredDraft == draft)
        let cancel = Task { try await pressSheet("取消") }
        let closed = await closePreview(browser); try await cancel.value
        let canceledDraft = try await text(web)
        try check("F2 外部变化后取消关闭仍保留原草稿", !closed && browser.previewDocument === editing
                  && editing.modified && canceledDraft == draft)
        let discard = Task { try await pressSheet("不保存") }
        let discarded = await closePreview(browser); try await discard.value
        try await waitUntil("F2 关闭后补齐待同步变化") { store.entries.contains { $0.url == pending } && !store.entries.contains { $0.url == added } }
        try check("F2 放弃草稿后自动补齐外部变化并恢复选择", discarded && browser.previewModal == nil && store.selectedURL == retained
                  && (try String(contentsOf: retained)) == "# original 61\n" && browser.backgroundView === list)
        let next = output.appendingPathComponent("F2-renamed-" + UUID().uuidString, isDirectory: true)
        try external("/bin/mv", [directory.path, next.path])
        try await waitUntil("F2 当前目录外部重命名同步") { store.currentDirectory == next && store.selectedURL == next.appendingPathComponent(retained.lastPathComponent) }
        try check("F2 当前目录改名同步管理根和历史而不进入加载态", store.rootURL == next && store.history == history.map { $0 == directory ? next : $0 }
                  && !store.managedRoots.contains(directory) && !store.isLoading && browser.backgroundView === list)
        let selected = next.appendingPathComponent(retained.lastPathComponent)
        browser.openPreview(selected, source: "F2-directory-rename-preview")
        try await waitUntil("F2 目录改名前预览就绪") { browser.previewDocument?.canBeginEditing == true }
        let finalDirectory = output.appendingPathComponent("F2-final-" + UUID().uuidString, isDirectory: true)
        try external("/bin/mv", [next.path, finalDirectory.path])
        try await Task.sleep(for: .milliseconds(450))
        let deferredDirectory = store.currentDirectory == next && store.selectedURL == selected
        let cleanClosed = await closePreview(browser)
        try await waitUntil("F2 预览关闭后恢复改名目录") { store.currentDirectory == finalDirectory && store.directoryIssue == nil }
        try check("F2 预览期间目录改名延后且关闭恢复原身份选择", deferredDirectory && cleanClosed
                  && store.selectedURL == finalDirectory.appendingPathComponent(retained.lastPathComponent)
                  && browser.backgroundView === list && !store.isLoading)
        try captureBrowser(browser, name: "external-sync.png")
        try JSONSerialization.data(withJSONObject: ["mechanism": "independent filesystem processes, real vnode events; not Finder UI",
            "directory": finalDirectory.path, "draftDiscarded": true, "automaticRefresh": true], options: [.prettyPrinted])
            .write(to: output.appendingPathComponent("external-sync.json"))
    }

    func browserChecks() async throws {
        let directory = output.appendingPathComponent("弹窗验收", isDirectory: true)
        let child = directory.appendingPathComponent("展开子目录", isDirectory: true)
        let secondChild = directory.appendingPathComponent("第二个展开目录", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondChild, withIntermediateDirectories: true)
        for index in 0..<180 {
            try Data("# 文件 \(index)\n本机原文\n".utf8).write(to: directory.appendingPathComponent(String(format: "文件-%03d.md", index)))
        }
        let source = directory.appendingPathComponent("文件-090.md")
        let second = directory.appendingPathComponent("文件-091.md")
        let tabs = NSTabView(frame: .zero)
        var opened: [URL] = []
        let browser = FWBrowserHost(editorView: tabs, openHandler: { url, _ in opened.append(url) }, commandHandler: { _ in })
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let store = browser.browserStore
        try check("普通启动停留在启动页", store.startupPhase == .welcome)
        try await Task.sleep(for: .milliseconds(300))
        try captureBrowser(browser, name: "startup.png")
        store.openRoot(directory, remember: false)
        try await waitUntil("目录读取") { !store.isLoading && store.entries.count == 182 }
        window.setContentSize(NSSize(width: 1040, height: 760))
        try await Task.sleep(for: .milliseconds(300))
        try captureBrowser(browser, name: "browser-1040.png")
        try await directoryClickChecks(browser, directory: directory, child: child, secondChild: secondChild)
        try await contextCreationCheck(browser, directory: directory)
        window.setContentSize(NSSize(width: 1440, height: 900))
        store.toggleExpanded(child)
        store.toggleExpanded(secondChild)
        store.selectedURL = source
        try await Task.sleep(for: .milliseconds(300))
        browser.view.layoutSubtreeIfNeeded()
        try check("单击只改变文件选择且不读取编辑内容", store.selectedEntry?.url == source && browser.previewModal == nil && opened.isEmpty)
        guard let table = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).last,
              let scroll = table.enclosingScrollView,
              let row = store.orderedEntries.firstIndex(where: { $0.url == source }) else { throw Failed.assertion("没有实际文件列表") }
        table.scrollRowToVisible(row)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        window.makeFirstResponder(table)
        try await Task.sleep(for: .milliseconds(100))
        let origin = scroll.contentView.bounds.origin
        let expanded = store.expandedDirectories
        let originalList = browser.backgroundView
        let point = table.convert(NSPoint(x: table.rect(ofRow: row).minX + 110, y: table.rect(ofRow: row).midY), to: nil)
        for click in 1...2 {
            print("STEP mouse", click)
            try await mouseClick(at: point, clickCount: click)
            try await Task.sleep(for: .milliseconds(80))
        }
        try await waitUntil("原生预览就绪") { browser.previewDocument?.canBeginEditing == true }
        guard let modal = browser.previewModal, let document = modal.documentHost,
              let _ = findWeb(document.view) else { throw Failed.assertion("没有真实弹窗编辑器") }
        try check("弹窗默认只读且焦点不进入编辑按钮或文本框", !document.isEditing && !document.modified && window.firstResponder === modal.overlay.dialog)
        try check("弹窗位于同一窗口并具有模态语义", modal.overlay.isDescendant(of: browser.view) && document.view.window === window && modal.overlay.dialog.isAccessibilityModal())
        let blankPoint = modal.overlay.dialog.convert(NSPoint(x: modal.overlay.dialog.bounds.midX, y: 3), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = NSEvent.mouseEvent(with: type, location: blankPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
            NSApp.postEvent(click, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(180))
        try check("点击弹窗内部空白不触发遮罩关闭", browser.previewModal === modal && !modal.isClosing)
        try await event("\t", keyCode: 48)
        let responder = window.firstResponder as? NSView
        try check("Tab焦点被限制在弹窗内部", responder === modal.overlay.dialog || responder?.isDescendant(of: modal.overlay.dialog) == true)
        modal.toggleExpanded(); browser.view.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 820, height: 580)); browser.view.layoutSubtreeIfNeeded()
        try check("主窗口缩小时最大化弹窗仍保留安全边距", modal.overlay.dialog.frame.minX >= 16 && modal.overlay.dialog.frame.maxX <= browser.view.bounds.width - 16 && modal.overlay.dialog.frame.maxY <= browser.view.bounds.height - 16)
        modal.toggleExpanded(); window.setContentSize(NSSize(width: 1440, height: 900)); browser.view.layoutSubtreeIfNeeded()
        try check("关闭干净预览成功", await closePreview(browser))
        try await Task.sleep(for: .milliseconds(120))
        try check("关闭后目录选中树展开及原列表对象保持", store.currentDirectory == directory && store.selectedURL == source && store.expandedDirectories == expanded && browser.backgroundView === originalList)
        try check("关闭后水平垂直滚动位置恢复", abs(scroll.contentView.bounds.origin.y - origin.y) < 1 && abs(scroll.contentView.bounds.origin.x - origin.x) < 1)
        try check("关闭后焦点回到原文件列表", window.firstResponder === table)
        try await event("\u{f701}", keyCode: 125)
        try check("键盘关闭后列表仍可继续方向键导航", store.selectedURL != source && store.selectedURL != nil)
        store.selectedURL = source
        print("STEP 重新打开编辑预览")
        browser.openPreview(source, source: "space")
        try await waitUntil("编辑按钮就绪") { browser.previewDocument?.canBeginEditing == true }
        guard let editing = browser.previewDocument, let editorWeb = findWeb(editing.view) else { throw Failed.assertion("编辑器缺失") }
        print("STEP 预览就绪，进入编辑")
        editing.beginEditing()
        try await waitUntil("进入编辑") { editing.isEditing && editing.canSave }
        window.makeFirstResponder(editorWeb)
        _ = try await editorWeb.callAsyncJavaScript("document.querySelector('[data-mode=source]').focus()", arguments: [:], in: nil, contentWorld: .page)
        try await event("\t", keyCode: 48)
        let forwardMode = try await editorWeb.callAsyncJavaScript("return document.activeElement.dataset.mode", arguments: [:], in: nil, contentWorld: .page) as? String
        try check("Tab可以访问编辑器内部模式按钮", forwardMode == "preview")
        try await event("\t", keyCode: 48, flags: .shift)
        let backwardMode = try await editorWeb.callAsyncJavaScript("return document.activeElement.dataset.mode", arguments: [:], in: nil, contentWorld: .page) as? String
        try check("ShiftTab在编辑器内部反向恢复焦点", backwardMode == "source")
        print("STEP 编辑就绪，真实输入")
        try await replace(editing, "# 真实未保存内容\n光标测试\n")
        let actualDraft = try await text(editorWeb)
        try check("修改来自真实编辑器且包含完整输入", actualDraft.contains("# 真实未保存内容\n光标测试\n"))
        print("STEP 输入完成，发送Esc")
        let oldDisk = try Data(contentsOf: source)
        try await event("\u{1b}", keyCode: 53)
        if window.attachedSheet == nil { try await event("\u{1b}", keyCode: 53) }
        try await waitUntil("Esc确认") { self.window.attachedSheet != nil }
        let topResponder = window.attachedSheet?.firstResponder
        try check("未保存确认是顶层模态并隔离背景", window.sheets.count == 1 && ((topResponder as? NSView)?.window === window.attachedSheet || topResponder === window.attachedSheet))
        try await pressSheet("取消")
        try await waitUntil("取消关闭返回") { self.window.attachedSheet == nil && !editing.busy }
        let afterCancelText = try await text(editorWeb)
        try check("取消保持同一WK文档草稿与编辑焦点", browser.previewDocument === editing && editing.modified && findWeb(editing.view) === editorWeb && window.firstResponder !== table && afterCancelText == actualDraft)
        browser.previewModal?.toggleExpanded(); browser.previewModal?.toggleExpanded()
        let afterResizeText = try await text(editorWeb)
        try check("最大化恢复不会丢失未保存内容", editing.modified && afterResizeText == actualDraft)
        let saveInteraction = Task { try await pressSheet("保存") }
        let savedClosed = await closePreview(browser)
        try await saveInteraction.value
        try check("确认保存真实写盘后才关闭并恢复选中", savedClosed && browser.previewModal == nil && String(contentsOf: source, encoding: .utf8) == actualDraft && store.selectedURL == source && (try Data(contentsOf: source)) != oldDisk)
        browser.openPreview(source, source: "space")
        try await waitUntil("删除前预览") { browser.previewDocument?.canBeginEditing == true }
        try FileManager.default.removeItem(at: source)
        try check("外部删除后干净预览可关闭", await closePreview(browser))
        try check("删除后仅清理失效选择且目录筛选不变", store.selectedURL == nil && store.currentDirectory == directory && store.query.isEmpty)
        browser.openPreview(second, source: "space")
        let fastClosed = await closePreview(browser)
        try await Task.sleep(for: .milliseconds(400))
        try check("读取中关闭不被迟到结果重新打开", fastClosed && browser.previewModal == nil)
        browser.openPreview(second, source: "space")
        browser.openPreview(directory.appendingPathComponent("文件-092.md"), source: "space")
        browser.openPreview(directory.appendingPathComponent("文件-093.md"), source: "space")
        try await waitUntil("快速切换最新文件") { browser.previewModal?.url?.lastPathComponent == "文件-093.md" && browser.previewDocument?.canBeginEditing == true }
        let latestText = try await text(findWeb(browser.previewDocument!.view)!)
        try check("快速A/B切换仅展示最新标题与内容", browser.previewDocument?.documentURL?.lastPathComponent == "文件-093.md" && latestText.contains("文件 93"))
        _ = await closePreview(browser)
        try await trashMenuChecks(browser)
        try await externalSyncChecks(browser)
        try await fileOperationChecks(browser)
        try await directorySearchChecks(browser)
    }
    func finish(_ passed: Bool) {
        guard !finished else { return }
        finished = true
        window?.close()
        let selectedCase = ProcessInfo.processInfo.environment["FW_NATIVE_HOST_TEST_CASE"]
        let report: [String: Any] = ["passed": passed, "testCase": selectedCase ?? "all",
                                   "mouseDriver": ProcessInfo.processInfo.environment["FW_NATIVE_HOST_MOUSE_DRIVER"] ?? "nsevent", "engine": "real WKWebView with FWTextContent/FWDocumentHost/FWBrowserHost", "checks": records,
                                   "scope": selectedCase == "interaction-fixes" ? "eight interaction fixes: native key routing, explicit CSV deletion, search line selection, media preview/edit/save/return, Office route and command forwarding, actual multi-selection context menu and Rust name sheet; Office engine tested separately" : selectedCase == "languages" ? "12 language fixtures created through real templates; native filename mapping, offline WKWebView highlighting, logical LF input and exact CRLF saves; all native classes compiled; no installed app or Office changes" : selectedCase == "icons-interaction" ? "icon-only regression: workspace resume, sidebar focus, direct key input, save-and-return, conflict preservation, inline name/content search and result preview/location; unchanged system folder authorization panel excluded" : selectedCase == "icons" ? "actual list/grid light/dark rendering; metadata-only classification; preserved app system icons and symbolic link badge; click icon retains native list selection and focus; fixtures are display-only, not document parsing" : selectedCase == "interaction" ? "real main workspace: system folder panel cancellation, isolated workspace resume, light/dark/narrow/sidebar focus, direct key input, native save-and-return and conflict retention, inline name/content search preview and location; no installed app or Office mixed-tab acceptance" : selectedCase == "text-selection" ? "focused TXT modal Command+A and real Command+C pasteboard copy, Unicode across virtualized lines, readonly deletion protection, native mouse focus and bounded large-file preview; all native classes compiled" : selectedCase == "search" ? "F5 real toolbar/search sheet, typing, name/content, cancel with isolated worker gate, result location and browser state protection; fd searches on UUID fixtures; not real slow volume" : selectedCase == "file-operations" ? "F4 focused real file progress/cancel/undo controls, system Trash and same-volume move/copy with isolated UUID samples; EXDEV and cleanup failures covered by unit injection" : selectedCase == "external-sync" ? "F2 focused real vnode automatic synchronization from independent filesystem processes (not Finder UI), native list selection/scroll/focus, rename/delete, dirty WK draft and current directory relocation; all native classes compiled" : selectedCase == "trash" ? "F1 focused real two-item context menu and system Trash, replacement rejection/partial failure and UUID identity recovery; all native classes compiled, full browser/text workflow not executed" : "all native and browser UI classes compiled; F5 recursive search toolbar/sheet/cancel/location and content line, F4 real progress/cancel/undo controls and UUID copy/move/system Trash; real two-item context menu trash, identity replacement/partial failure and exact UUID trash identity recovery; F2 real vnode changes from independent filesystem processes (not Finder UI), list selection/scroll/focus, dirty WK draft and directory rename during preview; real modal preview/editor, save routing, close cancellation and stale results; Office mixed tabs require separate acceptance"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("report.json")) }
        exit(passed ? 0 : 1)
    }
}
/// 测试只替换呈现根和工作器，复用正式搜索视图的全部表单、取消、定位与关闭处理。
@MainActor
private struct DirectorySearchAcceptanceRoot: View {
    let store: BrowserStore
    let session: DirectorySearchSession
    @State private var showing = true
    var body: some View {
        Color.clear.sheet(isPresented: $showing) { WorkspaceDirectorySearchView(store: store, session: session, editor: WorkspaceEditorBridge(), isPresented: $showing).frame(width: 850, height: 620) }
    }
}
@main
struct Main {
    static func main() {
        // Finder 启动测试 .app 不会传入夹具目录；必须在初始化和任何磁盘写入前安全退出。
        guard CommandLine.arguments.count == 2,
              ProcessInfo.processInfo.environment["FW_OFFICE_SMOKE_DIR"] == CommandLine.arguments[1] else {
            fputs("这是自动验收程序，请运行 bash scripts/test-native-hosts.sh。正式应用为 build/FileDeck.app。\n", stderr)
            exit(64)
        }
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = NativeTextTests()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
