import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 两种应用入口共用窗口规则：16:9 仅用于欢迎页首次显示，随后不干预用户缩放。
enum WorkspaceWindowLayout {
    static let welcomeSize = NSSize(width: 1280, height: 720)
    static let welcomeMinimum = NSSize(width: 640, height: 600)
    static let workbenchMinimum = NSSize(width: 860, height: 660)

    static func configure(_ window: NSWindow, ready: Bool, initial: Bool) {
        window.contentMinSize = ready ? workbenchMinimum : welcomeMinimum
        guard !window.styleMask.contains(.fullScreen) else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        var frame = window.frame
        if initial {
            let desired = ready ? NSSize(width: 1440, height: 900) : welcomeSize
            let scale = min(1, visible.width / desired.width, visible.height / desired.height)
            frame.size = NSSize(width: desired.width * scale, height: desired.height * scale)
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        } else {
            // 仅在窄欢迎窗进入工作台时补足列表的最小空间；宽窗沿用用户尺寸。
            let top = frame.maxY
            // contentMinSize 的窗口派生值可能尚未更新，直接按内容最小值换算外框。
            let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
            frame.size.width = min(visible.width, max(frame.width, minimumFrame.width))
            frame.size.height = min(visible.height, max(frame.height, minimumFrame.height))
            frame.origin.y = top - frame.height
        }
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }
}

/// 等待 SwiftUI 挂载到真实 NSWindow 后设置一次默认尺寸，不在每次视图刷新时重置窗口。
struct WorkspaceWindowConfiguration: NSViewRepresentable {
    let ready: Bool

    func makeNSView(context: Context) -> WindowProbe { WindowProbe() }
    func updateNSView(_ view: WindowProbe, context: Context) {
        view.ready = ready
        view.scheduleConfiguration()
    }

    final class WindowProbe: NSView {
        var ready = false
        private weak var configuredWindow: NSWindow?
        private var configuredReady: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            // 上游窗口控制器先完成标题栏和容器布局，再按当前屏幕可见区域设置初始外框。
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window,
                      self.configuredWindow !== window || self.configuredReady != self.ready else { return }
                let initial = self.configuredWindow !== window
                self.configuredWindow = window
                self.configuredReady = self.ready
                WorkspaceWindowLayout.configure(window, ready: self.ready, initial: initial)
            }
        }
    }
}

/// 跟随窗口有效外观，系统高对比度与用户强调色也由 AppKit 管理。
enum WorkspacePalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let preview = Color(nsColor: .controlBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color.accentColor
    static let separator = Color(nsColor: .separatorColor)
    static let emptyIcon = Color(nsColor: .tertiaryLabelColor)
}

