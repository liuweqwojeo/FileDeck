import AppKit
import UniformTypeIdentifiers

/// Objective-C++ 只接触此门面；面板与异步保存始终捕获创建它们的文档，不能再次查询当前标签。
@MainActor
@objc(FWDocumentHost)
public final class FWDocumentHost: NSViewController {
    private let content: any FWNativeContent
    private let notice: String?
    private var actionBusy = false { didSet { stateDidChange?() } }
    private var saving = false
    private var closed = false
    private var conflict = false
    @objc public private(set) var lastError: String?
    @objc public private(set) var lastSavedURL: URL?
    @objc public var stateDidChange: (() -> Void)?
    @objc public var documentTitle: String { content.contentTitle }
    @objc public var documentURL: URL? { content.path }
    @objc public var modified: Bool { content.isModified }
    @objc public var busy: Bool { actionBusy || content.isBusy }
    @objc public var readOnly: Bool { content.isReadOnly }
    @objc public var canSave: Bool { !busy && content.availableOperations.contains(.save) }
    @objc public var canSaveAs: Bool { !busy && content.availableOperations.contains(.saveAs) }
    @objc public var canExport: Bool { !busy && content.availableOperations.contains(.export) }
    @objc public var isEditing: Bool { (content as? FWTextContent)?.isEditing ?? !content.isReadOnly }
    @objc public var canBeginEditing: Bool { !busy && !closed && (content as? FWTextContent)?.canBeginEditing == true }
    @objc public var statusText: String { lastError ?? (content as? FWTextContent)?.statusText ?? (readOnly ? "只读" : modified ? "未保存" : "已保存") }
    @objc public var sessionState: String {
        if closed { return "CLOSED" }
        if saving { return "SAVING" }
        if conflict { return "CONFLICT" }
        if lastError != nil { return "SAVE_ERROR" }
        if let text = content as? FWTextContent {
            if text.loadError != nil { return "LOAD_ERROR" }
            if text.isLoading { return "LOADING" }
        }
        return isEditing ? (modified ? "DIRTY" : "EDITING") : "PREVIEW"
    }

    private init(content: any FWNativeContent, notice: String? = nil) {
        self.content = content
        self.notice = notice
        super.init(nibName: nil, bundle: nil)
        content.onStateChanged = { [weak self] in self?.stateDidChange?() }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc(kindForURL:)
    public static func kind(for url: URL) -> String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return FileCapabilityRegistry().capabilities(for: url, contentType: type).kind.rawValue
    }

    @objc(openDocumentAt:kind:completion:)
    public static func openDocument(at url: URL?, kind: String,
                             completion: @escaping (FWDocumentHost?, NSError?) -> Void) {
        Task {
            do {
                guard let fileKind = WorkbenchFileKind(rawValue: kind) else {
                    throw DocumentSessionError.unsupportedOperation(.open)
                }
                let document: any FWNativeContent
                var notice: String?
                if let url {
                    switch fileKind {
                    case .text, .code, .json, .yaml, .markdown:
                        do { document = try await FWTextContent.open(url: url, kind: fileKind) }
                        catch let error as DocumentIOError {
                            switch error {
                            case .fileTooLarge, .unknownEncoding, .nonRoundTrippableEncoding, .binaryContent:
                                document = try await FWQuickLookContent.open(url: url)
                                notice = error.localizedDescription
                            default: throw error
                            }
                        }
                    case .csv: document = try await FWCSVContent.open(url: url)
                    case .pdf: document = try await FWPDFContent.open(url: url)
                    case .png, .jpeg, .heic: document = try await FWImageContent.open(url: url)
                    case .other: document = try await FWQuickLookContent.open(url: url)
                    default: throw DocumentSessionError.unsupportedOperation(.open)
                    }
                } else {
                    switch fileKind {
                    case .text, .code, .json, .yaml, .markdown: document = FWTextContent.create(kind: fileKind)
                    case .csv: document = try FWCSVContent.create()
                    case .pdf:
                        let images = try await selectImagesForPDF()
                        document = try await FWPDFContent.createFromImages(urls: images)
                    default: throw DocumentSessionError.unsupportedOperation(.create)
                    }
                }
                completion(FWDocumentHost(content: document, notice: notice), nil)
            } catch is CancellationError { completion(nil, nil) }
            catch { completion(nil, error as NSError) }
        }
    }

