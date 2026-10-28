import AppKit
import SwiftUI
import XCTest
@testable import FileWorkbench

/// 用受控 AppKit 事件与真实视图验证路由/生命周期；不能代替物理触控板的手感验收。
@MainActor
final class WorkspaceNavigationGestureTests: XCTestCase {
    func testTwoFingerSwipeWaitsForFingerUpAndNavigatesOnlyOnce() {
        let fixture = probe()
        defer { fixture.window.close() }
        var actions: [WorkspaceSwipeIntent.Direction] = []
        fixture.view.navigate = { actions.append($0) }
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.x = 0
        XCTAssertFalse(fixture.view.handle(event), "真实触控板可能以零位移 began 开始")
        event.eventPhase = .changed; event.x = 35
        XCTAssertTrue(fixture.view.handle(event))
        XCTAssertTrue(fixture.view.handle(event))
        XCTAssertTrue(actions.isEmpty)
        event.eventPhase = .ended; event.x = 0
        XCTAssertTrue(fixture.view.handle(event))
        XCTAssertEqual(actions, [.back])
        XCTAssertFalse(fixture.view.handle(event))
        event.eventMomentum = .began; event.eventPhase = []; event.x = 90
        XCTAssertTrue(fixture.view.handle(event))
        XCTAssertEqual(actions, [.back])
    }

    func testBothDirectionsUseTheSameHistorySemantics() {
        let fixture = probe()
        defer { fixture.window.close() }
        var actions: [WorkspaceSwipeIntent.Direction] = []
        fixture.view.navigate = { actions.append($0) }
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        for delta in [CGFloat(80), -80] {
            event.eventPhase = .began; event.x = delta
            XCTAssertTrue(fixture.view.handle(event))
            event.eventPhase = .ended; event.x = 0
            XCTAssertTrue(fixture.view.handle(event))
        }
        XCTAssertEqual(actions, [.back, .forward])
    }

    func testVerticalScrollNeverChangesIntoNavigation() {
        let fixture = probe()
        defer { fixture.window.close() }
        var actions: [WorkspaceSwipeIntent.Direction] = []
        fixture.view.navigate = { actions.append($0) }
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.x = 1; event.y = 15
        XCTAssertFalse(fixture.view.handle(event))
        event.eventPhase = .changed; event.x = 100; event.y = 0
        XCTAssertFalse(fixture.view.handle(event))
        event.eventPhase = .ended; event.x = 0
        XCTAssertFalse(fixture.view.handle(event))
        XCTAssertTrue(actions.isEmpty)
    }

    func testShortCancelledAndReversedGesturesDoNotNavigate() {
        for variant in 0..<4 {
            let fixture = probe()
            defer { fixture.window.close() }
            var count = 0
            fixture.view.navigate = { _ in count += 1 }
            let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
            event.x = variant == 0 ? 20 : 90
            XCTAssertTrue(fixture.view.handle(event))
            event.eventPhase = .changed
            event.x = variant == 2 ? -85 : (variant == 3 ? -180 : 0)
            _ = fixture.view.handle(event)
            event.eventPhase = variant == 1 ? .cancelled : .ended; event.x = 0
            _ = fixture.view.handle(event)
            XCTAssertEqual(count, 0)
        }
    }

    func testWheelMomentumMissingBeginningAndNonFiniteSamplesDoNotNavigate() {
        let fixture = probe()
        defer { fixture.window.close() }
        var count = 0
        fixture.view.navigate = { _ in count += 1 }
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.x = 90; event.precise = false
        XCTAssertFalse(fixture.view.handle(event))
        event.precise = true; event.eventPhase = .changed
        XCTAssertFalse(fixture.view.handle(event))
        event.eventPhase = []; event.eventMomentum = .began
        XCTAssertFalse(fixture.view.handle(event))
        event.eventMomentum = []; event.eventPhase = .began; event.x = .nan
        XCTAssertFalse(fixture.view.handle(event))
        event.eventPhase = .ended; event.x = 0
        XCTAssertFalse(fixture.view.handle(event))
        XCTAssertEqual(count, 0)
    }