struct WorkspaceEmptyState<Actions: View>: View {
    let title: String
    let icon: String
    let detail: String
    var iconColor: Color = WorkspacePalette.emptyIcon
    var badge: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(iconColor)
                .frame(height: 76)
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge).font(.system(size: 24, weight: .medium))
                            .foregroundStyle(WorkspacePalette.secondary)
                            .padding(5).background(WorkspacePalette.background, in: Circle())
                            .offset(x: 10, y: 2)
                    }
                }
                .accessibilityHidden(true)
                .padding(.bottom, 17)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WorkspacePalette.primary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(WorkspacePalette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.top, 9)
            actions().padding(.top, 22)
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 启动页复用应用包图标，避免与 Finder、Dock 显示不同的品牌标识。
struct WorkspaceAppIcon: View {
    var size: CGFloat = 80
    private static let image = Bundle.main.url(forResource: "FileDeck", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// NSHostingView 嵌在 AppKit 窗口时，SwiftUI 的菜单快捷键注册会随响应链变化；
/// 仅在当前工作窗的 keyDown 中分发浏览命令，系统 sheet 和编辑工作层由调用方排除。
struct WorkspaceBrowserShortcuts: NSViewRepresentable {
    var handle: (NSEvent) -> Bool
    func makeNSView(context: Context) -> ShortcutProbe { ShortcutProbe() }
    func updateNSView(_ view: ShortcutProbe, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: ShortcutProbe, coordinator: ()) { view.stop() }

    final class ShortcutProbe: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil, event.modifierFlags.contains(.command) else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}

/// 双指轻扫直接跟踪精确滚动的 began/changed/ended，避免本地事件监视器依赖系统翻页动画回调。
struct WorkspaceSwipeIntent {
    enum Direction: Equatable { case back, forward }
    struct Feedback: Equatable {
        var direction: Direction?
        var progress: CGFloat = 0
    }
    struct Observation {
        var feedback = Feedback()
        var consumesEvent = false
        var navigation: Direction?
    }
    private enum Axis { case pending, vertical, horizontal }
    private var axis = Axis.pending
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var began = false
    private var initialDirection: Direction?
    var isActive: Bool { began }

    mutating func reset() {
        axis = .pending; horizontal = 0; vertical = 0; began = false; initialDirection = nil
    }

    mutating func observe(horizontal x: CGFloat, vertical y: CGFloat, phase: NSEvent.Phase,
                          momentum: NSEvent.Phase, precise: Bool,
                          canNavigate: (Direction) -> Bool) -> Observation {
        if phase.contains(.began) { reset(); began = true }
        guard precise, x.isFinite, y.isFinite else { reset(); return Observation() }
        if phase.contains(.cancelled) {
            let consumed = axis == .horizontal
            reset()
            return Observation(consumesEvent: consumed)
        }
        // 松手后的惯性只延续事件归属，不再次推进历史；新一轮 began 会清除归属。
        guard momentum.isEmpty else { return Observation(consumesEvent: axis == .horizontal) }
        guard began else { return Observation() }
        guard phase.contains(.began) || phase.contains(.changed) || phase.contains(.ended) else { return Observation() }
        horizontal += x; vertical += y
        guard horizontal.isFinite, vertical.isFinite else { reset(); return Observation() }
        if axis == .pending, max(abs(horizontal), abs(vertical)) >= 8 {
            let direction: Direction = horizontal > 0 ? .back : .forward
            if abs(horizontal) > abs(vertical) * 1.5, canNavigate(direction) {
                axis = .horizontal; initialDirection = direction
            } else { axis = .vertical }
        }
        let consumed = axis == .horizontal
        guard phase.contains(.ended) else {
            let direction: Direction = horizontal > 0 ? .back : .forward
            let feedback = consumed && direction == initialDirection
                ? Feedback(direction: direction, progress: min(1, abs(horizontal) / 60)) : Feedback()
            return Observation(feedback: feedback, consumesEvent: consumed)
        }
        began = false
        let direction: Direction = horizontal > 0 ? .back : .forward
        // 60pt 净位移区分轻扫与抖动；松手前折返、斜向滚动和不可用历史不会导航。
        let accepted = consumed && abs(horizontal) >= 60 && abs(horizontal) > abs(vertical) * 1.5 &&
            direction == initialDirection && canNavigate(direction)
        return Observation(consumesEvent: consumed, navigation: accepted ? direction : nil)
    }

}

/// 只处理浏览区域的原生滚动，不占据命中区域；网页/原生文档与系统 sheet 保留自己的手势。
struct WorkspaceBrowserNavigationGestures: NSViewRepresentable {
    var isEnabled: () -> Bool
    var canNavigate: (WorkspaceSwipeIntent.Direction) -> Bool
    var navigate: (WorkspaceSwipeIntent.Direction) -> Void
    var onFeedback: ((WorkspaceSwipeIntent.Feedback) -> Void)? = nil
    var location: [URL?] = []

    func makeNSView(context: Context) -> GestureProbe { GestureProbe() }
    func updateNSView(_ view: GestureProbe, context: Context) {
        view.isEnabled = isEnabled; view.canNavigate = canNavigate; view.navigate = navigate; view.onFeedback = onFeedback
        view.updateLocation(location)
        if !isEnabled() { view.cancelGesture() }
    }
    static func dismantleNSView(_ view: GestureProbe, coordinator: ()) { view.stop() }

    final class GestureProbe: NSView {
        var isEnabled: (() -> Bool)?
        var canNavigate: ((WorkspaceSwipeIntent.Direction) -> Bool)?
        var navigate: ((WorkspaceSwipeIntent.Direction) -> Void)?
        var onFeedback: ((WorkspaceSwipeIntent.Feedback) -> Void)?
        private var feedback = WorkspaceSwipeIntent.Feedback()
        private var feedbackGeneration: UInt64 = 0
        private weak var lastEvent: NSEvent?
        private var lastConsumed = false
        private var lastTimestamp: TimeInterval = 0
        private var lastPhase: NSEvent.Phase = []
        private var scrollResponders: [ObjectIdentifier: ScrollResponder] = [:]
        private weak var activeScrollView: NSScrollView?
        private var deferredScrollStart = false
        // 实时读取系统设置；测试注入隔离值，不写用户的触控板偏好。
        var scrollSwipeEnabled: () -> Bool = { NSEvent.isSwipeTrackingFromScrollEventsEnabled }
        private var monitor: Any?
        private var resignObservers: [NSObjectProtocol] = []
        private var intent = WorkspaceSwipeIntent()
        private var location: [URL?] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            // 切走窗口/应用时立即废弃半途手势，避免重新激活后的 ended 使用旧位移。
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                                   (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
                resignObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelGesture() }
                })
            }
            // 不监听 swipe：离散 swipe 可能来自三指系统手势，不应被文件浏览抢占。
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                var dispatched = event
                if self.deferredScrollStart, event.phase.contains(.changed),
                   event.scrollingDeltaX == 0, event.scrollingDeltaY == 0 {
                    _ = self.handle(event)
                    return self.deferredScrollStart ? nil : event
                }
                if self.deferredScrollStart, event.phase.contains(.changed),
                   event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                    self.deferredScrollStart = false
                    // 把延迟的原生开始阶段附在首个位移上；纵向弹性和惯性仍有完整生命周期。
                    if let copy = event.cgEvent?.copy() {
                        copy.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
                        dispatched = NSEvent(cgEvent: copy) ?? event
                    }
                }
                self.prepareScrollResponder(for: dispatched)
                let routed = self.activeScrollView != nil
                let consumed = self.handle(dispatched)
                // 静止 changed 同样没有内容位移；不让它重置原生已经判定的滚动轴。
                if routed, event.phase.contains(.changed), event.momentumPhase.isEmpty,
                   event.scrollingDeltaX == 0, event.scrollingDeltaY == 0 { return nil }
                // 零位移 began 没有滚动内容，却会让 NSScrollView 提前进入纵向内部跟踪，
                // 吞掉尚未判向的后续事件。留待首个位移交给原生滚动，不修改方向或位移。
                if routed, event.phase.contains(.began), event.scrollingDeltaX == 0, event.scrollingDeltaY == 0 {
                    self.deferredScrollStart = true
                    return nil
                }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.deferredScrollStart = false }
                // 具体滚动视图必须收到完整阶段，尤其 ended；只在其转发的水平事件上截获。
                return routed || !consumed ? dispatched : nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            for responder in scrollResponders.values {
                if let scroll = responder.scroll, scroll.nextResponder === responder {
                    scroll.nextResponder = responder.nextResponder
                }
            }
            scrollResponders = [:]
            lastEvent = nil
            activeScrollView = nil
            resignObservers.forEach(NotificationCenter.default.removeObserver)
            resignObservers = []
            cancelGesture()
        }

        func cancelGesture() {
            intent.reset()
            activeScrollView = nil
            deferredScrollStart = false
            guard feedback != WorkspaceSwipeIntent.Feedback() else { return }
            feedback = .init(); feedbackGeneration &+= 1
            let generation = feedbackGeneration
            // 取消可能来自 SwiftUI 正在更新视图；下一轮清理提示，且不覆盖新一轮手势。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.feedbackGeneration == generation else { return }
                self.onFeedback?(.init())
            }
        }

        func updateLocation(_ value: [URL?]) {
            // 按钮/键盘切换目录后，旧的半途手势不能继续作用于新分支。
            if value != location, intent.isActive { cancelGesture() }
            location = value
        }

        private var acceptsNavigation: Bool {
            guard let window, window.isKeyWindow, window.attachedSheet == nil, NSEvent.pressedMouseButtons == 0,
                  NSApp.modalWindow == nil, !isHiddenOrHasHiddenAncestor else { return false }
            return isEnabled?() == true
        }

        func handle(_ event: NSEvent) -> Bool {
            // 同一事件可能先经过本地监视器、再由滚动视图转发，不能累计两次位移。
            if event.type == .scrollWheel, event.timestamp > 0, lastEvent === event,
               lastTimestamp == event.timestamp, lastPhase == event.phase { return lastConsumed }
            prepareScrollResponder(for: event)
            let consumed = process(event)
            if event.type == .scrollWheel, event.timestamp > 0 {
                lastEvent = event; lastConsumed = consumed; lastTimestamp = event.timestamp; lastPhase = event.phase
            }
            return consumed
        }

        private func process(_ event: NSEvent) -> Bool {
            guard event.type == .scrollWheel,
                  acceptsNavigation, event.window === window,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  !hitsScrollableInput(event) else { cancelGesture(); return false }
            guard scrollSwipeEnabled() else { cancelGesture(); return false }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { activeScrollView = nil }
            let observation = intent.observe(horizontal: event.scrollingDeltaX, vertical: event.scrollingDeltaY,
                                             phase: event.phase, momentum: event.momentumPhase,
                                             precise: event.hasPreciseScrollingDeltas,
                                             canNavigate: { self.canNavigate?($0) == true })
            if observation.feedback != feedback {
                feedback = observation.feedback; feedbackGeneration &+= 1
                onFeedback?(feedback)
            }
            if let direction = observation.navigation { navigate?(direction) }
            return observation.consumesEvent
        }

        private func prepareScrollResponder(for event: NSEvent) {
            guard event.type == .scrollWheel, event.phase.contains(.began) else { return }
            activeScrollView = nil
            guard acceptsNavigation, scrollSwipeEnabled(), event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
                  event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !hitsScrollableInput(event), let content = window?.contentView else { return }
            scrollResponders = scrollResponders.filter { $0.value.scroll != nil }
            var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let view = hit {
                if let scroll = view as? NSScrollView {
                    let key = ObjectIdentifier(scroll)
                    activeScrollView = scroll
                    if let existing = scrollResponders[key], scroll.nextResponder === existing { return }
                    // 弹性滚动可能在 NSScrollView 内部跟踪后续阶段，故在具体滚动视图的
                    // 原响应者前接入水平转发；纵向滚动、键盘与菜单仍沿原链处理。
                    let responder = ScrollResponder()
                    responder.owner = self; responder.scroll = scroll
                    responder.nextResponder = scroll.nextResponder
                    scroll.nextResponder = responder
                    scrollResponders[key] = responder
                    return
                }
                hit = view.superview
            }
        }

        private final class ScrollResponder: NSResponder {
            weak var owner: GestureProbe?
            weak var scroll: NSScrollView?
            override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
                guard axis == .horizontal, let owner, let scroll, owner.acceptsNavigation, owner.scrollSwipeEnabled(),
                      (scroll.documentView?.frame.width ?? 0) <= scroll.contentSize.width + 1 else {
                    return nextResponder?.wantsForwardedScrollEvents(for: axis) ?? false
                }
                return owner.canNavigate?(.back) == true || owner.canNavigate?(.forward) == true ||
                    nextResponder?.wantsForwardedScrollEvents(for: axis) == true
            }
            override var undoManager: UndoManager? { nextResponder?.undoManager }
            override func scrollWheel(with event: NSEvent) {
                let consumed = owner?.handle(event) == true
                if !consumed || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    super.scrollWheel(with: event)
                }
            }
        }

        private func hitsScrollableInput(_ event: NSEvent) -> Bool {
            guard let content = window?.contentView else { return true }
            var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let view = hit {
                // 普通文件名标签也可能由 NSTextField 承载；仅把可编辑/可选文字留给文字交互。
                if let field = view as? NSTextField, field.isEditable || field.isSelectable { return true }
                if let text = view as? NSTextView, text.isEditable || text.isSelectable { return true }
                if let scroll = view as? NSScrollView, let document = scroll.documentView,
                   document.frame.width > scroll.contentSize.width + 1 { return true }
                hit = view.superview
            }
            return false
        }
    }
}

