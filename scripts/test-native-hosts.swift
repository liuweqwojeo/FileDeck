import AppKit
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

    /// 固定隔离夹具使用 1040×760 窗口与默认 260 pt 侧栏；坐标由 browser-1040.png 与实际根行 frame 核验。
    /// SwiftUI 子行仅绘制、不暴露 NSView/进程内 AX 节点，因此从根行 {{16,347},{228,34}} 按 36 pt 行距推导。
    func directoryControlFrame(index: Int, expanding: Bool) -> NSRect {
        let row = NSRect(x: 16, y: 347 - CGFloat(index) * 36, width: 228, height: 34)
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

    func mouseClick(at point: NSPoint, right: Bool = false) async throws {
        for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw Failed.assertion("无法创建鼠标事件")
            }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    func directoryClickChecks(_ browser: FWBrowserHost, directory: URL, child: URL, secondChild: URL) async throws {
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
        var contextMenu: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            if let menu = note.object as? NSMenu, contextMenu == nil { contextMenu = menu }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let chooseTemplate = Task { @MainActor in
            try await waitUntil("右键新建菜单") { contextMenu != nil }
            guard let menu = contextMenu, let (submenu, index) = menuItem(named: "文本文件 (.txt)", in: menu) else {
                contextMenu?.cancelTrackingWithoutAnimation()
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
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: click, clickCount: click, pressure: 1)!
                print("STEP mouse", click)
        NSApp.postEvent(event, atStart: false)
            }
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
    }
    func finish(_ passed: Bool) {
        guard !finished else { return }
        finished = true
        window?.close()
        let report: [String: Any] = ["passed": passed, "engine": "real WKWebView with FWTextContent/FWDocumentHost/FWBrowserHost", "checks": records,
                                   "scope": "all native and browser UI classes compiled; real modal preview/editor, keyboard focus, window resizing, exact scroll/navigation retention, save routing, close cancellation, deletion and stale results; Office mixed tabs require separate acceptance"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("report.json")) }
        exit(passed ? 0 : 1)
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