    /// 模态预览只使用完整、安全解码的文本；首次载入不允许输入，也不重新创建已有会话。
    @objc(openPreviewAt:completion:)
    public static func openPreview(at url: URL, completion: @escaping (FWDocumentHost?, NSError?) -> Void) {
        Task {
            do {
                guard let kind = WorkbenchFileKind(rawValue: kind(for: url)),
                      [.text, .code, .json, .yaml, .markdown].contains(kind) else {
                    throw DocumentSessionError.unsupportedOperation(.open)
                }
                let content = try await FWTextContent.open(url: url, kind: kind, preview: true)
                completion(FWDocumentHost(content: content), nil)
            } catch { completion(nil, error as NSError) }
        }
    }

    @objc public func beginEditing() {
        guard canBeginEditing else { return }
        (content as? FWTextContent)?.beginEditing()
    }

    /// 过期读取结果可释放无修改的预览；有草稿时只能走 requestClose 的确认流程。
    @objc public func disposePreview() {
        guard !modified, !actionBusy else { return }
        content.dispose()
        closed = true
        stateDidChange = nil
    }

    @objc(consumeEscapeWithCompletion:)
    public func consumeEscape(completion: @escaping (Bool) -> Void) {
        guard !actionBusy, let text = content as? FWTextContent else { completion(false); return }
        Task { completion(await text.consumeEscape()) }
    }