/// 仅决定图标外观，不扩大编辑器支持范围；分类使用目录快照和扩展名，不读取文件正文或链接目标。
struct WorkspaceFileIconDescriptor {
    enum Kind: CaseIterable {
        case folder, word, spreadsheet, presentation, pdf, markdown, code, structuredText, text
        case image, audio, video, archive, generic, system

        var symbol: String {
            switch self {
            case .folder: "folder.fill"
            case .word, .text: "text.alignleft"
            case .spreadsheet: "tablecells"
            case .presentation: "play.rectangle"
            case .pdf: "doc.richtext"
            case .markdown: "text.alignleft"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .structuredText: "curlybraces"
            case .image: "photo"
            case .audio: "waveform"
            case .video: "film"
            case .archive: "archivebox"
            case .generic, .system: "doc"
            }
        }
        var tint: Color {
            switch self {
            case .folder, .word: Color(nsColor: .systemBlue)
            case .spreadsheet: Color(nsColor: .systemGreen)
            case .presentation: Color(nsColor: .systemOrange)
            case .pdf: Color(nsColor: .systemRed)
            case .markdown, .structuredText: Color(nsColor: .systemIndigo)
            case .code, .video: Color(nsColor: .systemPurple)
            case .image: Color(nsColor: .systemTeal)
            case .audio: Color(nsColor: .systemPink)
            case .archive: Color(nsColor: .systemBrown)
            case .text, .generic, .system: Color(nsColor: .secondaryLabelColor)
            }
        }
        var letter: String? {
            switch self {
            case .word: "W"
            case .spreadsheet: "X"
            case .presentation: "P"
            case .pdf: "PDF"
            case .markdown: "M"
            default: nil
            }
        }
    }
    let url: URL
    let kind: Kind
    let marker: String
    let isSymbolicLink: Bool
    private static let capabilities = FileCapabilityRegistry()

