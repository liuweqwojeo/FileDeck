import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class FWImageContent: NSViewController, FWNativeContent {
    let id = UUID()
    var controller: NSViewController { self }
    var contentTitle: String { path?.lastPathComponent ?? "未命名图片" }
    var path: URL? { state.path }
    var isModified: Bool { state.isModified }
    var isReadOnly: Bool { state.isReadOnly }
    var isBusy: Bool { state.isBusy || processing }
    var canUndo: Bool { state.canEdit && !isBusy && history.canUndo }
    var canRedo: Bool { state.canEdit && !isBusy && history.canRedo }
    var onStateChanged: (() -> Void)?
    var kind: WorkbenchFileKind { currentKind }
    var availableOperations: Set<FileOperation> {
        guard !state.isClosed else { return [] }
        var result: Set<FileOperation> = [.open]
        if state.canEdit && !processing { result.insert(.edit) }
        if !isBusy {
            result.formUnion([.saveAs, .export])
            if !isReadOnly && kind != .heic { result.insert(.save) }
        }
        return result
    }

    private let state: FWBinaryState
    private var encodedSnapshot: (source: Data, format: WorkbenchFileKind, output: Data)?
    private var currentKind: WorkbenchFileKind
    private var pixels: CGImage
    private var pixelStorageBytes: Int
    private var processing = false
    private let imageView = NSImageView()
    private let imageScroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let history: FWMediaHistory
    private var editButtons: [NSButton] = []
    override var undoManager: UndoManager? { history.manager }

    private struct Snapshot: Sendable {
        let data: Data
        let pixels: CGImage
        let pixelStorageBytes: Int
        var historyBytes: Int { data.count + pixelStorageBytes }
    }

    private init(data: Data, fileState: FileSaveState?, pixels: CGImage, kind: WorkbenchFileKind,
                 maximumBytes: Int, historyMaximumBytes: Int) throws {
        state = try FWBinaryState(data: data, fileState: fileState, maximumBytes: maximumBytes)
        history = FWMediaHistory(maximumBytes: historyMaximumBytes)
        self.pixels = pixels
        pixelStorageBytes = pixels.bytesPerRow * pixels.height
        currentKind = kind
        super.init(nibName: nil, bundle: nil)
        state.onChange = { [weak self] in self?.refreshState() }
    }
    required init?(coder: NSCoder) { fatalError("请使用 open(url:)") }

    var recoveryCapture: DraftRecoveryCapture? {
        guard !state.isClosed, isModified else { return nil }
        return DraftRecoveryCapture(kind: kind, originalURL: path, title: contentTitle, body: .binary(state.data))
    }
    static func recover(_ draft: DraftRecoveryDocument) async throws -> FWImageContent {
        let data = draft.data
        let pixels = try await Task.detached(priority: .userInitiated) { try ImageOperations.read(data) }.value
        let content = try FWImageContent(data: data, fileState: nil, pixels: pixels, kind: Self.detectKind(data),
            maximumBytes: SafeFileIO.maximumMediaBytes, historyMaximumBytes: FWMediaHistory.defaultMaximumBytes)
        content.state.markRecovered()
        return content
    }

    static func open(url: URL, maximumBytes: Int = SafeFileIO.maximumMediaBytes,
                     historyMaximumBytes: Int = FWMediaHistory.defaultMaximumBytes) async throws -> FWImageContent {
        let loaded = try await Task.detached(priority: .userInitiated) {
            let result = try SafeFileIO.open(url: url, maximumBytes: maximumBytes)
            return (result, try ImageOperations.read(result.data), Self.detectKind(result.data))
        }.value
        // SDK 将不可变 CGImage 声明为 Sendable；只把像素传回主 actor，NSImage/视图仍在主线程创建。
        return try FWImageContent(data: loaded.0.data, fileState: loaded.0.state, pixels: loaded.1, kind: loaded.2,
                                  maximumBytes: maximumBytes, historyMaximumBytes: historyMaximumBytes)
    }

    override func loadView() {
        let toolbar = NSStackView()
        toolbar.spacing = 8
        for (name, selector) in [("左转 90°", #selector(turnLeft)), ("右转 90°", #selector(turnRight)),
                                 ("裁剪像素区域", #selector(cropImage)), ("调整尺寸", #selector(resizeImage))] {
            let button = NSButton(title: name, target: self, action: selector)
            editButtons.append(button)
            toolbar.addArrangedSubview(button)
        }
        // NSScrollView 原生捏合会保持手势中心，滚动仅作用于图片文档，不缩放工具栏。
        let scroll = imageScroll
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        for (name, selector, key) in [("缩小", #selector(zoomOut), "-"), ("实际大小", #selector(actualSize), "0"), ("放大", #selector(zoomIn), "+")] {
            let button = NSButton(title: name, target: self, action: selector)
            button.keyEquivalent = key; button.keyEquivalentModifierMask = .command
            toolbar.addArrangedSubview(button)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(zoomDidChange), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        imageView.imageScaling = .scaleNone
        scroll.documentView = imageView
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        view = FWMediaUI.layout(toolbar: toolbar, body: scroll, status: status)
        refreshImage()
        refreshState()
    }

    func save(overwriteExternalChanges: Bool) async throws {
        guard kind != .heic else { throw DocumentSessionError.unsupportedOperation(.save) }
        try await persist(to: nil, format: kind, overwrite: overwriteExternalChanges)
    }

    func saveAs(to destination: URL, overwriteExternalChanges: Bool) async throws {
        try FWMediaUI.requireExtension(destination, allowed: ["png", "jpg", "jpeg"])
        let output: WorkbenchFileKind = destination.pathExtension.lowercased() == "png" ? .png : .jpeg
        try await persist(to: destination, format: output, overwrite: overwriteExternalChanges)
        currentKind = output
        refreshState()
    }

    func export(to destination: URL, format: WorkbenchFileKind, overwriteExisting: Bool) async throws {
        guard [.png, .jpeg, .pdf].contains(format) else { throw DocumentSessionError.unsupportedOperation(.export) }
        let extensions: Set<String> = format == .png ? ["png"] : (format == .jpeg ? ["jpg", "jpeg"] : ["pdf"])
        try FWMediaUI.requireExtension(destination, allowed: extensions)
        let replacesSource = destination.standardizedFileURL == path?.standardizedFileURL
        guard !replacesSource || format != .pdf else {
            throw MediaOperationError.invalidParameter("转换为 PDF 时请选择新的文件位置。")
        }
        try await persist(to: destination, format: format, overwrite: overwriteExisting, adoptDestination: false)
        if replacesSource { currentKind = format; refreshState() }
    }

    func reload(discardChanges: Bool) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        processing = true
        defer { processing = false; refreshState() }
        pixels = try await state.reload(discardChanges: discardChanges) { try ImageOperations.read($0) }
        pixelStorageBytes = pixels.bytesPerRow * pixels.height
        encodedSnapshot = nil
        currentKind = Self.detectKind(state.data)
        history.removeAll()
        if isViewLoaded { refreshImage() }
        refreshState()
    }

    func close(discardChanges: Bool) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        try state.close(discardChanges: discardChanges); history.removeAll()
    }
    func undo() { if canUndo { history.undo() } }
    func redo() { if canRedo { history.redo() } }

    private func persist(to destination: URL?, format: WorkbenchFileKind, overwrite: Bool, adoptDestination: Bool = true) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        let cached = encodedSnapshot
        let encoder = Self.encoder(for: format, pixels: pixels)
        let replacesSource = destination?.standardizedFileURL == path?.standardizedFileURL
        let saved = try await state.save(to: destination, overwrite: overwrite, adoptDestination: adoptDestination) { data in
            if let cached, cached.format == format, cached.source == data { return cached.output }
            return try encoder(data)
        }
        // 基于本次保存快照缓存实际写出的字节；保存等待期间的新编辑不能命中这份缓存。
        // 导出其他格式的副本不替换原路径缓存，随后普通保存仍应使用已落盘的原格式字节。
        if adoptDestination || replacesSource { encodedSnapshot = (saved.source, format, saved.encoded) }
    }

    @objc private func turnLeft() { performAsync { try await self.rotate(clockwise: false) } }
    @objc private func turnRight() { performAsync { try await self.rotate(clockwise: true) } }
    func rotate(clockwise: Bool) async throws {
        try await transform(name: "旋转图片") { try ImageOperations.rotate90($0, clockwise: clockwise) }
    }
    func crop(pixelRect: CGRect) async throws {
        try await transform(name: "裁剪图片", preservesBacking: true) { try ImageOperations.crop($0, pixelRect: pixelRect) }
    }
    func resize(width: Int, height: Int) async throws {
        try await transform(name: "调整图片尺寸") { try ImageOperations.resize($0, width: width, height: height) }
    }

    @objc private func cropImage() {
        guard state.canEdit, !processing,
              let values = FWMediaUI.fields(title: "裁剪图片（左上角为原点）", labels: ["X", "Y", "宽度（像素）", "高度（像素）"],
                                            values: ["0", "0", "\(pixels.width)", "\(pixels.height)"]) else { return }
        performAsync {
            let numbers = values.compactMap(Double.init)
            guard numbers.count == 4 else { throw MediaOperationError.invalidParameter("请输入整数像素坐标与尺寸。") }
            let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            try await self.crop(pixelRect: rect)
        }
    }

    @objc private func resizeImage() {
        guard state.canEdit, !processing,
              let values = FWMediaUI.fields(title: "调整图片尺寸", labels: ["宽度（像素）", "高度（像素）"],
                                            values: ["\(pixels.width)", "\(pixels.height)"]) else { return }
        performAsync {
            guard let width = Int(values[0]), let height = Int(values[1]) else {
                throw MediaOperationError.invalidParameter("请输入整数像素尺寸。")
            }
            try await self.resize(width: width, height: height)
        }
    }

    private func install(_ snapshot: Snapshot, name: String) throws {
        let previous = Snapshot(data: state.data, pixels: pixels, pixelStorageBytes: pixelStorageBytes)
        try state.replace(snapshot.data)
        pixels = snapshot.pixels
        pixelStorageBytes = snapshot.pixelStorageBytes
        registerUndo(previous, name: name)
        if isViewLoaded { refreshImage() }
        refreshState()
    }
    private func registerUndo(_ snapshot: Snapshot, name: String) {
        history.register(bytes: snapshot.historyBytes, name: name) { [weak self] in
            self?.perform { try self?.install(snapshot, name: name) }
        }
    }
    private func transform(name: String, preservesBacking: Bool = false, operation: @escaping @Sendable (CGImage) throws -> CGImage) async throws {
        guard !processing else { throw DocumentSessionError.busy }
        // 一直占用到像素和撤销项安装完毕，避免底层字节先完成时新动作读到旧显示像素。
        processing = true
        defer { processing = false; refreshState() }
        let previous = Snapshot(data: state.data, pixels: pixels, pixelStorageBytes: pixelStorageBytes)
        let image = try await state.transformWithResult(allowDuringSave: true) { data in
            let output = try operation(previous.pixels)
            return (try ImageOperations.export(output, format: .png, preservingMetadataFrom: data), output)
        }
        pixels = image
        // CGImage 裁剪可能共享原像素 backing，不能按裁剪后的小尺寸低估撤销保留量。
        pixelStorageBytes = preservesBacking ? max(previous.pixelStorageBytes, image.bytesPerRow * image.height)
            : image.bytesPerRow * image.height
        registerUndo(previous, name: name)
        if isViewLoaded { refreshImage() }
        refreshState()
    }

    @objc private func zoomOut() { zoom(to: imageScroll.magnification / 1.25) }
    @objc private func zoomIn() { zoom(to: imageScroll.magnification * 1.25) }
    @objc private func actualSize() { zoom(to: 1) }
    private func zoom(to scale: CGFloat) {
        let visible = imageScroll.contentView.bounds
        imageScroll.setMagnification(scale, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        zoomDidChange()
    }
    @objc private func zoomDidChange() { refreshState() }

    private func refreshImage() {
        let size = NSSize(width: pixels.width, height: pixels.height)
        imageView.image = NSImage(cgImage: pixels, size: size)
        imageView.frame = CGRect(origin: .zero, size: size)
        refreshState()
    }

    private func refreshState() {
        for button in editButtons { button.isEnabled = state.canEdit && !processing }
        status.stringValue = "\(pixels.width) × \(pixels.height) 像素 · \(kind.rawValue.uppercased()) · \(Int(imageScroll.magnification * 100))%"
            + (kind == .heic ? " · 修改后请另存为 PNG/JPEG" : "") + (isBusy ? " · 正在处理…" : "")
        onStateChanged?()
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { FWMediaUI.show(error, in: view.window) }
    }

    private func performAsync(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { FWMediaUI.show(error, in: view.window) } }
    }

    nonisolated private static func detectKind(_ data: Data) -> WorkbenchFileKind {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .heic }
        let type = CGImageSourceGetType(source) as String?
        return type == UTType.png.identifier ? .png : (type == UTType.jpeg.identifier ? .jpeg : .heic)
    }

    private static func encoder(for format: WorkbenchFileKind, pixels: CGImage) -> @Sendable (Data) throws -> Data {
        { data in
            if format == .pdf { return try PDFOperations.imageToPDF(pixels) }
            // 原始文件和撤销恢复的原始快照保留全部字节；仍由 FWBinaryState 执行冲突检查及原子写入。
            let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
            if type == (format == .png ? UTType.png.identifier : UTType.jpeg.identifier) { return data }
            return try ImageOperations.export(pixels, format: format == .png ? .png : .jpeg(quality: 0.92),
                                              preservingMetadataFrom: data)
        }
    }
}
