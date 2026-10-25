import AppKit
import SwiftUI

/// 在独立应用、独立偏好域与临时目录中运行真实欢迎页，检查窗口与按钮边界。
/// 不向系统注入鼠标键盘事件；按钮通过 AppKit 的 performClick 进入原有业务回调。
@MainActor
final class WelcomeAcceptance: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var host: NSHostingView<AnyView>!
    var checks: [[String: Any]] = []
    var captures: [[String: Any]] = []
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let domain = "local.filedeck.welcome-acceptance." + UUID().uuidString
    lazy var defaults = UserDefaults(suiteName: domain)!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            try? await Task.sleep(for: .seconds(45))
            checks.append(["check": "运行验收超时", "passed": false])
            finish(false)
        }
        Task {
            do { try await run(); finish(true) }
            catch { print("FAIL", error); checks.append(["check": String(describing: error), "passed": false]); finish(false) }
        }
    }

    enum Failure: Error { case check(String) }
    func check(_ title: String, _ passed: Bool) throws {
        checks.append(["check": title, "passed": passed])
        print("\(passed ? "PASS" : "FAIL") \(title)")
        fflush(stdout)
        if !passed { throw Failure.check(title) }
    }
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    func press(primary: Bool) throws {
        let buttons = descendants(host!).compactMap { $0 as? NSButton }
        try check("欢迎页仅有两个真实业务按钮", buttons.count == 2)
        let button = buttons[primary ? 0 : 1]
        try check("业务按钮可用", button.isEnabled)
        button.performClick(nil)
    }
    func show(_ store: BrowserStore) async throws {
        host = NSHostingView(rootView: AnyView(ContentView(store: store).preferredColorScheme(.light)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await settle()
    }
    func capture(_ name: String) throws {
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.check("截图缓存失败") }
        host.cacheDisplay(in: host.bounds, to: image)
        captures.append(["file": name + ".png", "windowWidth": window.frame.width,
                         "windowHeight": window.frame.height, "contentWidth": host.bounds.width,
                         "contentHeight": host.bounds.height])
        try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    func run() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FileDeck · 欢迎页验收"
        window.isReleasedWhenClosed = false
        let first = BrowserStore(defaults: defaults, arguments: [])
        try await show(first)
        try check("首次显示 16:9 外框", abs(window.frame.width / window.frame.height - 16 / 9) < 0.01)
        try check("未锁定宽高比", window.contentAspectRatio == .zero)
        for size in [NSSize(width: 1280, height: 720), NSSize(width: 1040, height: 600),
                     NSSize(width: 1000, height: 720), NSSize(width: 800, height: 720),
                     NSSize(width: 640, height: 600), NSSize(width: 1600, height: 900)] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            try await settle()
            let name = "welcome-\(Int(size.width))x\(Int(size.height))"
            try capture(name)
            let views = descendants(host!)
            let buttons = views.compactMap { $0 as? NSButton }
            try check(name + " 无滚动容器", !views.contains { $0 is NSScrollView })
            try check(name + " 两个按钮完整显示", buttons.count == 2 && buttons.allSatisfy {
                host.bounds.contains(host.convert($0.bounds, from: $0))
            })
        }
        try press(primary: true)
        try await settle()
        guard let cancelled = window.attachedSheet as? NSOpenPanel else { throw Failure.check("未弹出真实目录选择框") }
        try check("目录选择沿用原生授权面板", cancelled.canChooseDirectories && !cancelled.canChooseFiles)
        cancelled.cancel(nil)
        try await settle()
        try check("取消后仍在欢迎页且没有工作区", first.startupPhase == .welcome && !first.hasPreviousWorkspace)
        try press(primary: false)
        try await settle()
        try check("无历史时可进入空工作台", first.startupPhase == .ready)

        let folder = output.appendingPathComponent("验收目录", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("欢迎页验收".utf8).write(to: folder.appendingPathComponent("说明.txt"))
        // 先用真实 openRoot 建立隔离工作区，再创建一次普通启动，避免模拟恢复状态。
        first.openRoot(folder)
        try await settle()
        let restored = BrowserStore(defaults: defaults, arguments: [])
        try await show(restored)
        try check("有历史仍停留欢迎页", restored.startupPhase == .welcome && restored.hasPreviousWorkspace)
        try capture("welcome-with-history")
        try press(primary: false)
        try await settle()
        guard let otherPanel = window.attachedSheet as? NSOpenPanel else { throw Failure.check("次级操作未打开目录面板") }
        otherPanel.cancel(nil)
        try await settle()
        try check("取消其他文件夹不丢失历史", restored.startupPhase == .welcome && restored.hasPreviousWorkspace)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 640, height: 600)), display: true)
        try press(primary: true)
        try await settle()
        try check("继续按钮恢复真实目录与文件", restored.startupPhase == .ready && restored.currentDirectory == folder && restored.entries.count == 1)
        try check("窄窗进入工作台补足最小宽度", window.frame.width >= 1040 && window.contentMinSize.width == 1040)
        try capture("workbench-restored")

        try FileManager.default.removeItem(at: folder)
        let missing = BrowserStore(defaults: defaults, arguments: [])
        try await show(missing)
        try press(primary: true)
        try await settle()
        try check("历史目录不存在时沿用原错误提示", missing.startupPhase == .ready && missing.directoryError != nil)
        try capture("workbench-missing-directory")
    }
    func finish(_ success: Bool) {
        defaults.removePersistentDomain(forName: domain)
        let report: [String: Any] = ["passed": success, "checks": checks, "captures": captures]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
        fflush(stdout)
        exit(success ? 0 : 1)
    }
}

@main
struct RunWelcomeAcceptance {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = WelcomeAcceptance()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