    init(url: URL, isDirectory: Bool = false, isPackage: Bool = false,
         isSymbolicLink: Bool = false, typeIdentifier: String? = nil) {
        self.url = url; self.isSymbolicLink = isSymbolicLink
        let ext = url.pathExtension.lowercased()
        marker = ext.isEmpty ? "FILE" : String(ext.prefix(4)).uppercased()
        let type = typeIdentifier.flatMap { UTType($0) }
        // 应用包和 Finder 替身保留系统图标，避免把真实应用标识替换成普通文档纸张。
        if isPackage || ext == "app" || type?.conforms(to: .applicationBundle) == true || type?.conforms(to: .aliasFile) == true {
            kind = .system
        } else if isDirectory {
            kind = .folder
        } else if ["doc", "docm", "pages"].contains(ext) { kind = .word
        } else if ["xls", "xlsm", "tsv", "numbers"].contains(ext) { kind = .spreadsheet
        } else if ["ppt", "pptm", "key"].contains(ext) { kind = .presentation
        } else if ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst", "dmg", "iso"].contains(ext) || type?.conforms(to: .archive) == true { kind = .archive
        } else if type?.conforms(to: .audio) == true || ["mp3", "wav", "m4a", "aac", "flac", "aiff", "ogg"].contains(ext) { kind = .audio
        } else if type?.conforms(to: .movie) == true || ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(ext) { kind = .video
        } else if type?.conforms(to: .image) == true || ["gif", "webp", "svg", "tif", "tiff", "bmp", "avif"].contains(ext) { kind = .image
        } else {
            switch Self.capabilities.capabilities(for: url, contentType: type).kind {
            case .word: kind = .word
            case .spreadsheet, .csv: kind = .spreadsheet
            case .presentation: kind = .presentation
            case .pdf: kind = .pdf
            case .markdown: kind = .markdown
            case .json, .yaml: kind = .structuredText
            case .code: kind = .code
            case .text: kind = .text
            case .png, .jpeg, .heic: kind = .image
            case .directory: kind = .folder
            case .other: kind = .generic
            }
        }
    }
    init(entry: FileEntry) {
        self.init(url: entry.url, isDirectory: entry.isDirectory, isPackage: entry.isPackage,
                  isSymbolicLink: entry.isSymbolicLink, typeIdentifier: entry.typeIdentifier)
    }
}

