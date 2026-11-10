import AppKit
import SwiftUI
import PDFKit
import ApplicationServices
@preconcurrency import WebKit

/// 八项交互修复使用独立窗口、偏好域和 UUID 样本，禁止将测试数据写入用户文档。
extension NativeTextTests {
    /// 从列表真实右键菜单进入命名面板，覆盖组件单测遗漏的焦点移交与关闭时机。
    func fileRenameChecks(_ browser: FWBrowserHost) async throws {
        let directory = output.appendingPathComponent("file-rename", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("原始文件.txt")
        let occupied = directory.appendingPathComponent("已有文件.txt")
        try Data("重命名保留内容\n".utf8).write(to: source)
        try Data("已有内容".utf8).write(to: occupied)
        let store = browser.browserStore
        store.gridView = false
        store.openRoot(directory, remember: false)
        try await waitUntil("重命名样本目录") { !store.isLoading && store.entries.count == 2 }
        try await Task.sleep(for: .milliseconds(200))

        func openRename(_ url: URL) async throws -> (NSWindow, NSTextField, NSTextView) {
            guard let table = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).first,
                  let row = store.orderedEntries.firstIndex(where: { $0.url == url }) else { throw Failed.assertion("缺少重命名目标行") }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try await fixTrackedMenu(browser, table: table, row: row) { menu in
                guard let (owner, index) = self.menuItem(named: "重命名…", in: menu) else { throw Failed.assertion("缺少重命名菜单") }
                menu.cancelTrackingWithoutAnimation(); owner.performActionForItem(at: index)
            }
            try await waitUntil("列表重命名面板打开") { self.window.attachedSheet != nil }
            let sheet = window.attachedSheet!
            try await Task.sleep(for: .milliseconds(600))
            try check("列表重命名面板保持打开", window.attachedSheet === sheet)
            guard let field = sheet.contentView?.allDescendants.compactMap({ $0 as? NSTextField })
                .first(where: { $0.accessibilityIdentifier() == "rename.name" }),
                  let editor = field.currentEditor() as? NSTextView else { throw Failed.assertion("重命名字段未聚焦") }
            return (sheet, field, editor)
        }

        let (sheet, field, editor) = try await openRename(source)
        try check("重命名首次仅选主体名", editor.selectedRange() == NSRange(location: 0, length: 4))
        editor.insertText("修改后的文件", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(120))
        try check("输入名称不提交也不关闭", window.attachedSheet === sheet && field.stringValue == "修改后的文件.txt"
                  && FileManager.default.fileExists(atPath: source.path))
        sheet.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(200))
        try check("命名框失焦不自动提交", window.attachedSheet === sheet && FileManager.default.fileExists(atPath: source.path))
        sheet.makeFirstResponder(field)
        try await searchSheetKey("\u{1b}", code: 53)
        try await waitUntil("取消重命名") { self.window.attachedSheet == nil }
        try check("取消后原文件内容不变", (try String(contentsOf: source)) == "重命名保留内容\n")

        let (_, _, returnEditor) = try await openRename(source)
        returnEditor.insertText("回车重命名", replacementRange: returnEditor.selectedRange())
        try await searchSheetKey("\r", code: 36)
        let renamed = directory.appendingPathComponent("回车重命名.txt")
        try await waitUntil("回车重命名完成") { self.window.attachedSheet == nil && !store.isLoading && store.selectedURL == renamed }
        try check("回车提交真实落盘且保留扩展名与内容", !FileManager.default.fileExists(atPath: source.path)
                  && (try String(contentsOf: renamed)) == "重命名保留内容\n")

