import Combine
import Darwin
import Foundation

/// 搜索是显式、只读且有预算的一次性快照，不改动浏览列表，也不建立全盘索引。
struct DirectorySearchRequest: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable { case name = "名称", content = "文本内容" }
    struct Limits: Equatable, Sendable {
        var entries = 50_000
        var results = 1_000
        var depth = 64
        var fileBytes = 2 * 1_048_576
        var totalBytes = 256 * 1_048_576
    }
    static let defaultExclusions: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "vendor", "pods", "carthage",
        ".build", "build", "dist", "deriveddata", ".next", ".cache"
    ]
    let root: URL
    var rootIdentity: FileIdentity?
    let term: String
    let mode: Mode
    let caseSensitive: Bool
    let includeHidden: Bool
    let excludedDirectories: Set<String>
    let limits: Limits

    init(root: URL, term: String, mode: Mode = .name, caseSensitive: Bool = false,
         includeHidden: Bool = false, excludedDirectories: Set<String> = defaultExclusions,
         limits: Limits = Limits(), expectedRootIdentity: FileIdentity? = nil) throws {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.isFileURL, !term.isEmpty, term.utf16.count <= 512 else {
            throw DirectorySearchEngine.failure("请选择本机目录，输入 1–512 个 UTF-16 单元的搜索词。")
        }
        let maximum = Limits()
        guard (1...maximum.entries).contains(limits.entries), (1...maximum.results).contains(limits.results),
              (1...maximum.depth).contains(limits.depth), (1...maximum.fileBytes).contains(limits.fileBytes),
              (1...maximum.totalBytes).contains(limits.totalBytes), excludedDirectories.count <= 128,
              excludedDirectories.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") && $0.utf8.count <= 255 }) else {
            throw DirectorySearchEngine.failure("搜索上限无效，排除项只能填写目录名（最多 128 项）。")
        }
        self.root = root.standardizedFileURL
        // 默认由唯一后台工作器绑定目录身份，表单提交不在主线程对慢卷执行 stat。
        // 已有目录快照的调用方可传入预期身份，要求搜索从一开始就拒绝同名替换。
        self.rootIdentity = expectedRootIdentity
        self.term = term; self.mode = mode; self.caseSensitive = caseSensitive
        self.includeHidden = includeHidden
        self.excludedDirectories = Set(excludedDirectories.map { $0.lowercased() })
        self.limits = limits
    }
}

struct DirectorySearchHit: Identifiable, Equatable, Sendable {
    let components: [String]
    let identity: FileIdentity
    let isDirectory: Bool
    let line: Int?
    let excerpt: String?
    var id: String { components.joined(separator: "/") }
}

struct DirectorySearchSnapshot: Equatable, Sendable {
    enum End: Equatable, Sendable {
        case running, completed, cancelled, entryLimit, resultLimit, byteLimit
        case failed(String)
        var description: String {
            switch self {
            case .running: "正在搜索"
            case .completed: "搜索结束"
            case .cancelled: "已取消，保留已找到的结果"
            case .entryLimit: "达到扫描数量上限，结果不完整"
            case .resultLimit: "达到结果数量上限，结果不完整"
            case .byteLimit: "达到内容读取总量上限，结果不完整"
            case .failed(let message): "搜索未完成：" + message
            }
        }
    }
    enum Skip: String, CaseIterable, Sendable {
        case hidden = "隐藏项", excluded = "排除目录", package = "文档包", link = "符号链接"
        case volume = "其他卷", special = "特殊文件", nonText = "非文本/不支持的编码"
        case size = "单文件超限", depth = "目录深度超限", changed = "搜索期间变化"
    }
    let request: DirectorySearchRequest
    var end: End = .running
    var hits: [DirectorySearchHit] = []
    var visited = 0
    var bytesRead = 0
    var currentPath = ""
    var skipped: [Skip: Int] = [:]
    var issueCount = 0
    var issues: [String] = []
    var hasUnsearchedItems: Bool {
        issueCount > 0 || [Skip.size, .depth, .changed].contains { skipped[$0, default: 0] > 0 }
    }
    var skipDescription: String {
        Skip.allCases.compactMap { key in skipped[key].map { "\(key.rawValue) \($0)" } }.joined(separator: " · ")
    }
    mutating func skip(_ reason: Skip) { skipped[reason, default: 0] += 1 }
    mutating func issue(_ path: String, _ error: Error) {
        issueCount += 1
        if issues.count < 20 { issues.append("\(path)：\(error.localizedDescription)") }
    }
}

/// 工作器更新快照，界面每 100 ms 取样；取消标志独立于 Swift Task，可跨阻塞系统调用保留。
final class DirectorySearchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DirectorySearchSnapshot
    private var cancelled = false
    init(_ request: DirectorySearchRequest) { value = DirectorySearchSnapshot(request: request) }
    var snapshot: DirectorySearchSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func publish(_ snapshot: DirectorySearchSnapshot) { lock.lock(); value = snapshot; lock.unlock() }
}