/// 列表、网格、搜索和预览兜底共用同一矢量图标；22 pt 依靠颜色/符号，36 pt 以上增加格式标识。
struct WorkspaceFileIcon: View {
    let descriptor: WorkspaceFileIconDescriptor
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var colorScheme
    init(entry: FileEntry, size: CGFloat = 22) { descriptor = .init(entry: entry); self.size = size }
    init(url: URL, isDirectory: Bool = false, size: CGFloat = 22) {
        descriptor = .init(url: url, isDirectory: isDirectory); self.size = size
    }
    var body: some View {
        Group {
            if descriptor.kind == .system {
                Image(nsImage: NSWorkspace.shared.icon(forFile: descriptor.url.path)).resizable().scaledToFit()
            } else if descriptor.kind == .folder {
                Image(systemName: "folder.fill").resizable().scaledToFit().symbolRenderingMode(.hierarchical)
                    .foregroundStyle(descriptor.kind.tint).padding(size * 0.04)
            } else {
                paper
            }
        }.frame(width: size, height: size)
            .overlay(alignment: .bottomLeading) {
                if descriptor.isSymbolicLink && descriptor.kind != .system {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: max(6, size * 0.22), weight: .bold))
                        .foregroundStyle(WorkspacePalette.primary).padding(size * 0.045)
                        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: size * 0.07))
                }
            }
            .accessibilityHidden(true)
    }
    private var paper: some View {
        let width = size * 0.78
        let fold = width * 0.28
        let hasMarker = size >= 36 && descriptor.kind != .pdf
        return ZStack {
            WorkspaceFilePageShape().fill(WorkspacePalette.surface)
            WorkspaceFilePageShape().fill(LinearGradient(colors: [descriptor.kind.tint.opacity(0.16), descriptor.kind.tint.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
            WorkspaceFilePageShape().stroke(descriptor.kind.tint.opacity(colorScheme == .dark ? 0.65 : 0.4), lineWidth: size >= 36 ? 1 : 0.7)
            Path { path in
                path.move(to: CGPoint(x: width - fold, y: 0))
                path.addLine(to: CGPoint(x: width - fold, y: fold))
                path.addLine(to: CGPoint(x: width, y: fold))
            }.stroke(descriptor.kind.tint.opacity(0.35), lineWidth: 0.7)
            Group {
                if let letter = descriptor.kind.letter {
                    Text(letter).font(.system(size: descriptor.kind == .pdf ? max(6.5, size * 0.25) : size * (hasMarker ? 0.36 : 0.48), weight: .bold, design: .rounded))
                } else {
                    Image(systemName: descriptor.kind.symbol).font(.system(size: size * (hasMarker ? 0.33 : 0.46), weight: .medium))
                }
            }.foregroundStyle(descriptor.kind.tint)
                .position(x: width / 2, y: size * (hasMarker ? 0.43 : 0.55))
            if hasMarker {
                Text(descriptor.marker).font(.system(size: max(7, size * 0.16), weight: .semibold, design: .monospaced))
                    .foregroundStyle(descriptor.kind.tint).lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: width - 5).position(x: width / 2, y: size * 0.77)
            }
        }.frame(width: width, height: size * 0.96)
    }
}

private struct WorkspaceFilePageShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width * 0.12, fold = rect.width * 0.28
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }
}
