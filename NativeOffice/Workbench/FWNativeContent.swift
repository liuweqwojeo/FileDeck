import AppKit

/// 非 Office 内容控制器共同遵守的保存契约；Office 状态仍由原生壳直接查询 CEF。
@MainActor
protocol FWNativeContent: DocumentSession {
    var controller: NSViewController { get }
    var contentTitle: String { get }
    var kind: WorkbenchFileKind { get }
    var onStateChanged: (() -> Void)? { get set }
    func reload(discardChanges: Bool) async throws
    func undo()
    func redo()
    func find()
    var canCloseWhileBusy: Bool { get }
    func captureInteraction() async
    func suspendInteraction(_ suspended: Bool) async
    func restoreInteraction() async
    func dispose()
}

extension FWNativeContent {
    func undo() {}
    func redo() {}
    func find() {}
    var canCloseWhileBusy: Bool { false }
    func captureInteraction() async {}
    func suspendInteraction(_ suspended: Bool) async {}
    func restoreInteraction() async {}
    func dispose() {}
}