    func testNewVerticalGestureImmediatelyReleasesHorizontalMomentumCapture() {
        let fixture = probe()
        defer { fixture.window.close() }
        var count = 0
        fixture.view.navigate = { _ in count += 1 }
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.x = 90
        XCTAssertTrue(fixture.view.handle(event))
        event.eventPhase = .ended; event.x = 0
        XCTAssertTrue(fixture.view.handle(event))
        event.eventPhase = .began; event.x = 1; event.y = 30
        XCTAssertFalse(fixture.view.handle(event))
        event.eventPhase = .changed
        XCTAssertFalse(fixture.view.handle(event))
        XCTAssertEqual(count, 1)
    }

    func testUnavailableHistoryAndSystemPreferenceLeaveEventsUnconsumed() {
        let fixture = probe()
        defer { fixture.window.close() }
        fixture.view.canNavigate = { _ in false }
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.x = 90
        XCTAssertFalse(fixture.view.handle(event))
        // 手势开始时没有历史，不能在中途突然截获。
        fixture.view.canNavigate = { _ in true }; event.eventPhase = .changed
        XCTAssertFalse(fixture.view.handle(event))
        fixture.view.scrollSwipeEnabled = { false }; event.eventPhase = .began
        XCTAssertFalse(fixture.view.handle(event))
    }

    func testDisabledOrDetachedViewAndLostHistoryInvalidatePendingNavigation() {
        for reason in 0..<3 {
            let fixture = probe()
            defer { fixture.window.close() }
            var count = 0
            fixture.view.navigate = { _ in count += 1 }
            let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
            event.x = 90
            XCTAssertTrue(fixture.view.handle(event))
            if reason == 0 { fixture.view.isEnabled = { false }; fixture.view.cancelGesture() }
            if reason == 1 { fixture.view.removeFromSuperview() }
            if reason == 2 { fixture.view.canNavigate = { _ in false } }
            event.eventPhase = .ended; event.x = 0
            _ = fixture.view.handle(event)
            XCTAssertEqual(count, 0)
        }
    }

    func testNativeCoreGraphicsScrollEventsCompleteWithoutAnimationCallbacks() throws {
        var intent = WorkspaceSwipeIntent()
        var actions: [WorkspaceSwipeIntent.Direction] = []
        for (phase, delta) in [(1, 0), (2, 35), (2, 35), (4, 0), (4, 0)] {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: 0, wheel2: Int32(delta), wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            let result = intent.observe(horizontal: event.scrollingDeltaX, vertical: event.scrollingDeltaY,
                                        phase: event.phase, momentum: event.momentumPhase,
                                        precise: event.hasPreciseScrollingDeltas, canNavigate: { _ in true })
            if let direction = result.navigation { actions.append(direction) }
        }
        XCTAssertEqual(actions, [.back])
    }

    func testWindowOrApplicationDeactivationCancelsPendingSwipe() {
        for app in [false, true] {
            let fixture = probe()
            defer { fixture.window.close() }
            var count = 0
            fixture.view.navigate = { _ in count += 1 }
            let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
            event.x = 90
            XCTAssertTrue(fixture.view.handle(event))
            NotificationCenter.default.post(name: app ? NSApplication.didResignActiveNotification : NSWindow.didResignKeyNotification,
                                            object: app ? NSApp : fixture.window)
            event.eventPhase = .ended; event.x = 0
            XCTAssertFalse(fixture.view.handle(event))
            XCTAssertEqual(count, 0)
        }
    }

    func testExplicitDirectoryChangeCancelsOldGesture() {
        let fixture = probe()
        defer { fixture.window.close() }
        var count = 0
        fixture.view.navigate = { _ in count += 1 }
        fixture.view.updateLocation([URL(fileURLWithPath: "/workspace/A", isDirectory: true)])
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.x = 90
        XCTAssertTrue(fixture.view.handle(event))
        fixture.view.updateLocation([URL(fileURLWithPath: "/workspace/B", isDirectory: true)])
        event.eventPhase = .ended; event.x = 0
        XCTAssertFalse(fixture.view.handle(event))
        XCTAssertEqual(count, 0)
    }

