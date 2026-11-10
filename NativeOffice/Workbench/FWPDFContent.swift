import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class FWPDFContent: NSViewController, FWNativeContent, NSSearchFieldDelegate, @preconcurrency PDFDocumentDelegate {
    let id = UUID()
    let kind = WorkbenchFileKind.pdf
    var controller: NSViewController { self }
    var contentTitle: String { path?.lastPathComponent ?? "未命名 PDF" }
    var path: URL? { state.path }
    var isModified: Bool { state.isModified }
    var recoveryRevision: UInt64 { state.revision }
    var isReadOnly: Bool { state.isReadOnly }
    var isBusy: Bool { state.isBusy || processing }
    var canFind: Bool { !state.isClosed && !isBusy }
    var canUndo: Bool { state.canEdit && !isBusy && history.canUndo }
    var canRedo: Bool { state.canEdit && !isBusy && history.canRedo }
    var onStateChanged: (() -> Void)?
    var availableOperations: Set<FileOperation> {
        guard !state.isClosed else { return [] }
        var result: Set<FileOperation> = [.open]
        if state.canEdit && !processing { result.insert(.edit) }
        if !isBusy {
            result.formUnion([.saveAs, .export])
            if !isReadOnly { result.insert(.save) }
        }
        return result
    }
    private let state: FWBinaryState
    private var processing = false
    private let pdfView = PDFView()
    private let status = NSTextField(labelWithString: "")
    private let history: FWMediaHistory
    private var editButtons: [NSButton] = []
    private let searchField = NSSearchField()
    private let searchBar = NSStackView()
    private let searchCount = NSTextField(labelWithString: "")
    private let previousMatch = NSButton(title: "上一处", target: nil, action: nil)
    private let nextMatch = NSButton(title: "下一处", target: nil, action: nil)
    private var matches: [PDFSelection] = []
    private var matchIndex: Int?
    private var searchTask: Task<Void, Never>?
    private var searching = false
    override var undoManager: UndoManager? { history.manager }

    private init(data: Data, fileState: FileSaveState?, maximumBytes: Int, historyMaximumBytes: Int) throws {
        state = try FWBinaryState(data: data, fileState: fileState, maximumBytes: maximumBytes)
        history = FWMediaHistory(maximumBytes: historyMaximumBytes)
        super.init(nibName: nil, bundle: nil)
        state.onChange = { [weak self] in self?.refreshState() }
    }
    required init?(coder: NSCoder) { fatalError("请使用 open(url:)") }

    var recoveryCapture: DraftRecoveryCapture? {
        guard !state.isClosed, isModified else { return nil }
        return DraftRecoveryCapture(kind: kind, originalURL: path, title: contentTitle, body: .binary(state.data))
    }
    static func recover(_ draft: DraftRecoveryDocument) async throws -> FWPDFContent {
        let data = draft.data
        _ = try await Task.detached(priority: .userInitiated) { try PDFOperations.read(data).pageCount }.value
        let content = try FWPDFContent(data: data, fileState: nil, maximumBytes: SafeFileIO.maximumMediaBytes,
                                      historyMaximumBytes: FWMediaHistory.defaultMaximumBytes)
        content.state.markRecovered()
        return content
    }

    static func open(url: URL, maximumBytes: Int = SafeFileIO.maximumMediaBytes,
                     historyMaximumBytes: Int = FWMediaHistory.defaultMaximumBytes) async throws -> FWPDFContent {
        let loaded = try await Task.detached(priority: .userInitiated) {
            let result = try SafeFileIO.open(url: url, maximumBytes: maximumBytes)
            _ = try PDFOperations.read(result.data)
            return result
        }.value
        return try FWPDFContent(data: loaded.data, fileState: loaded.state, maximumBytes: maximumBytes, historyMaximumBytes: historyMaximumBytes)
    }

    static func createFromImages(urls: [URL], maximumBytes: Int = SafeFileIO.maximumMediaBytes,
                                 historyMaximumBytes: Int = FWMediaHistory.defaultMaximumBytes) async throws -> FWPDFContent {
        let data = try await Task.detached(priority: .userInitiated) {
            try PDFOperations.imagesToPDF(SafeFileIO.openMediaBatch(urls: urls, maximumBytes: maximumBytes))
        }.value
        return try FWPDFContent(data: data, fileState: nil, maximumBytes: maximumBytes, historyMaximumBytes: historyMaximumBytes)
    }

    override func loadView() {
        let toolbar = NSStackView()
        toolbar.orientation = .vertical; toolbar.alignment = .leading; toolbar.spacing = 6
        let actions = NSStackView(); actions.spacing = 8
        for (name, selector) in [("旋转本页", #selector(rotateCurrentPage)), ("高亮选中文字", #selector(highlightSelection)),
                                 ("文字批注", #selector(addNote)), ("合并 PDF", #selector(mergeFiles)),
                                 ("提取页面", #selector(extractPages)), ("添加图片页", #selector(appendImages))] {
            let button = NSButton(title: name, target: self, action: selector)
            editButtons.append(button)
            actions.addArrangedSubview(button)
        }
        // PDFKit 原生处理捏合和平移；按钮保留鼠标/键盘的同等入口。
        let zoom = NSStackView(); zoom.spacing = 8
        for (name, selector, key) in [("缩小", #selector(zoomOut), "-"), ("适合窗口", #selector(fitPage), "0"), ("放大", #selector(zoomIn), "+")] {
            let button = NSButton(title: name, target: self, action: selector)
            button.keyEquivalent = key; button.keyEquivalentModifierMask = .command
            zoom.addArrangedSubview(button)
        }
        searchField.placeholderString = "查找 PDF 文字"; searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        // 文本变化由 delegate 发起搜索；系统延迟 action 只应在回车时前进，不能输入停顿后跳过首处。
        searchField.sendsWholeSearchString = true
        searchField.target = self; searchField.action = #selector(nextSearchMatch)
        previousMatch.target = self; previousMatch.action = #selector(previousSearchMatch)
        nextMatch.target = self; nextMatch.action = #selector(nextSearchMatch)
        previousMatch.keyEquivalent = "g"; previousMatch.keyEquivalentModifierMask = [.command, .shift]
        nextMatch.keyEquivalent = "g"; nextMatch.keyEquivalentModifierMask = .command
        let close = NSButton(title: "关闭查找", target: self, action: #selector(closeSearch))
        for item in [searchField, searchCount, previousMatch, nextMatch, close] { searchBar.addArrangedSubview(item) }
        searchBar.spacing = 8; searchBar.isHidden = true
        toolbar.addArrangedSubview(actions); toolbar.addArrangedSubview(zoom); toolbar.addArrangedSubview(searchBar)
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 8
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        view = FWMediaUI.layout(toolbar: toolbar, body: pdfView, status: status)
        refreshPDF()
    }

    @objc private func zoomOut() { pdfView.zoomOut(nil) }
    @objc private func zoomIn() { pdfView.zoomIn(nil) }
    @objc private func fitPage() { pdfView.autoScales = true }

    func save(overwriteExternalChanges: Bool) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        try await state.save(to: nil, overwrite: overwriteExternalChanges)
    }
    func saveAs(to destination: URL, overwriteExternalChanges: Bool) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        try FWMediaUI.requireExtension(destination, allowed: ["pdf"])
        try await state.save(to: destination, overwrite: overwriteExternalChanges)
    }
    func export(to destination: URL, format: WorkbenchFileKind, overwriteExisting: Bool) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        guard format == .pdf else { throw DocumentSessionError.unsupportedOperation(.export) }
        try FWMediaUI.requireExtension(destination, allowed: ["pdf"])
        try await state.save(to: destination, overwrite: overwriteExisting, adoptDestination: false)
    }
    func reload(discardChanges: Bool) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        processing = true
        defer { processing = false; refreshState() }
        try await state.reload(discardChanges: discardChanges) { _ = try PDFOperations.read($0) }
        history.removeAll()
        if isViewLoaded { refreshPDF() }
    }
    func close(discardChanges: Bool) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        try state.close(discardChanges: discardChanges); history.removeAll()
        searchTask?.cancel(); pdfView.document?.cancelFindString(); pdfView.document?.delegate = nil
    }
    func undo() { if canUndo { history.undo() } }
    func redo() { if canRedo { history.redo() } }

    /// 供工具栏和会话回归共用；页码始终使用从 0 开始的 PDF 模型索引。
    func rotate(pageIndexes: [Int]) async throws {
        try await transform(name: "旋转页面", allowDuringSave: true) { try PDFOperations.rotate($0, pageIndexes: pageIndexes) }
    }
    func extract(pageIndexes: [Int]) throws {
        try install(PDFOperations.extract(state.data, pageIndexes: pageIndexes), name: "提取页面")
    }
    func addTextAnnotation(pageIndex: Int, bounds: CGRect, text: String) async throws {
        try await transform(name: "文字批注", allowDuringSave: true) { try PDFOperations.addTextAnnotation($0, pageIndex: pageIndex, bounds: bounds, text: text) }
    }
    func addHighlight(pageIndex: Int, bounds: CGRect) throws {
        try install(PDFOperations.addHighlight(state.data, pageIndex: pageIndex, bounds: bounds), name: "高亮文字")
    }
    func addHighlights(_ highlights: [PDFOperations.Highlight]) async throws {
        try await transform(name: "高亮文字") { try PDFOperations.addHighlights($0, highlights: highlights) }
    }

    @objc private func rotateCurrentPage() {
        let page = currentPageIndex
        Task {
            do { try await rotate(pageIndexes: [page]) }
            catch { FWMediaUI.show(error, in: view.window) }
        }
    }
    @objc private func highlightSelection() {
        perform {
            guard let selection = pdfView.currentSelection, let document = pdfView.document else {
                throw MediaOperationError.invalidParameter("请先选中要高亮的文字。")
            }
            let source = state.data
            var highlights: [PDFOperations.Highlight] = []
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = line.bounds(for: page).intersection(page.bounds(for: .cropBox))
                    guard !bounds.isNull, !bounds.isEmpty else { continue }
                    highlights.append(.init(pageIndex: document.index(for: page), bounds: bounds))
                }
            }
            guard !highlights.isEmpty else { throw MediaOperationError.invalidParameter("选区没有可高亮的文字。") }
            let captured = highlights
            Task {
                do {
                    guard state.data == source else { throw DocumentSessionError.busy }
                    try await addHighlights(captured)
                } catch { FWMediaUI.show(error, in: view.window) }
            }
        }
    }
    @objc private func addNote() {
        guard state.canEdit, let page = pdfView.currentPage,
              let text = FWMediaUI.fields(title: "添加文字批注", labels: ["批注内容"], values: [""], parse: { values in
                  guard !values[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MediaOperationError.invalidParameter("请输入批注内容。") }
                  return values[0]
              }) else { return }
        let box = page.bounds(for: .cropBox)
        let selection = pdfView.currentSelection?.bounds(for: page)
        let width = min(24, box.width), height = min(24, box.height)
        let x = max(box.minX, min(selection?.minX ?? (box.minX + 20), box.maxX - width))
        let y = max(box.minY, min(selection?.minY ?? (box.maxY - 44), box.maxY - height))
        let pageIndex = currentPageIndex
        Task {
            do { try await addTextAnnotation(pageIndex: pageIndex, bounds: CGRect(x: x, y: y, width: width, height: height), text: text) }
            catch { FWMediaUI.show(error, in: view.window) }
        }
    }
    @objc private func extractPages() {
        guard state.canEdit, let document = pdfView.document,
              let pages = FWMediaUI.fields(title: "提取页面到新文件", labels: ["页码（共 \(document.pageCount) 页），例如 1,3-5"], values: ["1-\(document.pageCount)"],
                                          parse: { try Self.parsePages($0[0], count: document.pageCount) }) else { return }
        let panel = NSSavePanel()
        panel.title = "保存提取的 \(pages.count) 页 · 原文档保持不变"
        panel.allowedContentTypes = [.pdf]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = (path?.deletingPathExtension().lastPathComponent ?? "文档") + "-提取.pdf"
        panel.directoryURL = path?.deletingLastPathComponent()
        let destinationCheck = FWPDFExtractDestination(source: path)
        panel.delegate = destinationCheck
        let response = withExtendedLifetime(destinationCheck) { panel.runModal() }
        guard response == .OK, let destination = panel.url else { return }
        Task {
            do {
                do { try await exportPages(pages, to: destination) }
                catch DocumentIOError.destinationExists {
                    let confirm = NSAlert(); confirm.messageText = "替换提取目标文件？"
                    confirm.informativeText = "仅替换所选目标，当前原文档不变。"; confirm.addButton(withTitle: "取消"); confirm.addButton(withTitle: "替换")
                    guard confirm.runModal() == .alertSecondButtonReturn else { return }
                    try await exportPages(pages, to: destination, overwriteExisting: true)
                }
                status.stringValue = "已提取 \(pages.count) 页到 \(destination.lastPathComponent) · 原文档不变"
            } catch { FWMediaUI.show(error, in: view.window) }
        }
    }
    @objc private func mergeFiles() {
        guard !isBusy, let urls = FWMediaUI.files(title: "选择要追加的 PDF", types: [.pdf]) else { return }
        processing = true; refreshState()
        let limit = state.maximumBytes, existingBytes = state.data.count
        Task {
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    let inputs = try SafeFileIO.openMediaBatch(urls: urls, existingBytes: existingBytes, maximumBytes: limit)
                    return try zip(urls, inputs).map { FWPDFMergeList.Item(url: $0.0, pages: try PDFOperations.read($0.1).pageCount) }
                }.value
                let list = FWPDFMergeList(items: items, existingPages: pdfView.document?.pageCount ?? 0)
                let alert = NSAlert(); alert.messageText = "确认 PDF 合并顺序"
                alert.informativeText = "当前文档保留在首位，以下文件依次追加；可拖动排序或使用上移、下移。"
                alert.addButton(withTitle: "合并"); alert.addButton(withTitle: "取消")
                alert.accessoryView = list
                list.changed = { [weak alert] empty in alert?.buttons.first?.isEnabled = !empty }
                let accepted = alert.runModal() == .alertFirstButtonReturn
                processing = false; refreshState()
                if accepted { try await merge(urls: list.orderedURLs) }
            } catch { processing = false; refreshState(); FWMediaUI.show(error, in: view.window) }
        }
    }
    @objc private func appendImages() {
        guard !isBusy, let urls = FWMediaUI.files(title: "每张图片追加为一页", types: [.png, .jpeg, .heic, .heif]) else { return }
        Task { do { try await appendImages(urls: urls) } catch { FWMediaUI.show(error, in: view.window) } }
    }

    /// 合并/追加在同一事务内检查累计输入和输出；失败不注册撤销，也不替换展示文档。
    func merge(urls: [URL]) async throws {
        let limit = state.maximumBytes
        try await transform(name: "合并 PDF") { data in
            let inputs = try SafeFileIO.openMediaBatch(urls: urls, existingBytes: data.count, maximumBytes: limit)
            return try PDFOperations.merge([data] + inputs)
        }
    }
    func appendImages(urls: [URL]) async throws {
        let limit = state.maximumBytes
        try await transform(name: "添加图片页") { data in
            let inputs = try SafeFileIO.openMediaBatch(urls: urls, existingBytes: data.count, maximumBytes: limit)
            let generated = try PDFOperations.imagesToPDF(inputs)
            guard generated.count <= limit else { throw DocumentIOError.fileTooLarge(limitBytes: limit) }
            return try PDFOperations.merge([data, generated])
        }
    }
    func find() {
        guard canFind else { return }
        _ = view
        searchBar.isHidden = false; searchField.selectText(nil)
        scheduleSearch()
    }

    func controlTextDidChange(_ notification: Notification) { scheduleSearch() }
    private func scheduleSearch() {
        searchTask?.cancel(); pdfView.document?.cancelFindString(); searching = false
        matches = []; matchIndex = nil; pdfView.highlightedSelections = nil
        updateSearchControls()
        let term = searchField.stringValue
        guard !searchBar.isHidden, !term.isEmpty else { return }
        searchCount.stringValue = "等待查找…"
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !self.state.isClosed, self.searchField.stringValue == term else { return }
            self.searching = true; self.updateSearchControls()
            self.pdfView.document?.beginFindString(term, withOptions: .caseInsensitive)
        }
    }
    func didMatchString(_ instance: PDFSelection) {
        guard searching, !searchBar.isHidden else { return }
        matches.append(instance)
    }
    func documentDidEndDocumentFind(_ notification: Notification) {
        guard notification.object as? PDFDocument === pdfView.document, searching else { return }
        searching = false
        if !matches.isEmpty { matchIndex = 0; showSearchMatch() }
        updateSearchControls()
    }
    @objc private func nextSearchMatch() { moveSearchMatch(1) }
    @objc private func previousSearchMatch() { moveSearchMatch(-1) }
    private func moveSearchMatch(_ offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = ((matchIndex ?? 0) + offset + matches.count) % matches.count
        showSearchMatch(); updateSearchControls()
    }
    private func showSearchMatch() {
        guard let index = matchIndex else { return }
        pdfView.setCurrentSelection(matches[index], animate: true); pdfView.go(to: matches[index])
    }
    private func updateSearchControls() {
        searchCount.stringValue = searching ? "正在查找…" : searchField.stringValue.isEmpty ? "输入查找内容" : matches.isEmpty ? "未找到" : "\((matchIndex ?? 0) + 1) / \(matches.count)"
        previousMatch.isEnabled = !searching && !matches.isEmpty; nextMatch.isEnabled = previousMatch.isEnabled
    }
    @discardableResult func dismissFind() -> Bool {
        guard !searchBar.isHidden else { return false }
        searchTask?.cancel(); pdfView.document?.cancelFindString(); searching = false
        searchBar.isHidden = true; matches = []; matchIndex = nil; pdfView.clearSelection()
        view.window?.makeFirstResponder(pdfView)
        return true
    }
    @objc private func closeSearch() { dismissFind() }

    /// 提取仅写入独立目标，源缓冲区、保存基线和撤销历史均不推进。
    func exportPages(_ pages: [Int], to destination: URL, overwriteExisting: Bool = false) async throws {
        try FWPDFExtractDestination.validate(destination, source: path)
        try FWMediaUI.requireExtension(destination, allowed: ["pdf"])
        try state.requireIdle()
        guard !processing else { throw DocumentSessionError.busy }
        processing = true; refreshState()
        defer { processing = false; refreshState() }
        let source = state.data, limit = state.maximumBytes
        try await Task.detached(priority: .userInitiated) {
            let extracted = try PDFOperations.extract(source, pageIndexes: pages)
            _ = try SafeFileIO.save(extracted, previous: nil, to: destination, maximumBytes: limit, overwriteExternalChanges: overwriteExisting)
        }.value
    }

    private var currentPageIndex: Int {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return 0 }
        return document.index(for: page)
    }
    private func install(_ data: Data, name: String) throws {
        guard !processing else { throw DocumentSessionError.busy }
        let document = try PDFOperations.read(data)
        let previous = state.data
        try state.replace(data)
        registerUndo(previous, name: name)
        // 验证已生成展示文档，安装时复用，避免撤销/重做连续解析同一份完整 PDF。
        if isViewLoaded { refreshPDF(prepared: document) }
    }
    private func registerUndo(_ data: Data, name: String) {
        history.register(bytes: data.count, name: name) { [weak self] in
            self?.perform { try self?.install(data, name: name) }
        }
    }
    private func transform(name: String, allowDuringSave: Bool = false, operation: @escaping @Sendable (Data) throws -> Data) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        processing = true
        defer { processing = false; refreshState() }
        let previous = state.data
        // PDF 的解析、页修改与整份序列化在后台完成；仅结果安装和 PDFView 更新回主线程。
        let _: Bool = try await state.transformWithResult(allowDuringSave: allowDuringSave) { (try operation($0), true) }
        registerUndo(previous, name: name)
        if isViewLoaded { refreshPDF() }
    }
    private func refreshPDF(prepared: PDFDocument? = nil) {
        let previousPage = currentPageIndex
        guard let document = prepared ?? (try? PDFOperations.read(state.data)) else { return }
        // 展示文档与保存缓冲区分离。禁用 PDFView 自带表单/批注编辑，避免绕过撤销与脏状态追踪；这些显示标记不会保存。
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                annotation.isReadOnly = true
                let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
                annotation.setValue(NSNumber(value: flags | 64 | 128), forAnnotationKey: .flags)
            }
        }
        pdfView.document?.cancelFindString(); pdfView.document?.delegate = nil
        pdfView.document = document; document.delegate = self
        if let page = document.page(at: min(previousPage, document.pageCount - 1)) { pdfView.go(to: page) }
        refreshState()
        if !searchBar.isHidden { scheduleSearch() }
    }
    private func refreshState() {
        for button in editButtons { button.isEnabled = state.canEdit && !isBusy }
        status.stringValue = "PDF · \(pdfView.document?.pageCount ?? 0) 页 · 支持批注与页面处理" + (isBusy ? " · 正在处理…" : "")
        onStateChanged?()
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { FWMediaUI.show(error, in: view.window) }
    }
    private static func parsePages(_ text: String, count: Int) throws -> [Int] {
        var result: [Int] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count), let start = Int(bounds[0]), start > 0, start <= count,
                  let end = Int(bounds.last!), end >= start, end <= count else {
                throw MediaOperationError.invalidParameter("页码须在 1 到 \(count) 之间，可使用逗号与连续范围。")
            }
            result.append(contentsOf: (start...end).map { $0 - 1 })
        }
        guard Set(result).count == result.count else { throw MediaOperationError.invalidParameter("页码不能重复。") }
        return result
    }
}

