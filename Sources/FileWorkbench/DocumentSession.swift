import Foundation

/// 工作台只读取会话的真实状态。Office 适配器须直接读取上游状态，不能另外维护一份 dirty 标志。
@MainActor
protocol DocumentSession: AnyObject {
    var id: UUID { get }
    var path: URL? { get }
    var isModified: Bool { get }
    var isReadOnly: Bool { get }
    var isBusy: Bool { get }
    var availableOperations: Set<FileOperation> { get }

    func save(overwriteExternalChanges: Bool) async throws
    func saveAs(to destination: URL, overwriteExternalChanges: Bool) async throws
    func export(to destination: URL, format: WorkbenchFileKind, overwriteExisting: Bool) async throws
    func close(discardChanges: Bool) async throws
}

extension DocumentSession {
    // 默认调用绝不覆盖外部改动，也不丢弃未保存内容；确认必须由调用方显式传递。
    func save() async throws { try await save(overwriteExternalChanges: false) }
    func saveAs(to destination: URL) async throws { try await saveAs(to: destination, overwriteExternalChanges: false) }
    func export(to destination: URL, format: WorkbenchFileKind) async throws {
        try await export(to: destination, format: format, overwriteExisting: false)
    }
    func close() async throws { try await close(discardChanges: false) }
}

enum DocumentSessionError: Error, LocalizedError, Equatable {
    case closed
    case busy
    case unsavedChanges
    case noFileToReload
    case unsupportedOperation(FileOperation)

    var errorDescription: String? {
        switch self {
        case .closed: "文档会话已关闭，请重新打开文件。"
        case .busy: "文件操作尚未完成，请稍后重试。"
        case .unsavedChanges: "文档有未保存内容，请先保存或明确确认丢弃。"
        case .noFileToReload: "新文档尚未保存，没有可重新加载的文件。"
        case .unsupportedOperation(let operation): "当前文档会话不支持此操作：\(operation.rawValue)。"
        }
    }
}