    func testForwardedEventIsNotAccumulatedTwice() {
        let fixture = probe()
        defer { fixture.window.close() }
        var count = 0
        fixture.view.navigate = { _ in count += 1 }
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.time = 1; event.x = 5
        _ = fixture.view.handle(event)
        for time in [2.0, 3.0] {
            event.time = time; event.eventPhase = .changed; event.x = 20
            XCTAssertTrue(fixture.view.handle(event))
            XCTAssertTrue(fixture.view.handle(event))
        }
        event.time = 4; event.eventPhase = .ended; event.x = 0
        XCTAssertTrue(fixture.view.handle(event))
        XCTAssertEqual(count, 0, "45pt 不能因同一事件经过两条路径而达到阈值")
    }

    func testScrollResponderPreservesVerticalRoutingUndoAndRestoresOnStop() {
        let fixture = probe()
        defer { fixture.window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        scroll.scrollerStyle = .overlay; scroll.hasVerticalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let original = OriginalScrollResponder()
        fixture.window.contentView!.addSubview(scroll)
        scroll.nextResponder = original
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.x = 5
        XCTAssertFalse(fixture.view.handle(event))
        XCTAssertFalse(scroll.nextResponder === original)
        XCTAssertTrue(scroll.nextResponder?.wantsForwardedScrollEvents(for: .vertical) == true)
        XCTAssertTrue(scroll.nextResponder?.undoManager === original.manager)
        fixture.view.stop()
        XCTAssertTrue(scroll.nextResponder === original)
    }

    func testReadOnlyFileLabelsDoNotBlockNavigation() {
        let fixture = probe()
        defer { fixture.window.close() }
        var count = 0
        fixture.view.navigate = { _ in count += 1 }
        let label = NSTextField(labelWithString: "example.swift")
        label.frame = NSRect(x: 50, y: 80, width: 300, height: 30)
        fixture.window.contentView!.addSubview(label)
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        event.x = 80
        XCTAssertTrue(fixture.view.handle(event))
        event.eventPhase = .ended; event.x = 0
        XCTAssertTrue(fixture.view.handle(event))
        XCTAssertEqual(count, 1)
    }

    func testOtherWindowOutsideBoundsModifiersAndTextFieldsAreExcluded() {
        let fixture = probe()
        let other = TestWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { fixture.window.close(); other.close() }
        let event = GestureEvent(window: other, kind: .scrollWheel)
        XCTAssertFalse(fixture.view.handle(event))
        event.target = fixture.window
        event.point = NSPoint(x: -1, y: -1)
        XCTAssertFalse(fixture.view.handle(event))
        event.point = NSPoint(x: 120, y: 100)
        event.flags = .command
        XCTAssertFalse(fixture.view.handle(event))
        event.flags = []
        let input = NSTextField(frame: NSRect(x: 50, y: 80, width: 300, height: 30))
        fixture.window.contentView!.addSubview(input)
        XCTAssertFalse(fixture.view.handle(event))
    }

    func testSystemSheetAndHorizontalDocumentScrollingKeepTheirEvents() {
        let fixture = probe()
        defer { fixture.window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 250))
        fixture.window.contentView!.addSubview(scroll)
        let event = GestureEvent(window: fixture.window, kind: .scrollWheel)
        XCTAssertFalse(fixture.view.handle(event))
        scroll.removeFromSuperview()
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        fixture.window.beginSheet(sheet)
        XCTAssertFalse(fixture.view.handle(event))
        fixture.window.endSheet(sheet)
    }