/// 系统保存面板保留无效目标及用户输入，选择原路径时不会先关闭面板再报错。
@MainActor
final class FWPDFExtractDestination: NSObject, NSOpenSavePanelDelegate {
    let source: URL?
    init(source: URL?) { self.source = source }
    static func validate(_ url: URL, source: URL?) throws {
        guard url.standardizedFileURL != source?.standardizedFileURL else {
            throw MediaOperationError.invalidParameter("请选择新文件位置，提取不会覆盖当前原文档。")
        }
    }
    func panel(_ sender: Any, validate url: URL) throws { try Self.validate(url, source: source) }
}

/// 合并队列只调整待追加文件顺序；真正读取和提交仍由原有受预算约束的 merge 流程完成。
@MainActor
final class FWPDFMergeList: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    struct Item: Sendable { let url: URL; let pages: Int }
    private(set) var items: [Item]
    let table = NSTableView()
    private let total = NSTextField(labelWithString: "")
    private let existingPages: Int
    var changed: ((Bool) -> Void)?
    var orderedURLs: [URL] { items.map(\.url) }
    private let dragType = NSPasteboard.PasteboardType("local.filedeck.pdf-merge-row")
    init(items: [Item], existingPages: Int) {
        self.items = items; self.existingPages = existingPages
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 290))
        orientation = .vertical; alignment = .leading; spacing = 8
        let column = NSTableColumn(identifier: .init("file")); column.width = 500
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 44
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        table.registerForDraggedTypes([dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        table.frame = NSRect(x: 0, y: 0, width: 500, height: items.count * 44); table.autoresizingMask = [.width]
        addArrangedSubview(scroll)
        let controls = NSStackView()
        for (title, action) in [("上移", #selector(moveItemUp)), ("下移", #selector(moveItemDown)), ("移除", #selector(removeSelected))] { controls.addArrangedSubview(NSButton(title: title, target: self, action: action)) }
        controls.addArrangedSubview(total); addArrangedSubview(controls)
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let name = NSTextField(labelWithString: "\(row + 1). \(item.url.lastPathComponent) · \(item.pages) 页")
        let path = NSTextField(labelWithString: item.url.path); path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor
        for field in [name, path] { field.lineBreakMode = .byTruncatingMiddle; field.toolTip = field.stringValue; field.widthAnchor.constraint(equalToConstant: 495).isActive = true }
        let stack = NSStackView(views: [name, path]); stack.orientation = .vertical; stack.alignment = .leading
        return stack
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let value = NSPasteboardItem(); value.setString(String(row), forType: dragType); return value
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        (info.draggingSource as? NSTableView) === table && operation == .above ? .move : []
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard (info.draggingSource as? NSTableView) === table, let value = info.draggingPasteboard.string(forType: dragType),
              let source = Int(value), items.indices.contains(source), (0...items.count).contains(row) else { return false }
        let item = items.remove(at: source), destination = row > source ? row - 1 : row
        items.insert(item, at: destination); update(selection: destination); return true
    }
    @objc private func moveItemUp() { moveSelected(-1) }
    @objc private func moveItemDown() { moveSelected(1) }
    private func moveSelected(_ offset: Int) {
        let row = table.selectedRow
        guard items.indices.contains(row), items.indices.contains(row + offset) else { return }
        items.swapAt(row, row + offset); update(selection: row + offset)
    }
    @objc private func removeSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        items.remove(at: row); update(selection: min(row, items.count - 1))
    }
    private func update(selection: Int = 0) {
        table.reloadData()
        if items.indices.contains(selection) { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        total.stringValue = "当前 \(existingPages) 页 + 追加 \(items.reduce(0) { $0 + $1.pages }) 页"
        changed?(items.isEmpty)
    }
}
