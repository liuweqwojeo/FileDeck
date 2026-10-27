import AppKit
import XCTest
@testable import FileWorkbench

/// 使用独立剪贴板与临时目录验证 Finder 兼容的文件复制粘贴，不修改用户剪贴板。
@MainActor
final class FileClipboardTests: XCTestCase {
    func testCopyMultipleSelectionAndPastePreservesOriginalsAndExistingFiles() async throws {
        try await fixture { root, store, pasteboard in
            let target = root.appendingPathComponent("Target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let first = root.appendingPathComponent("first.txt")
            let second = root.appendingPathComponent("second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            try Data("existing".utf8).write(to: target.appendingPathComponent("first.txt"))
            store.refresh()
            try await self.settled(store)
            store.setSelection([first, second], primary: second)
            XCTAssertTrue(store.copySelectedFiles(to: pasteboard))
            let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            XCTAssertEqual(Set(copied ?? []), [first, second])
            store.pasteFiles(from: pasteboard, into: target)
            try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: first), "first")
            XCTAssertEqual(try String(contentsOf: second), "second")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("first.txt")), "existing")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("first 副本.txt")), "first")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("second.txt")), "second")
            XCTAssertNil(store.actionError)
        }
    }

    func testPasteIntoSameFolderCreatesNumberedFileAndFolderCopies() async throws {
        try await fixture { root, store, pasteboard in
            let file = root.appendingPathComponent("文档.md")
            let folder = root.appendingPathComponent("资料", isDirectory: true)
            try Data("content".utf8).write(to: file)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("nested".utf8).write(to: folder.appendingPathComponent("child.txt"))
            XCTAssertTrue(store.copyFiles([file, folder], to: pasteboard))
            for _ in 0..<2 { store.pasteFiles(from: pasteboard); try await self.settled(store) }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("文档 副本.md")), "content")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("文档 副本 2.md")), "content")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("资料 副本/child.txt")), "nested")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("资料 副本 2/child.txt")), "nested")
            XCTAssertEqual(try String(contentsOf: file), "content")
            XCTAssertNil(store.actionError)
        }
    }

    func testEmptySelectionPreservesClipboardAndTextCannotBePastedAsFile() async throws {
        try await fixture { root, store, pasteboard in
            pasteboard.setString("keep text", forType: .string)
            XCTAssertFalse(store.copySelectedFiles(to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), "keep text")
            store.pasteFiles(from: pasteboard)
            XCTAssertFalse(store.isImporting)
            XCTAssertNotNil(store.actionError)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    private func fixture(_ run: (URL, BrowserStore, NSPasteboard) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("FileClipboard-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: path.path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openQuickLocation(root)
        try await settled(store)
        try await run(root, store, pasteboard)
    }

    private func settled(_ store: BrowserStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isImporting || store.isLoading || !store.treeLoading.isEmpty {
            if Date() >= deadline { throw NSError(domain: "FileClipboardTests.Timeout", code: 1) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
