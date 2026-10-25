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
    var isBusy: Bool { state.isBusy }
    var onStateChanged: (() -> Void)?
    var kind: WorkbenchFileKind { currentKind }
    var availableOperations: Set<FileOperation> {
        guard !state.isClosed else { return [] }
        var result: Set<FileOperation> = [.open]
        if state.canEdit { result.insert(.edit) }
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
    private let imageView = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let history = UndoManager()
    private var editButtons: [NSButton] = []
    override var undoManager: UndoManager? { history }

    private init(data: Data, fileState: FileSaveState, pixels: CGImage, kind: WorkbenchFileKind) {
        state = FWBinaryState(data: data, fileState: fileState)
        self.pixels = pixels
        currentKind = kind
        super.init(nibName: nil, bundle: nil)
        history.levelsOfUndo = 12
        state.onChange = { [weak self] in self?.refreshState() }
    }
    required init?(coder: NSCoder) { fatalError("请使用 open(url:)") }

    static func open(url: URL) async throws -> FWImageContent {
        let loaded = try await Task.detached(priority: .userInitiated) {
            let result = try SafeFileIO.open(url: url)
            _ = try ImageOperations.read(result.data)
            return result
        }.value
        let source = CGImageSourceCreateWithData(loaded.data as CFData, nil)!
        let type = CGImageSourceGetType(source) as String?
        let kind: WorkbenchFileKind = type == UTType.png.identifier ? .png
            : (type == UTType.jpeg.identifier ? .jpeg : .heic)
        return try FWImageContent(data: loaded.data, fileState: loaded.state, pixels: ImageOperations.read(loaded.data), kind: kind)
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
        let scroll = NSScrollView()
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
        try await state.reload(discardChanges: discardChanges) { _ = try ImageOperations.read($0) }
        encodedSnapshot = nil
        pixels = try ImageOperations.read(state.data)
        currentKind = Self.detectKind(state.data)
        history.removeAllActions()
        if isViewLoaded { refreshImage() }
    }

    func close(discardChanges: Bool) async throws { try state.close(discardChanges: discardChanges) }
    func undo() { if state.canEdit { history.undo() } }
    func redo() { if state.canEdit { history.redo() } }

    private func persist(to destination: URL?, format: WorkbenchFileKind, overwrite: Bool, adoptDestination: Bool = true) async throws {
        let cached = encodedSnapshot
        let encoder = Self.encoder(for: format)
        let replacesSource = destination?.standardizedFileURL == path?.standardizedFileURL
        let saved = try await state.save(to: destination, overwrite: overwrite, adoptDestination: adoptDestination) { data in
            if let cached, cached.format == format, cached.source == data { return cached.output }
            return try encoder(data)
        }
        // 基于本次保存快照缓存实际写出的字节；保存等待期间的新编辑不能命中这份缓存。
        // 导出其他格式的副本不替换原路径缓存，随后普通保存仍应使用已落盘的原格式字节。
        if adoptDestination || replacesSource { encodedSnapshot = (saved.source, format, saved.encoded) }
    }

    @objc private func turnLeft() { perform { try rotate(clockwise: false) } }
    @objc private func turnRight() { perform { try rotate(clockwise: true) } }
    func rotate(clockwise: Bool) throws {
        try install(ImageOperations.export(ImageOperations.rotate90(pixels, clockwise: clockwise), format: .png,
                                           preservingMetadataFrom: state.data), name: "旋转图片")
    }

    @objc private func cropImage() {
        guard state.canEdit,
              let values = FWMediaUI.fields(title: "裁剪图片（左上角为原点）", labels: ["X", "Y", "宽度（像素）", "高度（像素）"],
                                            values: ["0", "0", "\(pixels.width)", "\(pixels.height)"]) else { return }
        perform {
            let numbers = values.compactMap(Double.init)
            guard numbers.count == 4 else { throw MediaOperationError.invalidParameter("请输入整数像素坐标与尺寸。") }
            let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            try install(ImageOperations.export(ImageOperations.crop(pixels, pixelRect: rect), format: .png,
                                               preservingMetadataFrom: state.data), name: "裁剪图片")
        }
    }

    @objc private func resizeImage() {
        guard state.canEdit,
              let values = FWMediaUI.fields(title: "调整图片尺寸", labels: ["宽度（像素）", "高度（像素）"],
                                            values: ["\(pixels.width)", "\(pixels.height)"]) else { return }
        perform {
            guard let width = Int(values[0]), let height = Int(values[1]) else {
                throw MediaOperationError.invalidParameter("请输入整数像素尺寸。")
            }
            try install(ImageOperations.export(ImageOperations.resize(pixels, width: width, height: height), format: .png,
                                               preservingMetadataFrom: state.data), name: "调整图片尺寸")
        }
    }

    private func install(_ data: Data, name: String) throws {
        let image = try ImageOperations.read(data)
        let previous = state.data
        try state.replace(data)
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.perform { try target.install(previous, name: name) } }
        }
        history.setActionName(name)
        pixels = image
        if isViewLoaded { refreshImage() }
    }

    private func refreshImage() {
        let size = NSSize(width: pixels.width, height: pixels.height)
        imageView.image = NSImage(cgImage: pixels, size: size)
        imageView.frame = CGRect(origin: .zero, size: size)
        refreshState()
    }

    private func refreshState() {
        for button in editButtons { button.isEnabled = state.canEdit }
        status.stringValue = "\(pixels.width) × \(pixels.height) 像素 · \(kind.rawValue.uppercased())"
            + (kind == .heic ? " · 修改后请另存为 PNG/JPEG" : "") + (isBusy ? " · 正在处理…" : "")
        onStateChanged?()
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { FWMediaUI.show(error, in: view.window) }
    }

    private static func detectKind(_ data: Data) -> WorkbenchFileKind {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .heic }
        let type = CGImageSourceGetType(source) as String?
        return type == UTType.png.identifier ? .png : (type == UTType.jpeg.identifier ? .jpeg : .heic)
    }

    private static func encoder(for format: WorkbenchFileKind) -> @Sendable (Data) throws -> Data {
        { data in
            if format == .pdf { return try PDFOperations.imagesToPDF([data]) }
            // 原始文件和撤销恢复的原始快照保留全部字节；仍由 FWBinaryState 执行冲突检查及原子写入。
            let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
            if type == (format == .png ? UTType.png.identifier : UTType.jpeg.identifier) { return data }
            return try ImageOperations.export(ImageOperations.read(data), format: format == .png ? .png : .jpeg(quality: 0.92),
                                              preservingMetadataFrom: data)
        }
    }
}
