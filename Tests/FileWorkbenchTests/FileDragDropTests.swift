import AppKit
import Combine
import XCTest
@testable import FileWorkbench

/// 使用真实临时文件验证拖放的数据边界与导航状态，避免误操作用户目录。
@MainActor
final class FileDragDropTests: XCTestCase {
    func testUnselectedFolderProviderDoesNotPublishDuringNativeDragPreparation() async throws {
        try await fixture { root, target, store in
            let folder = root.appendingPathComponent("Unselected", isDirectory: true)
            let marker = root.appendingPathComponent("selected.txt")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("nested".utf8).write(to: folder.appendingPathComponent("content.txt"))
            try Data("keep".utf8).write(to: marker)
            store.refresh()
            try await self.settled(store)
            store.selectedURL = marker
            var publications = 0
            let observation = store.objectWillChange.sink { publications += 1 }
            let provider = WorkspaceFileDrag.provider(url: folder, store: store, selection: true)
            // 原生 List 尚在准备拖动项时不能同步触发视图更新；选中提示在回调返回后同步。
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(store.selectedURL, marker)
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.file-url"))
            await self.nextMainQueueTurn()
            XCTAssertEqual(store.selectedURL, folder)
            withExtendedLifetime(observation) {}
            let token = store.beginFileDrag(folder, includingSelection: true)
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Unselected/content.txt")), "nested")
            XCTAssertEqual(try String(contentsOf: marker), "keep")
        }
    }

