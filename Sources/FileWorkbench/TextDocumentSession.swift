import Foundation

@MainActor
final class TextDocumentSession: DocumentSession {
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
    private var savedText: String
    private var work: Work?
    private let storage: Storage

    var path: URL? { document.sourceURL }
    var text: String { document.text }
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
        self.savedText = savedText
        self.storage = storage
        isModified = !document.text.utf8.elementsEqual(savedText.utf8)
    }

    static func create(text: String = "", encoding: TextFileEncoding = .utf8(bom: false),
                       storage: Storage = .fileSystem) -> TextDocumentSession {
        // 未保存的新空文档可直接关闭；工厂传入的非空内容同样属于尚未保存的编辑。
        TextDocumentSession(document: DocumentIO.create(text: text, encoding: encoding), savedText: "", storage: storage)
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
        // String == 会把 NFC/NFD 视为相等，不能用于决定用户实际输入是否需要保存。
        guard !document.text.utf8.elementsEqual(text.utf8) else { return }
        document.text = text
        isModified = !text.utf8.elementsEqual(savedText.utf8)
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
        savedText = loaded.text
        isModified = false
    }

    private func persist(to destination: URL?, overwriteExternalChanges: Bool) async throws {
        // 所有保存入口在写入前集中检查并占用会话，检查与设置 busy 之间没有异步等待。
        try requireIdle()
        let snapshot = document
        work = .saving
        defer { work = nil }
        let saved = try await storage.save(snapshot, destination, overwriteExternalChanges)
        // 文件状态与基线必须推进到本次成功写入的快照，但等待期间的新输入仍留在编辑缓冲区。
        let currentText = document.text
        document = saved
        document.text = currentText
        savedText = saved.text
        isModified = !currentText.utf8.elementsEqual(savedText.utf8)
    }

    private func requireOpen() throws {
        guard !isClosed else { throw DocumentSessionError.closed }
    }

    private func requireIdle() throws {
        try requireOpen()
        guard !isBusy else { throw DocumentSessionError.busy }
    }
}
