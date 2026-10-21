import AppKit
import AVKit
import QuickLookUI
import SwiftUI

/// 每次读取以独立请求标识发布结果；关闭同时取消读取与原生预览资源，不修改浏览器选择。
@MainActor
final class FilePreviewSession: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var preparation: Result<PreparedFilePreview, FilePreviewFailure>?
    private(set) var requestID = UUID()
    private var loadingTask: Task<Result<PreparedFilePreview, FilePreviewFailure>, Never>?
    private var cleanup: [UUID: () -> Void] = [:]

    func load(url: URL, loader: @escaping @Sendable (URL) async -> Result<PreparedFilePreview, FilePreviewFailure> = { await TextPreviewLoader.prepare(url: $0) }) async {
        cancel()
        self.url = url
        let request = requestID
        let task = Task { await loader(url) }
        loadingTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard requestID == request, !Task.isCancelled, !task.isCancelled else { return }
        loadingTask = nil
        preparation = result
    }

    func cancel() {
        requestID = UUID()
        loadingTask?.cancel()
        loadingTask = nil
        let releases = Array(cleanup.values)
        cleanup.removeAll()
        releases.forEach { $0() }
        preparation = nil
        url = nil
    }

    func registerCleanup(_ release: @escaping () -> Void) -> UUID {
        let identifier = UUID()
        cleanup[identifier] = release
        return identifier
    }

    func removeCleanup(_ identifier: UUID?) {
        if let identifier { cleanup.removeValue(forKey: identifier) }
    }
}

/// 有界文本预览与系统 Quick Look 的统一容器；能力限制和真实读取失败使用不同恢复入口。
@MainActor
struct FilePreviewView: View {
    let url: URL
    var revision: UUID

    @StateObject private var session: FilePreviewSession
    @State private var openFailed = false
    @State private var retryRevision = UUID()

    init(url: URL, revision: UUID = UUID(), session: FilePreviewSession? = nil) {
        self.url = url
        self.revision = revision
        _session = StateObject(wrappedValue: session ?? FilePreviewSession())
    }