    private static func selectImagesForPDF() async throws -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择要生成 PDF 的图片"
        panel.prompt = "生成 PDF"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .heif]
        let response = await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { continuation.resume(returning: $0) }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        }
        guard response == .OK, !panel.urls.isEmpty else { throw CancellationError() }
        return panel.urls
    }

    public override func loadView() {
        let root = NSView()
        let child = content.controller
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(child.view)
        var top = root.topAnchor
        if let notice {
            let label = NSTextField(wrappingLabelWithString: notice)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
                label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12)
            ])
            top = label.bottomAnchor
        }
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: top, constant: notice == nil ? 0 : 10),
            child.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    @objc(saveIn:saveAs:completion:)
    public func save(in directory: URL?, saveAs: Bool, completion: @escaping (Bool) -> Void) {
        guard !busy else { completion(false); return }
        actionBusy = true
        saving = true
        lastError = nil
        conflict = false
        stateDidChange?()
        Task {
            let success = await performSave(directory: directory, saveAs: saveAs)
            saving = false
            actionBusy = false
            completion(success)
        }
    }

    /// 返回 true 只表示当前会话已无未保存内容；保存中继续输入时，磁盘成功也不能用于关闭标签。
    private func performSave(directory: URL?, saveAs: Bool) async -> Bool {
        var destination: URL?
        if saveAs || content.path == nil || !content.availableOperations.contains(.save) {
            guard content.availableOperations.contains(.saveAs),
                  let chosen = await chooseDestination(directory: directory, exporting: false)?.url else { return false }
            destination = chosen
        } else if !content.availableOperations.contains(.save) { return false }
        var overwrite = false
        while true {
            do {
                // 原路径已消失时只能让用户明确选择另存位置，不能用“覆盖冲突”悄悄重建它。
                if destination == nil, let path = content.path, !FileManager.default.fileExists(atPath: path.path) {
                    lastError = "原文件已不存在"
                    conflict = true
                    stateDidChange?()
                    guard await alert("原文件已不存在", detail: "编辑内容仍保留在内存中。请选择另存为，或取消后继续检查。", buttons: ["另存为…", "取消"]) == 0,
                          let chosen = await chooseDestination(directory: directory, exporting: false)?.url else { return false }
                    destination = chosen
                    overwrite = false
                }
                if let destination { try await content.saveAs(to: destination, overwriteExternalChanges: overwrite) }
                else { try await content.save(overwriteExternalChanges: overwrite) }
                lastSavedURL = content.path
                lastError = nil
                conflict = false
                stateDidChange?()
                return !content.isModified && !content.isBusy
            } catch let error as DocumentIOError {
                switch error {
                case .externalModification:
                    lastError = "文件已在其他应用中修改"
                    conflict = true
                    stateDidChange?()
                    if destination == nil, let path = content.path, !FileManager.default.fileExists(atPath: path.path) {
                        continue
                    }
                    let choice = await alert("文件已在其他应用中修改", detail: "重新加载会丢弃当前编辑；另存副本会保留两个版本；覆盖需要再次明确确认。",
                                             buttons: ["取消", "重新加载", "另存副本…", "明确覆盖"])
                    if choice == 1 {
                        do {
                            try await content.reload(discardChanges: true)
                            lastError = nil
                            conflict = false
                            stateDidChange?()
                        }
                        catch { await present(error) }
                        // 重新加载是冲突处理，不等同于完成最初的保存或关闭请求。
                        return false
                    } else if choice == 2 {
                        guard let chosen = await chooseDestination(directory: directory, exporting: false)?.url else { return false }
                        destination = chosen
                        overwrite = false
                    } else if choice == 3 {
                        guard await alert("确认覆盖磁盘上的文件？", detail: "这会替换其他应用写入的内容。", buttons: ["取消", "覆盖磁盘版本"]) == 1 else { return false }
                        overwrite = true
                    }
                    else { return false }
                case .destinationExists:
                    let choice = await alert("目标文件已存在", detail: "替换会覆盖目标文件的现有内容。原文档保持打开。",
                                             buttons: ["取消", "另选位置…", "替换目标文件"])
                    if choice == 1 {
                        guard let chosen = await chooseDestination(directory: directory, exporting: false)?.url else { return false }
                        destination = chosen
                        overwrite = false
                    } else if choice == 2 { overwrite = true }
                    else { return false }
                default: await present(error); return false
                }
            } catch is CancellationError { return false }
            catch { await present(error); return false }
        }
    }

    @objc(requestCloseIn:completion:)
    public func requestClose(in directory: URL?, completion: @escaping (Bool) -> Void) {
        guard !closed else { completion(true); return }
        guard !actionBusy, !content.isBusy || content.canCloseWhileBusy else { completion(false); return }
        actionBusy = true
        Task {
            await content.captureInteraction()
            await content.suspendInteraction(true)
            var closed = false
            do {
                // 文本 close 会再次同步 WebKit，覆盖“最后一次输入消息尚未回传”的窗口。
                try await content.close(discardChanges: false)
                closed = true
            } catch DocumentSessionError.unsavedChanges {
                let choice = await alert("是否保存对文件的修改？", detail: "当前文件包含尚未保存的修改。",
                                         buttons: ["保存", "不保存", "取消"])
                if choice == 0 {
                    saving = true
                    stateDidChange?()
                    if await performSave(directory: directory, saveAs: false) {
                        do { try await content.close(discardChanges: false); closed = true }
                        catch { await present(error) }
                    }
                    saving = false
                } else if choice == 1 {
                    do { try await content.close(discardChanges: true); closed = true }
                    catch { await present(error) }
                }
            } catch { await present(error) }
            self.closed = closed
            if !closed {
                await content.suspendInteraction(false)
                await content.restoreInteraction()
            }
            actionBusy = false
            completion(closed)
        }
    }

    /// 临时预览切换也必须同步真实编辑器；发现尚未回传的修改时让协调器固定旧标签。
    @objc(closeCleanPreviewWithCompletion:)
    public func closeCleanPreview(completion: @escaping (Bool) -> Void) {
        guard !busy else { completion(false); return }
        actionBusy = true
        Task {
            await content.captureInteraction()
            await content.suspendInteraction(true)
            let closed: Bool
            do { try await content.close(discardChanges: false); closed = true }
            catch { closed = false }
            self.closed = closed
            if !closed {
                await content.suspendInteraction(false)
                await content.restoreInteraction()
            }
            actionBusy = false
            completion(closed)
        }
    }

    @objc(exportIn:)
    public func export(in directory: URL?) {
        guard canExport else { return }
        actionBusy = true
        Task {
            defer { actionBusy = false }
            guard let selection = await chooseDestination(directory: directory, exporting: true) else { return }
            do {
                try await content.export(to: selection.url, format: selection.kind, overwriteExisting: false)
            } catch DocumentIOError.destinationExists {
                if await alert("替换导出文件？", detail: "目标已存在，替换会覆盖该文件。", buttons: ["取消", "替换"]) == 1 {
                    do { try await content.export(to: selection.url, format: selection.kind, overwriteExisting: true) }
                    catch { await present(error) }
                }
            } catch { await present(error) }
        }
    }

    private func chooseDestination(directory: URL?, exporting: Bool) async -> (url: URL, kind: WorkbenchFileKind)? {
        let formats: [WorkbenchFileKind]
        if [.png, .jpeg, .heic].contains(content.kind) { formats = exporting ? [.png, .jpeg, .pdf] : [.png, .jpeg] }
        else { formats = [content.kind] }
        let initial = formats.contains(content.kind) ? content.kind : formats[0]
        let panel = NSSavePanel()
        panel.title = exporting ? "导出文件" : "保存文件"
        panel.prompt = exporting ? "导出" : "保存"
        panel.canCreateDirectories = true
        panel.directoryURL = content.path?.deletingLastPathComponent() ?? directory
        let base = content.path?.deletingPathExtension().lastPathComponent ?? "未命名"
        let defaultExtension = content.kind == .code && !exporting ? content.path?.pathExtension : nil
        panel.nameFieldStringValue = base + "." + (defaultExtension.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fileExtension(for: initial))
        panel.allowedContentTypes = [Self.contentType(for: initial)]
        panel.allowsOtherFileTypes = [.code, .text].contains(content.kind)
        let formatChoice = FWExportChoice(panel: panel, formats: formats, initial: initial)
        if formats.count > 1 { panel.accessoryView = formatChoice.popup }
        let result = await withCheckedContinuation { continuation in
            // AppKit 在完成回调时仍可能保留面板动画；后续错误确认必须等旧面板真正隐藏。
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                panel.orderOut(nil)
                continuation.resume(returning: response)
            }
            if let window = view.window { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        }
        guard result == .OK, let url = panel.url else { return nil }
        return (url, formatChoice.selected)
    }

    private func alert(_ title: String, detail: String, buttons: [String]) async -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        for button in buttons { alert.addButton(withTitle: button) }
        if let cancel = buttons.firstIndex(of: "取消") { alert.buttons[cancel].keyEquivalent = "\u{1b}" }
        let response: NSApplication.ModalResponse
        if let window = view.window {
            weak var responder = window.firstResponder
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    alert.window.orderOut(nil)
                    continuation.resume(returning: response)
                }
            }
            if let control = responder as? NSView, control.window === window, !closed {
                window.makeFirstResponder(control)
            }
        } else { response = alert.runModal() }
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    private func present(_ error: Error) async {
        lastError = (error as NSError).localizedDescription
        stateDidChange?()
        _ = await alert("操作未完成", detail: (error as NSError).localizedDescription, buttons: ["知道了"])
    }

    @objc public func undo() { content.undo() }
    @objc public func redo() { content.redo() }
    @objc public func find() { content.find() }

    @objc(smokeReplaceText:completion:)
    public func smokeReplaceText(_ text: String, completion: @escaping (NSError?) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FW_OFFICE_SMOKE_DIR"]?.isEmpty == false,
              environment["FW_OFFICE_SMOKE_TOKEN"]?.isEmpty == false,
              let editor = content as? FWTextContent else {
            completion(NSError(domain: "FileWorkbench.Smoke", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "未启用文本编辑器验收入口。" ]))
            return
        }
        Task {
            do { try await editor.replaceTextForSmoke(text); completion(nil) }
            catch { completion(error as NSError) }
        }
    }
    @objc(undo:) private func undoFromResponder(_ sender: Any?) { undo() }
    @objc(redo:) private func redoFromResponder(_ sender: Any?) { redo() }
    @objc(performFindPanelAction:) private func findFromResponder(_ sender: Any?) { find() }

    static func fileExtension(for kind: WorkbenchFileKind) -> String {
        switch kind {
        case .word: "docx"
        case .spreadsheet: "xlsx"
        case .presentation: "pptx"
        case .markdown: "md"
        case .json: "json"
        case .yaml: "yaml"
        case .csv: "csv"
        case .pdf: "pdf"
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        default: "txt"
        }
    }

    private static func contentType(for kind: WorkbenchFileKind) -> UTType {
        UTType(filenameExtension: fileExtension(for: kind)) ?? .data
    }
}

@MainActor
private final class FWExportChoice: NSObject {
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 28), pullsDown: false)
    private weak var panel: NSSavePanel?
    private let formats: [WorkbenchFileKind]
    var selected: WorkbenchFileKind { formats[max(0, popup.indexOfSelectedItem)] }

    init(panel: NSSavePanel, formats: [WorkbenchFileKind], initial: WorkbenchFileKind) {
        self.panel = panel
        self.formats = formats
        super.init()
        popup.addItems(withTitles: formats.map { FWDocumentHost.fileExtension(for: $0).uppercased() })
        popup.selectItem(at: formats.firstIndex(of: initial) ?? 0)
        popup.target = self
        popup.action = #selector(changeFormat)
    }

    @objc private func changeFormat() {
        guard let panel else { return }
        let ext = FWDocumentHost.fileExtension(for: selected)
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
    }
}
