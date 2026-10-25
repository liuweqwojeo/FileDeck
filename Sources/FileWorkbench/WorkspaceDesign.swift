import AppKit
import SwiftUI

/// 两种应用入口共用窗口规则：16:9 仅用于欢迎页首次显示，随后不干预用户缩放。
enum WorkspaceWindowLayout {
    static let welcomeSize = NSSize(width: 1280, height: 720)
    static let welcomeMinimum = NSSize(width: 640, height: 600)
    static let workbenchMinimum = NSSize(width: 1040, height: 660)

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
            frame.size.width = min(visible.width, max(frame.width, window.minSize.width))
            frame.size.height = min(visible.height, max(frame.height, window.minSize.height))
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

/// 启动页和工作区共用的浅色系统配色，避免各类空状态出现不同的视觉层级。
enum WorkspacePalette {
    static let background = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    static let sidebar = background
    static let preview = Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255)
    static let primary = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let secondary = Color(red: 99 / 255, green: 99 / 255, blue: 102 / 255)
    static let tertiary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let accent = Color(red: 0, green: 122 / 255, blue: 1)
    static let separator = Color.black.opacity(0.09)
    static let emptyIcon = Color(red: 174 / 255, green: 188 / 255, blue: 204 / 255)
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
