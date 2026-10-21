import AppKit

@MainActor
final class FWCSVContent: NSViewController, FWNativeContent, NSTableViewDataSource, NSTableViewDelegate {
    let id = UUID()
    let kind = WorkbenchFileKind.csv
    var controller: NSViewController { self }
    var contentTitle: String { path?.lastPathComponent ?? "未命名 CSV" }
    var path: URL? { document.sourceURL }
    var isReadOnly: Bool { document.isReadOnly }
    var isBusy: Bool { work != nil }
    var isModified: Bool { !document.text.utf8.elementsEqual(savedText.utf8) || selectedEncoding != savedEncoding }
    var onStateChanged: (() -> Void)?
    var availableOperations: Set<FileOperation> {
        guard !closed, work != .reloading else { return [] }
        var result: Set<FileOperation> = [.open]
        if canEdit { result.insert(.edit) }
        if !isBusy { result.insert(.saveAs); if !isReadOnly { result.insert(.save) } }
        return result
    }
    private enum Work { case saving, reloading }
    private struct Snapshot { let model: CSVDocument; let text: String; let encoding: TextFileEncoding }
    private var document: TextFileDocument
    private var model: CSVDocument
    private var savedText: String
    private var savedEncoding: TextFileEncoding
    private var selectedEncoding: TextFileEncoding
    private var work: Work?
    private var closed = false
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let delimiterPopup = NSPopUpButton()
    private let encodingPopup = NSPopUpButton()
    private var editButtons: [NSButton] = []
    private let history = UndoManager()
    private static let encodings: [TextFileEncoding] = [.utf8(bom: false), .utf8(bom: true), .utf16LittleEndian, .utf16BigEndian, .gb18030]
    private var canEdit: Bool { !closed && !isReadOnly && work != .reloading }
    override var undoManager: UndoManager? { history }

    private init(document: TextFileDocument, model: CSVDocument) {
        self.document = document
        self.model = model
        savedText = document.text
        savedEncoding = document.encoding
        selectedEncoding = document.encoding
        super.init(nibName: nil, bundle: nil)
        history.levelsOfUndo = 12
    }
    required init?(coder: NSCoder) { fatalError("请使用 open(url:) 或 create()") }

    static func create() throws -> FWCSVContent {
        try FWCSVContent(document: DocumentIO.create(), model: CSVDocument())
    }
    static func open(url: URL) async throws -> FWCSVContent {
        do { return try await open(url: url, encoding: nil, delimiter: .comma) }
        catch {
            // 编码或分隔符错误时让用户明确指定重试；文件权限、大小等问题直接交给统一错误界面。
            let configurable: Bool
            if error is CSVDocumentError { configurable = true }
            else if let error = error as? DocumentIOError {
                switch error { case .unknownEncoding, .binaryContent: configurable = true; default: configurable = false }
            } else { configurable = false }
            guard configurable else { throw error }
            let alert = NSAlert()
            alert.messageText = "选择 CSV 读取方式"
            alert.informativeText = error.localizedDescription + "\n请选择读取编码和分隔符后重试。"
            alert.addButton(withTitle: "重新读取")
            alert.addButton(withTitle: "取消")
            let encoding = NSPopUpButton(frame: NSRect(x: 0, y: 40, width: 240, height: 28))
            encoding.addItems(withTitles: encodings.map(\.name))
            let delimiter = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
            delimiter.addItems(withTitles: ["逗号 ,", "分号 ;", "制表符 Tab"])
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
            accessory.addSubview(encoding); accessory.addSubview(delimiter)
            alert.accessoryView = accessory
            guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
            return try await open(url: url, encoding: encodings[encoding.indexOfSelectedItem], delimiter: CSVDelimiter.allCases[delimiter.indexOfSelectedItem])
        }
    }
    static func open(url: URL, encoding: TextFileEncoding?, delimiter: CSVDelimiter) async throws -> FWCSVContent {
        let loaded = try await Task.detached(priority: .userInitiated) {
            let document = try DocumentIO.open(url: url, encoding: encoding)
            return (document, try CSVDocument(text: document.text, delimiter: delimiter))
        }.value
        return FWCSVContent(document: loaded.0, model: loaded.1)
    }