    func testMountedBrowserRoutesBackForwardAndBlocksPreviewLayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeckSwipe-" + UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("A", isDirectory: true), second = first.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: second.appendingPathComponent("example.swift"))
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "local.fileworkbench.gesture-test-" + UUID().uuidString)!
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false, defaults: defaults)
        store.openRoot(root, remember: false); try await settled(store)
        store.navigate(to: first); try await settled(store)
        store.navigate(to: second); try await settled(store)
        let bridge = WorkspaceEditorBridge()
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: ContentView(store: store, editor: bridge).defaultAppStorage(defaults))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let view = try XCTUnwrap(descendants(hosting).compactMap { $0 as? WorkspaceBrowserNavigationGestures.GestureProbe }.first)
        XCTAssertGreaterThan(view.bounds.width, 500)
        XCTAssertGreaterThan(view.bounds.height, 400)
        let back = GestureEvent(window: window, kind: .scrollWheel)
        back.point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for delta in [CGFloat(80), -80] {
            back.eventPhase = .began; back.x = delta
            XCTAssertTrue(view.handle(back))
            back.eventPhase = .ended; back.x = 0
            XCTAssertTrue(view.handle(back))
            try await settled(store)
            XCTAssertEqual(store.currentDirectory, delta > 0 ? first : second)
        }
        let scroll = GestureEvent(window: window, kind: .scrollWheel)
        scroll.point = back.point
        for delta in [CGFloat(80), -80] {
            scroll.eventPhase = .began; scroll.x = delta
            XCTAssertTrue(view.handle(scroll))
            scroll.eventPhase = .ended; scroll.x = 0
            XCTAssertTrue(view.handle(scroll))
            try await settled(store)
            XCTAssertEqual(store.currentDirectory, delta > 0 ? first : second)
        }
        bridge.isPreviewPresented = true
        back.x = 12
        XCTAssertFalse(view.handle(back))
        XCTAssertEqual(store.currentDirectory, second)
        let systemSwipe = GestureEvent(window: window, kind: .swipe)
        systemSwipe.point = back.point
        bridge.isPreviewPresented = false
        XCTAssertFalse(view.handle(systemSwipe), "不截获可能来自三指的系统离散手势")
    }

    private func probe() -> (window: TestWindow, view: WorkspaceBrowserNavigationGestures.GestureProbe) {
        _ = NSApplication.shared
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WorkspaceBrowserNavigationGestures.GestureProbe(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.isEnabled = { true }; view.canNavigate = { _ in true }; view.scrollSwipeEnabled = { true }
        window.contentView!.addSubview(view)
        return (window, view)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settled(_ store: BrowserStore) async throws {
        let deadline = Date().addingTimeInterval(10)
        while store.isLoading || !store.treeLoading.isEmpty {
            guard Date() < deadline else { throw NSError(domain: "GestureTestTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(store.directoryError)
    }
}

private final class TestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private final class GestureEvent: NSEvent, @unchecked Sendable {
    var target: NSWindow?
    var kind: NSEvent.EventType
    var point = NSPoint(x: 120, y: 100)
    var flags: NSEvent.ModifierFlags = []
    var time: TimeInterval = 0
    var x: CGFloat = 12
    var y: CGFloat = 0
    var eventPhase: NSEvent.Phase
    var phaseReads = 0
    var eventMomentum: NSEvent.Phase = []
    var precise = true
    init(window: NSWindow, kind: NSEvent.EventType) {
        target = window; self.kind = kind; eventPhase = kind == .swipe ? [] : .began
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("仅供事件回归") }
    override var type: NSEvent.EventType { kind }
    override var timestamp: TimeInterval { time }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var deltaX: CGFloat { x }
    override var deltaY: CGFloat { y }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var phase: NSEvent.Phase { phaseReads += 1; return eventPhase }
    override var momentumPhase: NSEvent.Phase { eventMomentum }
    override var hasPreciseScrollingDeltas: Bool { precise }
}

private final class OriginalScrollResponder: NSResponder {
    let manager = UndoManager()
    override var undoManager: UndoManager? { manager }
    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool { axis == .vertical }
}
