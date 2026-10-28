import AppKit
import SwiftUI
import PDFKit
import ApplicationServices
@preconcurrency import WebKit

/// 八项交互修复使用独立窗口、偏好域和 UUID 样本，禁止将测试数据写入用户文档。
extension NativeTextTests {
    /// 经窗口服务器进入 NSApplication 与本地事件监视器，不能直接调用 handle 或伪造完成回调。
    func navigationSwipeChecks() async throws {
        let directory = output.appendingPathComponent("swipe-" + UUID().uuidString, isDirectory: true)
        let first = directory.appendingPathComponent("A", isDirectory: true)
        let second = directory.appendingPathComponent("B", isDirectory: true)
        let third = directory.appendingPathComponent("C", isDirectory: true)
        let nested = first.appendingPathComponent("Nested", isDirectory: true)
        for target in [directory, first, second, third, nested] {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for index in 0..<60 { try Data("fixture".utf8).write(to: target.appendingPathComponent("sample-\(index).swift")) }
        }
        let browser = FWBrowserHost(editorView: NSView(), openHandler: { _, _ in }, commandHandler: { _ in })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "FileDeck 触控板交互验收（自动关闭）"
        window.contentViewController = browser
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let store = browser.browserStore
        let eventSource = CGEventSource(stateID: .hidSystemState)
        eventSource?.localEventsSuppressionInterval = 0
        print("SWIPE_ACCESS post=\(CGPreflightPostEventAccess()),accessibility=\(AXIsProcessTrusted())")
        store.openRoot(directory, remember: false)
        try await waitUntil("工作区加载") { !store.isLoading }
        try await Task.sleep(for: .milliseconds(150))
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil("验收窗口激活") { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier && self.window.isKeyWindow }
        guard let probe = browser.backgroundView.allDescendants.compactMap({ $0 as? WorkspaceBrowserNavigationGestures.GestureProbe }).first else { throw Failed.assertion("原生手势监视器未挂载") }
        let systemSetting = probe.scrollSwipeEnabled
        probe.scrollSwipeEnabled = { true }
        defer { probe.scrollSwipeEnabled = systemSetting }
        func open(_ target: URL) async throws {
            store.navigate(to: target)
            try await waitUntil("目录加载") { !store.isLoading }
            try await Task.sleep(for: .milliseconds(70))
        }
        func scroll(_ deltas: [(Int64, Int32, Int32)], momentum: Int64 = 0) async throws {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await waitUntil("验收手势窗口激活") { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier && self.window.isKeyWindow }
            try await waitUntil("文件列表挂载") { browser.backgroundView.allDescendants.contains { $0 is NSTableView } }
            guard let table = browser.backgroundView.allDescendants.compactMap({ $0 as? NSTableView }).first else {
                throw Failed.assertion("未挂载真实文件列表")
            }
            let visible = table.visibleRect
            let point = table.convert(NSPoint(x: min(table.bounds.width - 20, 200), y: visible.midY), to: nil)
            let screenPoint = window.convertPoint(toScreen: point)
            let location = NSPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.height - screenPoint.y)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  window.isKeyWindow, NSEvent.pressedMouseButtons == 0 else { throw Failed.assertion("拒绝投递：前台=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)，key=\(window.isKeyWindow)，按钮=\(NSEvent.pressedMouseButtons)") }
            CGWarpMouseCursorPosition(location)
            CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(100))
            for (phase, x, y) in deltas {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                      window.isKeyWindow else { throw Failed.assertion("验收窗口失去前台，拒绝投递") }
                guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                                          wheel1: y, wheel2: x, wheel3: 0) else { throw Failed.assertion("不能创建滚动事件") }
                event.location = location; event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: 101414)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(70))
            }
            try await waitUntil("导航结束") { !store.isLoading }
            try await Task.sleep(for: .milliseconds(100))
        }
        let initialDelta = Int32(ProcessInfo.processInfo.environment["FW_NATIVE_GESTURE_INITIAL_DELTA"] ?? "5") ?? 5
        func back() async throws { try await scroll([(1,initialDelta,0),(2,0,0),(2,35,0),(2,35,0),(4,0,0)]) }
        func forward() async throws { try await scroll([(1,-initialDelta,0),(2,-35,0),(2,-35,0),(4,0,0)]) }
        try await open(first); try await open(second); try await open(third)
        var traceSamples = 0
        let trace = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard traceSamples < 8, event.window === self?.window else { return event }
            traceSamples += 1
            var classes: [String] = []
            if let content = self?.window.contentView {
                var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                while let view = hit {
                    if let scroll = view as? NSScrollView { classes.append("scroll:doc=\(scroll.documentView?.frame.width ?? 0),clip=\(scroll.contentSize.width),h=\(scroll.hasHorizontalScroller),v=\(scroll.hasVerticalScroller)") }
                    if let field = view as? NSTextField { classes.append("text:edit=\(field.isEditable),select=\(field.isSelectable)") }
                    hit = view.superview
                }
            }
            print("SWIPE_SAMPLE tag=\(event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0),phase=\(event.phase.rawValue),dx=\(event.scrollingDeltaX),precise=\(event.hasPreciseScrollingDeltas),canBack=\(store.canGestureGoBack),enabled=\(probe.isEnabled?() == true),inside=\(probe.bounds.contains(probe.convert(event.locationInWindow, from: nil))),\(classes)")
            return event
        }
        defer { if let trace { NSEvent.removeMonitor(trace) } }
        try await back()
        print("SWIPE_RESULT current=\(store.currentDirectory?.path ?? "nil"),expected=\(directory.path),forward=\(store.gestureForwardChain.map { $0.url.lastPathComponent })")
        try check("同级 C 手势只退到直接父目录", store.currentDirectory == directory)
        try await back()
        try check("工作区根目录停止后退", store.currentDirectory == directory)
        try await forward()
        try check("多个子目录只前进到刚退出的 C", store.currentDirectory == third)
        try await scroll([(0,90,0)], momentum: 1); try await scroll([(0,90,0)], momentum: 3)
        try check("横向惯性不重复切换目录", store.currentDirectory == third)
        let selected = third.appendingPathComponent("sample-0.swift")
        store.selectedURL = selected
        guard let fileTable = browser.backgroundView.allDescendants.compactMap({ $0 as? NSTableView }).first else { throw Failed.assertion("文件列表不存在") }
        let beforeScroll = fileTable.visibleRect.minY
        try await scroll([(1,0,0),(2,0,-40),(2,0,-40),(4,0,0)])
        try check("零位移起始纵向滚动移动列表", abs(fileTable.visibleRect.minY - beforeScroll) > 1)
        let middleScroll = fileTable.visibleRect.minY
        try await scroll([(1,0,0),(2,0,-40),(2,0,-40),(4,0,0)])
        try check("列表中部继续原生纵向滚动", fileTable.visibleRect.minY > middleScroll)
        let beforeMomentum = fileTable.visibleRect.minY
        try await scroll([(0,0,-25)], momentum: 1); try await scroll([(0,0,0)], momentum: 3)
        try check("纵向惯性继续滚动且不导航", fileTable.visibleRect.minY > beforeMomentum && store.currentDirectory == third)
        try await scroll([(1,80,0),(8,0,0)])
        try check("纵向滚动和取消保留目录与选择", store.currentDirectory == third && store.selectedURL == selected)
        try await back(); try await forward()
        try check("父子链往返恢复文件选择", store.currentDirectory == third && store.selectedURL == selected)
        try await open(nested)
        try await back(); try check("嵌套目录每次只退一级", store.currentDirectory == first)
        try await back(); try await forward()
        try check("多层前进先回直接子目录 A", store.currentDirectory == first)
        try await forward(); try check("再次前进回嵌套子目录", store.currentDirectory == nested)
        try await back(); try await open(second)
        try check("点击切换分支清空手势前进记录", !store.canGestureGoForward)
        try await forward(); try check("无前进记录不自动选兄弟分支", store.currentDirectory == second)
        probe.scrollSwipeEnabled = { false }
        try await back(); try check("系统禁用滚动轻扫时保持目录", store.currentDirectory == second)
        probe.scrollSwipeEnabled = { true }
        window.setContentSize(NSSize(width: 860, height: 660))
        try await Task.sleep(for: .milliseconds(150))
        try await back(); try await forward()
        try check("860 窄窗父子链往返正常", store.currentDirectory == second)
        store.selectedURL = second.appendingPathComponent("sample-0.swift")
        store.gridView = true
        try await Task.sleep(for: .milliseconds(150))
        try captureBrowser(browser, name: "trackpad-narrow-grid.png")
        try check("图标网格保留原选择模型", store.currentDirectory == second && store.selectedURL == second.appendingPathComponent("sample-0.swift"))
        window.close()
        try await previewZoomChecks(in: directory)
    }

    func previewZoomChecks(in directory: URL) async throws {
        guard let context = CGContext(data: nil, width: 2048, height: 1536, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failed.assertion("无法创建图片样本") }
        context.setFillColor(NSColor.systemTeal.cgColor); context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
        guard let pixels = context.makeImage() else { throw Failed.assertion("无法生成图片样本") }
        let original = try ImageOperations.export(pixels, format: .png)
        let imageURL = directory.appendingPathComponent("zoom.png"); try original.write(to: imageURL)
        let image = try await FWImageContent.open(url: imageURL)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "FileDeck 图片/PDF 缩放验收（自动关闭）"
        window.contentViewController = image; window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(120))
        guard let scroll = image.view.allDescendants.compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView else { throw Failed.assertion("图片没有原生滚动容器") }
        let frame = window.frame
        let point = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        let before = document.convert(point, to: nil)
        scroll.setMagnification(2, centeredAt: point)
        let after = document.convert(point, to: nil)
        try check("图片原生缩放保持中心位置", scroll.allowsMagnification && hypot(before.x - after.x, before.y - after.y) < 2)
        button(image.view, title: "放大")?.performClick(nil)
        try check("图片鼠标缩放按钮有效", scroll.magnification > 2)
        let imageBeforeKey = scroll.magnification
        try await event("-", keyCode: 27, flags: .command)
        try check("图片键盘缩小有效", scroll.magnification < imageBeforeKey)
        button(image.view, title: "实际大小")?.performClick(nil)
        try check("图片实际大小恢复且不缩放窗口", scroll.magnification == 1 && window.frame == frame)
        try check("图片缩放不修改磁盘与撤销历史", !image.isModified && !image.canUndo && (try Data(contentsOf: imageURL)) == original)
        let pdfURL = directory.appendingPathComponent("zoom.pdf")
        let pdfData = try PDFOperations.imageToPDF(pixels); try pdfData.write(to: pdfURL)
        let pdf = try await FWPDFContent.open(url: pdfURL)
        window.contentViewController = pdf
        window.setContentSize(NSSize(width: 900, height: 700))
        try await Task.sleep(for: .milliseconds(120))
        guard let view = pdf.view.allDescendants.compactMap({ $0 as? PDFView }).first else { throw Failed.assertion("没有 PDFKit 视图") }
        let pdfFrame = window.frame
        view.autoScales = false; view.scaleFactor = 1
        button(pdf.view, title: "放大")?.performClick(nil)
        try check("PDF 复用 PDFKit 缩放按钮", view.scaleFactor > 1)
        let pdfBeforeKey = view.scaleFactor
        try await event("-", keyCode: 27, flags: .command)
        try check("PDF 键盘缩小有效", view.scaleFactor < pdfBeforeKey)
        button(pdf.view, title: "适合窗口")?.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        print("PDF_FIT auto=\(view.autoScales),modified=\(pdf.isModified),frame=\(window.frame),baseline=\(pdfFrame),scale=\(view.scaleFactor),fit=\(view.scaleFactorForSizeToFit)")
        try check("PDF 适合窗口", view.autoScales)
        try check("PDF 缩放保持窗口尺寸", window.frame == pdfFrame)
        try check("PDF 缩放不修改文档", !pdf.isModified && (try Data(contentsOf: pdfURL)) == pdfData)
        window.close()
    }

    func fixJS(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
    func fixButton(_ browser: FWBrowserHost, _ identifier: String) -> NSButton? {
        let title = ["FileDeck.preview.save-and-return": "保存并返回", "FileDeck.preview.edit": "编辑"][identifier]
        return browser.previewModal?.overlay.dialog.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == identifier || $0.title == title }
    }
    func pressFixButton(_ browser: FWBrowserHost, _ identifier: String) throws {
        guard let button = fixButton(browser, identifier), !button.isHidden, button.isEnabled else {
            throw Failed.assertion("缺少可用按钮：" + identifier)
        }
        button.performClick(nil)
    }
    func fixReady(_ browser: FWBrowserHost) async throws -> FWDocumentHost {
        for _ in 0..<700 {
            if let host = browser.previewDocument, host.canSave { return host }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failed.assertion("修复验收编辑器超时：\(browser.previewDocument?.sessionState ?? "未创建")；\(browser.previewDocument?.statusText ?? "")")
    }
    func interactionFixChecks() async throws {
        let directory = output.appendingPathComponent("interaction-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var openedOffice: URL?
        var commands: [String] = []
        let browser = FWBrowserHost(editorView: NSTabView(frame: .zero), openHandler: { url, _ in openedOffice = url },
                                   commandHandler: { commands.append($0) })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "八项交互修复验收（自动关闭）"
        window.contentViewController = browser
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let file = directory.appendingPathComponent("audit.py")
        let original = "x = 1\r\n"
        try Data(original.utf8).write(to: file)
        browser.browserStore.openRoot(directory, remember: false)
        browser.openPreview(file, source: "edit")
        let host = try await fixReady(browser)
        guard let web = findWeb(host.view) else { throw Failed.assertion("没有 WK 编辑器") }
        window.makeFirstResponder(web)
        _ = try await fixJS(web, "document.querySelector('.cm-content').focus(); const s=getSelection(); s.selectAllChildren(document.querySelector('.cm-content')); s.collapseToStart(); return true;")
        try await event("\t", keyCode: 48)
        let indented = try await text(web)
        try check("I3 Tab 缩进正文并保留 CRLF", indented != original && indented.hasSuffix(original))
        try await event("\t", keyCode: 48, flags: .shift)
        try check("I3 Shift+Tab 减少缩进", try await text(web) == original)
        try await event("\t", keyCode: 48, flags: .control)
        let contentFocused = try await fixJS(web, "return document.activeElement === document.querySelector('.cm-content');") as? Bool == true
        let afterFocusChange = try await text(web)
        let responder = window.firstResponder as? NSView
        let webFocused = responder === web || responder?.isDescendant(of: web) == true
        try check("I3 Ctrl+Tab 可切换焦点且不修改正文", (!webFocused || !contentFocused) && afterFocusChange == original)
        window.makeFirstResponder(web)
        try await replace(host, "x = 2\r\n")
        host.find()
        try await Task.sleep(for: .milliseconds(120))
        window.makeFirstResponder(web)
        _ = try await fixJS(web, "const q=document.querySelector('.cm-search input[name=search]'); q.value=''; q.focus(); document.execCommand('insertText',false,'needle'); return true;")
        let before = try await text(web)
        try await event("z", keyCode: 6, flags: .command)
        let query = try await fixJS(web, "return document.querySelector('.cm-search input[name=search]').value;") as? String
        try check("I1 查找框撤销不影响正文", try await text(web) == before)
        try check("I1 查找输入保留自己的撤销历史", query != "needle")
        let localized = try await fixJS(web, "return document.querySelector('.cm-search input[name=search]').placeholder === '查找' && document.querySelector('.cm-search').textContent.includes('区分大小写');") as? Bool == true
        let formatHidden = try await fixJS(web, "return document.querySelector('[data-command=formatJSON]').hidden;") as? Bool == true
        let nativeFindButtons = host.view.allDescendants.compactMap { $0 as? NSButton }.filter { $0.title == "查找与替换" }
        try check("I7 单一编辑工具栏、中文查找且 Python 不显示 JSON 格式化", localized && formatHidden && nativeFindButtons.isEmpty)
        try captureBrowser(browser, name: "fixed-editor-search.png")
        try Data("external change\n".utf8).write(to: file)
        let cancelConflict = Task { try await pressSheet("取消") }
        try pressFixButton(browser, "FileDeck.preview.save-and-return")
        try await cancelConflict.value
        try await waitUntil("保存冲突取消") { !host.busy }
        try check("保存返回遇外部冲突保留编辑与磁盘版本", browser.previewDocument === host && host.modified && String(contentsOf: file) == "external change\n")
        let cancelClose = Task { try await pressSheet("取消") }
        let closed = await closePreview(browser)
        try await cancelClose.value
        try check("未保存返回可取消且继续同一会话", !closed && browser.previewDocument === host)
        let discard = Task { try await pressSheet("不保存") }
        _ = await closePreview(browser); try await discard.value
        try await fixCSVDeletion(directory: directory)
        window.contentViewController = browser
        window.makeKeyAndOrderFront(nil)
        let lines = (1...150).map { $0 == 120 ? "needle-line120" : "line\($0)" }.joined(separator: "\n") + "\n"
        let hit = directory.appendingPathComponent("search.txt")
        try Data(lines.utf8).write(to: hit)
        browser.editorBridge.preview(hit, source: "search", line: 120)
        try await waitUntil("搜索预览就绪") { browser.previewDocument?.canBeginEditing == true }
        let searchHost = browser.previewDocument!
        let searchWeb = findWeb(searchHost.view)!
        try await Task.sleep(for: .milliseconds(200))
        let selected = try await fixJS(searchWeb, "return getSelection().toString();") as? String
        try check("I4 搜索预览直达并选中第120行", selected == "needle-line120" && !searchHost.modified)
        try check("I4 定位保留只读源码与原文件", try await text(searchWeb) == lines && String(contentsOf: hit) == lines)
        try captureBrowser(browser, name: "fixed-search-line.png")
        _ = await closePreview(browser)
        let csvHit = directory.appendingPathComponent("search-lines.csv")
        let csvSource = "id,description\n1,\"first line\nneedle physical line\"\n"
        try Data(csvSource.utf8).write(to: csvHit)
        browser.editorBridge.preview(csvHit, source: "search", line: 3)
        try await waitUntil("CSV 物理行预览") { browser.previewDocument?.canBeginEditing == true }
        let csvWeb = findWeb(browser.previewDocument!.view)!
        try await Task.sleep(for: .milliseconds(180))
        let csvSelected = try await fixJS(csvWeb, "return getSelection().toString();") as? String
        let csvPreviewSource = try await text(csvWeb)
        try check("I4 CSV 搜索定位物理行且不改变引号与换行", csvSelected == "needle physical line\"" && csvPreviewSource == csvSource)
        try pressFixButton(browser, "FileDeck.preview.edit")
        let csvEditor = try await fixReady(browser)
        try check("I5 CSV 搜索预览进入原生表格编辑器", csvEditor.content is FWCSVContent && !csvEditor.modified)
        _ = await closePreview(browser)
        try await fixMediaEditing(browser, directory: directory)
        try await fixLegacyText(browser, directory: directory)
        // 无内核的辅助宿主只验证 Office 路由；真实 Office 保存返回另由完整应用验收。
        let office = directory.appendingPathComponent("route-only.docx")
        try Data().write(to: office)
        browser.openPreview(office, source: "space")
        try await waitUntil("Office 预览编辑入口") { self.fixButton(browser, "FileDeck.preview.edit")?.isEnabled == true }
        try pressFixButton(browser, "FileDeck.preview.edit")
        try await waitUntil("Office 同文件路由") { openedOffice == office }
        try check("I5 Office 预览编辑打开同一文件", browser.previewModal == nil && openedOffice == office)
        browser.updateEditor(title: "Office 路由验收", url: office, hasDocument: true, modified: false, busy: false, canSave: true, canSaveAs: true, canExport: true)
        browser.showEditor()
        try await waitUntil("Office 兼容工作层") { browser.previewModal?.mode == .legacy }
        let legacySave = fixButton(browser, "FileDeck.preview.save-and-return")!
        try check("I5 Office 工作层显示保存并返回", !legacySave.isHidden && legacySave.isEnabled)
        legacySave.performClick(nil)
        try check("I5 Office 保存返回使用协调器命令", commands.last == "saveAndReturn")
        let previousModal = browser.previewModal
        browser.hideEditor()
        browser.showEditor()
        try await waitUntil("返回动画后的新编辑请求") { browser.previewModal != nil && browser.previewModal !== previousModal && browser.previewModal?.mode == .legacy }
        try check("I5 返回动画期间重新打开不会丢失编辑层", browser.editorBridge.isPresented)
        browser.hideEditor()
        try await waitUntil("关闭 Office 路由层") { browser.previewModal == nil }
        browser.updateEditor(title: "", url: nil, hasDocument: false, modified: false, busy: false, canSave: false, canSaveAs: false, canExport: false)
        try await fixMenus(browser, directory: directory)
    }

    func fixCSVDeletion(directory: URL) async throws {
        let file = directory.appendingPathComponent("delete.csv")
        try Data("a,b,c\n1,2,3\n4,5,6\n".utf8).write(to: file)
        let csv = try await FWCSVContent.open(url: file, encoding: nil, delimiter: .comma)
        window.contentViewController = csv
        let table = csv.view.allDescendants.compactMap { $0 as? NSTableView }.first!
        let rowButton = button(csv.view, title: "删除行")!, columnButton = button(csv.view, title: "删除列")!
        table.deselectAll(nil)
        try check("I2 未选择行列时删除按钮禁用", !rowButton.isEnabled && !columnButton.isEnabled)
        rowButton.performClick(nil); columnButton.performClick(nil)
        try check("I2 无目标的删除不改变表格", table.numberOfRows == 3 && table.tableColumns.count == 3 && !csv.isModified)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(80))
        try check("I2 选中行后说明删除目标", rowButton.isEnabled && rowButton.toolTip == "删除第 2 行")
        rowButton.performClick(nil)
        try check("I2 删除明确选中行而非最后一行", table.numberOfRows == 2 && csv.tableView(table, objectValueFor: table.tableColumns[0], row: 1) as? String == "4")
        csv.undo()
        table.selectColumnIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(80))
        try check("I2 选中列后说明删除目标", columnButton.isEnabled && columnButton.toolTip == "删除第 2 列")
        columnButton.performClick(nil)
        try check("I2 删除明确选中列且可撤销", table.tableColumns.count == 2 && csv.canUndo && csv.tableView(table, objectValueFor: table.tableColumns[1], row: 1) as? String == "3")
        csv.undo()
        try check("I2 撤销恢复全部行列与干净状态", table.numberOfRows == 3 && table.tableColumns.count == 3 && !csv.isModified)
        try await csv.close(discardChanges: true)
    }

    func fixMediaEditing(_ browser: FWBrowserHost, directory: URL) async throws {
        let identity = try FileSystem.identity(at: directory)
        for template in [NewFileTemplate.csv, .pdf, .png] {
            let file = try NewFileCreator.create(template: template, name: "edit-\(template.rawValue)", directory: directory, expectedDirectoryIdentity: identity)
            if template == .csv { try Data("a,b\n1,2\n".utf8).write(to: file) }
            let initial = try Data(contentsOf: file)
            browser.openPreview(file, source: "space")
            try await waitUntil("\(template.rawValue) 预览编辑入口") { self.fixButton(browser, "FileDeck.preview.edit")?.isEnabled == true }
            try pressFixButton(browser, "FileDeck.preview.edit")
            let host = try await fixReady(browser)
            if let csv = host.content as? FWCSVContent { try csv.setCell("changed", row: 1, column: 1) }
            else if let pdf = host.content as? FWPDFContent { try pdf.rotate(pageIndexes: [0]) }
            else if let image = host.content as? FWImageContent { try await image.rotate(clockwise: true) }
            try check("I5 \(template.rawValue) 原位进入编辑并保持同一文件", host.isEditing && host.modified && host.documentURL == file)
            let saveReturn = fixButton(browser, "FileDeck.preview.save-and-return")!
            try check("I5 \(template.rawValue) 提供保存并返回", !saveReturn.isHidden && saveReturn.isEnabled)
            saveReturn.performClick(nil)
            try await waitUntil("\(template.rawValue) 保存返回") { browser.previewModal == nil }
            try check("I5 \(template.rawValue) 保存真实内容后返回", try Data(contentsOf: file) != initial)
        }
    }

    func fixLegacyText(_ browser: FWBrowserHost, directory: URL) async throws {
        let file = directory.appendingPathComponent("legacy.txt")
        try Data("original\n".utf8).write(to: file)
        let document = try await host(at: file)
        let tabs = browser.editorBridge.nativeView as! NSTabView
        let tab = NSTabViewItem(identifier: "legacy-test")
        tabs.addTabViewItem(tab)
        browser.addChild(document)
        let content = document.view
        content.translatesAutoresizingMaskIntoConstraints = false
        tab.view!.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: tab.view!.leadingAnchor),
                                     content.trailingAnchor.constraint(equalTo: tab.view!.trailingAnchor),
                                     content.topAnchor.constraint(equalTo: tab.view!.topAnchor),
                                     content.bottomAnchor.constraint(equalTo: tab.view!.bottomAnchor)])
        browser.legacyDocument = document
        browser.updateEditor(title: document.documentTitle, url: file, hasDocument: true,
                             modified: false, busy: false, canSave: true, canSaveAs: true, canExport: false)
        browser.showEditor()
        try await settle(document)
        let web = findWeb(document.view)!
        window.makeFirstResponder(web)
        try await replace(document, "edited\n")
        document.find()
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(web)
        _ = try await fixJS(web, "const q=document.querySelector('input[name=search]'); q.focus(); document.execCommand('insertText',false,'query'); return true;")
        try await event("z", keyCode: 6, flags: .command)
        let query = try await fixJS(web, "return document.querySelector('input[name=search]').value;") as? String
        try check("I1 打开文件的 legacy 文本入口同样按焦点撤销", try await text(web) == "edited\n" && query != "query")
        try await event("\u{1b}", keyCode: 53)
        let panelClosed = try await fixJS(web, "return document.querySelector('.cm-search') === null;") as? Bool == true
        try check("legacy 文本 Esc 先关闭查找并保留编辑器", panelClosed && browser.previewModal?.mode == .legacy)
        try await document.content.close(discardChanges: true)
        document.disposePreview()
        browser.hideEditor()
        try await waitUntil("legacy 文本返回") { browser.previewModal == nil }
        browser.legacyDocument = nil
        tabs.removeTabViewItem(tab)
        document.removeFromParent()
        browser.updateEditor(title: "", url: nil, hasDocument: false, modified: false, busy: false, canSave: false, canSaveAs: false, canExport: false)
    }

    func fixTrackedMenu(_ browser: FWBrowserHost, table: NSTableView, row: Int,
                        action: @escaping @MainActor (NSMenu) throws -> Void) async throws {
        let capture = MenuCapture()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated { if capture.menu == nil { capture.menu = notification.object as? NSMenu } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let choose = Task { @MainActor in
            try await waitUntil("修复验收右键菜单") { capture.menu != nil }
            defer { capture.menu?.cancelTrackingWithoutAnimation() }
            try action(capture.menu!)
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let rect = table.rect(ofRow: row)
        try await mouseClick(at: table.convert(NSPoint(x: rect.minX + 110, y: rect.midY), to: nil), right: true, nativeMouse: true)
        try await choose.value
    }

    func fixMenus(_ browser: FWBrowserHost, directory: URL) async throws {
        let store = browser.browserStore
        let files = ["menu-a.txt", "menu-b.txt", "menu-c.txt"].map { directory.appendingPathComponent($0) }
        for file in files { try Data("sample".utf8).write(to: file) }
        store.openRoot(directory, remember: false); store.gridView = false
        try await waitUntil("菜单样本载入") { !store.isLoading && store.entries.contains { $0.url == files[2] } }
        try await Task.sleep(for: .milliseconds(150))
        let table = browser.view.allDescendants.compactMap { $0 as? NSTableView }.last!
        let rows = files.prefix(2).compactMap { file in store.orderedEntries.firstIndex { $0.url == file } }
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        try await waitUntil("菜单多选同步") { store.selectedURLs == Set(files.prefix(2)) }
        // 恢复系统剪贴板原内容，测试报告不记录其中的数据。
        let clipboard = NSPasteboard.general.pasteboardItems?.map { item in item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in result[type] = item.data(forType: type) } } ?? []
        defer {
            NSPasteboard.general.clearContents()
            let items = clipboard.map { data in let item = NSPasteboardItem(); for (type, value) in data { item.setData(value, forType: type) }; return item }
            NSPasteboard.general.writeObjects(items)
        }
        try await fixTrackedMenu(browser, table: table, row: rows[0]) { menu in
            try self.check("I6 多选菜单标注批量数量并隐藏单项动作",
                           self.menuItem(named: "复制（2 个项目）", in: menu) != nil && self.menuItem(named: "在 Finder 中显示（2 个项目）", in: menu) != nil
                           && self.menuItem(named: "预览", in: menu) == nil && self.menuItem(named: "编辑", in: menu) == nil && self.menuItem(named: "重命名…", in: menu) == nil)
            guard let (owner, index) = self.menuItem(named: "复制路径（2 个项目）", in: menu) else { throw Failed.assertion("缺少批量复制路径") }
            store.selectedURL = files[2]
            menu.cancelTrackingWithoutAnimation(); owner.performActionForItem(at: index)
        }
        let paths = Set((NSPasteboard.general.string(forType: .string) ?? "").components(separatedBy: "\n"))
        try check("I6 批量复制路径冻结菜单打开时的二项范围", paths == Set(files.prefix(2).map(\.path)))
        let row = store.orderedEntries.firstIndex { $0.url == files[2] }!
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await fixTrackedMenu(browser, table: table, row: row) { menu in
            guard let (owner, index) = self.menuItem(named: "Rust (.rs)", in: menu) else { throw Failed.assertion("缺少 Rust 入口") }
            menu.cancelTrackingWithoutAnimation(); owner.performActionForItem(at: index)
        }
        try await waitUntil("Rust 新建命名面板") { self.window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        let field = sheet.contentView!.allDescendants.compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.isEnabled }!
        field.selectText(nil)
        let editor = sheet.firstResponder as! NSTextView
        editor.selectAll(nil); editor.insertText("main", replacementRange: editor.selectedRange())
        try await event("\r", keyCode: 36)
        let destination = directory.appendingPathComponent("main.rs")
        try await waitUntil("Rust 自动后缀真实创建") { self.window.attachedSheet == nil && store.selectedURL == destination }
        try check("I8 新建 Rust 只输入主体名即可创建并选中", try Data(contentsOf: destination).isEmpty)
        try captureBrowser(browser, name: "fixed-browser-created.png")
    }
}
