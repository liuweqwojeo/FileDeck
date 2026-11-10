import Foundation

@MainActor
final class TextDocumentSession: DocumentSession {
    struct Edit {
        let from: Int
        let to: Int
        let text: String
    }
    enum EditError: Error { case invalidRange }

    /// 保持实际文件 I/O 可替换，便于确定性验证保存期间的编辑；正式实现始终使用完整 DocumentIO。
    struct Storage: Sendable {
        let open: @Sendable (URL, TextFileEncoding?) async throws -> TextFileDocument
        let save: @Sendable (TextFileDocument, URL?, Bool) async throws -> TextFileDocument

        static let fileSystem = Storage(
            open: { url, encoding in
                try await Task.detached(priority: .userInitiated) { try DocumentIO.open(url: url, encoding: encoding) }.value
            },
            save: { document, destination, overwrite in
                try await Task.detached(priority: .userInitiated) {
                    try DocumentIO.save(document, to: destination, overwriteExternalChanges: overwrite)
                }.value
            }
        )
    }

    private enum Work { case saving, reloading }

    let id = UUID()
    private(set) var isModified: Bool
    private(set) var isClosed = false
    private var document: TextFileDocument
    /// 正文以可变 UTF-16 缓冲区接收差量；只有保存、恢复副本或完整同步才冻结为 String。
    private let buffer: NSMutableString
    private var textSnapshot: String?
    private var savedBuffer: NSString
    // 长度与保存基线相同时跟踪不同码元数，同长度小修改只比较受影响范围。
    private var differingUnits: Int?
    private(set) var revision: UInt64 = 0
    // 重建 WebKit 时需要恢复真实磁盘基线，不能把内存草稿误标为已保存。
    private(set) var savedText: String
    private var recoveredUnsaved = false
    private var work: Work?
    private let storage: Storage

    var path: URL? { document.sourceURL }
    var text: String {
        if let textSnapshot { return textSnapshot }
        let snapshot = (buffer.copy() as! NSString) as String
        textSnapshot = snapshot
        return snapshot
    }
    var encoding: TextFileEncoding { document.encoding }
    var isReadOnly: Bool { document.isReadOnly }
    var isBusy: Bool { work != nil }

    /// 新建、打开由工厂负责；这里报告当前会话可执行的编辑和持久化操作。
    var availableOperations: Set<FileOperation> {
        guard !isClosed, work != .reloading else { return [] }
        var operations: Set<FileOperation> = isReadOnly ? [] : [.edit]
        if !isBusy {
            operations.insert(.saveAs)
            if !isReadOnly { operations.insert(.save) }
        }
        return operations
    }

    private init(document: TextFileDocument, savedText: String, storage: Storage) {
        self.document = document
        buffer = NSMutableString(string: document.text)
        textSnapshot = document.text
        self.savedText = savedText
        savedBuffer = savedText as NSString
        self.storage = storage
        differingUnits = nil
        isModified = !document.text.utf8.elementsEqual(savedText.utf8)
        if isModified { compareSavedBuffer() }
        else { differingUnits = 0 }
    }

    static func create(text: String = "", encoding: TextFileEncoding = .utf8(bom: false),
                       storage: Storage = .fileSystem) -> TextDocumentSession {
        // 未保存的新空文档可直接关闭；工厂传入的非空内容同样属于尚未保存的编辑。
        TextDocumentSession(document: DocumentIO.create(text: text, encoding: encoding), savedText: "", storage: storage)
    }

    /// 崩溃恢复始终建立独立未命名文档，空正文也必须先保存或明确丢弃。
    static func recover(text: String, encoding: TextFileEncoding) -> TextDocumentSession {
        let session = create(text: text, encoding: encoding)
        session.recoveredUnsaved = true
        session.isModified = true
        return session
    }

    static func open(url: URL, encoding: TextFileEncoding? = nil,
                     storage: Storage = .fileSystem) async throws -> TextDocumentSession {
        let document = try await storage.open(url, encoding)
        return TextDocumentSession(document: document, savedText: document.text, storage: storage)
    }

    func replaceText(_ text: String) throws {
        try requireOpen()
        guard work != .reloading else { throw DocumentSessionError.busy }
        if isReadOnly, let path { throw DocumentIOError.readOnly(path) }
        let incoming = text as NSString
        guard !equalUnits(buffer, incoming) else { return }
        buffer.setString(text)
        textSnapshot = text
        revision &+= 1
        compareSavedBuffer()
    }