        let (retrySheet, retryField, retryEditor) = try await openRename(renamed)
        retryEditor.insertText("已有文件", replacementRange: retryEditor.selectedRange())
        try await searchSheetKey("\r", code: 36)
        try await Task.sleep(for: .milliseconds(200))
        try check("重名失败保留面板和输入且拒绝覆盖", window.attachedSheet === retrySheet && retryField.stringValue == "已有文件.txt"
                  && (try String(contentsOf: occupied)) == "已有内容" && FileManager.default.fileExists(atPath: renamed.path))
        retryField.selectText(nil)
        guard let editing = retryField.currentEditor() as? NSTextView else { throw Failed.assertion("失败后无法继续修改名称") }
        editing.selectAll(nil); editing.insertText("按钮重命名.txt", replacementRange: editing.selectedRange())
        try await Task.sleep(for: .milliseconds(120))
        try await clickControl("rename.submit", in: retrySheet.contentView!)
        let destination = directory.appendingPathComponent("按钮重命名.txt")
        try await waitUntil("按钮重命名完成") { self.window.attachedSheet == nil && !store.isLoading && store.selectedURL == destination }
        try check("失败后修改名称并点击按钮可成功且保留目录选区", store.currentDirectory == directory
                  && !FileManager.default.fileExists(atPath: renamed.path) && (try String(contentsOf: destination)) == "重命名保留内容\n")
    }

    func previewLayoutChecks(_ browser: FWBrowserHost) async throws {
        let directory = output.appendingPathComponent("preview-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("中文示例.json")
        let original = "{\n  \"message\": \"完整窗口预览\",\n  \"saved\": true\n}\n"
        try Data(original.utf8).write(to: file)
        let store = browser.browserStore
        store.openRoot(directory, remember: false)
        try await waitUntil("布局样本目录") { !store.isLoading && store.entries.count == 1 }
        store.setSelection([file], primary: file)
        // 模拟上游标签栏占据窗口顶部；预览必须覆盖浏览控制器之外的区域。
        window.contentViewController = nil
        let wrapper = NSViewController()
        wrapper.view = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        window.contentViewController = wrapper
        wrapper.addChild(browser)
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.view.addSubview(browser.view)
        NSLayoutConstraint.activate([
            browser.view.leadingAnchor.constraint(equalTo: wrapper.view.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: wrapper.view.trailingAnchor),
            browser.view.topAnchor.constraint(equalTo: wrapper.view.topAnchor, constant: 60),
            browser.view.bottomAnchor.constraint(equalTo: wrapper.view.bottomAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        browser.openPreview(file, source: "edit")
        let host = try await fixReady(browser)
        guard let modal = browser.previewModal, let web = findWeb(host.view), let content = window.contentView else { throw Failed.assertion("没有预览工作层") }
        content.layoutSubtreeIfNeeded()
        try check("默认覆盖整个窗口内容区而非浏览页内弹窗", modal.overlay.superview === content && modal.overlay.frame == content.bounds && modal.overlay.bounds.height > browser.view.bounds.height)
        try check("默认无弹窗边距圆角或遮罩阴影", modal.overlay.dialog.frame == modal.overlay.bounds && modal.overlay.dialog.layer?.cornerRadius == 0 && modal.overlay.dialog.shadow == nil)
        let back = fixButton(browser, "FileDeck.preview.close")!, save = fixButton(browser, "FileDeck.preview.save")!
        let backFrame = back.convert(back.bounds, to: modal.overlay), saveFrame = save.convert(save.bounds, to: modal.overlay)
        try check("返回固定左上保存固定右上且处于同一行", backFrame.minX < 24 && saveFrame.midX > modal.overlay.bounds.midX && abs(backFrame.midY - saveFrame.midY) < 1)
        try check("已保存时主保存按钮禁用且次级动作收进菜单", !save.isEnabled && fixMenuItem(browser, "FileDeck.preview.save-and-return")?.isEnabled == true && fixMenuItem(browser, "FileDeck.preview.save-as")?.isEnabled == true)
        let oldStatusRows = host.view.allDescendants.compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor && ($0.stringValue == "UTF-8" || $0.stringValue == "当前内容无需恢复副本") }
        try check("健康正文不再常驻编码行和无草稿提示行", oldStatusRows.isEmpty)
        try captureBrowser(browser, name: "preview-light-wide.png")
        window.setContentSize(NSSize(width: 860, height: 660)); content.layoutSubtreeIfNeeded()
        try check("窄窗仍铺满且主要操作不重叠", modal.overlay.dialog.frame == modal.overlay.bounds && back.convert(back.bounds, to: modal.overlay).maxX < save.convert(save.bounds, to: modal.overlay).minX)
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(180))
        try captureBrowser(browser, name: "preview-dark-narrow.png")
        window.appearance = nil
        let draft = original.replacingOccurrences(of: "true", with: "false")
        try await replace(host, draft)
        try await waitUntil("布局草稿更新") { host.modified && save.isEnabled }
        modal.toggleFullScreen()
        // styleMask 在全屏动画开始时即改变；等待完成通知更新按钮，再核对最终布局。
        try await waitUntil("进入真实 macOS 全屏") {
            self.window.styleMask.contains(.fullScreen) && modal.isFullScreen
                && self.fixButton(browser, "FileDeck.preview.fullscreen")?.toolTip == "退出全屏（⌃⌘F）"
                && modal.overlay.dialog.frame == modal.overlay.bounds
        }
        try check("全屏使用系统窗口状态且工作层无边距", window.styleMask.contains(.fullScreen) && modal.overlay.dialog.frame == modal.overlay.bounds && fixButton(browser, "FileDeck.preview.fullscreen")?.toolTip == "退出全屏（⌃⌘F）")
        let fullscreenText = try await text(web)
        try check("进入全屏保留同一正文及未保存修改", browser.previewDocument === host && findWeb(host.view) === web && host.modified && fullscreenText == draft)
        try captureBrowser(browser, name: "preview-fullscreen.png")
        modal.toggleFullScreen()
        try await waitUntil("退出系统全屏") {
            !self.window.styleMask.contains(.fullScreen) && !modal.isFullScreen
                && self.fixButton(browser, "FileDeck.preview.fullscreen")?.toolTip == "进入全屏（⌃⌘F）"
        }
        let restoredText = try await text(web)
        try check("退出全屏后正文及撤销会话保留", browser.previewDocument === host && host.modified && restoredText == draft)
        try pressFixButton(browser, "FileDeck.preview.save")
        try await waitUntil("主按钮保存完成") { !host.modified && !host.busy }
        try check("右上保存真实落盘并保留编辑器", (try String(contentsOf: file)) == draft && browser.previewDocument === host && !save.isEnabled)
        try await replace(host, original)
        try await event("f", keyCode: 3, flags: [.command, .control])
        try await waitUntil("全屏快捷键") {
            self.window.styleMask.contains(.fullScreen) && self.fixButton(browser, "FileDeck.preview.fullscreen")?.toolTip == "退出全屏（⌃⌘F）"
        }
        try await event("\r", keyCode: 36, flags: .command)
        try await waitUntil("保存返回与退出全屏") { browser.previewModal == nil && !self.window.styleMask.contains(.fullScreen) }
        try check("保存返回保留原快捷键并恢复浏览和窗口模式", (try String(contentsOf: file)) == original && store.currentDirectory == directory && store.selectedURL == file)
    }

    /// 通过实际 NSApplication 按键分发验证文件复制粘贴，避免只测存储方法而漏掉响应链。
    func fileClipboardShortcutChecks(_ browser: FWBrowserHost) async throws {
        let directory = output.appendingPathComponent("file-clipboard", isDirectory: true)
        let destination = directory.appendingPathComponent("目标目录", isDirectory: true)
        let file = directory.appendingPathComponent("中文.txt")
        let folder = directory.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("原始中文内容".utf8).write(to: file)
        try Data("子文件".utf8).write(to: folder.appendingPathComponent("nested.txt"))
        let store = browser.browserStore
        store.gridView = false
        store.openRoot(directory, remember: false)
        try await waitUntil("快捷键样本就绪") { !store.isLoading && store.entries.count == 3 }
        try await Task.sleep(for: .milliseconds(150))
        guard let table = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).first,
              let filter = browser.view.allDescendants.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "筛选当前目录" }) else {
            throw Failed.assertion("缺少文件列表或目录筛选框")
        }
        let board = NSPasteboard.general
        let original = board.pasteboardItems?.map { item in item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) } } ?? []
        var ownedChange: Int?
        let originalMenu = NSApp.mainMenu
        defer {
            NSApp.mainMenu = originalMenu
            if let ownedChange, board.changeCount == ownedChange {
                board.clearContents()
                board.writeObjects(original.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item })
            }
        }
        let menu = NSMenu(), edit = NSMenu(title: "编辑"), item = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        item.submenu = edit; menu.addItem(item)
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        NSApp.mainMenu = menu
        store.setSelection([file, folder], primary: file)
        try await Task.sleep(for: .milliseconds(120))
        try check("文件列表可获得复制焦点", window.makeFirstResponder(table))
        try await event("c", keyCode: 8, flags: .command)
        ownedChange = board.changeCount
        let copied = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        try check("CmdC 实际复制所选文件和文件夹", Set(copied) == [file, folder])
        store.navigate(to: destination)
        try await waitUntil("目标目录就绪") { !store.isLoading && store.currentDirectory == destination }
        try await Task.sleep(for: .milliseconds(150))
        // 空目录展示占位内容，没有 NSTableView；窗口本身也应能接收文件粘贴。
        window.makeFirstResponder(nil)
        try await event("v", keyCode: 9, flags: .command)
        try await waitUntil("CmdV 粘贴完成") { !store.isFileOperationBusy && FileManager.default.fileExists(atPath: destination.appendingPathComponent("中文.txt").path) }
        try check("CmdV 复制中文文件与目录内容", (try String(contentsOf: destination.appendingPathComponent("中文.txt"))) == "原始中文内容"
                  && (try String(contentsOf: destination.appendingPathComponent("资料/nested.txt"))) == "子文件")
        try check("复制后源文件与源目录保留", FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: folder.path))
        try await waitUntil("粘贴后列表更新") {
            !store.isLoading && browser.view.allDescendants.compactMap { $0 as? NSTableView }.contains { $0.numberOfRows == 2 }
        }
        guard let targetTable = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).first else {
            throw Failed.assertion("粘贴后缺少文件列表")
        }
        window.makeFirstResponder(targetTable)
        try await event("v", keyCode: 9, flags: .command)
        try await waitUntil("重复粘贴完成") { !store.isFileOperationBusy && FileManager.default.fileExists(atPath: destination.appendingPathComponent("中文 副本.txt").path) }
        try check("重复 CmdV 保留已有文件并生成副本", (try String(contentsOf: destination.appendingPathComponent("中文 副本.txt"))) == "原始中文内容"
                  && FileManager.default.fileExists(atPath: destination.appendingPathComponent("资料 副本/nested.txt").path))

        let external = output.appendingPathComponent("外部复制.txt")
        try Data("外部文件内容".utf8).write(to: external)
        board.clearContents(); board.writeObjects([external as NSURL]); ownedChange = board.changeCount
        try await event("v", keyCode: 9, flags: .command)
        try await waitUntil("外部文件快捷键粘贴") { !store.isFileOperationBusy && FileManager.default.fileExists(atPath: destination.appendingPathComponent(external.lastPathComponent).path) }
        try check("CmdV 接收外部应用的标准文件剪贴板", (try String(contentsOf: destination.appendingPathComponent(external.lastPathComponent))) == "外部文件内容"
                  && FileManager.default.fileExists(atPath: external.path))

        // 筛选框继续使用系统文本复制粘贴，不能把正文粘贴变成文件操作。
        board.clearContents(); board.setString("文本粘贴", forType: .string); ownedChange = board.changeCount
        filter.selectText(nil)
        try await event("v", keyCode: 9, flags: .command)
        try check("输入框 CmdV 保留文本语义", store.query == "文本粘贴" && !store.isFileOperationBusy && store.actionError == nil)
        store.query = ""
        try await Task.sleep(for: .milliseconds(150))
        guard let restoredTable = browser.view.allDescendants.compactMap({ $0 as? NSTableView }).first else {
            throw Failed.assertion("清空筛选后缺少文件列表")
        }
        window.makeFirstResponder(restoredTable)
        store.selectedURL = destination.appendingPathComponent("中文.txt")
        browser.openPreview(store.selectedURL!, source: "space")
        try await waitUntil("预览就绪") { browser.previewDocument?.canBeginEditing == true }
        let countBefore = try FileManager.default.contentsOfDirectory(atPath: destination.path).count
        try await event("v", keyCode: 9, flags: .command)
        try check("预览中 CmdV 不触发背景文件操作", browser.previewModal != nil && !store.isFileOperationBusy && store.actionError == nil
                  && (try FileManager.default.contentsOfDirectory(atPath: destination.path)).count == countBefore)
        try check("预览可以正常关闭", await closePreview(browser))
        try await Task.sleep(for: .milliseconds(120))
        try await event("c", keyCode: 8, flags: .command)
        ownedChange = board.changeCount
        try await event("v", keyCode: 9, flags: .command)
        try await waitUntil("预览返回后粘贴") { !store.isFileOperationBusy && FileManager.default.fileExists(atPath: destination.appendingPathComponent("中文 副本 2.txt").path) }
        try check("预览返回后 CmdC 与 CmdV 仍可用", (try String(contentsOf: destination.appendingPathComponent("中文 副本 2.txt"))) == "原始中文内容")

        store.gridView = true
        try await Task.sleep(for: .milliseconds(150))
        store.selectedURL = destination.appendingPathComponent("中文.txt")
        window.makeFirstResponder(nil)
        try await event("c", keyCode: 8, flags: .command)
        ownedChange = board.changeCount
        try await event("v", keyCode: 9, flags: .command)
        try await waitUntil("网格快捷键粘贴") { !store.isFileOperationBusy && FileManager.default.fileExists(atPath: destination.appendingPathComponent("中文 副本 3.txt").path) }
        try check("网格模式 CmdC 与 CmdV 同样可用", store.gridView && (try String(contentsOf: destination.appendingPathComponent("中文 副本 3.txt"))) == "原始中文内容")
    }

    /// 使用正式浏览页、原生列表、WK 和真实磁盘；所有样本与草稿只写入本轮隔离目录。
    func interactionPolishChecks() async throws {
        let root = output.appendingPathComponent("polish-" + UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("项目", isDirectory: true)
        let nested = parent.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("alpha.txt"), second = root.appendingPathComponent("beta.txt")
        let excluded = root.appendingPathComponent("unmatched.json")
        try Data("needle 第一份\n".utf8).write(to: first)
        try Data("needle 第二份 内容更长\n".utf8).write(to: second)
        try Data("{}".utf8).write(to: excluded)
        let browser = FWBrowserHost(editorView: NSTabView(frame: .zero), openHandler: { _, _ in }, commandHandler: { _ in })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "文件工作台交互优化验收（自动关闭）"
        window.contentViewController = browser; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let store = browser.browserStore
        store.openRoot(root, remember: false)
        try await waitUntil("优化样本目录") { !store.isLoading && store.entries.count == 4 }
        store.navigate(to: nested)
        try await waitUntil("深层目录") { !store.isLoading }
        try await Task.sleep(for: .milliseconds(150))
        try check("面包屑包含授权根与每层目录", store.breadcrumbDirectories.map(\.path) == [root.path, parent.path, nested.path])
        try captureBrowser(browser, name: "polish-breadcrumb.png")
        store.navigate(to: root)
        try await waitUntil("返回样本根") { !store.isLoading }
        store.typeFilter = .documents; store.query = ".txt"; store.sortKey = .name; store.sortAscending = true
        store.selectedURL = first
        browser.openPreview(first, source: "space")
        try await waitUntil("连续只读预览") { browser.previewDocument?.canBeginEditing == true }
        let modal = browser.previewModal
        try check("连续预览首项边界", fixButton(browser, "FileDeck.preview.previous")?.isEnabled == false
                  && fixButton(browser, "FileDeck.preview.next")?.isEnabled == true)
        try pressFixButton(browser, "FileDeck.preview.next")
        try await waitUntil("下一项加载") { browser.previewModal?.url == second && browser.previewDocument?.canBeginEditing == true }
        try check("沿筛选结果切换并复用同一弹层", browser.previewModal === modal && fixButton(browser, "FileDeck.preview.next")?.isEnabled == false)
        try captureBrowser(browser, name: "polish-preview-next.png")
        window.makeFirstResponder(browser.previewModal?.overlay.dialog)
        try await event("\u{f702}", keyCode: 123, flags: .option)
        try await waitUntil("快捷键上一项") { browser.previewModal?.url == first && browser.previewDocument?.canBeginEditing == true }
        try check("连续预览快捷键不改变浏览筛选选择", store.selectedURL == first && store.query == ".txt" && store.typeFilter == .documents)
        try pressFixButton(browser, "FileDeck.preview.edit")
        let host = try await fixReady(browser)
        try await replace(host, "未保存的交互验证")
        try check("编辑模式隐藏连续切换入口", fixButton(browser, "FileDeck.preview.next")?.isHidden == true)
        try await event("\u{f703}", keyCode: 124, flags: .option)
        try check("编辑快捷键不切换或丢弃修改", browser.previewDocument === host && host.modified && browser.previewModal?.url == first)
        let closing = Task { @MainActor in await closePreview(browser) }
        try await pressSheet("不保存")
        try check("关闭编辑仍经过原保护", await closing.value && (try String(contentsOf: first)) == "needle 第一份\n")
        store.resetFilters(); store.sortKey = .size; store.sortAscending = false
        try await Task.sleep(for: .milliseconds(120))
        try captureBrowser(browser, name: "polish-browser-light.png")
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        try captureBrowser(browser, name: "polish-browser-dark.png")
        window.appearance = NSAppearance(named: .aqua)

        // 从正式输入框下移进入结果，返回预览后仍在原结果上继续键盘操作。
        try await event("f", keyCode: 3, flags: [.command, .shift])
        try await waitUntil("优化搜索入口") { browser.view.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "输入搜索词（字面子串）" && !$0.isHiddenOrHasHiddenAncestor } }
        guard let term = browser.view.allDescendants.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "输入搜索词（字面子串）" && !$0.isHiddenOrHasHiddenAncestor }) else { throw Failed.assertion("缺少搜索字段") }
        try await typeSearchTerm(".txt")
        try await event("\r", keyCode: 36)
        try check("搜索框提交已确认文本", term.stringValue == ".txt")
        try captureBrowser(browser, name: "polish-search-submitted.png")
        try await waitUntil("键盘搜索产生结果") { browser.view.allDescendants.compactMap { $0 as? NSTableView }.contains { !$0.isHiddenOrHasHiddenAncestor && $0.numberOfRows == 2 } }
        try check("高级选项默认折叠", !browser.view.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "用逗号分隔；可修改或清空" && !$0.isHiddenOrHasHiddenAncestor })
        try captureBrowser(browser, name: "polish-search-results.png")
        try await event("\u{f701}", keyCode: 125)
        try await event(" ", keyCode: 49)
        try await waitUntil("空格预览搜索结果") { browser.previewModal != nil && browser.previewDocument?.canBeginEditing == true }
        try check("搜索空格预览选中结果", browser.previewModal?.url == first)
        try check("搜索预览不混入浏览目录序列", fixButton(browser, "FileDeck.preview.next")?.isHidden == true)
        try check("搜索预览关闭", await closePreview(browser))
        try await event("\u{f701}", keyCode: 125)
        try await event("\r", keyCode: 36)
        try await waitUntil("回车打开第二个搜索结果") { browser.previewModal?.url == second }
        try check("结果回车打开而非重新提交搜索", browser.previewModal?.url == second)
        try check("搜索第二份预览关闭", await closePreview(browser))
        try await event("\u{1b}", keyCode: 53)

        // 字段组件复用系统 NSTextField 编辑与撤销，先核对实际选区，再键入落盘。
        var name = first.lastPathComponent
        let nameView = NSHostingController(rootView: WorkspaceFileNameField(name: Binding(get: { name }, set: { name = $0 }), originalName: name, isDirectory: false, enabled: true, submit: {}).frame(width: 360, height: 30).padding(20))
        window.contentViewController = nameView
        try await Task.sleep(for: .milliseconds(200))
        guard let field = nameView.view.allDescendants.compactMap({ $0 as? NSTextField }).first else { throw Failed.assertion("缺少重命名字段") }
        let selected = (field.currentEditor() as? NSTextView)?.selectedRange()
        try check("重命名默认只选主体名", selected == NSRange(location: 0, length: 5))
        guard let nameEditor = field.currentEditor() as? NSTextView else { throw Failed.assertion("重命名未进入系统字段编辑器") }
        nameEditor.insertText("renamed", replacementRange: nameEditor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        try check("输入主体保留原扩展名", name == "renamed.txt")
        let originalEntry = try FileSystem.entries(at: root, showHidden: false).first { $0.url == first }!
        let renamed = try await store.rename(originalEntry, to: name)
        try check("重命名真实落盘且内容不变", renamed.lastPathComponent == "renamed.txt" && (try String(contentsOf: renamed)) == "needle 第一份\n")
        window.contentViewController = browser
        try await Task.sleep(for: .milliseconds(150))

        let header = DraftRecoveryHeader(version: 1, id: UUID(), owner: UUID(), kind: "text", originalPath: first.path,
            title: "同名.txt", updatedAt: Date(), encoding: .utf8(bom: false), delimiter: nil, payloadBytes: 10, digest: "display-only")
        let otherHeader = DraftRecoveryHeader(version: 1, id: UUID(), owner: UUID(), kind: "text", originalPath: nested.appendingPathComponent("同名.txt").path,
            title: "同名.txt", updatedAt: Date(), encoding: .utf8(bom: false), delimiter: nil, payloadBytes: 10, digest: "display-only")
        let drafts = FWDraftRecoveryList(items: [.init(id: header.id, header: header, bytes: 10, problem: nil),
                                                .init(id: otherHeader.id, header: otherHeader, bytes: 10, problem: "校验失败")])
        let recoveryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        recoveryWindow.isReleasedWhenClosed = false; recoveryWindow.title = "草稿列表验收"
        recoveryWindow.contentView = drafts; recoveryWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(120))
        try check("草稿列表默认选择可恢复项", drafts.table.numberOfRows == 2 && drafts.selectedItem?.id == header.id)
        let labels = drafts.allDescendants.compactMap { $0 as? NSTextField }.map { $0.stringValue }.joined(separator: "\n")
        try check("同名草稿显示不同原路径及状态", labels.contains(first.path) && labels.contains(nested.path) && labels.contains("不可恢复：校验失败") && labels.contains("TEXT"))
        drafts.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try check("草稿选择保留独立ID与损坏状态", drafts.selectedItem?.id == otherHeader.id && drafts.selectedItem?.problem == "校验失败")
        recoveryWindow.orderOut(nil); recoveryWindow.contentView = nil
        window.makeKeyAndOrderFront(nil)
        try check("本轮未改写搜索文件和未选中文件", (try String(contentsOf: second)) == "needle 第二份 内容更长\n" && (try String(contentsOf: excluded)) == "{}")
    }

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
    func clickControl(_ identifier: String, in root: NSView) async throws {
        root.layoutSubtreeIfNeeded()
        guard let anchor = root.allDescendants.first(where: { $0.identifier?.rawValue == identifier }),
              !anchor.isHiddenOrHasHiddenAncestor, anchor.bounds.width > 0, anchor.bounds.height > 0,
              let targetWindow = anchor.window else {
            throw Failed.assertion("缺少可定位控件：" + identifier)
        }
        try await mouseClick(at: anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil), in: targetWindow)
    }

    func fixButton(_ browser: FWBrowserHost, _ identifier: String) -> NSButton? {
        let title = ["FileDeck.preview.save-and-return": "保存并返回", "FileDeck.preview.edit": "编辑"][identifier]
        return browser.previewModal?.overlay.dialog.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == identifier || $0.accessibilityIdentifier() == identifier || $0.title == title }
    }
    func fixMenuItem(_ browser: FWBrowserHost, _ identifier: String) -> NSMenuItem? {
        guard let more = fixButton(browser, "FileDeck.preview.more") as? NSPopUpButton else { return nil }
        return more.itemArray.first { $0.identifier?.rawValue == identifier }
    }
    func pressFixButton(_ browser: FWBrowserHost, _ identifier: String) throws {
        if let button = fixButton(browser, identifier), !button.isHidden, button.isEnabled { button.performClick(nil); return }
        guard let item = fixMenuItem(browser, identifier), !item.isHidden, item.isEnabled, let menu = item.menu else {
            throw Failed.assertion("缺少可用操作：" + identifier)
        }
        menu.performActionForItem(at: menu.index(of: item))
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
        let legacySave = fixMenuItem(browser, "FileDeck.preview.save-and-return")!
        try check("I5 Office 工作层显示保存并返回", !legacySave.isHidden && legacySave.isEnabled)
        try pressFixButton(browser, "FileDeck.preview.save-and-return")
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
            else if let pdf = host.content as? FWPDFContent { try await pdf.rotate(pageIndexes: [0]) }
            else if let image = host.content as? FWImageContent { try await image.rotate(clockwise: true) }
            try check("I5 \(template.rawValue) 原位进入编辑并保持同一文件", host.isEditing && host.modified && host.documentURL == file)
            let saveReturn = fixMenuItem(browser, "FileDeck.preview.save-and-return")!
            try check("I5 \(template.rawValue) 提供保存并返回", !saveReturn.isHidden && saveReturn.isEnabled)
            try pressFixButton(browser, "FileDeck.preview.save-and-return")
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
        // 在现有 legacy 工作层中打开真实空白文档，覆盖旧自动展开信号与首次保存状态。
        let untitled = FWDocumentHost(content: FWTextContent.create(kind: .text))
        browser.addChild(untitled)
        let newTab = NSTabViewItem(identifier: "untitled-layout")
        newTab.view = untitled.view
        tabs.addTabViewItem(newTab); tabs.selectTabViewItem(newTab)
        browser.legacyDocument = untitled
        try await settle(untitled)
        browser.updateEditor(title: untitled.documentTitle, url: untitled.documentURL, hasDocument: true,
                             modified: untitled.modified, busy: untitled.busy, canSave: untitled.canSave, canSaveAs: untitled.canSaveAs, canExport: false)
        browser.showEditor()
        try await Task.sleep(for: .milliseconds(250))
        try check("空白新文档首次保存按钮可用", untitled.documentURL == nil && !untitled.modified && fixButton(browser, "FileDeck.preview.save")?.isEnabled == true)
        try check("切换未命名文档的自动展开不触发系统全屏", browser.editorBridge.isExpanded && !window.styleMask.contains(.fullScreen))
        try await untitled.content.close(discardChanges: false)
        untitled.disposePreview()
        tabs.removeTabViewItem(newTab); untitled.removeFromParent()
        tabs.selectTabViewItem(tab)
        browser.legacyDocument = document
        browser.updateEditor(title: document.documentTitle, url: document.documentURL, hasDocument: true,
                             modified: document.modified, busy: document.busy, canSave: document.canSave, canSaveAs: document.canSaveAs, canExport: false)
        browser.showEditor()
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

/// 生成可搜索的真实 PDF 文字页，合并顺序按页面文字验证。
@MainActor
private final class EditorPDFTextFixture: NSView {
    let text: String
    init(_ text: String) { self.text = text; super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(at: NSPoint(x: 20, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
    }
}

extension NativeTextTests {
    func editorInteractionChecks() async throws {
        let directory = output.appendingPathComponent("editor-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "编辑交互九项验收（隔离样本）"
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await editorCSVTarget(directory)
        try await editorPDFChecks(directory)
        try await editorImageChecks(directory)
        try await editorDragChecks(directory)
    }

    func editorCSVTarget(_ directory: URL) async throws {
        let file = directory.appendingPathComponent("cells.csv")
        try Data("a,b,c\n1,2,3\n".utf8).write(to: file)
        let csv = try await FWCSVContent.open(url: file, encoding: nil, delimiter: .comma)
        window.contentViewController = csv
        try await Task.sleep(for: .milliseconds(120))
        guard let table = csv.view.allDescendants.compactMap({ $0 as? FWCSVTable }).first,
              let editButton = button(csv.view, title: "编辑单元格") else { throw Failed.assertion("CSV 控件缺失") }
        table.deselectAll(nil)
        try check("CSV 无选区时禁用编辑且不猜首格", !editButton.isEnabled)
        editButton.performClick(nil)
        try check("CSV 无目标编辑不弹窗也不修改", NSApp.modalWindow == nil && !csv.isModified)
        // 双击编辑的委托接收原生列对象，目标不是由行选择猜测。
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        _ = csv.tableView(table, shouldEdit: table.tableColumns[2], row: 1)
        try check("CSV 编辑目标明确到第三列", editButton.isEnabled && editButton.toolTip == "编辑第 2 行、第 3 列")
        try csv.setCell("changed", row: 1, column: 2)
        try await csv.save(overwriteExternalChanges: false)
        try check("CSV 只修改明确目标格", (try String(contentsOf: file)) == "a,b,c\n1,2,changed\n")
        try await csv.close(discardChanges: false)
    }

    func editorPDFChecks(_ directory: URL) async throws {
        let oneView = EditorPDFTextFixture("needle FIRST needle")
        let twoView = EditorPDFTextFixture("SECOND-PAGE")
        let one = oneView.dataWithPDF(inside: oneView.bounds), two = twoView.dataWithPDF(inside: twoView.bounds)
        let source = directory.appendingPathComponent("source.pdf"), first = directory.appendingPathComponent("one.pdf"), second = directory.appendingPathComponent("two.pdf")
        try one.write(to: first); try two.write(to: second)
        let initial = try PDFOperations.merge([one, two]); try initial.write(to: source)
        let pdf = try await FWPDFContent.open(url: source)
        window.contentViewController = pdf
        pdf.find()
        guard let field = pdf.view.allDescendants.compactMap({ $0 as? NSSearchField }).first,
              let next = button(pdf.view, title: "下一处"), let previous = button(pdf.view, title: "上一处") else { throw Failed.assertion("PDF 查找栏缺失") }
        func type(_ value: String) async throws {
            field.selectText(nil)
            guard let editor = window.firstResponder as? NSTextView else { throw Failed.assertion("PDF 查找焦点缺失") }
            editor.selectAll(nil); editor.insertText(value, replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(250))
        }
        func count(_ value: String) -> Bool { pdf.view.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == value } }
        try await type("needle")
        try await waitUntil("PDF 异步查找完成") { count("1 / 2") && next.isEnabled }
        next.performClick(nil); try check("PDF 下一处及计数", count("2 / 2"))
        previous.performClick(nil); try check("PDF 上一处及计数", count("1 / 2"))
        try await type("not-present")
        try await waitUntil("PDF 未命中提示") { count("未找到") }
        try check("PDF 未命中禁用跳转", !next.isEnabled && !previous.isEnabled)
        try await type("needle"); try await type("SECOND")
        try await waitUntil("PDF 重搜替换旧结果") { count("1 / 1") }
        try check("PDF 搜索不修改文档", !pdf.isModified && (try Data(contentsOf: source)) == initial)
        try captureView(pdf.view, name: "pdf-find.png")
        try check("PDF Escape 可先关闭查找", pdf.dismissFind() && !pdf.dismissFind())
        let extracted = directory.appendingPathComponent("extracted.pdf")
        try await pdf.exportPages([1], to: extracted)
        let result = try PDFOperations.read(Data(contentsOf: extracted))
        try check("PDF 提取生成独立文件且页码正确", result.pageCount == 1 && result.page(at: 0)?.string?.contains("SECOND-PAGE") == true)
        try check("PDF 提取保留源路径基线与撤销", pdf.path == source && !pdf.isModified && !pdf.canUndo && (try Data(contentsOf: source)) == initial)
        do { try await pdf.exportPages([0], to: source); throw Failed.assertion("允许提取覆盖原文件") }
        catch is MediaOperationError { try check("PDF 提取拒绝原路径", (try Data(contentsOf: source)) == initial) }
        let occupied = directory.appendingPathComponent("occupied.pdf")
        try Data("keep".utf8).write(to: occupied)
        do { try await pdf.exportPages([0], to: occupied); throw Failed.assertion("未确认覆盖现有目标") }
        catch DocumentIOError.destinationExists { try check("PDF 提取重名保留现有目标", (try String(contentsOf: occupied)) == "keep") }
        let queue = FWPDFMergeList(items: [.init(url: first, pages: 1), .init(url: second, pages: 1)], existingPages: 2)
        window.contentViewController = NSViewController(); window.contentViewController?.view = queue
        button(queue, title: "下移")!.performClick(nil)
        try check("PDF 合并队列可调整顺序", queue.orderedURLs == [second, first])
        try await pdf.merge(urls: queue.orderedURLs)
        let merged = directory.appendingPathComponent("merged.pdf")
        try await pdf.export(to: merged, format: .pdf, overwriteExisting: false)
        let mergedPDF = try PDFOperations.read(Data(contentsOf: merged))
        try check("PDF 合并按确认顺序追加真实页面", mergedPDF.pageCount == 4 && mergedPDF.page(at: 2)?.string?.contains("SECOND-PAGE") == true && mergedPDF.page(at: 3)?.string?.contains("FIRST") == true)
        queue.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        button(queue, title: "移除")!.performClick(nil)
        try check("PDF 合并队列可移除文件", queue.orderedURLs == [first])
        try await pdf.close(discardChanges: true)
        let closedTarget = directory.appendingPathComponent("closed.pdf")
        do { try await pdf.exportPages([0], to: closedTarget); throw Failed.assertion("已关闭 PDF 仍允许提取") }
        catch DocumentSessionError.closed { try check("关闭的 PDF 不再写入提取文件", !FileManager.default.fileExists(atPath: closedTarget.path)) }
    }

    func captureView(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failed.assertion("截图失败") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }

    func editorImageChecks(_ directory: URL) async throws {
        let resize = FWImageResizeForm(width: 200, height: 100)
        let submit = NSButton(title: "应用", target: nil, action: nil)
        resize.fields.submitButton = submit
        func change(_ form: FWValidatedFields, _ index: Int, _ value: String) {
            form.inputs[index].stringValue = value
            form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.inputs[index]))
        }
        change(resize.fields, 0, "100")
        try check("图片宽高默认锁定比例", resize.result?.width == 100 && resize.result?.height == 50)
        change(resize.fields, 2, "25")
        try check("图片百分比基于原始像素", resize.result?.width == 50 && resize.result?.height == 25)
        resize.lock.performClick(nil); change(resize.fields, 1, "80")
        try check("解锁后允许独立调整高度", resize.result?.width == 50 && resize.result?.height == 80)
        change(resize.fields, 0, "0")
        try check("无效参数保留字段并禁用提交", resize.result == nil && !submit.isEnabled && resize.fields.inputs[0].stringValue == "0" && !resize.fields.errorLabel.stringValue.isEmpty)
        change(resize.fields, 0, "60")
        try check("修正参数后同一表单可继续提交", resize.result?.width == 60 && submit.isEnabled)
        change(resize.fields, 2, "999999999999")
        try check("超大百分比不能提交旧尺寸", resize.result == nil && !submit.isEnabled)
        let unlocked = FWImageResizeForm(width: 100, height: 1000)
        change(unlocked.fields, 0, "10000")
        try check("锁定比例时拒绝联动越界", unlocked.result == nil)
        unlocked.lock.performClick(nil)
        try check("解除锁定清除旧联动错误", unlocked.result?.width == 10000 && unlocked.result?.height == 1000)
        change(unlocked.fields, 1, "10")
        try check("解锁后按实际宽高校验合法尺寸", unlocked.result?.width == 10000 && unlocked.result?.height == 10)
        let source = try NewFileCreator.create(template: .png, name: "image.png", directory: directory, expectedDirectoryIdentity: FileSystem.identity(at: directory))
        let bytes = try Data(contentsOf: source)
        let image = try ImageOperations.read(bytes)
        let crop = FWImageCropForm(image: image)
        let controller = NSViewController(); controller.view = crop; window.contentViewController = controller
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(120))
        let canvas = crop.canvas
        let start = canvas.displayRect(CGRect(x: 10, y: 10, width: 1, height: 1)).origin
        let end = canvas.displayRect(CGRect(x: 110, y: 90, width: 1, height: 1)).origin
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            guard let event = NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failed.assertion("裁剪事件失败") }
            window.sendEvent(event)
        }
        try check("可视裁剪拖动映射原图像素", crop.result == CGRect(x: 10, y: 10, width: 100, height: 80))
        crop.ratio.selectItem(at: 2)
        // 通过真实控件 target/action 更新比例，避免弹出菜单后测试等待人工选择。
        NSApp.sendAction(crop.ratio.action!, to: crop.ratio.target, from: crop.ratio)
        try check("可视裁剪支持方形比例", crop.result?.width == crop.result?.height)
        change(crop.fields, 0, "-1")
        try check("裁剪错误留在原字段且不产生结果", crop.result == nil && crop.fields.inputs[0].stringValue == "-1")
        change(crop.fields, 0, "10")
        try captureView(crop, name: "image-crop.png")
        let content = try await FWImageContent.open(url: source)
        window.contentViewController = content; window.setContentSize(NSSize(width: 640, height: 500))
        try await Task.sleep(for: .milliseconds(150))
        guard let scroll = content.view.allDescendants.compactMap({ $0 as? NSScrollView }).first else { throw Failed.assertion("图片滚动视图缺失") }
        try check("图片初次显示适应窗口且不改像素", scroll.magnification < 1 && !content.isModified && (try Data(contentsOf: source)) == bytes)
        button(content.view, title: "实际大小")!.performClick(nil)
        try check("实际大小明确恢复百分之百", scroll.magnification == 1)
        button(content.view, title: "适合窗口")!.performClick(nil)
        try check("适合窗口可重新进入", scroll.magnification < 1)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: scroll)
        scroll.setMagnification(1.5, centeredAt: NSPoint(x: 100, y: 100)); content.view.layoutSubtreeIfNeeded()
        try check("用户开始缩放后不被适合窗口复位", scroll.magnification == 1.5)
        try await content.crop(pixelRect: CGRect(x: 10, y: 10, width: 100, height: 80))
        let target = directory.appendingPathComponent("cropped.png"); try await content.saveAs(to: target, overwriteExternalChanges: false)
        let saved = try ImageOperations.read(Data(contentsOf: target))
        try check("裁剪复用真实保存流程且原图不变", saved.width == 100 && saved.height == 80 && (try Data(contentsOf: source)) == bytes)
        try await content.close(discardChanges: false)
    }

    func editorDragChecks(_ directory: URL) async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
        scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200)); scroll.documentView = document
        let controller = NSViewController(); controller.view = scroll; window.contentViewController = controller
        window.setContentSize(NSSize(width: 400, height: 260)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(120))
        guard NSApp.isActive, NSApp.keyWindow === window else { throw Failed.assertion("拖放验收窗口未获得焦点") }
        let geometry = WorkspaceDropGeometry(); geometry.view = document
        let assistance = WorkspaceDragAssistance()
        let local = NSPoint(x: 180, y: scroll.contentView.bounds.maxY - 2)
        let point = window.convertPoint(toScreen: document.convert(local, to: nil))
        let screenTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let global = CGPoint(x: point.x, y: screenTop - point.y)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: global, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: global, mouseButton: .left) else { throw Failed.assertion("拖动按键事件失败") }
        down.post(tap: .cghidEventTap)
        defer { up.post(tap: .cghidEventTap); assistance.stop() }
        assistance.update(geometry, location: local, springAction: nil)
        try await Task.sleep(for: .milliseconds(220))
        try check("拖动边缘持续滚动", scroll.contentView.bounds.origin.y > 0)
        assistance.stop(); scroll.contentView.scroll(to: .zero)
        var expanded = false
        assistance.update(geometry, location: NSPoint(x: 180, y: 120), springAction: { expanded = true })
        try await Task.sleep(for: .milliseconds(800))
        try check("拖动悬停延迟打开目标", expanded)
        assistance.stop(); expanded = false
        assistance.update(geometry, location: NSPoint(x: 180, y: 120), springAction: { expanded = true })
        assistance.exit(geometry)
        try await Task.sleep(for: .milliseconds(700))
        try check("拖动离开后取消旧目标展开", !expanded)
    }
}