    override func loadView() {
        let actions = NSStackView()
        actions.spacing = 8
        for (name, selector) in [("添加行", #selector(addRow)), ("删除行", #selector(removeRow)),
                                 ("添加列", #selector(addColumn)), ("删除列", #selector(removeColumn)),
                                 ("编辑单元格", #selector(editSelectedCell))] {
            let button = NSButton(title: name, target: self, action: selector)
            editButtons.append(button); actions.addArrangedSubview(button)
        }
        delimiterPopup.addItems(withTitles: ["逗号 ,", "分号 ;", "制表符 Tab"])
        delimiterPopup.target = self; delimiterPopup.action = #selector(changeDelimiter)
        delimiterPopup.toolTip = "按选定分隔符重新解析当前文本，不自动转换文件。"
        encodingPopup.addItems(withTitles: Self.encodings.map(\.name))
        encodingPopup.target = self; encodingPopup.action = #selector(changeEncoding)
        let settings = NSStackView(views: [NSTextField(labelWithString: "分隔符"), delimiterPopup,
                                          NSTextField(labelWithString: "保存编码"), encodingPopup,
                                          NSButton(title: "按此编码重新读取", target: self, action: #selector(redecode))])
        let toolbar = NSStackView(views: [actions, settings])
        toolbar.orientation = .vertical; toolbar.alignment = .leading; toolbar.spacing = 6
        table.dataSource = self; table.delegate = self
        table.allowsColumnSelection = true
        table.allowsMultipleSelection = false
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 25
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.documentView = table
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        view = FWMediaUI.layout(toolbar: toolbar, body: scroll, status: status)
        refreshTable()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.rowCount }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), model.rows.indices.contains(row),
              model.rows[row].indices.contains(column) else { return nil }
        return model.rows[row][column]
    }
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { canEdit }
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), let text = object as? String else { return }
        perform { try setCell(text, row: row, column: column) }
    }

    func setCell(_ text: String, row: Int, column: Int) throws {
        guard model.rows.indices.contains(row), model.rows[row].indices.contains(column) else { throw CSVDocumentError.indexOutOfRange }
        // 仅结束编辑而未改动值时，不把原文可选引号规范化成另一份 CSV。
        guard !model.rows[row][column].utf8.elementsEqual(text.utf8) else { return }
        try mutate(name: "编辑单元格") { try $0.setCell(text, row: row, column: column) }
    }
    func appendRow() throws { try mutate(name: "添加行") { try $0.appendRow() } }
    func appendColumn() throws { try mutate(name: "添加列") { try $0.appendColumn() } }
    func save(overwriteExternalChanges: Bool) async throws {
        guard path != nil else { throw DocumentIOError.saveLocationRequired }
        try await persist(to: nil, overwrite: overwriteExternalChanges)
    }
    func saveAs(to destination: URL, overwriteExternalChanges: Bool) async throws {
        try FWMediaUI.requireExtension(destination, allowed: ["csv", "tsv"])
        try await persist(to: destination, overwrite: overwriteExternalChanges)
    }
    func export(to destination: URL, format: WorkbenchFileKind, overwriteExisting: Bool) async throws {
        try requireIdle(); throw DocumentSessionError.unsupportedOperation(.export)
    }
    func reload(discardChanges: Bool) async throws {
        try await reload(discardChanges: discardChanges, encoding: document.encoding)
    }
    func close(discardChanges: Bool) async throws {
        if closed { return }
        try requireIdle()
        try commitCellEditor()
        guard !isModified || discardChanges else { throw DocumentSessionError.unsavedChanges }
        closed = true; refreshState()
    }
    func undo() { if canEdit { history.undo() } }
    func redo() { if canEdit { history.redo() } }

    private func persist(to destination: URL?, overwrite: Bool) async throws {
        try requireIdle()
        try commitCellEditor()
        let snapshot = document
        let outputEncoding = selectedEncoding
        work = .saving; refreshState()
        defer { work = nil; refreshState() }
        let saved = try await Task.detached(priority: .userInitiated) {
            try DocumentIO.save(snapshot, to: destination,
                                encoding: outputEncoding == snapshot.encoding ? nil : outputEncoding,
                                overwriteExternalChanges: overwrite)
        }.value
        // 推进磁盘指纹和保存基线，但保留异步写入期间的新单元格与编码选择。
        let currentText = document.text
        document = saved; document.text = currentText
        savedText = saved.text; savedEncoding = outputEncoding
    }
    private func reload(discardChanges: Bool, encoding: TextFileEncoding) async throws {
        try requireIdle()
        try commitCellEditor()
        guard !isModified || discardChanges else { throw DocumentSessionError.unsavedChanges }
        guard let path else { throw DocumentSessionError.noFileToReload }
        let delimiter = model.delimiter
        work = .reloading; refreshState()
        defer { work = nil; refreshState() }
        let loaded = try await Task.detached(priority: .userInitiated) {
            let document = try DocumentIO.open(url: path, encoding: encoding)
            return (document, try CSVDocument(text: document.text, delimiter: delimiter))
        }.value
        document = loaded.0; model = loaded.1; savedText = document.text
        savedEncoding = document.encoding; selectedEncoding = document.encoding
        history.removeAllActions(); refreshTable()
    }
    private func mutate(name: String, operation: (inout CSVDocument) throws -> Void) throws {
        try requireEditable()
        var next = model
        try operation(&next)
        let text = try next.serialize()
        guard !text.utf8.elementsEqual(document.text.utf8) else { return }
        try install(Snapshot(model: next, text: text, encoding: selectedEncoding), name: name)
    }
    private func install(_ snapshot: Snapshot, name: String) throws {
        try requireEditable()
        let previous = Snapshot(model: model, text: document.text, encoding: selectedEncoding)
        model = snapshot.model; document.text = snapshot.text; selectedEncoding = snapshot.encoding
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.perform { try target.install(previous, name: name) } }
        }
        history.setActionName(name)
        refreshTable()
    }
    private func commitCellEditor() throws {
        if isViewLoaded, let window = view.window, !window.makeFirstResponder(nil) {
            throw MediaOperationError.invalidParameter("请先完成当前单元格编辑。")
        }
    }
    private func requireIdle() throws {
        guard !closed else { throw DocumentSessionError.closed }
        guard !isBusy else { throw DocumentSessionError.busy }
    }
    private func requireEditable() throws {
        guard !closed else { throw DocumentSessionError.closed }
        guard work != .reloading else { throw DocumentSessionError.busy }
        if isReadOnly, let path { throw DocumentIOError.readOnly(path) }
    }
    @objc private func addRow() { perform { try commitCellEditor(); try appendRow() } }
    @objc private func addColumn() { perform { try commitCellEditor(); try appendColumn() } }
    @objc private func removeRow() {
        perform { try commitCellEditor(); try mutate(name: "删除行") { try $0.deleteRow(at: table.selectedRow >= 0 ? table.selectedRow : model.rowCount - 1) } }
    }
    @objc private func removeColumn() {
        perform { try commitCellEditor(); try mutate(name: "删除列") { try $0.deleteColumn(at: table.selectedColumn >= 0 ? table.selectedColumn : model.columnCount - 1) } }
    }
    @objc private func changeDelimiter() {
        perform {
            try commitCellEditor()
            let delimiter = CSVDelimiter.allCases[delimiterPopup.indexOfSelectedItem]
            let next = try CSVDocument(text: document.text, delimiter: delimiter)
            try install(Snapshot(model: next, text: document.text, encoding: selectedEncoding), name: "切换分隔符")
        }
        refreshState()
    }
    @objc private func changeEncoding() {
        perform { try install(Snapshot(model: model, text: document.text, encoding: Self.encodings[encodingPopup.indexOfSelectedItem]), name: "选择保存编码") }
        refreshState()
    }
    @objc private func redecode() {
        guard !isBusy, path != nil else { return }
        perform { try commitCellEditor() }
        guard !isModified || FWMediaUI.confirmDiscard() else { return }
        let encoding = selectedEncoding
        Task { @MainActor in
            do { try await reload(discardChanges: true, encoding: encoding) }
            catch { FWMediaUI.show(error, in: view.window) }
        }
    }
    @objc private func editSelectedCell() {
        guard canEdit else { return }
        perform {
            try commitCellEditor()
            let row = max(0, table.selectedRow), column = max(0, table.selectedColumn)
            guard row < model.rowCount, column < model.columnCount else { throw CSVDocumentError.indexOutOfRange }
            let alert = NSAlert()
            alert.messageText = "编辑第 \(row + 1) 行、第 \(column + 1) 列（支持换行）"
            alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
            editor.isRichText = false; editor.string = model.rows[row][column]
            let scroll = NSScrollView(frame: editor.frame)
            scroll.hasVerticalScroller = true; scroll.documentView = editor
            alert.accessoryView = scroll
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try setCell(editor.string, row: row, column: column)
        }
    }
    private func refreshTable() {
        guard isViewLoaded else { refreshState(); return }
        if table.tableColumns.count != model.columnCount {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for index in 0..<model.columnCount {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = "列 \(index + 1)"; column.width = 160; column.minWidth = 60
                column.isEditable = true
                table.addTableColumn(column)
            }
        }
        table.reloadData(); refreshState()
    }
    private func refreshState() {
        for button in editButtons { button.isEnabled = canEdit }
        delimiterPopup.isEnabled = canEdit; encodingPopup.isEnabled = canEdit
        delimiterPopup.selectItem(at: CSVDelimiter.allCases.firstIndex(of: model.delimiter) ?? 0)
        encodingPopup.selectItem(at: Self.encodings.firstIndex(of: selectedEncoding) ?? 0)
        status.stringValue = "\(model.rowCount) 行 × \(model.columnCount) 列 · \(selectedEncoding.name) · \(model.preferredLineEnding == .crlf ? "CRLF" : model.preferredLineEnding == .cr ? "CR" : "LF")" + (isBusy ? " · 正在处理…" : "")
        onStateChanged?()
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { FWMediaUI.show(error, in: view.window); if isViewLoaded { table.reloadData() } }
    }
}
