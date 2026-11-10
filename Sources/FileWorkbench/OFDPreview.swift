import AppKit
import PDFKit
import SwiftUI

/// 复用完整应用内的 ONLYOFFICE x2t，将 OFD 转成仅供阅读的内存 PDF；原文件不写回。
@MainActor
final class OFDPreviewController: NSViewController {
    let pdfView = PDFView()
    private(set) var currentURL: URL?
    private(set) var isLoading = false
    private(set) var failureMessage: String?
    private(set) var process: Process?
    private let converterURL: URL?
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let fitButton = NSButton(title: "适合窗口", target: nil, action: nil)
    private let zoomOutButton = NSButton(title: "缩小", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "放大", target: nil, action: nil)
    private var timeoutTask: Task<Void, Never>?

    init(converterURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("converter/x2t")) {
        self.converterURL = converterURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for (button, action) in [(retryButton, #selector(retry)), (fitButton, #selector(fit)),
                                 (zoomOutButton, #selector(zoomOut)), (zoomInButton, #selector(zoomIn))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        let toolbar = NSStackView(views: [progress, status, spacer, retryButton, zoomOutButton, zoomInButton, fitButton])
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        for child in [toolbar, pdfView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        updateControls()
    }

    func load(url: URL) {
        guard currentURL != url else { return }
        stop()
        _ = view
        currentURL = url
        guard let converterURL, FileManager.default.isExecutableFile(atPath: converterURL.path) else {
            fail("当前应用未包含 OFD 预览组件，请使用完整 FileDeck 应用。")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeck-OFD-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let output = directory.appendingPathComponent("preview.pdf")
            let parameters = XMLElement(name: "TaskQueueDataConvert")
            // 格式值来自锁定内核 Common/OfficeFileFormats.h：OFD=0x020a，PDF=0x0201。
            // 独立运行的 x2t 必须显式指定字体目录；本版本自动枚举系统字体会崩溃。
            for (name, value) in [("m_sFileFrom", url.path), ("m_sFileTo", output.path),
                                  ("m_nFormatFrom", "522"), ("m_nFormatTo", "513"),
                                  ("m_sTempDir", directory.path), ("m_sFontDir", "/System/Library/Fonts"),
                                  ("m_bDontSaveAdditional", "true")] {
                parameters.addChild(XMLElement(name: name, stringValue: value))
            }
            let parameterURL = directory.appendingPathComponent("convert.xml")
            try XMLDocument(rootElement: parameters).xmlData.write(to: parameterURL)
            let conversion = Process()
            conversion.executableURL = converterURL
            conversion.arguments = [parameterURL.path]
            conversion.currentDirectoryURL = directory
            conversion.standardOutput = FileHandle.nullDevice
            conversion.standardError = FileHandle.nullDevice
            conversion.terminationHandler = { [weak self] completed in
                Task { @MainActor [weak self] in
                    // 进程退出后才清理临时目录，关闭中的转换不会重新创建已删除的文件。
                    defer { try? FileManager.default.removeItem(at: directory) }
                    guard let self, self.process === completed else { return }
                    self.process = nil
                    self.timeoutTask?.cancel()
                    self.timeoutTask = nil
                    do {
                        guard completed.terminationReason == .exit, completed.terminationStatus == 0 else {
                            throw OFDPreviewError.conversionFailed
                        }
                        let data = try Data(contentsOf: output)
                        let document = try PDFOperations.read(data)
                        self.pdfView.document = document
                        self.isLoading = false
                        self.status.stringValue = "OFD · \(document.pageCount) 页"
                        self.updateControls()
                    } catch {
                        self.fail("无法预览此 OFD 文件，文件可能已损坏或包含暂不支持的内容。")
                    }
                }
            }
            process = conversion
            isLoading = true
            status.stringValue = "正在加载 OFD…"
            updateControls()
            try conversion.run()
            // 转换异常不能让弹窗无限加载；关闭和切换文件也会立即终止本次子进程。
            timeoutTask = Task { [weak self, weak conversion] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, let conversion, self.process === conversion else { return }
                self.stopConversion()
                self.fail("OFD 预览超时，请重试或使用默认应用打开。")
            }
        } catch {
            process = nil
            try? FileManager.default.removeItem(at: directory)
            fail("无法加载 OFD 预览：" + error.localizedDescription)
        }
    }

    func stop() {
        stopConversion()
        pdfView.document = nil
        currentURL = nil
        failureMessage = nil
        isLoading = false
        if isViewLoaded { updateControls() }
    }

    private func stopConversion() {
        timeoutTask?.cancel()
        timeoutTask = nil
        let previous = process
        process = nil
        if previous?.isRunning == true { previous?.terminate() }
    }

    private func fail(_ message: String) {
        isLoading = false
        failureMessage = message
        status.stringValue = message
        updateControls()
    }

    private func updateControls() {
        if isLoading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        retryButton.isHidden = failureMessage == nil
        for button in [fitButton, zoomOutButton, zoomInButton] { button.isEnabled = pdfView.document != nil }
    }

    @objc private func retry() {
        guard let url = currentURL else { return }
        currentURL = nil
        load(url: url)
    }
    @objc private func fit() { pdfView.autoScales = true }
    @objc private func zoomOut() { pdfView.zoomOut(nil) }
    @objc private func zoomIn() { pdfView.zoomIn(nil) }
}

private enum OFDPreviewError: Error { case conversionFailed }

/// 预览会话拥有转换资源；弹窗关闭时立即取消，无须等待 SwiftUI 拆卸视图。
struct LocalOFDPreview: NSViewControllerRepresentable {
    let url: URL
    let session: FilePreviewSession

    final class Coordinator {
        weak var session: FilePreviewSession?
        var cleanupID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSViewController(context: Context) -> OFDPreviewController {
        let controller = OFDPreviewController()
        context.coordinator.session = session
        context.coordinator.cleanupID = session.registerCleanup { [weak controller] in controller?.stop() }
        return controller
    }
    func updateNSViewController(_ controller: OFDPreviewController, context: Context) { controller.load(url: url) }
    static func dismantleNSViewController(_ controller: OFDPreviewController, coordinator: Coordinator) {
        coordinator.session?.removeCleanup(coordinator.cleanupID)
        controller.stop()
    }
}
