import AppKit
import SwiftUI

/// 独立浏览 UI 验证入口；完整编辑应用由 NativeOffice 原生入口启动。
@main
struct FileWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var browser = BrowserStore()

    var body: some Scene {
        Window("FileDeck", id: "main") {
            ContentView(store: browser)
        }
        .defaultSize(width: WorkspaceWindowLayout.welcomeSize.width, height: WorkspaceWindowLayout.welcomeSize.height)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…", action: browser.chooseFile)
                    .keyboardShortcut("o", modifiers: [.command])
                Button("打开文件夹…", action: browser.chooseFolder)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("浏览") {
                Button("后退", action: browser.goBack)
                    .keyboardShortcut("[", modifiers: [.command])
                    .disabled(!browser.canGoBack)
                Button("前进", action: browser.goForward)
                    .keyboardShortcut("]", modifiers: [.command])
                    .disabled(!browser.canGoForward)
                Button("上一级", action: browser.goUp)
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                    .disabled(!browser.canGoUp)
                Divider()
                Button("刷新", action: browser.refresh)
                    .keyboardShortcut("r", modifiers: [.command])
                Toggle("显示隐藏文件", isOn: $browser.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
