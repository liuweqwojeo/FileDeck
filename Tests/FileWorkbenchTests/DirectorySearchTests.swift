import CoreFoundation
import Darwin
import XCTest
@testable import FileWorkbench

/// 使用真实 UUID 文件树与 fd 读取；注入边界只用于确定性制造阻塞、失败和替换，不扫描用户目录。
@MainActor
final class DirectorySearchTests: XCTestCase {
    func testRecursiveNamesStayInsideSelectedSubtreeAndMatchBasenames() throws {
        try fixture { base in
            let scope = try directory(base, "scope")
            try write(scope, "notes/Needle.txt", "content")
            try write(scope, "Needle-folder/plain.txt", "content")
            try write(base, "outside/Needle.txt", "outside")
            let result = try search(scope, "needle")
            XCTAssertEqual(result.hits.map(\.id), ["Needle-folder", "notes/Needle.txt"])
            XCTAssertTrue(result.hits[0].isDirectory)
            XCTAssertEqual(result.end, .completed)
            XCTAssertEqual(result.bytesRead, 0, "名称搜索不读取正文")
            XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("outside/Needle.txt")), "outside")
        }
    }

    func testCaseSensitiveLiteralSubstringAndUnicodeNames() throws {
        try fixture { root in
            try write(root, "中文😀-Needle[1].txt", "none")
            XCTAssertEqual(try search(root, "needle[1]").hits.count, 1)
            XCTAssertEqual(try search(root, "needle[1]", sensitive: true).hits.count, 0)
            XCTAssertEqual(try search(root, "中文😀").hits.count, 1)
            XCTAssertEqual(try search(root, "Needle.*").hits.count, 0, "不把用户输入解释成正则")
        }
    }

    func testDefaultExclusionsHiddenItemsPackagesAndSymlinksAreNotTraversed() throws {
        try fixture { root in
            for folder in ["node_modules", "BUILD", "vendor", ".git", ".hidden", "Doc.rtfd", "Tool.app", "normal"] {
                try write(root, folder + "/needle.txt", "needle")
            }
            let outside = try directory(root, "external")
            try write(outside, "needle.txt", "needle")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("needle-link.txt"), withDestinationURL: outside.appendingPathComponent("needle.txt"))
            let result = try search(root, "needle")
            XCTAssertEqual(Set(result.hits.map(\.id)), ["external/needle.txt", "normal/needle.txt"])
            XCTAssertEqual(result.skipped[.package], 2)
            XCTAssertEqual(result.skipped[.link], 2)
            XCTAssertEqual(result.skipped[.hidden], 2)
            XCTAssertEqual(result.skipped[.excluded], 3)
        }
    }

    func testExplicitHiddenAndCustomExclusionsCanReplaceDefaults() throws {
        try fixture { root in
            try write(root, ".hidden/needle.txt", "needle")
            try write(root, "build/needle.txt", "needle")
            try write(root, "archive/needle.txt", "needle")
            let request = try DirectorySearchRequest(root: root, term: "needle", includeHidden: true, excludedDirectories: ["ARCHIVE"])
            let result = run(request)
            XCTAssertEqual(Set(result.hits.map(\.id)), [".hidden/needle.txt", "build/needle.txt"])
            XCTAssertEqual(result.skipped[.excluded], 1)
        }
    }

    func testExplicitExcludedBasenameRootIsStillSearchable() throws {
        try fixture { root in
            let build = try directory(root, "build")
            try write(build, "needle.txt", "yes")
            XCTAssertEqual(try search(build, "needle").hits.map(\.id), ["needle.txt"])
        }
    }

    func testContentsUseTextDecodingAndReportFirstMatchingLineWithMixedEndings() throws {
        try fixture { root in
            try write(root, "nested/document.txt", "one\r\ntwo\r中文 NEEDLE😀\nneedle again")
            let result = try search(root, "needle", mode: .content)
            XCTAssertEqual(result.hits.map(\.id), ["nested/document.txt"], "\(result)")
            let hit = try XCTUnwrap(result.hits.first)
            XCTAssertEqual(hit.line, 3)
            XCTAssertTrue(try XCTUnwrap(hit.excerpt).contains("NEEDLE😀"))
            XCTAssertFalse(try XCTUnwrap(hit.excerpt).contains("\r"))
            XCTAssertEqual(result.end, .completed)
            XCTAssertEqual(try search(root, "nEeDlE", mode: .content, sensitive: true).hits.count, 0)
        }
    }

    func testUTF8BOMUTF16AndGB18030ContentsAreSearchable() throws {
        try fixture { root in
            let text = "第一行\n命中😀"
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            for (name, encoding, prefix) in [("utf8", String.Encoding.utf8, Data([0xEF, 0xBB, 0xBF])),
                                              ("le", .utf16LittleEndian, Data([0xFF, 0xFE])),
                                              ("be", .utf16BigEndian, Data([0xFE, 0xFF])), ("gb", gb, Data())] {
                try (prefix + XCTUnwrap(text.data(using: encoding))).write(to: root.appendingPathComponent(name + ".txt"))
            }
            let result = try search(root, "命中😀", mode: .content)
            XCTAssertEqual(result.hits.count, 4)
            XCTAssertTrue(result.hits.allSatisfy { $0.line == 2 })
            XCTAssertEqual(result.issueCount, 0)
        }
    }

    func testBinaryAndNonTextFormatsAreSkippedWithoutParsingContainers() throws {
        try fixture { root in
            try Data([0x00, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65]).write(to: root.appendingPathComponent("binary.txt"))
            try Data([0xFF, 0xFE, 0x41]).write(to: root.appendingPathComponent("broken.txt"))
            for name in ["container.docx", "document.pdf", "image.png"] { try write(root, name, "needle") }
            try write(root, "plain.csv", "needle,value")
            let result = try search(root, "needle", mode: .content)
            XCTAssertEqual(result.hits.map(\.id), ["plain.csv"])
            XCTAssertEqual(result.skipped[.nonText], 5)
            XCTAssertEqual(result.issueCount, 0)
        }
    }

    func testFIFOAndSimulatedOtherVolumeNeverReachRead() throws {
        try fixture { root in
            let fifo = root.appendingPathComponent("needle-pipe.txt")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            try write(root, "needle-volume.txt", "needle")
            var io = DirectorySearchEngine.IO()
            let metadata = io.metadata
            io.metadata = { parent, name in
                var value = try metadata(parent, name)
                if name == "needle-volume.txt" { value.st_dev += 1 }
                return value
            }
            io.read = { _, _ in XCTFail("不能读取 FIFO 或其他卷"); return Data() }
            let request = try DirectorySearchRequest(root: root, term: "needle", mode: .content)
            let result = DirectorySearchEngine.run(request, control: .init(request), io: io)
            XCTAssertTrue(result.hits.isEmpty)
            XCTAssertEqual(result.skipped[.special], 1)
            XCTAssertEqual(result.skipped[.volume], 1)
            XCTAssertEqual(result.bytesRead, 0)
        }
    }

    func testDepthLimitReportsSkippedSubtrees() throws {
        try fixture { root in
            try write(root, "a/b/needle.txt", "needle")
            var limits = DirectorySearchRequest.Limits(); limits.depth = 1
            let result = try search(root, "needle", limits: limits)
            XCTAssertTrue(result.hits.isEmpty)
            XCTAssertEqual(result.skipped[.depth], 1)
            XCTAssertTrue(result.hasUnsearchedItems)
            XCTAssertEqual(result.visited, 1)
        }
    }

    func testEntryAndResultCapsMarkIncompleteWithoutGrowingResults() throws {
        try fixture { root in
            for i in 0..<12 { try write(root, "needle-\(i).txt", "needle") }
            var limits = DirectorySearchRequest.Limits(); limits.entries = 3
            let entries = try search(root, "needle", limits: limits)
            XCTAssertEqual(entries.visited, 3)
            XCTAssertEqual(entries.hits.count, 3)
            XCTAssertEqual(entries.end, .entryLimit)
            limits.entries = 50_000; limits.results = 2
            let results = try search(root, "needle", limits: limits)
            XCTAssertEqual(results.hits.count, 2)
            XCTAssertEqual(results.end, .resultLimit)
        }
    }

    func testSingleFileAndTotalContentBudgetsAreDistinctAndExactBoundWorks() throws {
        try fixture { root in
            try write(root, "a.txt", "needle")
            var limits = DirectorySearchRequest.Limits(); limits.fileBytes = 5
            let large = try search(root, "needle", mode: .content, limits: limits)
            XCTAssertEqual(large.skipped[.size], 1)
            XCTAssertEqual(large.bytesRead, 0)
            XCTAssertTrue(large.hasUnsearchedItems)
            limits.fileBytes = 6; limits.totalBytes = 6
            let exact = try search(root, "needle", mode: .content, limits: limits)
            XCTAssertEqual(exact.hits.count, 1)
            XCTAssertEqual(exact.bytesRead, 6)
            XCTAssertEqual(exact.end, .completed)
            try write(root, "b.txt", "needle")
            let total = try search(root, "needle", mode: .content, limits: limits)
            XCTAssertEqual(total.hits.count, 1)
            XCTAssertEqual(total.bytesRead, 6)
            XCTAssertEqual(total.end, .byteLimit)
        }
    }

    func testCancelBeforeStartDoesNotEnumerate() throws {
        try fixture { root in
            try write(root, "needle.txt", "needle")
            let request = try DirectorySearchRequest(root: root, term: "needle")
            let control = DirectorySearchControl(request); control.cancel()
            let result = DirectorySearchEngine.run(request, control: control)
            XCTAssertEqual(result.end, .cancelled)
            XCTAssertEqual(result.visited, 0)
            XCTAssertEqual(control.snapshot, result)
        }
    }

    func testCancelDuringChunkReadDoesNotPublishInflightMatch() throws {
        try fixture { root in
            try write(root, "a.txt", "needle" + String(repeating: "x", count: 100_000))
            let request = try DirectorySearchRequest(root: root, term: "needle", mode: .content)
            let control = DirectorySearchControl(request)
            var io = DirectorySearchEngine.IO(); let read = io.read
            io.read = { fd, count in let data = try read(fd, count); control.cancel(); return data }
            let result = DirectorySearchEngine.run(request, control: control, io: io)
            XCTAssertEqual(result.end, .cancelled)
            XCTAssertTrue(result.hits.isEmpty)
            XCTAssertEqual(result.bytesRead, 65_536)
        }
    }

    func testReadFailureContinuesAndCapsIssueDetails() throws {
        try fixture { root in
            for i in 0..<25 { try write(root, "needle-\(i).txt", "needle") }
            var io = DirectorySearchEngine.IO(); let metadata = io.metadata
            io.metadata = { fd, name in
                if name == "needle-24.txt" { return try metadata(fd, name) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            }
            let request = try DirectorySearchRequest(root: root, term: "needle")
            let result = DirectorySearchEngine.run(request, control: .init(request), io: io)
            XCTAssertEqual(result.hits.map(\.id), ["needle-24.txt"])
            XCTAssertEqual(result.issueCount, 24)
            XCTAssertEqual(result.issues.count, 20)
            XCTAssertEqual(result.end, .completed)
        }
    }

    func testReplacingFileWithSymlinkBetweenStatAndOpenNeverReadsOutside() throws {
        try fixture { base in
            let root = try directory(base, "scope")
            let file = try write(root, "a.txt", "needle")
            let outside = try write(base, "outside.txt", "secret needle")
            var io = DirectorySearchEngine.IO(); let metadata = io.metadata
            io.metadata = { fd, name in
                let value = try metadata(fd, name)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
                return value
            }
            io.read = { _, _ in XCTFail("替换链接不能读到范围外正文"); return Data() }
            let request = try DirectorySearchRequest(root: root, term: "needle", mode: .content)
            let result = DirectorySearchEngine.run(request, control: .init(request), io: io)
            XCTAssertTrue(result.hits.isEmpty)
            XCTAssertEqual(result.bytesRead, 0)
            XCTAssertEqual(result.issueCount, 1)
            XCTAssertEqual(try String(contentsOf: outside), "secret needle")
        }
    }

    func testReplacedFileDuringReadIsNotReturnedAsStableHit() throws {
        try fixture { root in
            let file = try write(root, "a.txt", "needle" + String(repeating: "x", count: 100_000))
            let once = SearchOnce()
            var io = DirectorySearchEngine.IO(); let read = io.read
            io.read = { fd, count in
                let data = try read(fd, count)
                if once.take() { try Data("replacement".utf8).write(to: file, options: .atomic) }
                return data
            }
            let request = try DirectorySearchRequest(root: root, term: "needle", mode: .content)
            let result = DirectorySearchEngine.run(request, control: .init(request), io: io)
            XCTAssertTrue(result.hits.isEmpty)
            XCTAssertEqual(result.skipped[.changed], 1)
            XCTAssertTrue(result.hasUnsearchedItems)
            XCTAssertEqual(try String(contentsOf: file), "replacement")
        }
    }

    func testRootReplacementDuringReadStopsAndRejectsOldSnapshot() throws {
        try fixture { base in
            let root = try directory(base, "scope")
            try write(root, "a.txt", "needle" + String(repeating: "x", count: 100_000))
            let once = SearchOnce()
            var io = DirectorySearchEngine.IO(); let read = io.read
            io.read = { fd, count in
                let data = try read(fd, count)
                if once.take() {
                    try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("old"))
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                }
                return data
            }
            let request = try DirectorySearchRequest(root: root, term: "needle", mode: .content)
            let result = DirectorySearchEngine.run(request, control: .init(request), io: io)
            guard case .failed = result.end else { return XCTFail("范围变化不能报告完整成功") }
            XCTAssertTrue(result.hits.isEmpty)
            XCTAssertEqual(result.bytesRead, 65_536)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testRootReplacementBeforeWorkerAndPackageOrSymlinkRootsAreRejected() throws {
        try fixture { base in
            let root = try directory(base, "scope")
            let request = try DirectorySearchRequest(root: root, term: "needle", expectedRootIdentity: try FileSystem.identity(at: root))
            try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("old"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            guard case .failed = run(request).end else { return XCTFail("冻结的目录身份已被替换") }
            let package = try directory(base, "Doc.rtfd")
            guard case .failed = try search(package, "needle").end else { return XCTFail("不能搜索文档包根") }
            let link = base.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            guard case .failed = try search(link, "needle").end else { return XCTFail("不能搜索链接根") }
        }
    }

    func testResultLocationRejectsReplacementAndAncestorSymlinkAndEscapes() throws {
        try fixture { base in
            let root = try directory(base, "scope")
            let file = try write(root, "nested/needle.txt", "needle")
            let request = try DirectorySearchRequest(root: root, term: "needle", expectedRootIdentity: try FileSystem.identity(at: root))
            let hit = try XCTUnwrap(run(request).hits.first)
            XCTAssertEqual(try DirectorySearchEngine.validatedURL(for: hit, request: request), file)
            try Data("replacement".utf8).write(to: file, options: .atomic)
            XCTAssertThrowsError(try DirectorySearchEngine.validatedURL(for: hit, request: request))
            let current = try XCTUnwrap(run(request).hits.first)
            let nested = file.deletingLastPathComponent(), moved = base.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: nested, to: moved)
            try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: moved)
            XCTAssertThrowsError(try DirectorySearchEngine.validatedURL(for: current, request: request))
            let escape = DirectorySearchHit(components: ["..", "moved", "needle.txt"], identity: current.identity, isDirectory: false, line: nil, excerpt: nil)
            XCTAssertThrowsError(try DirectorySearchEngine.validatedURL(for: escape, request: request))
        }
    }

    func testInvalidQueriesExclusionsAndBudgetsAreRejected() throws {
        try fixture { root in
            for term in ["", "   ", String(repeating: "😀", count: 257)] {
                XCTAssertThrowsError(try DirectorySearchRequest(root: root, term: term))
            }
            for exclusions: Set<String> in [[".."], ["path/to"], ["bad\0name"]] {
                XCTAssertThrowsError(try DirectorySearchRequest(root: root, term: "x", excludedDirectories: exclusions))
            }
            var limits = DirectorySearchRequest.Limits(); limits.entries = 50_001
            XCTAssertThrowsError(try DirectorySearchRequest(root: root, term: "x", limits: limits))
            XCTAssertThrowsError(try DirectorySearchRequest(root: URL(string: "https://example.invalid")!, term: "x"))
        }
    }

    func testSessionCoalescesRestartRequestsAndNeverRunsTwoRealWorkers() async throws {
        let base = try makeRoot(); defer { try? FileManager.default.removeItem(at: base) }
        try write(base, "C.txt", "C")
        let gate = SearchWorkerGate()
        defer { gate.release() }
        let session = DirectorySearchSession(worker: { request, control in gate.run(request, control) })
        session.start(try DirectorySearchRequest(root: base, term: "A"))
        try await wait { gate.calls == ["A"] }
        session.start(try DirectorySearchRequest(root: base, term: "B"))
        session.start(try DirectorySearchRequest(root: base, term: "C"))
        XCTAssertTrue(session.isStopping)
        XCTAssertEqual(session.snapshot?.request.term, "C")
        gate.release()
        try await wait { !session.isRunning }
        XCTAssertEqual(gate.calls, ["A", "C"])
        XCTAssertEqual(gate.maximumActive, 1)
        XCTAssertEqual(session.snapshot?.request.term, "C")
        XCTAssertEqual(session.snapshot?.hits.map(\.id), ["C.txt"])
        XCTAssertEqual(session.snapshot?.end, .completed)
    }

    func testCancelQueuedRequestAndResetDoNotResurrectOldResults() async throws {
        let base = try makeRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let gate = SearchWorkerGate(); defer { gate.release() }
        let session = DirectorySearchSession(worker: { request, control in gate.run(request, control) })
        session.start(try DirectorySearchRequest(root: base, term: "A"))
        try await wait { gate.calls == ["A"] }
        session.start(try DirectorySearchRequest(root: base, term: "B"))
        session.cancel()
        XCTAssertEqual(session.snapshot?.end, .cancelled)
        session.reset()
        XCTAssertNil(session.snapshot)
        gate.release()
        try await wait { !session.isRunning }
        XCTAssertEqual(gate.calls, ["A"])
        XCTAssertNil(session.snapshot)
    }

    func testRequestCreationDoesNotReadScopeAndWorkerBindsIdentity() throws {
        try fixture { root in
            let missing = root.appendingPathComponent("not-created", isDirectory: true)
            let missingRequest = try DirectorySearchRequest(root: missing, term: "needle")
            XCTAssertNil(missingRequest.rootIdentity)
            guard case .failed = run(missingRequest).end else { return XCTFail("不存在的范围应由后台工作器报告") }
            let request = try DirectorySearchRequest(root: root, term: "needle")
            let result = run(request)
            XCTAssertEqual(result.request.rootIdentity, try FileSystem.identity(at: root))
            XCTAssertEqual(result.end, .completed)
        }
    }

    func testUnreadableEntriesStillConsumeEntryBudget() throws {
        try fixture { root in
            for i in 0..<5 { try write(root, "entry-\(i).txt", "needle") }
            var limits = DirectorySearchRequest.Limits(); limits.entries = 1
            let request = try DirectorySearchRequest(root: root, term: "needle", limits: limits)
            var io = DirectorySearchEngine.IO()
            io.metadata = { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            let result = DirectorySearchEngine.run(request, control: .init(request), io: io)
            XCTAssertEqual(result.visited, 1)
            XCTAssertEqual(result.issueCount, 1)
            XCTAssertEqual(result.end, .entryLimit)
            XCTAssertTrue(result.hits.isEmpty)
        }
    }

    func testContentReadFailureDoesNotHideOtherMatchesAndExcerptIsBoundedByScalars() throws {
        try fixture { root in
            let bad = try write(root, "a.txt", "needle")
            try write(root, "b.txt", "needle x" + String(repeating: "\u{301}", count: 20_000))
            let badIdentity = try FileSystem.identity(at: bad)
            var io = DirectorySearchEngine.IO(); let read = io.read
            io.read = { fd, count in
                var metadata = stat()
                guard fstat(fd, &metadata) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if FileSystem.identity(metadata) == badIdentity { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                return try read(fd, count)
            }
            let request = try DirectorySearchRequest(root: root, term: "needle", mode: .content)
            let result = DirectorySearchEngine.run(request, control: .init(request), io: io)
            XCTAssertEqual(result.issueCount, 1)
            XCTAssertEqual(result.hits.map(\.id), ["b.txt"])
            let excerpt = try XCTUnwrap(result.hits.first?.excerpt)
            XCTAssertLessThanOrEqual(excerpt.unicodeScalars.count, 200)
            XCTAssertLessThanOrEqual(excerpt.utf8.count, 800)
        }
    }

    private func search(_ root: URL, _ term: String, mode: DirectorySearchRequest.Mode = .name, sensitive: Bool = false,
                        limits: DirectorySearchRequest.Limits = .init()) throws -> DirectorySearchSnapshot {
        run(try DirectorySearchRequest(root: root, term: term, mode: mode, caseSensitive: sensitive, limits: limits))
    }
    private func run(_ request: DirectorySearchRequest) -> DirectorySearchSnapshot { DirectorySearchEngine.run(request, control: .init(request)) }
    @discardableResult private func directory(_ root: URL, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @discardableResult private func write(_ root: URL, _ relative: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileDeck-F5-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.resolvingSymlinksInPath()
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }; try body(root)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw DirectorySearchEngine.failure("等待搜索测试超时") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private final class SearchOnce: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
private final class SearchWorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var names: [String] = []
    private var active = 0
    private var maximum = 0
    var calls: [String] { condition.lock(); defer { condition.unlock() }; return names }
    var maximumActive: Int { condition.lock(); defer { condition.unlock() }; return maximum }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func run(_ request: DirectorySearchRequest, _ control: DirectorySearchControl) -> DirectorySearchSnapshot {
        condition.lock(); names.append(request.term); active += 1; maximum = max(maximum, active)
        while !released { condition.wait() }
        condition.unlock()
        let result = DirectorySearchEngine.run(request, control: control)
        condition.lock(); active -= 1; condition.unlock()
        return result
    }
}