    /// 所有偏移基于同一份原始 UTF-16；先校验全部范围，再倒序提交，错误不能留下半份草稿。
    func applyEdits(_ edits: [Edit]) throws {
        try requireOpen()
        guard work != .reloading else { throw DocumentSessionError.busy }
        if isReadOnly, let path { throw DocumentIOError.readOnly(path) }
        let source = buffer
        let length = source.length
        // NSRange 可以切开 UTF-16 高/低代理对，必须拒绝；组合附加符的合法边界仍允许编辑。
        func isScalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < length else { return true }
            return !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
                || !(0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        var previousEnd = 0
        for edit in edits {
            guard edit.from >= previousEnd, edit.to >= edit.from, edit.to <= length,
                  isScalarBoundary(edit.from), isScalarBoundary(edit.to) else {
                throw EditError.invalidRange
            }
            previousEnd = edit.to
        }
        let changes = edits.filter { edit in
            !source.substring(with: NSRange(location: edit.from, length: edit.to - edit.from)).utf16.elementsEqual(edit.text.utf16)
        }
        guard !changes.isEmpty else { return }
        let preserveOffsets = differingUnits != nil && changes.allSatisfy { $0.to - $0.from == ($0.text as NSString).length }
        for edit in changes.reversed() {
            let range = NSRange(location: edit.from, length: edit.to - edit.from)
            if preserveOffsets { differingUnits! -= differences(in: range) }
            buffer.replaceCharacters(in: range, with: edit.text)
            if preserveOffsets { differingUnits! += differences(in: range) }
        }
        textSnapshot = nil
        revision &+= 1
        if preserveOffsets { isModified = recoveredUnsaved || differingUnits != 0 }
        else { compareSavedBuffer() }
    }

    func save(overwriteExternalChanges: Bool) async throws {
        try requireIdle()
        guard path != nil else { throw DocumentIOError.saveLocationRequired }
        try await persist(to: nil, overwriteExternalChanges: overwriteExternalChanges)
    }

    func saveAs(to destination: URL, overwriteExternalChanges: Bool) async throws {
        try await persist(to: destination, overwriteExternalChanges: overwriteExternalChanges)
    }

    func export(to destination: URL, format: WorkbenchFileKind, overwriteExisting: Bool) async throws {
        try requireIdle()
        throw DocumentSessionError.unsupportedOperation(.export)
    }

    func close(discardChanges: Bool) async throws {
        if isClosed { return }
        try requireIdle()
        guard !isModified || discardChanges else { throw DocumentSessionError.unsavedChanges }
        isClosed = true
    }

    func reload(discardChanges: Bool = false, encoding: TextFileEncoding? = nil) async throws {
        try requireIdle()
        guard !isModified || discardChanges else { throw DocumentSessionError.unsavedChanges }
        guard let path else { throw DocumentSessionError.noFileToReload }
        work = .reloading
        defer { work = nil }
        let loaded = try await storage.open(path, encoding ?? document.encoding)
        document = loaded
        buffer.setString(loaded.text)
        textSnapshot = loaded.text
        savedText = loaded.text
        savedBuffer = loaded.text as NSString
        differingUnits = 0
        revision &+= 1
        recoveredUnsaved = false
        isModified = false
    }

    private func persist(to destination: URL?, overwriteExternalChanges: Bool) async throws {
        // 所有保存入口在写入前集中检查并占用会话，检查与设置 busy 之间没有异步等待。
        try requireIdle()
        var snapshot = document
        snapshot.text = text
        work = .saving
        defer { work = nil }
        let saved = try await storage.save(snapshot, destination, overwriteExternalChanges)
        // 文件状态与基线必须推进到本次成功写入的快照，但等待期间的新输入仍留在编辑缓冲区。
        document = saved
        savedText = saved.text
        savedBuffer = saved.text as NSString
        recoveredUnsaved = false
        compareSavedBuffer()
    }

    /// Unicode 标准等价不能清除 dirty；比较 UTF-16 码元可区分 NFC/NFD，且不构造全文 String。
    private func equalUnits(_ lhs: NSString, _ rhs: NSString) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.character(at: index) != rhs.character(at: index) { return false }
        return true
    }
    private func differences(in range: NSRange) -> Int {
        var count = 0
        for index in range.location..<NSMaxRange(range) where buffer.character(at: index) != savedBuffer.character(at: index) { count += 1 }
        return count
    }
    private func compareSavedBuffer() {
        differingUnits = buffer.length == savedBuffer.length ? differences(in: NSRange(location: 0, length: buffer.length)) : nil
        isModified = recoveredUnsaved || differingUnits != 0
    }

    private func requireOpen() throws {
        guard !isClosed else { throw DocumentSessionError.closed }
    }

    private func requireIdle() throws {
        try requireOpen()
        guard !isBusy else { throw DocumentSessionError.busy }
    }
}