extension NativeTextTests {
    /// 本轮六项操作均使用生产控制器、真实窗口与隔离磁盘；不替换保存或查找实现。
    func workflowInteractionChecks() async throws {
        let directory = output.appendingPathComponent("workflow-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cells.csv")
        try Data("head,Needle\nneedle,other\n".utf8).write(to: file)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "六项工作流优化验收（隔离样本）"
        let browser = FWBrowserHost(editorView: NSTabView(frame: .zero), openHandler: { _, _ in }, commandHandler: { _ in })
        window.contentViewController = browser; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let store = browser.browserStore
        store.openRoot(directory, remember: false)
        try await waitUntil("工作流目录") { !store.isLoading && store.entries.count == 1 }
        store.selectedURL = file
        browser.openPreview(file, source: "edit")
        // CSV 初次呈现为文本预览，由现有编辑按钮进入表格。
        try await waitUntil("CSV 预览") { browser.previewModal != nil && self.fixButton(browser, "FileDeck.preview.edit")?.isEnabled == true }
        if !(browser.previewDocument?.content is FWCSVContent) { try pressFixButton(browser, "FileDeck.preview.edit") }
        let host = try await fixReady(browser)
        guard let csv = host.content as? FWCSVContent else { throw Failed.assertion("未进入 CSV 表格编辑") }
        let previous = host.stateDidChange
        var edited = false, editError: Error?
        host.stateDidChange = {
            previous?()
            if csv.isBusy && !edited {
                edited = true
                do { try csv.setCell("newer", row: 1, column: 1) } catch { editError = error }
            }
        }
        try csv.setCell("saved snapshot", row: 0, column: 0)
        try pressFixButton(browser, "FileDeck.preview.save-and-return")
        try await waitUntil("快照写盘完成") { host.successfulSaveGeneration == 1 && !host.busy }
        if let editError { throw editError }
        host.stateDidChange = previous
        try check("保存期间输入保留 dirty 且保存返回不关闭", edited && host.modified && browser.previewDocument === host)
        try check("快照确实写盘且新输入尚未覆盖", (try String(contentsOf: file)) == "saved snapshot,Needle\nneedle,other\n")
        try await Task.sleep(for: .milliseconds(900))
        let labels = browser.previewModal!.overlay.dialog.allDescendants.compactMap { $0 as? NSTextField }.map(\.stringValue)
        try check("真实保存更新指纹，不误报外部修改", !labels.contains(where: { $0.contains("文件状态已变化") }) && host.statusText.contains("当前仍有未保存修改"))
        try await event("f", keyCode: 3, flags: .command)
        try await waitUntil("CSV 查找框") { csv.view.allDescendants.contains { ($0 as? NSSearchField)?.isHidden == false } }
        let search = csv.view.allDescendants.compactMap { $0 as? NSSearchField }.first!
        search.selectText(nil)
        let fieldEditor = window.firstResponder as! NSTextView
        fieldEditor.insertText("needle", replacementRange: fieldEditor.selectedRange())
        func count(_ value: String) -> Bool { csv.view.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == value } }
        try await waitUntil("CSV 两格匹配") { count("1 / 2 格 · R1C2") }
        let table = csv.view.allDescendants.compactMap { $0 as? FWCSVTable }.first!
        try check("CSV 首匹配选择明确单元格", table.selectedRow == 0 && csv.view.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("当前单元格 R1C2") } && host.canFind)
        try await event("g", keyCode: 5, flags: .command)
        try await waitUntil("CSV 下一格") { count("2 / 2 格 · R2C1") }
        try await event("g", keyCode: 5, flags: [.command, .shift])
        try await waitUntil("CSV 上一格") { count("1 / 2 格 · R1C2") }
        try csv.setCell("gone", row: 0, column: 1)
        try await waitUntil("CSV 修改后重算查找") { count("1 / 1 格 · R2C1") }
        csv.undo()
        try await waitUntil("CSV 撤销后恢复查找") { count("1 / 2 格 · R1C2") }
        try captureBrowser(browser, name: "workflow-csv-find.png")
        try await event("\u{1b}", keyCode: 53)
        try check("CSV Escape 只关闭查找并保留编辑", browser.previewDocument === host && host.modified && window.firstResponder === table)
        try captureBrowser(browser, name: "workflow-csv-save.png")
        try pressFixButton(browser, "FileDeck.preview.save-and-return")
        try await waitUntil("第二次保存后返回") { browser.previewModal == nil && !store.isLoading }
        try check("后续保存写入新编辑并返回原选择", (try String(contentsOf: file)).contains("newer") && store.selectedURL == file)

        let markdown = directory.appendingPathComponent("link.md")
        try Data("[文档](https://example.com/a?x=1&y=2)".utf8).write(to: markdown)
        store.refresh(); try await waitUntil("Markdown 样本") { !store.isLoading && store.entries.count == 2 }
        browser.openPreview(markdown, source: "space")
        try await waitUntil("Markdown 只读渲染") { browser.previewDocument?.canBeginEditing == true }
        let markdownHost = browser.previewDocument!
        let web = findWeb(markdownHost.view)!
        try await waitUntil("Markdown 资源就绪") { (markdownHost.content as? FWTextContent)?.canBeginEditing == true }
        let oldClipboard = NSPasteboard.general.pasteboardItems?.map { item in item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) } } ?? []
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(oldClipboard.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item })
        }
        _ = try await fixJS(web, "document.querySelector('.md-copy-link').click(); return true")
        try await waitUntil("Markdown 复制真实剪贴板") { NSPasteboard.general.string(forType: .string) == "https://example.com/a?x=1&y=2" }
        try await Task.sleep(for: .milliseconds(120))
        try check("Markdown 复制不导航、不修改且原生回执显示成功", (try await fixJS(web, "return document.querySelector('.md-copy-link').textContent === '已复制' && document.querySelector('#preview').querySelectorAll('a,[href]').length === 0")) as? Bool == true && !markdownHost.modified)
        try check("Markdown 关闭保护不受复制影响", await closePreview(browser))
        try await workflowBrowserChecks(browser, directory: directory)
    }

    func workflowBrowserChecks(_ browser: FWBrowserHost, directory: URL) async throws {
        let store = browser.browserStore
        guard let field = browser.view.allDescendants.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "筛选已加载目录…" }) else { throw Failed.assertion("缺少侧栏范围提示") }
        field.selectText(nil)
        let editor = window.firstResponder as! NSTextView
        editor.insertText("deep needle", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(120))
        try captureBrowser(browser, name: "workflow-sidebar.png")
        try await clickControl("sidebar.recursive-search", in: browser.view)
        try await Task.sleep(for: .milliseconds(150))
        let search = browser.view.allDescendants.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "输入搜索词（字面子串）" }
        try check("侧栏转入保留搜索词且不修改列表筛选", search?.stringValue == "deep needle" && store.query.isEmpty)
        try captureBrowser(browser, name: "workflow-search-form.png")
        try await event("\u{1b}", keyCode: 53)
        try await Task.sleep(for: .milliseconds(120))
        field.selectText(nil)
        let filterEditor = window.firstResponder as! NSTextView
        filterEditor.selectAll(nil); filterEditor.insertText("", replacementRange: filterEditor.selectedRange())
        try await event("n", keyCode: 45, flags: [.command, .shift])
        try check("文本输入不接收新建文件夹快捷键", window.attachedSheet == nil)
        let table = browser.view.allDescendants.compactMap { $0 as? NSTableView }.first!
        window.makeFirstResponder(table)
        try await event("n", keyCode: 45, flags: [.command, .shift])
        try await waitUntil("快捷键新建文件夹") { self.window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        let name = sheet.contentView!.allDescendants.compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.isEnabled }!
        name.selectText(nil)
        let nameEditor = sheet.firstResponder as! NSTextView
        let folderName = "快捷键目录-" + UUID().uuidString
        nameEditor.selectAll(nil); nameEditor.insertText(folderName, replacementRange: nameEditor.selectedRange())
        try await event("\u{7f}", keyCode: 51, flags: .command)
        try check("命名弹窗不接收文件废纸篓快捷键", store.entries.count == 2)
        // 系统文本框可能处理 Cmd+Delete，重新提交名称后走默认创建动作。
        nameEditor.selectAll(nil); nameEditor.insertText(folderName, replacementRange: nameEditor.selectedRange())
        try await event("\r", keyCode: 36)
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        try await waitUntil("文件夹真实创建") { !store.isLoading && self.window.attachedSheet == nil && store.selectedURL == folder }
        try check("文件区 ShiftCmdN 复用安全新建流程", FileManager.default.fileExists(atPath: folder.path))
        let fileTable = browser.view.allDescendants.compactMap { $0 as? NSTableView }.first { $0.window === self.window }!
        try check("新建返回后文件列表可获得焦点", window.makeFirstResponder(fileTable))
        try await event("\u{7f}", keyCode: 51, flags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await waitUntil("快捷键移入废纸篓") { !store.isFileOperationBusy && !FileManager.default.fileExists(atPath: folder.path) }
        try check("文件区 CmdDelete 移入废纸篓并提供撤销", !store.fileOperationUndo.isEmpty)
        await store.undoLastFileOperation()
        try await waitUntil("撤销快捷键废纸篓") { !store.isLoading && FileManager.default.fileExists(atPath: folder.path) }
        try check("快捷键废纸篓可真实撤销", store.fileOperationUndo.isEmpty)
        try await workflowCreateFromMenu(browser, name: "created", action: "创建并编辑")
        let created = directory.appendingPathComponent("created.md")
        let createdHost = try await fixReady(browser)
        try check("创建并编辑自动补后缀并进入同一文件编辑", createdHost.documentURL == created && createdHost.isEditing && store.selectedURL == created)
        try await replace(createdHost, "# 新建后编辑")
        try pressFixButton(browser, "FileDeck.preview.save-and-return")
        try await waitUntil("创建后编辑保存返回") { browser.previewModal == nil && !store.isLoading }
        try check("创建编辑保存沿用原文档流程", (try String(contentsOf: created)) == "# 新建后编辑" && store.selectedURL == created)
        try await workflowCreateFromMenu(browser, name: "only", action: "仅创建")
        let only = directory.appendingPathComponent("only.md")
        try await waitUntil("仅创建选中文件") { self.window.attachedSheet == nil && !store.isLoading && store.selectedURL == only }
        try check("保留仅创建，不自动进入编辑", browser.previewModal == nil && FileManager.default.fileExists(atPath: only.path))
        try captureBrowser(browser, name: "workflow-browser.png")
    }
    func workflowCreateFromMenu(_ browser: FWBrowserHost, name: String, action: String) async throws {
        let table = browser.view.allDescendants.compactMap { $0 as? NSTableView }.first!
        let row = browser.browserStore.orderedEntries.firstIndex { !$0.isBrowsableDirectory }!
        try await fixTrackedMenu(browser, table: table, row: row) { menu in
            guard let (owner, index) = self.menuItem(named: "Markdown (.md)", in: menu) else { throw Failed.assertion("缺少 Markdown 新建菜单") }
            menu.cancelTrackingWithoutAnimation(); owner.performActionForItem(at: index)
        }
        try await waitUntil("新建 Markdown 面板") { self.window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        let field = sheet.contentView!.allDescendants.compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.isEnabled }!
        field.selectText(nil)
        let editor = sheet.firstResponder as! NSTextView
        editor.selectAll(nil); editor.insertText(name, replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(80))
        try captureView(sheet.contentView!, name: "workflow-create-sheet.png")
        if action == "创建并编辑" { try await event("\r", keyCode: 36) }
        else {
            try await clickControl("creation.create", in: sheet.contentView!)
        }
    }
}
