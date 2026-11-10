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
    var recoveryRevision: UInt64 { state.revision }
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
    private var fitsWindow = true
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
        for (name, selector, key) in [("缩小", #selector(zoomOut), "-"), ("适合窗口", #selector(fitWindow), "0"), ("实际大小", #selector(actualSize), "1"), ("放大", #selector(zoomIn), "+")] {
            let button = NSButton(title: name, target: self, action: selector)
            button.keyEquivalent = key; button.keyEquivalentModifierMask = .command
            toolbar.addArrangedSubview(button)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(zoomDidChange), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(zoomDidChange), name: NSScrollView.willStartLiveMagnifyNotification, object: scroll)
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
    override func viewDidLayout() {
        super.viewDidLayout()
        if fitsWindow { applyFit() }
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
        guard state.canEdit, !processing else { return }
        let alert = NSAlert(); alert.messageText = "裁剪图片"
        alert.informativeText = "拖动四角调整范围，拖动框内移动；按住 Option 可重新框选。数值以左上角为原点。"
        alert.addButton(withTitle: "确认裁剪"); alert.addButton(withTitle: "取消")
        let form = FWImageCropForm(image: pixels)
        form.fields.submitButton = alert.buttons.first; form.fields.validate(); alert.accessoryView = form
        guard alert.runModal() == .alertFirstButtonReturn, let rect = form.result else { return }
        performAsync { try await self.crop(pixelRect: rect) }
    }

    @objc private func resizeImage() {
        guard state.canEdit, !processing else { return }
        let alert = NSAlert(); alert.messageText = "调整图片像素尺寸"
        alert.informativeText = "这会修改文件实际像素；仅查看放大缩小请使用工具栏缩放。"
        alert.addButton(withTitle: "调整尺寸"); alert.addButton(withTitle: "取消")
        let form = FWImageResizeForm(width: pixels.width, height: pixels.height)
        form.fields.submitButton = alert.buttons.first; form.fields.validate(); alert.accessoryView = form
        guard alert.runModal() == .alertFirstButtonReturn, let size = form.result else { return }
        performAsync { try await self.resize(width: size.width, height: size.height) }
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
    @objc private func fitWindow() { fitsWindow = true; applyFit() }
    private func applyFit() {
        let visible = imageScroll.contentSize
        guard visible.width > 0, visible.height > 0 else { return }
        let scale = min(1, visible.width / CGFloat(pixels.width), visible.height / CGFloat(pixels.height))
        imageScroll.minMagnification = min(0.1, scale)
        if abs(imageScroll.magnification - scale) > 0.001 {
            imageScroll.setMagnification(scale, centeredAt: NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY))
            refreshState()
        }
    }
    private func zoom(to scale: CGFloat) {
        fitsWindow = false
        let visible = imageScroll.contentView.bounds
        imageScroll.setMagnification(scale, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        zoomDidChange()
    }
    @objc private func zoomDidChange() { fitsWindow = false; refreshState() }

    private func refreshImage() {
        let size = NSSize(width: pixels.width, height: pixels.height)
        imageView.image = NSImage(cgImage: pixels, size: size)
        imageView.frame = CGRect(origin: .zero, size: size)
        if fitsWindow { applyFit() }
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

/// 宽高和百分比共用一份像素尺寸；联动仅响应用户编辑，避免程序更新再次触发比例计算。
@MainActor
final class FWImageResizeForm: NSStackView {
    let fields: FWValidatedFields
    let lock = NSButton(checkboxWithTitle: "锁定原始宽高比", target: nil, action: nil)
    private let original: (width: Int, height: Int)
    private let summary = NSTextField(labelWithString: "")
    private var linkageError: String?
    private(set) var result: (width: Int, height: Int)?
    init(width: Int, height: Int) {
        original = (width, height)
        fields = FWValidatedFields(labels: ["宽度（像素）", "高度（像素）", "缩放百分比（%）"], values: ["\(width)", "\(height)", "100"])
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 310))
        orientation = .vertical; alignment = .leading; spacing = 8
        lock.state = .on; lock.target = self; lock.action = #selector(lockChanged)
        addArrangedSubview(lock); addArrangedSubview(fields); addArrangedSubview(summary)
        fields.onEdit = { [weak self] index in self?.synchronize(index) }
        fields.validation = { [weak self] values in
            guard let self else { return nil }
            self.result = nil
            if let error = self.linkageError { return error }
            guard let w = Int(values[0]), let h = Int(values[1]) else { return "请输入整数像素尺寸。" }
            do { try ImageOperations.validate(width: w, height: h) } catch { return error.localizedDescription }
            guard let percent = Double(values[2]), percent.isFinite, percent > 0 else { return "缩放百分比须为正数。" }
            self.result = (w, h)
            self.summary.stringValue = "\(width) × \(height) → \(w) × \(h) 像素"
            return nil
        }
        fields.validate()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func lockChanged() {
        if lock.state == .on { synchronize(0) } else { linkageError = nil }
        fields.validate()
    }
    private func synchronize(_ index: Int) {
        let inputs = fields.inputs
        linkageError = nil
        guard let value = Double(inputs[index].stringValue), value.isFinite, value > 0 else { return }
        if index != 2, lock.state == .off {
            let fraction = value / Double(index == 0 ? original.width : original.height)
            inputs[2].stringValue = String(format: "%.2f", fraction * 100)
            return
        }
        var width = Double(original.width), height = Double(original.height)
        if index == 2 { width *= value / 100; height *= value / 100 }
        else {
            guard value <= Double(ImageOperations.maximumDimension) else { return }
            if index == 0 { width = value; height = value * Double(original.height) / Double(original.width) }
            else { height = value; width = value * Double(original.width) / Double(original.height) }
        }
        guard width >= 1, height >= 1, width <= Double(ImageOperations.maximumDimension), height <= Double(ImageOperations.maximumDimension) else {
            linkageError = "该比例会使图片尺寸超出允许范围。"; return
        }
        if index == 2 || lock.state == .on {
            inputs[0].stringValue = String(Int(width.rounded())); inputs[1].stringValue = String(Int(height.rounded()))
        }
        if index != 2 {
            let fraction = index == 0 ? value / Double(original.width) : value / Double(original.height)
            inputs[2].stringValue = String(format: "%.2f", fraction * 100)
        }
    }
}

/// 裁剪坐标始终使用原图左上角像素；画布只映射显示，不对原像素进行缩放或重编码。
@MainActor
final class FWImageCropView: NSView {
    let image: CGImage
    private let displayImage: NSImage
    var selection: CGRect { didSet { needsDisplay = true } }
    var aspect: CGFloat?
    var selectionChanged: ((CGRect) -> Void)?
    private enum Drag { case resize(CGPoint), move(CGPoint, CGRect) }
    private var drag: Drag?
    override var isFlipped: Bool { true }
    init(image: CGImage) {
        self.image = image; selection = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        displayImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 290))
        setAccessibilityLabel("图片裁剪画布；也可使用右侧数值调整")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var imageRect: CGRect {
        let scale = min((bounds.width - 16) / CGFloat(image.width), (bounds.height - 16) / CGFloat(image.height))
        return CGRect(x: (bounds.width - CGFloat(image.width) * scale) / 2, y: (bounds.height - CGFloat(image.height) * scale) / 2,
                      width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }
    func displayRect(_ rect: CGRect) -> CGRect {
        let display = imageRect, scale = display.width / CGFloat(image.width)
        return CGRect(x: display.minX + rect.minX * scale, y: display.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
    private func pixelPoint(_ point: CGPoint) -> CGPoint {
        let display = imageRect, scale = display.width / CGFloat(image.width)
        return CGPoint(x: min(CGFloat(image.width), max(0, ((point.x - display.minX) / scale).rounded())),
                       y: min(CGFloat(image.height), max(0, ((point.y - display.minY) / scale).rounded())))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        displayImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let selected = displayRect(selection)
        let mask = NSBezierPath(rect: imageRect); mask.append(NSBezierPath(rect: selected)); mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill(); mask.fill()
        NSColor.controlAccentColor.setStroke(); let border = NSBezierPath(rect: selected); border.lineWidth = 2; border.stroke()
        NSColor.white.setFill()
        for x in [selected.minX, selected.maxX] { for y in [selected.minY, selected.maxY] { NSRect(x: x - 4, y: y - 4, width: 8, height: 8).fill() } }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), selected = displayRect(selection)
        guard imageRect.insetBy(dx: -8, dy: -8).contains(point) else { return }
        if event.modifierFlags.contains(.option) { drag = .resize(pixelPoint(point)); return }
        for x in [selected.minX, selected.maxX] {
            for y in [selected.minY, selected.maxY] where hypot(point.x - x, point.y - y) <= 11 {
                let opposite = CGPoint(x: x == selected.minX ? selection.maxX : selection.minX, y: y == selected.minY ? selection.maxY : selection.minY)
                drag = .resize(opposite); return
            }
        }
        if selected.contains(point), !event.modifierFlags.contains(.option) { drag = .move(pixelPoint(point), selection) }
        else { drag = .resize(pixelPoint(point)) }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = pixelPoint(convert(event.locationInWindow, from: nil))
        switch drag {
        case .move(let start, let original):
            selection.origin = CGPoint(x: min(CGFloat(image.width) - original.width, max(0, original.minX + point.x - start.x)),
                                       y: min(CGFloat(image.height) - original.height, max(0, original.minY + point.y - start.y)))
        case .resize(let anchor):
            var w = abs(point.x - anchor.x), h = abs(point.y - anchor.y)
            if let aspect { if w > h * aspect { w = h * aspect } else { h = w / aspect } }
            guard w >= 1, h >= 1 else { return }
            w = w.rounded(.down); h = h.rounded(.down)
            selection = CGRect(x: point.x >= anchor.x ? anchor.x : anchor.x - w, y: point.y >= anchor.y ? anchor.y : anchor.y - h, width: w, height: h)
        case nil: return
        }
        selectionChanged?(selection)
    }
    override func mouseUp(with event: NSEvent) { drag = nil }
}

@MainActor
final class FWImageCropForm: NSStackView {
    let canvas: FWImageCropView
    let fields: FWValidatedFields
    let ratio = NSPopUpButton()
    private let preview = NSImageView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private(set) var result: CGRect?
    init(image: CGImage) {
        canvas = FWImageCropView(image: image)
        fields = FWValidatedFields(labels: ["X（像素）", "Y（像素）", "宽度（像素）", "高度（像素）"], values: ["0", "0", "\(image.width)", "\(image.height)"], fieldWidth: 150)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 390))
        orientation = .vertical; alignment = .leading; spacing = 8
        canvas.widthAnchor.constraint(equalToConstant: 420).isActive = true; canvas.heightAnchor.constraint(equalToConstant: 290).isActive = true
        let body = NSStackView(views: [canvas, fields]); body.alignment = .top; body.spacing = 12; addArrangedSubview(body)
        ratio.addItems(withTitles: ["自由比例", "原图比例", "1:1", "4:3", "16:9"]); ratio.target = self; ratio.action = #selector(changeRatio)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.widthAnchor.constraint(equalToConstant: 90).isActive = true; preview.heightAnchor.constraint(equalToConstant: 70).isActive = true
        addArrangedSubview(NSStackView(views: [ratio, NSTextField(labelWithString: "裁剪结果"), preview, sizeLabel]))
        canvas.selectionChanged = { [weak self] rect in self?.setFields(rect) }
        fields.onEdit = { [weak self] index in
            guard let self, let aspect = self.canvas.aspect, (2...3).contains(index),
                  let value = Int(self.fields.inputs[index].stringValue), value > 0,
                  value <= (index == 2 ? image.width : image.height) else { return }
            let other = index == 2 ? CGFloat(value) / aspect : CGFloat(value) * aspect
            self.fields.inputs[index == 2 ? 3 : 2].stringValue = String(max(1, Int(other.rounded())))
        }
        fields.validation = { [weak self] values in
            guard let self else { return nil }
            self.result = nil
            let numbers = values.compactMap(Int.init)
            guard numbers.count == 4 else { return "请输入整数像素坐标和尺寸。" }
            let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            do { try ImageOperations.validateCrop(image, pixelRect: rect) } catch { return error.localizedDescription }
            self.result = rect; self.canvas.selection = rect
            if let cropped = image.cropping(to: rect) { self.preview.image = NSImage(cgImage: cropped, size: rect.size) }
            self.sizeLabel.stringValue = "\(numbers[2]) × \(numbers[3]) 像素"
            return nil
        }
        fields.validate()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func setFields(_ rect: CGRect) {
        for (field, number) in zip(fields.inputs, [rect.minX, rect.minY, rect.width, rect.height]) { field.stringValue = String(Int(number)) }
        fields.validate()
    }
    @objc private func changeRatio() {
        canvas.aspect = [nil, CGFloat(canvas.image.width) / CGFloat(canvas.image.height), 1, 4.0 / 3, 16.0 / 9][ratio.indexOfSelectedItem]
        if let aspect = canvas.aspect {
            var rect = canvas.selection
            if rect.width > rect.height * aspect { rect.size.width = max(1, (rect.height * aspect).rounded(.down)) }
            else { rect.size.height = max(1, (rect.width / aspect).rounded(.down)) }
            setFields(rect)
        }
    }
}