enum DirectorySearchEngine {
    /// 真实 fd I/O 可替换以确定性复现读失败、取消和并发替换；生产默认只调用系统只读操作。
    struct IO: Sendable {
        var metadata: @Sendable (Int32, String) throws -> stat = { directory, name in
            var value = stat()
            guard fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return value
        }
        var read: @Sendable (Int32, Int) throws -> Data = { fd, count in
            var data = Data(count: count)
            let size = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count) }
            guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            data.count = size
            return data
        }
    }
    private struct Stop: Error { let end: DirectorySearchSnapshot.End }
    private struct Directory { let components: [String]; let identity: FileIdentity }

    static func run(_ input: DirectorySearchRequest, control: DirectorySearchControl, io: IO = IO()) -> DirectorySearchSnapshot {
        var request = input
        let accessed = request.root.startAccessingSecurityScopedResource()
        defer { if accessed { request.root.stopAccessingSecurityScopedResource() } }
        var state = DirectorySearchSnapshot(request: request)
        var lastPublish = Date.distantPast
        func publish(force: Bool = false) {
            if force || Date().timeIntervalSince(lastPublish) >= 0.1 { control.publish(state); lastPublish = Date() }
        }
        func checkCancellation() throws { if control.isCancelled { throw Stop(end: .cancelled) } }
        do {
            try checkCancellation()
            if request.rootIdentity == nil { request.rootIdentity = try FileSystem.identity(at: request.root) }
            state = DirectorySearchSnapshot(request: request)
            guard let rootIdentity = request.rootIdentity else { throw failure("未能确认范围目录身份。") }
            let rootFD = try openRoot(request)
            defer { close(rootFD) }
            var pending = [Directory(components: [], identity: rootIdentity)]
            var seen: Set<FileIdentity> = []
            while let directory = pending.popLast() {
                try checkCancellation()
                try validateRoot(request)
                guard seen.insert(directory.identity).inserted else { continue }
                do {
                    let fd = try openDirectory(rootFD, components: directory.components)
                    // fdopendir 接管 fd；每次只持有当前目录和根描述符，不随目录深度积累句柄。
                    guard let stream = fdopendir(fd) else { let error = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
                    defer { closedir(stream) }
                    guard try FileSystem.identity(ofDescriptor: fd) == directory.identity else {
                        state.skip(.changed); continue
                    }
                    while true {
                        try checkCancellation()
                        errno = 0
                        guard let entry = readdir(stream) else {
                            if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                            break
                        }
                        let name = withUnsafeBytes(of: entry.pointee.d_name, { String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8) })
                        if name == "." || name == ".." { continue }
                        guard state.visited < request.limits.entries else { throw Stop(end: .entryLimit) }
                        state.visited += 1
                        // 无效编码的目录项也必须计入预算，不能让特殊文件名绕过扫描上限。
                        guard let name else {
                            state.issue(directory.components.joined(separator: "/"), failure("文件名不是有效 UTF-8，未尝试读取。")); publish(); continue
                        }
                        let components = directory.components + [name]
                        state.currentPath = components.joined(separator: "/")
                        publish()
                        do {
                            let metadata = try io.metadata(fd, name)
                            let kind = metadata.st_mode & S_IFMT
                            if !request.includeHidden && (name.hasPrefix(".") || metadata.st_flags & UInt32(UF_HIDDEN) != 0) { state.skip(.hidden); continue }
                            if kind == S_IFLNK { state.skip(.link); continue }
                            if Int64(metadata.st_dev) != rootIdentity.device { state.skip(.volume); continue }
                            if kind == S_IFDIR {
                                if request.excludedDirectories.contains(name.lowercased()) { state.skip(.excluded); continue }
                                // macOS 的 /dev/fd 不支持在描述符后追加子路径。仅包属性使用候选 URL，
                                // 查询前后核验身份；正文与目录枚举仍通过不跟随链接的 openat 读取。
                                let candidate = components.reduce(request.root) { $0.appendingPathComponent($1) }
                                guard try FileSystem.identity(at: candidate) == FileSystem.identity(metadata) else { state.skip(.changed); continue }
                                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                                guard try FileSystem.identity(at: candidate) == FileSystem.identity(metadata) else { state.skip(.changed); continue }
                                if FileSystem.isPackageDirectory(candidate, values: values) { state.skip(.package); continue }
                            } else if kind != S_IFREG { state.skip(.special); continue }
                            let identity = FileSystem.identity(metadata)
                            if request.mode == .name {
                                if matches(name, request) {
                                    state.hits.append(.init(components: components, identity: identity, isDirectory: kind == S_IFDIR, line: nil, excerpt: nil))
                                }
                            } else if kind == S_IFREG {
                                let url = components.reduce(request.root) { $0.appendingPathComponent($1) }
                                if !TextPreviewLoader.isTextFile(url) { state.skip(.nonText); continue }
                                if metadata.st_size > request.limits.fileBytes { state.skip(.size); continue }
                                if let hit = try contentHit(request, directory: directory, rootFD: rootFD, parentFD: fd, name: name,
                                                            metadata: metadata, components: components, state: &state, control: control, io: io) {
                                    state.hits.append(hit)
                                }
                            }
                            if state.hits.count >= request.limits.results { throw Stop(end: .resultLimit) }
                            if kind == S_IFDIR {
                                if components.count < request.limits.depth { pending.append(Directory(components: components, identity: identity)) }
                                else { state.skip(.depth) }
                            }
                        } catch let stop as Stop { throw stop }
                        catch let error as DocumentIOError {
                            switch error {
                            case .binaryContent, .unknownEncoding, .nonRoundTrippableEncoding: state.skip(.nonText)
                            default: state.issue(state.currentPath, error)
                            }
                        } catch { state.issue(state.currentPath, error) }
                    }
                } catch let stop as Stop { throw stop }
                catch { state.issue(directory.components.isEmpty ? request.root.path : directory.components.joined(separator: "/"), error) }
            }
            try checkCancellation()
            try validateRoot(request)
            state.end = .completed
        } catch let stop as Stop { state.end = stop.end }
        catch { state.end = .failed(error.localizedDescription) }
        state.hits.sort {
            let comparison = $0.id.localizedStandardCompare($1.id)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        state.currentPath = ""
        publish(force: true)
        return state
    }

    private static func contentHit(_ request: DirectorySearchRequest, directory: Directory, rootFD: Int32, parentFD: Int32,
                                   name: String, metadata: stat, components: [String], state: inout DirectorySearchSnapshot,
                                   control: DirectorySearchControl, io: IO) throws -> DirectorySearchHit? {
        // 打开前重验父目录的相对路径；openat/O_NOFOLLOW/O_NONBLOCK 不跟随替换链接，也不会阻塞在 FIFO。
        let verified = try openDirectory(rootFD, components: directory.components)
        defer { close(verified) }
        guard try FileSystem.identity(ofDescriptor: verified) == directory.identity else { state.skip(.changed); return nil }
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              FileSystem.identity(initial) == FileSystem.identity(metadata) else { state.skip(.changed); return nil }
        if initial.st_size > request.limits.fileBytes { state.skip(.size); return nil }
        if initial.st_size > request.limits.totalBytes - state.bytesRead { throw Stop(end: .byteLimit) }
        var data = Data()
        while true {
            if control.isCancelled { throw Stop(end: .cancelled) }
            do { try validateRoot(request) }
            catch { throw Stop(end: .failed(error.localizedDescription)) }
            let count = min(65_536, request.limits.fileBytes + 1 - data.count, request.limits.totalBytes - state.bytesRead)
            guard count > 0 else { throw Stop(end: .byteLimit) }
            let chunk = try io.read(fd, count)
            guard chunk.count <= count else { throw failure("读取返回了超出请求的内容，搜索已拒绝该文件。") }
            state.bytesRead += chunk.count
            data.append(chunk)
            if control.isCancelled { throw Stop(end: .cancelled) }
            if data.count > request.limits.fileBytes { state.skip(.size); return nil }
            if chunk.isEmpty { break }
            // 已读取完整声明大小时仍探测 EOF，但总预算正好耗尽时用 fstat 大小验证避免多读越限。
            if state.bytesRead == request.limits.totalBytes && data.count == initial.st_size { break }
        }
        var final = stat()
        guard fstat(fd, &final) == 0, data.count == final.st_size, sameVersion(initial, final),
              sameVersion(final, try IO().metadata(parentFD, name)) else { state.skip(.changed); return nil }
        let currentParent = try openDirectory(rootFD, components: directory.components)
        defer { close(currentParent) }
        guard try FileSystem.identity(ofDescriptor: currentParent) == directory.identity else { state.skip(.changed); return nil }
        let text = try DocumentIO.decode(data, requestedEncoding: nil).text
        if control.isCancelled { throw Stop(end: .cancelled) }
        guard let range = text.range(of: request.term, options: request.caseSensitive ? [] : [.caseInsensitive]) else { return nil }
        var line = 1, previousCR = false
        for scalar in text[..<range.lowerBound].unicodeScalars {
            if scalar.value == 13 { line += 1 }
            else if scalar.value == 10 && !previousCR { line += 1 }
            previousCR = scalar.value == 13
        }
        // 按 Unicode 标量限制摘要，避免一个含数万组合附加符的字素撑大每条结果。
        let excerpt = String(String.UnicodeScalarView(text[..<range.lowerBound].unicodeScalars.suffix(70)))
            + String(String.UnicodeScalarView(text[range.lowerBound...].unicodeScalars.prefix(130)))
        return DirectorySearchHit(components: components, identity: FileSystem.identity(final), isDirectory: false, line: line,
                                  excerpt: excerpt.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
    }

    /// 定位不是直接打开快照路径：重新逐段拒绝链接并核验对象，失效结果要求重搜。
    static func validatedURL(for hit: DirectorySearchHit, request: DirectorySearchRequest) throws -> URL {
        guard !hit.components.isEmpty, hit.components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else { throw failure("结果路径无效。") }
        let root = try openRoot(request)
        defer { close(root) }
        let parent = try openDirectory(root, components: Array(hit.components.dropLast()))
        defer { close(parent) }
        let metadata = try IO().metadata(parent, hit.components.last!)
        let kind = metadata.st_mode & S_IFMT
        guard kind == (hit.isDirectory ? S_IFDIR : S_IFREG), FileSystem.identity(metadata) == hit.identity else {
            throw failure("搜索结果已变化，请重新搜索。")
        }
        try validateRoot(request)
        return hit.components.reduce(request.root) { $0.appendingPathComponent($1) }
    }

    private static func matches(_ text: String, _ request: DirectorySearchRequest) -> Bool {
        text.range(of: request.term, options: request.caseSensitive ? [] : [.caseInsensitive]) != nil
    }
    private static func sameVersion(_ a: stat, _ b: stat) -> Bool {
        FileSystem.identity(a) == FileSystem.identity(b) && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func validateRoot(_ request: DirectorySearchRequest) throws {
        guard let identity = request.rootIdentity, try FileSystem.identity(at: request.root) == identity else { throw failure("范围目录已变化，请重新选择后搜索。") }
    }
    private static func openRoot(_ request: DirectorySearchRequest) throws -> Int32 {
        try validateRoot(request)
        let fd = open(request.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do {
            guard try FileSystem.identity(ofDescriptor: fd) == request.rootIdentity else { throw failure("范围目录已被替换。") }
            let values = try request.root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard !FileSystem.isPackageDirectory(request.root, values: values) else { throw failure("请选择普通目录，不能在文档包内递归搜索。") }
            return fd
        } catch { close(fd); throw error }
    }
    private static func openDirectory(_ rootFD: Int32, components: [String]) throws -> Int32 {
        var fd = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        for name in components {
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            fd = next
        }
        return fd
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "FileDeck.Search", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

/// 单个窗口最多一个真实搜索工作器；连续重搜只保留最新排队请求，旧工作器返回前不追加并发扫描。
@MainActor
final class DirectorySearchSession: ObservableObject {
    typealias Worker = @Sendable (DirectorySearchRequest, DirectorySearchControl) -> DirectorySearchSnapshot
    private struct Job { let id: UUID; let request: DirectorySearchRequest; let control: DirectorySearchControl }
    @Published private(set) var snapshot: DirectorySearchSnapshot?
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var generation = UUID()
    private var active: Job?
    private var pending: Job?
    private var polling: Task<Void, Never>?
    private let worker: Worker
    init(worker: @escaping Worker = { DirectorySearchEngine.run($0, control: $1) }) { self.worker = worker }
    deinit { active?.control.cancel(); polling?.cancel() }

    func start(_ request: DirectorySearchRequest) {
        let id = UUID()
        generation = id
        pending = Job(id: id, request: request, control: DirectorySearchControl(request))
        snapshot = DirectorySearchSnapshot(request: request)
        isRunning = true; isStopping = active != nil
        active?.control.cancel()
        launchPending()
    }
    func cancel() {
        pending = nil
        active?.control.cancel()
        isStopping = active != nil
        if active?.id != generation { snapshot?.end = .cancelled }
        if active == nil { isRunning = false; isStopping = false }
    }
    func reset() { cancel(); generation = UUID(); snapshot = nil }
    private func launchPending() {
        guard active == nil, let job = pending else { return }
        pending = nil; active = job; isStopping = false
        let worker = worker
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { worker(job.request, job.control) }.value
            guard let self else { return }
            self.polling?.cancel()
            self.active = nil
            if self.generation == job.id { self.snapshot = result }
            self.isRunning = self.pending != nil
            self.isStopping = false
            self.launchPending()
        }
        polling = Task { [weak self] in
            while !Task.isCancelled, self?.active?.id == job.id {
                let value = job.control.snapshot
                if self?.generation == job.id, self?.snapshot != value { self?.snapshot = value }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
