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
    var canUndo: Bool { canEdit && !isBusy && history.canUndo }
    var canRedo: Bool { canEdit && !isBusy && history.canRedo }
    var isModified: Bool { recoveredUnsaved || textModified || selectedEncoding != savedEncoding }
    var onStateChanged: (() -> Void)?
    var availableOperations: Set<FileOperation> {
        guard !closed, work != .reloading else { return [] }
        var result: Set<FileOperation> = [.open]
        if canEdit { result.insert(.edit) }
        if !isBusy { result.insert(.saveAs); if !isReadOnly { result.insert(.save) } }
        return result
    }
    private enum Work { case saving, reloading }
    private struct Snapshot { let model: CSVDocument; let originalText: String?; let encoding: TextFileEncoding }
    private var document: TextFileDocument
    private var model: CSVDocument
    private var savedText: String
    // nil 表示正文由当前表格按既有规则生成；未修改原文仍保留可选引号等原始字节。
    private var originalText: String?
    private var recoveredUnsaved = false
    private var textModified = false
    private var savedSignature: CSVDocument.SerializationSignature?
    private var revision: UInt64 = 0
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
        originalText = document.text
        savedSignature = model.serializationSignature
        savedEncoding = document.encoding
        selectedEncoding = document.encoding
        super.init(nibName: nil, bundle: nil)
        history.levelsOfUndo = 12
    }
    required init?(coder: NSCoder) { fatalError("请使用 open(url:) 或 create()") }

    var recoveryCapture: DraftRecoveryCapture? {
        guard !closed, isModified else { return nil }
        return DraftRecoveryCapture(kind: kind, originalURL: path, title: contentTitle,
                                    body: .csv(model, original: originalText, encoding: selectedEncoding))
    }
    static func recover(_ draft: DraftRecoveryDocument) throws -> FWCSVContent {
        guard let text = String(data: draft.data, encoding: .utf8), let encoding = draft.header.encoding,
              let raw = draft.header.delimiter, let delimiter = CSVDelimiter(rawValue: raw) else { throw DraftRecoveryError.invalidRecord }
        let document = DocumentIO.create(text: text, encoding: encoding)
        let content = try FWCSVContent(document: document, model: CSVDocument(text: text, delimiter: delimiter))
        content.recoveredUnsaved = true
        return content
    }

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
    func tableViewSelectionDidChange(_ notification: Notification) { refreshState() }
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), let text = object as? String else { return }
        perform { try setCell(text, row: row, column: column) }
    }

    func setCell(_ text: String, row: Int, column: Int) throws {
        guard model.rows.indices.contains(row), model.rows[row].indices.contains(column) else { throw CSVDocumentError.indexOutOfRange }
        // 仅结束编辑而未改动值时，不把原文可选引号规范化成另一份 CSV。
        guard !model.rows[row][column].utf8.elementsEqual(text.utf8) else { return }
        let before = try model.cellSnapshot(row: row, column: column)
        try installCell(CSVDocument.CellSnapshot(row: row, column: column, value: text,
                                                 fieldCount: max(before.fieldCount, column + 1)),
                        originalText: nil, name: "编辑单元格")
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
    func undo() { if canUndo { history.undo() } }
    func redo() { if canRedo { history.redo() } }

    private func persist(to destination: URL?, overwrite: Bool) async throws {
        try requireIdle()
        try commitCellEditor()
        let snapshot = document
        let snapshotModel = model
        let snapshotOriginal = originalText
        let snapshotRevision = revision
        let outputEncoding = selectedEncoding
        work = .saving; refreshState()
        defer { work = nil; refreshState() }
        let saved = try await Task.detached(priority: .userInitiated) {
            var output = snapshot
            output.text = try snapshotOriginal ?? snapshotModel.serialize()
            return try DocumentIO.save(output, to: destination,
                                encoding: outputEncoding == snapshot.encoding ? nil : outputEncoding,
                                overwriteExternalChanges: overwrite)
        }.value
        // 推进磁盘指纹和保存基线，但保留异步写入期间的新单元格与编码选择。
        document = saved
        recoveredUnsaved = false
        savedText = saved.text; savedEncoding = outputEncoding
        savedSignature = model.delimiter == snapshotModel.delimiter ? snapshotModel.serializationSignature
            : (try? CSVDocument(text: savedText, delimiter: model.delimiter))?.serializationSignature
        if revision == snapshotRevision { textModified = false }
        else { updateModifiedState() }
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
        recoveredUnsaved = false
        document = loaded.0; model = loaded.1; savedText = document.text; originalText = document.text
        savedSignature = model.serializationSignature; textModified = false; revision &+= 1
        savedEncoding = document.encoding; selectedEncoding = document.encoding
        history.removeAllActions(); refreshTable()
    }
    private func mutate(name: String, operation: (inout CSVDocument) throws -> Void) throws {
        try requireEditable()
        var next = model
        try operation(&next)
        guard next != model else { return }
        try install(Snapshot(model: next, originalText: nil, encoding: selectedEncoding), name: name)
    }
    private func install(_ snapshot: Snapshot, name: String) throws {
        try requireEditable()
        let previous = Snapshot(model: model, originalText: originalText, encoding: selectedEncoding)
        let previousDelimiter = model.delimiter
        model = snapshot.model; originalText = snapshot.originalText; selectedEncoding = snapshot.encoding
        if previousDelimiter != model.delimiter {
            savedSignature = (try? CSVDocument(text: savedText, delimiter: model.delimiter))?.serializationSignature
        }
        revision &+= 1
        updateModifiedState()
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.perform { try target.install(previous, name: name) } }
        }
        history.setActionName(name)
        refreshTable()
    }

    /// 单格撤销只保存单元格值与短行字段数，不让每次编辑持有整张表并触发顶层数组复制。
    private func installCell(_ cell: CSVDocument.CellSnapshot, originalText restoredText: String?, name: String) throws {
        try requireEditable()
        let previous = try model.cellSnapshot(row: cell.row, column: cell.column)
        let previousOriginal = originalText
        try model.restoreCell(cell)
        originalText = restoredText
        revision &+= 1
        updateModifiedState()
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.perform { try target.installCell(previous, originalText: previousOriginal, name: name) } }
        }
        history.setActionName(name)
        if isViewLoaded {
            table.reloadData(forRowIndexes: IndexSet(integer: cell.row), columnIndexes: IndexSet(integer: cell.column))
        }
        refreshState()
    }

    private func currentText() throws -> String { try originalText ?? model.serialize() }

    private func updateModifiedState() {
        if let originalText { textModified = !originalText.utf8.elementsEqual(savedText.utf8) }
        else if model.serializationSignature != savedSignature { textModified = true }
        else {
            // 快速签名只能证明不同；碰撞或用户改回原值时，必须逐字节确认才能清除 dirty。
            let text = try? model.serialize()
            textModified = !(text?.utf8.elementsEqual(savedText.utf8) ?? false)
        }
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
        // 没有明确目标时不猜测最后一行；即使 action 被程序调用也遵守与按钮相同的门禁。
        let row = table.selectedRow
        guard canEdit, model.rows.indices.contains(row) else { return }
        perform { try commitCellEditor(); try mutate(name: "删除行") { try $0.deleteRow(at: row) } }
    }
    @objc private func removeColumn() {
        let column = table.selectedColumn
        guard canEdit, column >= 0, column < model.columnCount else { return }
        perform { try commitCellEditor(); try mutate(name: "删除列") { try $0.deleteColumn(at: column) } }
    }
    @objc private func changeDelimiter() {
        perform {
            try commitCellEditor()
            let delimiter = CSVDelimiter.allCases[delimiterPopup.indexOfSelectedItem]
            let text = try currentText()
            let next = try CSVDocument(text: text, delimiter: delimiter)
            try install(Snapshot(model: next, originalText: text, encoding: selectedEncoding), name: "切换分隔符")
        }
        refreshState()
    }
    @objc private func changeEncoding() {
        perform { try install(Snapshot(model: model, originalText: originalText, encoding: Self.encodings[encodingPopup.indexOfSelectedItem]), name: "选择保存编码") }
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
        for button in editButtons {
            button.isEnabled = canEdit
            if button.action == #selector(removeRow) {
                button.isEnabled = canEdit && model.rows.indices.contains(table.selectedRow)
                button.toolTip = button.isEnabled ? "删除第 \(table.selectedRow + 1) 行" : "请先选择要删除的行"
            } else if button.action == #selector(removeColumn) {
                button.isEnabled = canEdit && table.selectedColumn >= 0 && table.selectedColumn < model.columnCount
                button.toolTip = button.isEnabled ? "删除第 \(table.selectedColumn + 1) 列" : "请先选择要删除的列"
            }
        }
        delimiterPopup.isEnabled = canEdit; encodingPopup.isEnabled = canEdit
        delimiterPopup.selectItem(at: CSVDelimiter.allCases.firstIndex(of: model.delimiter) ?? 0)
        encodingPopup.selectItem(at: Self.encodings.firstIndex(of: selectedEncoding) ?? 0)
        status.stringValue = "\(model.rowCount) 行 × \(model.columnCount) 列 · \(selectedEncoding.name) · \(model.preferredLineEnding == .crlf ? "CRLF" : model.preferredLineEnding == .cr ? "CR" : "LF")" + (isBusy ? " · 正在处理…" : "")
        if table.selectedRow >= 0 { status.stringValue += " · 已选第 \(table.selectedRow + 1) 行" }
        if table.selectedColumn >= 0 { status.stringValue += " · 已选第 \(table.selectedColumn + 1) 列" }
        onStateChanged?()
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { FWMediaUI.show(error, in: view.window); if isViewLoaded { table.reloadData() } }
    }
}
