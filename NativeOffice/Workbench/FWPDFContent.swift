import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class FWPDFContent: NSViewController, FWNativeContent {
    let id = UUID()
    let kind = WorkbenchFileKind.pdf
    var controller: NSViewController { self }
    var contentTitle: String { path?.lastPathComponent ?? "未命名 PDF" }
    var path: URL? { state.path }
    var isModified: Bool { state.isModified }
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
        toolbar.spacing = 8
        for (name, selector) in [("旋转本页", #selector(rotateCurrentPage)), ("高亮选中文字", #selector(highlightSelection)),
                                 ("文字批注", #selector(addNote)), ("合并 PDF", #selector(mergeFiles)),
                                 ("提取页面", #selector(extractPages)), ("添加图片页", #selector(appendImages))] {
            let button = NSButton(title: name, target: self, action: selector)
            editButtons.append(button)
            toolbar.addArrangedSubview(button)
        }
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        view = FWMediaUI.layout(toolbar: toolbar, body: pdfView, status: status)
        refreshPDF()
    }

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
    }
    func undo() { if canUndo { history.undo() } }
    func redo() { if canRedo { history.redo() } }

    /// 供工具栏和会话回归共用；页码始终使用从 0 开始的 PDF 模型索引。
    func rotate(pageIndexes: [Int]) throws {
        try install(PDFOperations.rotate(state.data, pageIndexes: pageIndexes), name: "旋转页面")
    }
    func extract(pageIndexes: [Int]) throws {
        try install(PDFOperations.extract(state.data, pageIndexes: pageIndexes), name: "提取页面")
    }
    func addTextAnnotation(pageIndex: Int, bounds: CGRect, text: String) throws {
        try install(PDFOperations.addTextAnnotation(state.data, pageIndex: pageIndex, bounds: bounds, text: text), name: "文字批注")
    }
    func addHighlight(pageIndex: Int, bounds: CGRect) throws {
        try install(PDFOperations.addHighlight(state.data, pageIndex: pageIndex, bounds: bounds), name: "高亮文字")
    }
    func addHighlights(_ highlights: [PDFOperations.Highlight]) async throws {
        try await transform(name: "高亮文字") { try PDFOperations.addHighlights($0, highlights: highlights) }
    }

    @objc private func rotateCurrentPage() {
        perform { try rotate(pageIndexes: [currentPageIndex]) }
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
              let input = FWMediaUI.fields(title: "添加文字批注", labels: ["批注内容"], values: [""]) else { return }
        perform {
            let box = page.bounds(for: .cropBox)
            let selection = pdfView.currentSelection?.bounds(for: page)
            let width = min(24, box.width), height = min(24, box.height)
            let x = max(box.minX, min(selection?.minX ?? (box.minX + 20), box.maxX - width))
            let y = max(box.minY, min(selection?.minY ?? (box.maxY - 44), box.maxY - height))
            try addTextAnnotation(pageIndex: currentPageIndex, bounds: CGRect(x: x, y: y, width: width, height: height), text: input[0])
        }
    }
    @objc private func extractPages() {
        guard state.canEdit, let document = pdfView.document,
              let input = FWMediaUI.fields(title: "提取页面到当前标签（另存为可保留原文件）", labels: ["页码，例如 1,3-5"], values: ["1-\(document.pageCount)"]) else { return }
        perform { try extract(pageIndexes: Self.parsePages(input[0], count: document.pageCount)) }
    }
    @objc private func mergeFiles() {
        guard !isBusy, let urls = FWMediaUI.files(title: "选择要追加的 PDF", types: [.pdf]) else { return }
        Task { do { try await merge(urls: urls) } catch { FWMediaUI.show(error, in: view.window) } }
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
        guard let values = FWMediaUI.fields(title: "查找 PDF 文字", labels: ["查找内容"], values: [""]), !values[0].isEmpty,
              let selection = pdfView.document?.findString(values[0], withOptions: .caseInsensitive).first else { return }
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }

    private var currentPageIndex: Int {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return 0 }
        return document.index(for: page)
    }
    private func install(_ data: Data, name: String) throws {
        guard !processing else { throw DocumentSessionError.busy }
        _ = try PDFOperations.read(data)
        let previous = state.data
        try state.replace(data)
        registerUndo(previous, name: name)
        if isViewLoaded { refreshPDF() }
    }
    private func registerUndo(_ data: Data, name: String) {
        history.register(bytes: data.count, name: name) { [weak self] in
            self?.perform { try self?.install(data, name: name) }
        }
    }
    private func transform(name: String, operation: @escaping @Sendable (Data) throws -> Data) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        processing = true
        defer { processing = false; refreshState() }
        let previous = state.data
        try await state.transform(operation)
        registerUndo(previous, name: name)
        if isViewLoaded { refreshPDF() }
    }
    private func refreshPDF() {
        let previousPage = currentPageIndex
        guard let document = try? PDFOperations.read(state.data) else { return }
        // 展示文档与保存缓冲区分离。禁用 PDFView 自带表单/批注编辑，避免绕过撤销与脏状态追踪；这些显示标记不会保存。
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                annotation.isReadOnly = true
                let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
                annotation.setValue(NSNumber(value: flags | 64 | 128), forAnnotationKey: .flags)
            }
        }
        pdfView.document = document
        if let page = document.page(at: min(previousPage, document.pageCount - 1)) { pdfView.go(to: page) }
        refreshState()
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