    // URL 变化与 .task 开始之间仍可能有一帧更新，不能把上个文件内容显示在新标题下。
    private var preparation: Result<PreparedFilePreview, FilePreviewFailure>? {
        session.url == url ? session.preparation : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let preparation {
                    switch preparation {
                    case .success(.text(let document)):
                        textPreview(document)
                    case .success(.media):
                        LocalMediaPreview(url: url, session: session)
                            .id(PreviewIdentity(url: url, revision: retryRevision))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .success(.quickLook):
                        SystemQuickLookPreview(url: url, revision: retryRevision, session: session)
                            .id(PreviewIdentity(url: url, revision: retryRevision))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure(let failure):
                        unavailablePreview(failure)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取文件…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if case .success = preparation {
                Divider()
                HStack(spacing: 12) {
                    Text(footerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button(action: openFile) {
                        Label("默认应用打开", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .help("使用 macOS 为此文件配置的默认应用打开")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.bar)
            }
        }
        .task(id: PreviewRequest(url: url, revision: revision, retryRevision: retryRevision)) {
            await session.load(url: url)
        }
        .onDisappear { session.cancel() }
        .alert("无法打开文件", isPresented: $openFailed) {
            Button("好", role: .cancel) { }
        } message: {
            Text("请确认文件仍然存在且具有访问权限，并已安装支持此格式的应用。")
        }
    }

    private var footerText: String {
        switch preparation {
        case .success(.text(let document)):
            return "\(document.encodingName) · 只读文本预览"
        case .success(.media):
            return "本机媒体预览 · 不自动播放"
        case .success(.quickLook):
            return "macOS 系统预览 · 格式支持取决于系统与已安装的预览扩展"
        default:
            return "文件预览"
        }
    }

    private func textPreview(_ document: TextPreviewDocument) -> some View {
        VStack(spacing: 0) {
            if document.isTruncated {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("文件较大，仅显示前 1 MiB 内容。使用默认应用查看完整文件。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.accentColor.opacity(0.07))
                Divider()
            }
            if document.text.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 30))
                    Text("此文件没有文本内容")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReadOnlyTextPreview(text: document.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func unavailablePreview(_ failure: FilePreviewFailure) -> some View {
        GeometryReader { geometry in
            // 预览栏允许收窄；短视口下可滚动查看完整恢复操作，不能被外层圆角容器裁掉。
            ScrollView {
                unavailableContent(failure)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .help(failure.localizedDescription)
    }

    private func unavailableContent(_ failure: FilePreviewFailure) -> some View {
        VStack(spacing: 14) {
            if failure.isUnsupported {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().scaledToFit().frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(.orange)
                            .background(.background, in: Circle())
                            .offset(x: 8, y: 3)
                    }
                    .accessibilityHidden(true)
            }
            Text(failure.isUnsupported ? "暂不支持预览此文件" : "无法加载文件预览")
                .font(.system(size: 16, weight: .semibold))
            Text(failure.isUnsupported
                 ? "可以使用系统默认应用打开，或查看文件的基本信息。"
                 : "请检查文件是否仍然存在，以及当前访问权限。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { recoveryActions(failure) }.fixedSize()
                VStack(spacing: 10) { recoveryActions(failure) }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: 360)
    }

    @ViewBuilder private func recoveryActions(_ failure: FilePreviewFailure) -> some View {
        if failure.isUnsupported {
            Button("打开文件", action: openFile)
                .buttonStyle(.borderedProminent)
        } else {
            Button("重试") { retryRevision = UUID() }
                .buttonStyle(.borderedProminent)
        }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .buttonStyle(.bordered)
    }

    private func openFile() {
        let request = session.requestID
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                guard session.requestID == request, session.url == url else { return }
                openFailed = error != nil
            }
        }
    }
}

private struct PreviewRequest: Hashable {
    let url: URL
    let revision: UUID
    let retryRevision: UUID
}

private struct PreviewIdentity: Hashable {
    let url: URL
    let revision: UUID
}

private struct SystemQuickLookPreview: NSViewRepresentable {
    let url: URL
    let revision: UUID
    let session: FilePreviewSession

    final class Coordinator {
        var identity: PreviewIdentity?
        var cleanupID: UUID?
        weak var session: FilePreviewSession?
        var closed = false

        func close(_ view: QLPreviewView) {
            guard !closed else { return }
            closed = true
            view.previewItem = nil
            view.close()
            identity = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        // SwiftUI 会反复装卸视图，由 dismantle 负责关闭，避免窗口重用已关闭的预览。
        view.shouldCloseWithWindow = false
        context.coordinator.session = session
        context.coordinator.cleanupID = session.registerCleanup { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.close(view) }
        }
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        let identity = PreviewIdentity(url: url, revision: revision)
        guard !context.coordinator.closed, context.coordinator.identity != identity else { return }
        view.autostarts = false
        if context.coordinator.identity?.url == url {
            view.refreshPreviewItem()
        } else {
            view.previewItem = url as NSURL
        }
        // Quick Look 异步生成预览；赋值不代表文件已成功渲染，也不猜测不支持状态。
        context.coordinator.identity = identity
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        coordinator.session?.removeCleanup(coordinator.cleanupID)
        coordinator.close(view)
    }
}

/// 显式拥有 AVPlayer，关闭时立即切断播放与资源加载，不依赖 Quick Look 的内部播放器寿命。
@MainActor
final class FileMediaPreviewController: NSViewController {
    private(set) var player: AVPlayer?
    private(set) var currentURL: URL?
    private(set) var playerView = AVPlayerView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var observation: NSKeyValueObservation?
    private var requestID = UUID()

    override func loadView() {
        view = NSView()
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32)
        ])
    }

    func load(url: URL) {
        guard currentURL != url else { return }
        stop()
        _ = view
        guard url.isFileURL else {
            errorLabel.stringValue = "仅支持预览本机媒体文件。"
            errorLabel.isHidden = false
            return
        }
        currentURL = url
        let request = requestID
        // 禁止媒体数据引用其他路径或网络；权限仍由调用方保留的 macOS 授权及系统读取决定。
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        playerView.player = player
        errorLabel.isHidden = true
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == request, self.player?.currentItem === item else { return }
                if item.status == .failed {
                    self.player?.pause()
                    self.errorLabel.stringValue = "无法播放此媒体：" + (item.error?.localizedDescription ?? "系统不支持此格式或无法读取文件。")
                    self.errorLabel.isHidden = false
                }
            }
        }
    }

    func stop() {
        requestID = UUID()
        observation?.invalidate()
        observation = nil
        player?.pause()
        player?.cancelPendingPrerolls()
        player?.currentItem?.cancelPendingSeeks()
        player?.currentItem?.asset.cancelLoading()
        player?.replaceCurrentItem(with: nil)
        playerView.player = nil
        player = nil
        currentURL = nil
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stop()
    }
}

private struct LocalMediaPreview: NSViewControllerRepresentable {
    let url: URL
    let session: FilePreviewSession

    final class Coordinator {
        weak var session: FilePreviewSession?
        var cleanupID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSViewController(context: Context) -> FileMediaPreviewController {
        let controller = FileMediaPreviewController()
        context.coordinator.session = session
        context.coordinator.cleanupID = session.registerCleanup { [weak controller] in controller?.stop() }
        return controller
    }
    func updateNSViewController(_ controller: FileMediaPreviewController, context: Context) { controller.load(url: url) }
    static func dismantleNSViewController(_ controller: FileMediaPreviewController, coordinator: Coordinator) {
        coordinator.session?.removeCleanup(coordinator.cleanupID)
        controller.stop()
    }
}

private struct ReadOnlyTextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> ReadOnlyTextScrollView {
        let scrollView = ReadOnlyTextScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // NSTextView 适合有界的大段文本，保留选择/复制与横向滚动，不创建逐行 SwiftUI 视图。
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: ReadOnlyTextScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.sizeToFit()
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

private final class ReadOnlyTextScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        // SwiftUI 初次创建时视口可能为零；拿到实际尺寸后让空白区域至少铺满整个预览栏。
        let minimumSize = contentSize
        if textView.minSize != minimumSize {
            textView.minSize = minimumSize
            textView.sizeToFit()
        }
    }
}