    func testDeferredDragSelectionPreservesNewerSelectionAndActiveDrag() async throws {
        try await fixture { root, target, store in
            let first = root.appendingPathComponent("First", isDirectory: true)
            let second = root.appendingPathComponent("Second", isDirectory: true)
            for folder in [first, second] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            _ = store.beginFileDrag(first, includingSelection: true)
            store.selectedURL = target
            await self.nextMainQueueTurn()
            XCTAssertEqual(store.selectedURL, target)
            _ = store.beginFileDrag(second, includingSelection: true)
            let token = store.beginFileDrag(first, includingSelection: true)
            await self.nextMainQueueTurn()
            XCTAssertEqual(store.selectedURL, first)
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("First").path))
        }
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testInternalDragMovesFrozenMultipleSelection() async throws {
        try await fixture { root, target, store in
            let first = root.appendingPathComponent("first.txt")
            let second = root.appendingPathComponent("second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            store.refresh()
            try await self.settled(store)
            store.setSelection([first, second], primary: first)
            let token = store.beginFileDrag(first, includingSelection: true)
            store.selectedURL = target
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("first.txt")), "first")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("second.txt")), "second")
            XCTAssertEqual(store.currentDirectory, root)
            XCTAssertEqual(Set(store.entries.map(\.name)), ["Target"])
            XCTAssertNil(store.actionError)
        }
    }

    func testOptionCopyAndExternalImportUseDropDirectoryAfterNavigationChanges() async throws {
        try await fixture { root, target, store in
            let file = root.appendingPathComponent("copy.txt")
            try Data("preserve".utf8).write(to: file)
            store.refresh()
            try await self.settled(store)
            let token = store.beginFileDrag(file, includingSelection: false)
            store.dropActiveDrag(token: token, into: target, copy: true)
            store.clearCurrentDirectory()
            try await self.settled(store)
            XCTAssertNil(store.currentDirectory)
            XCTAssertEqual(try String(contentsOf: file), "preserve")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("copy.txt")), "preserve")
            let external = root.appendingPathComponent("external.txt")
            try Data("external".utf8).write(to: external)
            store.importFiles([external], into: target)
            try await self.settled(store)
            XCTAssertNil(store.currentDirectory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("external.txt")), "external")
        }
    }

    func testMoveRejectsExistingFilesAndDanglingSymlinks() async throws {
        try await fixture { root, target, store in
            let file = root.appendingPathComponent("exists.txt")
            let destination = target.appendingPathComponent("exists.txt")
            try Data("source".utf8).write(to: file)
            try Data("keep".utf8).write(to: destination)
            store.refresh()
            try await self.settled(store)
            var token = store.beginFileDrag(file, includingSelection: false)
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: file), "source")
            XCTAssertEqual(try String(contentsOf: destination), "keep")
            XCTAssertNotNil(store.actionError)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("missing"))
            token = store.beginFileDrag(file, includingSelection: false)
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: file), "source")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), root.appendingPathComponent("missing").path)
            XCTAssertNotNil(store.actionError)
        }
    }

    func testRejectsAncestorSelfSameParentAndReplacedSource() async throws {
        try await fixture { root, target, store in
            _ = store.beginFileDrag(root, includingSelection: false)
            XCTAssertFalse(store.canDropActiveDrag(into: target))
            XCTAssertFalse(store.canDropActiveDrag(into: root))
            _ = store.beginFileDrag(target, includingSelection: false)
            XCTAssertFalse(store.canDropActiveDrag(into: root))
            let file = root.appendingPathComponent("changed.txt")
            let replacement = root.appendingPathComponent("replacement.txt")
            try Data("original".utf8).write(to: file)
            try Data("replacement".utf8).write(to: replacement)
            let token = store.beginFileDrag(file, includingSelection: false)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: replacement, to: file)
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: file), "replacement")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("changed.txt").path))
            XCTAssertNotNil(store.actionError)
        }
    }

    func testMovingManagedDirectoryRebasesCurrentPathHistoryAndExpandedTree() async throws {
        try await fixture { root, target, store in
            let source = root.appendingPathComponent("Managed", isDirectory: true)
            let child = source.appendingPathComponent("Child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            store.openRoot(source, remember: false)
            try await self.settled(store)
            store.navigate(to: child)
            try await self.settled(store)
            let token = store.beginFileDrag(source, includingSelection: false)
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            let moved = target.appendingPathComponent("Managed", isDirectory: true)
            let movedChild = moved.appendingPathComponent("Child", isDirectory: true)
            XCTAssertEqual(store.managedRoots, [moved])
            XCTAssertEqual(store.currentDirectory, movedChild)
            XCTAssertEqual(store.rootURL, moved)
            XCTAssertTrue(store.history.contains(moved))
            XCTAssertTrue(store.history.contains(movedChild))
            XCTAssertTrue(store.expandedDirectories.contains(moved))
            XCTAssertFalse(store.treeChildren.keys.contains(source))
            XCTAssertNil(store.directoryError)
        }
    }

    func testDragProviderExportsFileURLAndOnlyCurrentTokenCanMove() async throws {
        try await fixture { root, target, store in
            let file = root.appendingPathComponent("export.txt")
            try Data("export".utf8).write(to: file)
            let provider = WorkspaceFileDrag.provider(url: file, store: store, selection: false)
            XCTAssertTrue(provider.canLoadObject(ofClass: NSURL.self))
            XCTAssertTrue(WorkspaceFileDrag.contentType.conforms(to: .data))
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(WorkspaceFileDrag.type))
            let exported: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.resume(returning: object as? URL)
                }
            }
            XCTAssertEqual(exported?.path, file.path)
            let payload: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: WorkspaceFileDrag.type) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            let tokenText = try XCTUnwrap(payload.flatMap { String(data: $0, encoding: .utf8) })
            XCTAssertNotNil(UUID(uuidString: tokenText))
            let old = store.beginFileDrag(file, includingSelection: false)
            _ = store.beginFileDrag(target, includingSelection: false)
            store.dropActiveDrag(token: old, into: target, copy: false)
            XCTAssertFalse(store.isImporting)
            XCTAssertEqual(try String(contentsOf: file), "export")
        }
    }

    func testChangedDropDirectoryIsRejectedBeforeWriting() async throws {
        try await fixture { root, target, _ in
            let file = root.appendingPathComponent("original.txt")
            try Data("preserve".utf8).write(to: file)
            let identity = try FileSystem.identity(at: target)
            try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("OldTarget", isDirectory: true))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let result = WorkspaceFileTransfer.perform(
                [BrowserFileReference(url: file, identity: try FileSystem.identity(at: file))],
                into: target, expectedIdentity: identity, move: true)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertTrue(result.moved.isEmpty)
            XCTAssertEqual(try String(contentsOf: file), "preserve")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        }
    }

    func testMovingSymbolicLinkPreservesItsTarget() async throws {
        try await fixture { root, target, store in
            let original = root.appendingPathComponent("original.txt")
            let link = root.appendingPathComponent("shortcut.txt")
            try Data("preserve".utf8).write(to: original)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let token = store.beginFileDrag(link, includingSelection: false)
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: original), "preserve")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("shortcut.txt").path), original.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
            XCTAssertNil(store.actionError)
        }
    }

    func testReturningFromFinderMoveRefreshesOnlyChangedDragSources() async throws {
        try await fixture { root, target, store in
            let source = root.appendingPathComponent("finder-moved.txt")
            try Data("preserve".utf8).write(to: source)
            store.refresh()
            try await self.settled(store)
            let revision = store.revision
            _ = store.beginFileDrag(source, includingSelection: true)
            store.refreshAfterExternalDrag()
            XCTAssertEqual(store.revision, revision)
            XCTAssertFalse(store.isLoading)
            _ = store.beginFileDrag(source, includingSelection: true)
            try FileManager.default.moveItem(at: source, to: target.appendingPathComponent(source.lastPathComponent))
            store.refreshAfterExternalDrag()
            try await self.settled(store)
            XCTAssertFalse(store.entries.contains { $0.url == source })
            XCTAssertNil(store.selectedURL)
            XCTAssertNil(store.actionError)
        }
    }

    func testNativeListProvidersShareTokenForTheSameMultipleSelection() async throws {
        try await fixture { root, target, store in
            let first = root.appendingPathComponent("first.txt")
            let second = root.appendingPathComponent("second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            store.refresh()
            try await self.settled(store)
            store.setSelection([first, second], primary: first)
            let token = store.beginFileDrag(first, includingSelection: true)
            XCTAssertEqual(store.beginFileDrag(second, includingSelection: true), token)
            store.dropActiveDrag(token: token, into: target, copy: false)
            try await self.settled(store)
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("first.txt")), "first")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("second.txt")), "second")
        }
    }

    func testKeyboardMoveUsesFrozenClipboardAndCanUndo() async throws {
        try await fixture { root, target, store in
            let source = root.appendingPathComponent("move.txt")
            try Data("keep".utf8).write(to: source)
            store.refresh(); try await self.settled(store)
            let folder = root.appendingPathComponent("Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("nested".utf8).write(to: folder.appendingPathComponent("inside.txt"))
            store.refresh(); try await self.settled(store)
            store.setSelection([source, folder], primary: source)
            let board = NSPasteboard(name: NSPasteboard.Name("FileDeck-move-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            XCTAssertTrue(store.copySelectedFiles(to: board))
            store.pasteFiles(from: board, into: target, move: true)
            try await self.settled(store)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("move.txt")), "keep")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Folder/inside.txt")), "nested")
            await store.undoLastFileOperation(); try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: source), "keep")
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("inside.txt")), "nested")
        }
    }

    func testKeyboardMoveFailurePreservesReplacementAndConflictingTarget() async throws {
        try await fixture { root, target, store in
            let source = root.appendingPathComponent("move.txt"), destination = target.appendingPathComponent("move.txt")
            try Data("old".utf8).write(to: source); try Data("target".utf8).write(to: destination)
            store.refresh(); try await self.settled(store)
            let board = NSPasteboard(name: NSPasteboard.Name("FileDeck-move-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            XCTAssertTrue(store.copyFiles([source], to: board))
            store.pasteFiles(from: board, into: target, move: true); try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: source), "old"); XCTAssertEqual(try String(contentsOf: destination), "target")
            try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("old.txt"))
            try Data("replacement".utf8).write(to: source)
            store.pasteFiles(from: board, into: target, move: true); try await self.settled(store)
            XCTAssertEqual(try String(contentsOf: source), "replacement"); XCTAssertEqual(try String(contentsOf: destination), "target")
            XCTAssertNotNil(store.actionError)
        }
    }

    private func fixture(_ run: (URL, URL, BrowserStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDragDrop-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootDirectory = URL(fileURLWithPath: root.path, isDirectory: true)
        let target = rootDirectory.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore(observesExternalChanges: false, restoreLastLocation: false)
        store.openQuickLocation(rootDirectory)
        try await settled(store)
        try await run(rootDirectory, target, store)
    }

    private func settled(_ store: BrowserStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isImporting || store.isLoading || !store.treeLoading.isEmpty {
            if Date() >= deadline { throw NSError(domain: "FileDragDropTests.Timeout", code: 1) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
