import AppKit
import XCTest
@testable import FileWorkbench

/// 用真实 NSWindow 验证默认外框与阶段切换，避免只校验一个未作用于窗口的尺寸常量。
@MainActor
final class WorkspaceWindowLayoutTests: XCTestCase {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testWelcomeStartsWidescreenWithinVisibleDisplayWithoutLockingAspect() {
        let window = window()
        defer { window.close() }
        WorkspaceWindowLayout.configure(window, ready: false, initial: true)
        XCTAssertEqual(window.frame.width / window.frame.height, 16.0 / 9.0, accuracy: 0.01)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 640, height: 600))
        XCTAssertEqual(window.contentAspectRatio, .zero)
        if let screen = window.screen {
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame))
        }
    }

    func testWorkbenchExpandsNarrowWelcomeAndThenAllowsIndependentResizing() {
        let window = window()
        defer { window.close() }
        WorkspaceWindowLayout.configure(window, ready: false, initial: true)
        window.setFrame(NSRect(x: 100, y: 100, width: 680, height: 780), display: false)
        WorkspaceWindowLayout.configure(window, ready: true, initial: false)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 1040, height: 660))
        XCTAssertGreaterThanOrEqual(window.frame.width, 1040)
        window.setFrame(NSRect(x: 100, y: 100, width: 1100, height: 850), display: false)
        XCTAssertEqual(window.frame.size, NSSize(width: 1100, height: 850))
        XCTAssertEqual(window.contentAspectRatio, .zero)
    }

    func testEnteringWorkbenchPreservesAnAlreadyUsableUserWindow() {
        let window = window()
        defer { window.close() }
        WorkspaceWindowLayout.configure(window, ready: false, initial: true)
        let size = window.frame.size
        WorkspaceWindowLayout.configure(window, ready: true, initial: false)
        XCTAssertEqual(window.frame.size, size)
    }
}
