import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

/// 启动与目录错误分开建模，单个目录失效不会把整个工作台停留在启动页。
enum WorkspaceStartupPhase { case welcome, restoring, ready }
enum DirectoryIssue: Equatable { case permission, unavailable, readFailure }

struct BrowserFileReference: Hashable, Sendable {
    let url: URL
    let identity: FileIdentity?
}

/// 一次临时预览会话的轻量快照；文件内容与整份目录列表仍由各自原有对象持有。
struct BrowserPreviewSnapshot: Sendable {
    let id: UUID
    let directory: URL?
    let directoryIdentity: FileIdentity?
    let selection: Set<BrowserFileReference>
    let primarySelection: BrowserFileReference?
    let query: String
    let typeFilter: FileTypeFilter
    let showHidden: Bool
    let sortByModified: Bool
    let gridView: Bool
    let expandedDirectories: Set<URL>
    let source: String
}

enum FileTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all, folders, documents, images, media, archives
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部类型"
        case .folders: "文件夹"
        case .documents: "文档"
        case .images: "图像"
        case .media: "音视频"
        case .archives: "压缩包"
        }
    }
    func includes(_ entry: FileEntry) -> Bool {
        if self == .all { return true }
        if self == .folders { return entry.isBrowsableDirectory }
        guard !entry.isBrowsableDirectory else { return false }
        let type = entry.typeIdentifier.flatMap { UTType($0) } ?? UTType(filenameExtension: entry.url.pathExtension)
        switch self {
        case .images: return type?.conforms(to: .image) == true
        case .media: return type?.conforms(to: .audiovisualContent) == true
        case .archives: return type?.conforms(to: .archive) == true
        case .documents:
            return TextPreviewLoader.isTextFile(entry.url) || type?.conforms(to: .pdf) == true
                || ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf"].contains(entry.url.pathExtension.lowercased())
        case .all, .folders: return false
        }
    }
}

/// 与筛选条件同寿命的显示快照；身份碰撞必须保留歧义，不能用字典最后一项猜测硬链接。
final class BrowserDisplaySnapshot {
    enum IdentityMatch { case unique(URL), ambiguous }
    let visible: [FileEntry]
    let ordered: [FileEntry]
    let byURL: [URL: FileEntry]
    let byIdentity: [FileIdentity: IdentityMatch]
    let positions: [URL: Int]

    init(entries: [FileEntry], query: String, filter: FileTypeFilter, sortByModified: Bool) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = entries.filter { filter.includes($0) && (term.isEmpty || $0.name.localizedStandardContains(term)) }
        ordered = sortByModified ? visible.sorted {
            if $0.isBrowsableDirectory != $1.isBrowsableDirectory { return $0.isBrowsableDirectory }
            if $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.url.path < $1.url.path : comparison == .orderedAscending
        } : visible
        byURL = Dictionary(uniqueKeysWithValues: visible.map { ($0.url, $0) })
        positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.url, $0.offset) })
        var identities: [FileIdentity: IdentityMatch] = [:]
        for item in visible {
            guard let identity = item.identity else { continue }
            identities[identity] = identities[identity] == nil ? .unique(item.url) : .ambiguous
        }
        byIdentity = identities
    }

    /// 菜单通常只涉及少量项目，按已建索引取值并排序所选项，不为每个网格菜单扫描整目录。
    func entries(for urls: Set<URL>) -> [FileEntry] {
        urls.compactMap { byURL[$0] }.sorted { positions[$0.url, default: .max] < positions[$1.url, default: .max] }
    }

}

struct BrowserDirectorySnapshot: Sendable {
    let entries: [FileEntry]
    let trulyEmpty: Bool
    let identity: FileIdentity?
    init(entries: [FileEntry], trulyEmpty: Bool, identity: FileIdentity? = nil) {
        self.entries = entries; self.trulyEmpty = trulyEmpty; self.identity = identity
    }

    nonisolated static func read(_ url: URL, showHidden: Bool) throws -> Self {
        let identity = try FileSystem.identity(at: url)
        let items = try FileSystem.entries(at: url, showHidden: showHidden)
        // 保留系统隐藏属性的语义；只有可见列表为空时才额外判断“仅含隐藏文件”。
        let empty = items.isEmpty && !showHidden ? try FileSystem.entries(at: url, showHidden: true).isEmpty : items.isEmpty
        guard try FileSystem.identity(at: url) == identity else { throw FileSystemError.notBrowsableDirectory(url) }
        return Self(entries: items, trulyEmpty: empty, identity: identity)
    }
}

/// 列表与树共用在途读取；最多两个磁盘任务，收起/切走后的无订阅排队项立即移除。
/// 系统目录 I/O 不能可靠中止，已运行任务仍占槽直到结束，不能取消包装 Task 后虚增并发。
@MainActor
final class BrowserDirectoryLoader {
    typealias Read = @Sendable (URL, Bool) throws -> BrowserDirectorySnapshot
    typealias Completion = @MainActor (Result<BrowserDirectorySnapshot, Error>) -> Void
    private struct Key: Hashable {
        let url: URL
        let hidden: Bool
        let generation: UUID
        let expectedIdentity: FileIdentity?
    }
    private final class Job {
        let id = UUID()
        var callbacks: [UUID: Completion] = [:]
        var running = false
    }
    private let read: Read
    private var jobs: [Key: Job] = [:]
    private var subscriptions: [UUID: Key] = [:]
    private var queue: [Key] = []
    private var running = 0

    init(read: @escaping Read) { self.read = read }

    @discardableResult
    func request(_ url: URL, hidden: Bool, generation: UUID, foreground: Bool = false, expectedIdentity: FileIdentity? = nil,
                 completion: @escaping Completion) -> UUID {
        let key = Key(url: url, hidden: hidden, generation: generation, expectedIdentity: expectedIdentity)
        let job = jobs[key] ?? Job()
        if jobs[key] == nil { jobs[key] = job; queue.append(key) }
        let ticket = UUID()
        subscriptions[ticket] = key
        job.callbacks[ticket] = completion
        // 快速切换时当前目录优先于尚未开始的树分支，但不会突破正在执行的 I/O 上限。
        if foreground, !job.running { queue.removeAll { $0 == key }; queue.insert(key, at: 0) }
        startNext()
        return ticket
    }

    func cancel(_ ticket: UUID?) {
        guard let ticket, let key = subscriptions.removeValue(forKey: ticket), let job = jobs[key] else { return }
        let callback = job.callbacks.removeValue(forKey: ticket)
        if job.callbacks.isEmpty {
            // 无人接收的运行结果不能被后来的导航重新订阅；文件可能已经变化。
            // 工作器仍计入 running，结束时用 job.id 区分同路径的新请求。
            jobs[key] = nil
            queue.removeAll { $0 == key }
        }
        // 等待关闭预览的 continuation 也必须结束；页面请求另有代次检查，不会提交取消结果。
        callback?(.failure(CancellationError()))
    }

    private func startNext() {
        while running < 2, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let job = jobs[key] else { continue }
            job.running = true
            running += 1
            let id = job.id
            let read = read
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        if let identity = key.expectedIdentity, try FileSystem.identity(at: key.url) != identity {
                            throw FileSystemError.notBrowsableDirectory(key.url)
                        }
                        let snapshot = try read(key.url, key.hidden)
                        // 枚举期间也可能替换整个目录；不能只在开始时验身份就安装后来对象的快照。
                        if let identity = key.expectedIdentity {
                            guard snapshot.identity == nil || snapshot.identity == identity,
                                  try FileSystem.identity(at: key.url) == identity else {
                                throw FileSystemError.notBrowsableDirectory(key.url)
                            }
                        }
                        return snapshot
                    }
                }.value
                self.running -= 1
                if let completed = self.jobs[key], completed.id == id {
                    self.jobs[key] = nil
                    for (ticket, callback) in completed.callbacks {
                        self.subscriptions[ticket] = nil
                        callback(result)
                    }
                }
                self.startNext()
            }
        }
    }
}

/// 只监听一层目录 vnode，不递归扫描。所有 fd/订阅由专用串行队列持有，主 actor 不执行 open。
/// 无法建立监听时只报告一次；回前台或父目录变化后重试，避免失败导致持续重读。
final class BrowserDirectoryObserver: Sendable {
    static let maximumSubscriptions = 128
    struct Target: Equatable, Sendable { let url: URL; let identity: FileIdentity? }
    struct Event: Sendable {
        let url: URL
        let identity: FileIdentity?
        let destination: URL?
    }
    private final class Registration {
        var url: URL
        let identity: FileIdentity
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
        init(url: URL, identity: FileIdentity, descriptor: Int32, source: DispatchSourceFileSystemObject) {
            self.url = url; self.identity = identity; self.descriptor = descriptor; self.source = source
        }
        deinit { source.cancel() }
    }
    /// 可变状态只在 queue 访问；事件通过不可变 Sendable 值传回，源回调不保留 owner 或 fd 之外的资源。
    private final class State: @unchecked Sendable {
        let queue: DispatchQueue
        let callback: @Sendable (Event) -> Void
        var registrations: [URL: Registration] = [:]
        var failed: [URL: Target] = [:]
        var targets: [URL: Target] = [:]
        init(queue: DispatchQueue, callback: @escaping @Sendable (Event) -> Void) {
            self.queue = queue; self.callback = callback
        }
        func reconcile(_ requested: [Target], retry: Bool) {
            var seen: Set<URL> = []
            let requested = Array(requested.filter { seen.insert($0.url).inserted }.prefix(BrowserDirectoryObserver.maximumSubscriptions))
            var relocated: [Registration] = []
            targets = Dictionary(uniqueKeysWithValues: requested.map { ($0.url, $0) })
            var next: [URL: Registration] = [:]
            var used: Set<Int32> = []
            for target in requested {
                let previous = registrations[target.url].flatMap { registration in
                    target.identity == nil || registration.identity == target.identity ? registration : nil
                } ?? registrations.values.first { $0.identity == target.identity && !used.contains($0.descriptor) }
                if let previous, used.insert(previous.descriptor).inserted {
                    if previous.url != target.url { relocated.append(previous) }
                    previous.url = target.url
                    next[target.url] = previous
                    continue
                }
                if !retry, failed[target.url] == target { continue }
                let descriptor = target.url.withUnsafeFileSystemRepresentation { path in
                    path.map { open($0, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
                }
                do {
                    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    let identity = try FileSystem.identity(ofDescriptor: descriptor)
                    guard target.identity == nil || identity == target.identity,
                          try FileSystem.identity(at: target.url) == identity else {
                        throw FileSystemError.notBrowsableDirectory(target.url)
                    }
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                        eventMask: [.write, .delete, .rename, .revoke, .attrib, .link, .extend], queue: queue)
                    let registration = Registration(url: target.url, identity: identity, descriptor: descriptor, source: source)
                    source.setEventHandler { [weak self, weak registration] in
                        guard let self, let registration, self.registrations[registration.url] === registration else { return }
                        self.report(registration)
                        // 目录已被删除/卸载时旧 fd 不再监视同路径的后来对象，等待父目录或前台重试。
                        if !registration.source.data.intersection([.delete, .revoke]).isEmpty {
                            self.registrations[registration.url] = nil
                            self.failed[registration.url] = self.targets[registration.url]
                        }
                        if registration.source.data.contains(.write) {
                            let children = self.targets.values.filter { $0.url.deletingLastPathComponent().path == registration.url.path }
                            for child in children { self.failed[child.url] = nil }
                            if !children.isEmpty { self.reconcile(Array(self.targets.values), retry: false) }
                        }
                    }
                    source.setCancelHandler { close(descriptor) }
                    next[target.url] = registration
                    failed[target.url] = nil
                    source.resume()
                    // 注册与第一次枚举有时序间隙，补一次合并检查，不能漏掉安装监听前发生的变化。
                    callback(Event(url: target.url, identity: identity, destination: nil))
                } catch {
                    if descriptor >= 0 { close(descriptor) }
                    failed[target.url] = target
                    callback(Event(url: target.url, identity: nil, destination: nil))
                }
            }
            registrations = next
            failed = failed.filter { targets[$0.key] != nil }
            // 重命名时按身份复用原 fd；若路径又变过，不能先关掉唯一仍指向原对象的描述符。
            for registration in relocated {
                if let destination = currentPath(registration), destination.path != registration.url.path {
                    callback(Event(url: registration.url, identity: registration.identity, destination: destination))
                }
            }
        }
        private func report(_ registration: Registration) {
            let path = currentPath(registration)
            callback(Event(url: registration.url, identity: registration.identity,
                           destination: path.flatMap { $0.path == registration.url.path ? nil : $0 }))
        }
        private func currentPath(_ registration: Registration) -> URL? {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let path: String? = buffer.withUnsafeMutableBufferPointer {
                guard let base = $0.baseAddress, fcntl(registration.descriptor, F_GETPATH, base) == 0 else { return nil }
                return String(validatingCString: base)
            }
            guard let path else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard (try? FileSystem.identity(at: url)) == registration.identity else { return nil }
            return url
        }
        func stop() { registrations = [:]; targets = [:]; failed = [:] }
    }
    private let queue = DispatchQueue(label: "FileDeck.directory-observation", qos: .utility)
    private let state: State
    init(callback: @escaping @Sendable (Event) -> Void) { state = State(queue: queue, callback: callback) }
    func setTargets(_ targets: [Target], retry: Bool = false) {
        let state = state
        queue.async { state.reconcile(targets, retry: retry) }
    }
    deinit {
        let state = state
        queue.async { state.stop() }
    }
}

/// 管理多根目录、原生授权、懒加载树与导航历史。磁盘枚举只接收最后一次请求。
@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var managedRoots: [URL] = []
    @Published private(set) var startupPhase: WorkspaceStartupPhase = .welcome
    @Published private(set) var rootURL: URL?
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var entries: [FileEntry] = [] {
        didSet {
            entriesByURL = Dictionary(uniqueKeysWithValues: entries.map { ($0.url, $0) })
            cachedDisplaySnapshot = nil
            cachedSelectedEntries = nil
        }
    }
    @Published var selectedURL: URL? {
        didSet {
            guard !updatingSelection else { return }
            selectedURLs = selectedURL.map { [$0] } ?? []
            selectionAnchor = selectedURL
        }
    }
    @Published private(set) var selectedURLs: Set<URL> = [] {
        didSet { cachedSelectedEntries = nil }
    }
    @Published var sortByModified = false {
        didSet {
            if sortByModified != oldValue { cachedDisplaySnapshot = nil }
            if persistsWorkspace { defaults.set(sortByModified, forKey: "FileWorkbench.sortByModified") }
        }
    }
    @Published var gridView = false {
        didSet { if persistsWorkspace { defaults.set(gridView, forKey: "FileWorkbench.gridView") } }
    }
    @Published var query = "" {
        didSet { if query != oldValue { cachedDisplaySnapshot = nil; updateSearchSelection() } }
    }
    @Published var typeFilter: FileTypeFilter = .all {
        didSet { if typeFilter != oldValue { cachedDisplaySnapshot = nil; updateSearchSelection() } }
    }
    @Published var showHidden = false
    @Published private(set) var isLoading = false { didSet { if !isLoading { scheduleExternalSynchronization() } } }
    @Published private(set) var isImporting = false { didSet { if !isImporting { scheduleExternalSynchronization() } } }
    @Published private(set) var isTrashing = false { didSet { if !isTrashing { scheduleExternalSynchronization() } } }
    var isFileOperationBusy: Bool { isImporting || isTrashing }
    @Published private(set) var fileOperationProgress: FileOperationControl.Progress?
    @Published private(set) var fileOperationSummary: String?
    @Published private(set) var fileOperationUndo: [FileOperationUndo] = []
    private var operationControl: FileOperationControl?

    @Published private(set) var directoryError: String?
    @Published private(set) var directoryIssue: DirectoryIssue?
    @Published private(set) var directoryIsTrulyEmpty = false
    @Published private(set) var treeChildren: [URL: [FileEntry]] = [:]
    @Published private(set) var treeErrors: [URL: String] = [:]
    @Published private(set) var treeLoading: Set<URL> = []
    @Published private(set) var expandedDirectories: Set<URL> = []
    @Published private(set) var history: [URL] = []
    @Published private(set) var historyIndex = -1
    @Published private(set) var revision = UUID()
    @Published var actionError: String?

    private struct SavedLocation: Codable, Sendable {
        var path: String
        var bookmark: Data?
    }
    private struct ResolvedLocation: Sendable {
        var url: URL
        var bookmark: Data?
    }
    private struct SavedWorkspace: Codable {
        var roots: [SavedLocation]
        var currentPath: String?
        var activeRoot: SavedLocation?
        var expandedPaths: [String]
    }
    private let defaults: UserDefaults
    private let workspaceKey = "FileWorkbench.workspace.v1"
    private let welcomedKey = "FileWorkbench.didCompleteWelcome"
    private let savedRootKey = "FileWorkbench.lastRoot"
    private var persistsWorkspace: Bool
    private var loadID = UUID()
    private var currentRestoreID: UUID?
    private var pendingWorkspace: SavedWorkspace?
    private var treeGeneration = UUID()
    private var openPanel: NSOpenPanel?
    private var bookmarks: [URL: Data] = [:]
    // 键跟随浏览路径，值保留系统最初授予的作用域令牌；重命名不能丢弃仍有效的授权。
    private var scopedURLs: [URL: URL] = [:]
    private var navigationRoots: [URL: URL] = [:]
    private var updatingDisplayState = false
    private var updatingSelection = false
    private var selectionAnchor: URL?
    private struct NavigationSelection {
        let files: Set<BrowserFileReference>
        let primary: BrowserFileReference?
    }
    private var navigationSelections: [URL: NavigationSelection] = [:]
    @Published private(set) var gestureForwardChain: [BrowserFileReference] = []
    private var activePreviewSnapshotID: UUID? { didSet { if activePreviewSnapshotID == nil { scheduleExternalSynchronization() } } }
    private var activeFileDrag: (id: UUID, files: [BrowserFileReference])?
    private var copiedFiles: (board: NSPasteboard.Name, change: Int, files: [BrowserFileReference])?

    private var entriesByURL: [URL: FileEntry] = [:]
    // 列表加载时会清空 entries；连续刷新仍须沿用第一次捕获的身份，不能重新 stat 后继承同名替换项。
    private var pendingSelectionReferences: [URL: BrowserFileReference] = [:]
    private var cachedDisplaySnapshot: BrowserDisplaySnapshot?
    private var cachedSelectedEntries: (display: BrowserDisplaySnapshot, entries: [FileEntry])?
    private let directoryLoader: BrowserDirectoryLoader
    private var listTicket: UUID?
    private var treeTickets: [URL: UUID] = [:]

    private let observesExternalChanges: Bool
    private var directoryObserver: BrowserDirectoryObserver?
    private var observedDirectories: Set<URL> = []
    private var directoryIdentities: [URL: FileIdentity] = [:]
    private var externalDirty: [URL: UInt64] = [:]
    private var externalVersion: UInt64 = 0
    private var externalEpoch = UUID()
    private var externalMoves: [URL: (identity: FileIdentity, destination: URL)] = [:]
    private var externalRequests: [URL: (id: UUID, ticket: UUID)] = [:]
    private var externalDebounce: Task<Void, Never>?
    private(set) var isSynchronizingExternalChanges = false

    var displaySnapshot: BrowserDisplaySnapshot {
        if let cachedDisplaySnapshot { return cachedDisplaySnapshot }
        let snapshot = BrowserDisplaySnapshot(entries: entries, query: query, filter: typeFilter, sortByModified: sortByModified)
        cachedDisplaySnapshot = snapshot
        return snapshot
    }
    var visibleEntries: [FileEntry] { displaySnapshot.visible }
    var selectedEntry: FileEntry? { selectedURL.flatMap { displaySnapshot.byURL[$0] } }
    var orderedEntries: [FileEntry] { displaySnapshot.ordered }
    var hasActiveFilters: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || typeFilter != .all || (!isLoading && directoryIssue == nil && currentDirectory != nil && entries.isEmpty && !directoryIsTrulyEmpty) }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex + 1 < history.count }
    // 加载完成后才有当前目录的身份；连续点击或快捷键不能把无身份的目录压入返回链。
    var canGoUp: Bool { !isLoading && currentDirectory != nil && currentDirectory != rootURL }
    var canGestureGoBack: Bool {
        guard !isLoading, let currentDirectory, let rootURL, currentDirectory != rootURL else { return false }
        return Self.contains(currentDirectory, in: rootURL)
    }
    var canGestureGoForward: Bool {
        guard !isLoading, let currentDirectory, let child = gestureForwardChain.last, child.identity != nil else { return false }
        return Self.directoryURL(child.url.deletingLastPathComponent()) == currentDirectory
    }
    var hasPreviousWorkspace: Bool {
        pendingWorkspace.map { !$0.roots.isEmpty || $0.currentPath != nil } ?? false
    }

    init(observesExternalChanges: Bool = true, restoreLastLocation: Bool = true, defaults: UserDefaults = .standard,
         arguments: [String] = ProcessInfo.processInfo.arguments,
         directoryReader: @escaping BrowserDirectoryLoader.Read = { try BrowserDirectorySnapshot.read($0, showHidden: $1) }) {
        self.defaults = defaults
        self.directoryLoader = BrowserDirectoryLoader(read: directoryReader)
        self.persistsWorkspace = restoreLastLocation
        self.observesExternalChanges = observesExternalChanges
        if observesExternalChanges {
            directoryObserver = BrowserDirectoryObserver { [weak self] event in
                Task { @MainActor [weak self] in self?.receiveDirectoryEvent(event) }
            }
        }
        self.gridView = defaults.bool(forKey: "FileWorkbench.gridView")
        self.sortByModified = defaults.bool(forKey: "FileWorkbench.sortByModified")
        guard restoreLastLocation else { startupPhase = .ready; return }
        if let index = arguments.firstIndex(of: "--open"), arguments.indices.contains(index + 1) {
            // 临时验收入口沿用原约定，不覆盖用户记住的目录与工作区。
            persistsWorkspace = false
            openRoot(URL(fileURLWithPath: arguments[index + 1], isDirectory: true), remember: false)
            return
        }
        // 欢迎页是每次普通启动的入口；这里只读取偏好，不访问上次目录或自动进入工作台。
        pendingWorkspace = savedWorkspace()
    }

    deinit {
        externalDebounce?.cancel()
        for url in scopedURLs.values { url.stopAccessingSecurityScopedResource() }
    }

    func skipWelcome() {
        if let saved = pendingWorkspace {
            pendingWorkspace = nil
            restore(saved)
            return
        }
        startupPhase = .ready
        if persistsWorkspace { defaults.set(true, forKey: welcomedKey); saveWorkspace() }
    }

    func chooseFolder() {
        chooseLocation(selectingFile: false) { [weak self] in self?.openRoot($0) }
    }

    func chooseFile() {
        chooseLocation(selectingFile: true) { [weak self] in self?.openFile($0) }
    }

    func authorizeCurrentDirectory() {
        guard let currentDirectory else { chooseFolder(); return }
        chooseLocation(selectingFile: false) { [weak self] chosen in
            guard let self else { return }
            let target = Self.directoryURL(chosen.resolvingSymlinksInPath())
            if target == currentDirectory {
                self.retainAccess(to: chosen)
                self.rememberBookmark(for: target)
                self.navigate(to: target)
            } else {
                self.openRoot(chosen)
            }
        }
    }

    func relocateManagedRoot(_ root: URL) {
        chooseLocation(selectingFile: false) { [weak self] chosen in self?.replaceManagedRoot(root, with: chosen) }
    }

    /// 搜索只取得目录授权，不新增管理根、不改变当前导航；定位结果时才显式导航。
    func chooseSearchDirectory(completion: @escaping (URL) -> Void) {
        chooseLocation(selectingFile: false, completion: completion)
    }

    private func chooseLocation(selectingFile: Bool, completion: @escaping (URL) -> Void) {
        guard openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = selectingFile ? "选择要预览的文件" : "选择本地文件夹"
        panel.prompt = selectingFile ? "打开文件" : "选择文件夹"
        panel.canChooseDirectories = !selectingFile
        panel.canChooseFiles = selectingFile
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.showsHiddenFiles = showHidden
        panel.directoryURL = currentDirectory
        // 使用系统授权面板，不能用应用内开关模拟 macOS 的访问权限。
        openPanel = panel
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                let chosen = self.openPanel?.url
                self.openPanel = nil
                if response == .OK, let chosen {
                    self.retainAccess(to: chosen)
                    completion(chosen)
                }
            }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    func openFile(_ url: URL, remember: Bool = true) {
        guard url.isFileURL else { actionError = "请选择本机文件。"; return }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey])
            guard values.isDirectory != true || FileSystem.isPackageDirectory(url, values: values) || values.isSymbolicLink == true else {
                actionError = "请选择单个文件，或使用“打开文件夹”浏览目录。"
                return
            }
            // 只解析父目录的链接，保留文件本身的链接身份，与目录列表中的 URL 一致。
            let parent = Self.directoryURL(url.deletingLastPathComponent().resolvingSymlinksInPath())
            let file = parent.appendingPathComponent(url.lastPathComponent, isDirectory: values.isDirectory == true)
            if values.isHidden == true || file.lastPathComponent.hasPrefix(".") { showHidden = true }
            actionError = nil
            openRoot(parent, remember: remember, selecting: file)
        } catch { actionError = "无法打开文件：\(error.localizedDescription)" }
    }

    func openRoot(_ url: URL, remember: Bool = true, selecting file: URL? = nil) {
        guard url.isFileURL else { actionError = "请选择本机文件夹。"; return }
        restoreManagedRootsForExplicitOpen()
        let normalized = Self.directoryURL(url.resolvingSymlinksInPath())
        persistsWorkspace = remember && persistsWorkspace
        if !managedRoots.contains(normalized) { managedRoots.append(normalized) }
        if remember { rememberBookmark(for: normalized) }
        activateRoot(normalized, selecting: file)
    }

    /// 快速访问只是导航入口，不会自动成为用户的管理目录。
    func openQuickLocation(_ url: URL) {
        guard url.isFileURL else { return }
        restoreManagedRootsForExplicitOpen()
        activateRoot(Self.directoryURL(url.resolvingSymlinksInPath()))
    }

    private func activateRoot(_ url: URL, selecting file: URL? = nil) {
        rootURL = url
        expandedDirectories.insert(url)
        startupPhase = .ready
        if persistsWorkspace { defaults.set(true, forKey: welcomedKey) }
        navigate(to: url, selecting: file)
        loadChildren(of: url)
    }

    func navigate(to url: URL, recordHistory: Bool = true, selecting file: URL? = nil, restoringSelection: Bool = false) {
        guard url.isFileURL else { return }
        // 返回历史目录时按文件身份恢复多选；同名替换文件不能继承之前的选择。
        if let currentDirectory, !isLoading, directoryError == nil {
            navigationSelections[currentDirectory] = NavigationSelection(files: Set(selectedURLs.map(fileReference)),
                                                                         primary: selectedURL.map(fileReference))
        }
        gestureForwardChain = []
        activePreviewSnapshotID = nil
        let target = Self.directoryURL(url)
        let savedSelection = (!recordHistory || restoringSelection) && file == nil ? navigationSelections[target] : nil
        currentRestoreID = nil
        if let rememberedRoot = navigationRoots[target], !recordHistory {
            rootURL = rememberedRoot
        } else if let managed = managedRoots.filter({ Self.contains(target, in: $0) }).max(by: { $0.path.count < $1.path.count }) {
            rootURL = managed
        } else if rootURL.map({ !Self.contains(target, in: $0) }) ?? true {
            rootURL = target
        }
        if recordHistory, currentDirectory != target || history.isEmpty {
            history = Array(history.prefix(historyIndex + 1))
            history.append(target)
            historyIndex = history.count - 1
            let retained = Set(history)
            navigationSelections = navigationSelections.filter { retained.contains($0.key) }
        }
        cancelExternalRequests()
        directoryIdentities[target] = nil
        currentDirectory = target
        navigationRoots[target] = rootURL
        // 先进入加载态再清除过滤，避免 didSet 把待恢复的文件选择当作旧快照清空。
        isLoading = true
        if let savedSelection {
            pendingSelectionReferences = Dictionary(uniqueKeysWithValues: savedSelection.files.map { ($0.url, $0) })
            setSelection(Set(savedSelection.files.map(\.url)), primary: savedSelection.primary?.url)
        } else { selectedURL = file }
        query = ""
        typeFilter = .all
        expandAncestors(of: target)
        cancelInvisibleTreeLoads()
        saveWorkspace()
        loadDirectory()
        updateObservationTargets()
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigate(to: history[historyIndex], recordHistory: false)
    }
    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigate(to: history[historyIndex], recordHistory: false)
    }
    func goUp() {
        guard canGoUp, let currentDirectory else { return }
        let chain = gestureForwardChain
        let child = BrowserFileReference(url: currentDirectory, identity: directoryIdentities[currentDirectory])
        navigate(to: currentDirectory.deletingLastPathComponent(), restoringSelection: true)
        gestureForwardChain = chain + [child]
    }

    /// 手势与上级目录按钮/快捷键共用父子链；浏览历史仍由独立的历史按钮管理。
    func gestureGoBack() {
        guard canGestureGoBack else { return }
        goUp()
    }

    func gestureGoForward() {
        guard canGestureGoForward, let child = gestureForwardChain.last else { return }
        // 刚退出的目录若被删除/替换，要求重新点击选择，不能进入同路径的另一个对象。
        guard let identity = child.identity, (try? FileSystem.identity(at: child.url)) == identity else {
            gestureForwardChain = []
            actionError = "刚刚退出的子目录已变更，请在列表中重新打开。"
            return
        }
        let remaining = Array(gestureForwardChain.dropLast())
        navigate(to: child.url, restoringSelection: true)
        gestureForwardChain = remaining
    }

    func refresh() {
        cancelExternalRequests()
        clearTree()
        loadDirectory()
        reloadVisibleTree()
        updateObservationTargets()
    }

    /// 返回中性空状态时保留管理根与树展开，但取消待返回的旧列表和预览。
    func clearCurrentDirectory() {
        cancelExternalRequests()
        externalMoves = [:]
        activePreviewSnapshotID = nil
        currentRestoreID = nil
        loadID = UUID()
        directoryLoader.cancel(listTicket)
        listTicket = nil
        isLoading = false
        rootURL = nil
        currentDirectory = nil
        entries = []
        pendingSelectionReferences = [:]
        selectedURL = nil
        directoryError = nil
        directoryIssue = nil
        directoryIsTrulyEmpty = false
        query = ""
        typeFilter = .all
        history = []
        historyIndex = -1
        navigationSelections = [:]
        gestureForwardChain = []
        navigationRoots = [:]
        startupPhase = .ready
        saveWorkspace()
        updateObservationTargets()
    }

    func clearSearch() { query = "" }
    func resetFilters() { query = ""; typeFilter = .all }

    func updateSearchSelection() {
        guard !isLoading, !updatingDisplayState else { return }
        let visible = displaySnapshot.byURL
        setSelection(selectedURLs.filter { visible[$0] != nil }, primary: selectedURL.flatMap { visible[$0] != nil ? $0 : nil })
    }

    func setSelection(_ urls: Set<URL>, primary: URL?) {
        updatingSelection = true
        selectedURLs = urls
        selectedURL = primary.flatMap { urls.contains($0) ? $0 : nil }
        updatingSelection = false
        if selectionAnchor == nil { selectionAnchor = selectedURL }
    }

    /// 修饰键选择只改变当前文件集合，不负责导航或打开预览。
    func select(_ entry: FileEntry, extending: Bool = false, toggling: Bool = false) {
        let snapshot = displaySnapshot
        if extending, let anchor = selectionAnchor,
           let start = snapshot.positions[anchor], let end = snapshot.positions[entry.url] {
            let range = Set(snapshot.ordered[min(start, end)...max(start, end)].map(\.url))
            setSelection(toggling ? selectedURLs.union(range) : range, primary: entry.url)
        } else if toggling {
            var selection = selectedURLs
            if selection.remove(entry.url) == nil { selection.insert(entry.url) }
            setSelection(selection, primary: selection.contains(entry.url) ? entry.url : orderedEntries.first(where: { selection.contains($0.url) })?.url)
            selectionAnchor = entry.url
        } else {
            selectedURL = entry.url
        }
    }

    func capturePreviewSnapshot(source: String) -> BrowserPreviewSnapshot {
        let id = UUID()
        activePreviewSnapshotID = id
        return BrowserPreviewSnapshot(id: id, directory: currentDirectory,
                                      directoryIdentity: currentDirectory.flatMap { try? FileSystem.identity(at: $0) },
                                      selection: Set(selectedURLs.map(fileReference)),
                                      primarySelection: selectedURL.map(fileReference), query: query,
                                      typeFilter: typeFilter, showHidden: showHidden, sortByModified: sortByModified,
                                      gridView: gridView, expandedDirectories: expandedDirectories, source: source)
    }

    /// 关闭后仅更新当前目录的元数据，不走 navigate/refresh，不清空列表、树或触发整页加载态。
    /// savedURL 只能由真实保存成功回调提供：原子写入会替换 inode，此时明确接受新磁盘身份。
    func refreshAfterPreview(snapshot: BrowserPreviewSnapshot, savedURL: URL? = nil) async {
        guard activePreviewSnapshotID == snapshot.id, currentDirectory == snapshot.directory,
              let directory = snapshot.directory else { return }
        let request = UUID()
        loadID = request
        directoryLoader.cancel(listTicket)
        directoryLoader.cancel(treeTickets.removeValue(forKey: directory))
        treeLoading.remove(directory)
        // 保存可能以原子替换更新磁盘，关闭预览必须开启新一代读取，不能加入保存前的在途快照。
        let result: Result<BrowserDirectorySnapshot, Error> = await withCheckedContinuation { continuation in
            listTicket = directoryLoader.request(directory, hidden: snapshot.showHidden, generation: UUID(),
                                                 foreground: true, expectedIdentity: snapshot.directoryIdentity) {
                continuation.resume(returning: $0)
            }
        }
        guard activePreviewSnapshotID == snapshot.id, loadID == request, currentDirectory == directory else { return }
        activePreviewSnapshotID = nil
        listTicket = nil
        pendingSelectionReferences = [:]
        updatingDisplayState = true
        query = snapshot.query
        typeFilter = snapshot.typeFilter
        showHidden = snapshot.showHidden
        sortByModified = snapshot.sortByModified
        gridView = snapshot.gridView
        expandedDirectories = snapshot.expandedDirectories
        updatingDisplayState = false
        isLoading = false
        revision = UUID()
        switch result {
        case .success(let loaded):
            let items = loaded.entries
            let trulyEmpty = loaded.trulyEmpty
            if let identity = loaded.identity { directoryIdentities[directory] = identity }
            entries = items
            directoryIsTrulyEmpty = trulyEmpty
            directoryError = nil
            directoryIssue = nil
            treeChildren[directory] = items.filter(\.isBrowsableDirectory)
            treeErrors[directory] = nil
            restoreSelection(snapshot.selection, primary: snapshot.primarySelection, savedURL: savedURL)
        case .failure(let error):
            // 原目录可能在预览期间改名。保留原身份快照供监听迁移，不能先清掉待恢复的选择。
            // 同路径后来对象仍被 expectedIdentity 拒绝，失败不会安装其内容。
            applyExternalSnapshot(.failure(error), at: directory)
        }
        saveWorkspace()
        updateObservationTargets()
    }

    private func fileReference(_ url: URL) -> BrowserFileReference {
        if let entry = entriesByURL[url] {
            return BrowserFileReference(url: url, identity: entry.identity ?? (try? FileSystem.identity(at: url)))
        }
        if let pending = pendingSelectionReferences[url] { return pending }
        return BrowserFileReference(url: url, identity: try? FileSystem.identity(at: url))
    }

    private func restoreSelection(_ references: Set<BrowserFileReference>, primary: BrowserFileReference?, savedURL: URL? = nil, anchor: BrowserFileReference? = nil) {
        let snapshot = displaySnapshot
        func resolve(_ reference: BrowserFileReference) -> URL? {
            if reference.url == savedURL, snapshot.byURL[reference.url] != nil { return savedURL }
            guard let identity = reference.identity else { return nil }
            // 原路径优先且必须同身份；唯一身份才允许跟随重命名，硬链接歧义不能随意继承选择。
            if snapshot.byURL[reference.url]?.identity == identity { return reference.url }
            if case .unique(let url) = snapshot.byIdentity[identity] { return url }
            return nil
        }
        let selection = Set(references.compactMap(resolve))
        let resolvedPrimary = primary.flatMap(resolve)
        if selection != selectedURLs || resolvedPrimary != selectedURL {
            setSelection(selection, primary: resolvedPrimary)
        }
        selectionAnchor = anchor.flatMap(resolve) ?? selectedURL
    }

    func enter(_ entry: FileEntry) {
        guard entry.isBrowsableDirectory else { return }
        navigate(to: entry.url)
    }

    /// 移除仅改变持久化引用；绝不调用磁盘删除，也要失效正在返回的旧目录请求。
    func removeManagedRoot(_ url: URL) {
        let root = Self.directoryURL(url)
        guard managedRoots.contains(root) else { return }
        managedRoots.removeAll { $0 == root }
        expandedDirectories = expandedDirectories.filter { !Self.contains($0, in: root) }
        bookmarks[root] = nil
        for (path, scoped) in scopedURLs.filter({ $0.key.path == root.path }) {
            scopedURLs[path] = nil
            scoped.stopAccessingSecurityScopedResource()
        }
        clearTree()
        if currentDirectory.map({ Self.contains($0, in: root) }) == true {
            clearCurrentDirectory()
        }
        navigationRoots = navigationRoots.filter { !Self.contains($0.key, in: root) }
        let retainedPrefixCount = history.prefix(historyIndex + 1).filter { !Self.contains($0, in: root) }.count
        history = history.filter { !Self.contains($0, in: root) }
        historyIndex = retainedPrefixCount - 1
        saveWorkspace()
        updateObservationTargets()
    }

    func replaceManagedRoot(_ url: URL, with replacement: URL) {
        let root = Self.directoryURL(url)
        guard let index = managedRoots.firstIndex(of: root), replacement.isFileURL else { return }
        let target = Self.directoryURL(replacement.resolvingSymlinksInPath())
        if target == root {
            retainAccess(to: replacement)
            rememberBookmark(for: target)
            saveWorkspace()
            refresh()
            return
        }
        removeManagedRoot(root)
        if !managedRoots.contains(target) { managedRoots.insert(target, at: min(index, managedRoots.count)) }
        retainAccess(to: replacement)
        rememberBookmark(for: target)
        activateRoot(target)
    }

    func createFolder(named name: String) {
        guard let directory = currentDirectory, directoryIssue == nil, !isLoading else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\0") else {
            actionError = "请输入有效的文件夹名称，不能包含 / 或 :。"
            return
        }
        let target = directory.appendingPathComponent(trimmed, isDirectory: true)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                // 不创建中间目录，不替换同名文件；系统的排他 mkdir 会报告冲突。
                Result {
                    guard mkdir(target.path, 0o777) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: target.path])
                    }
                }
            }.value
            switch result {
            case .success:
                if self.currentDirectory == directory { self.selectedURL = target; self.refresh() }
            case .failure(let error): self.actionError = "无法创建文件夹：\(error.localizedDescription)"
            }
        }
    }

    var selectedFileEntries: [FileEntry] {
        let display = displaySnapshot
        if let cachedSelectedEntries, cachedSelectedEntries.display === display { return cachedSelectedEntries.entries }
        let entries = display.entries(for: selectedURLs)
        cachedSelectedEntries = (display, entries)
        return entries
    }
    var selectedFileURLs: [URL] { selectedFileEntries.map(\.url) }

    /// List 的右键目标由系统给出；网格右键已选项目才沿用多选，右键未选项目只操作该项。
    /// 返回值在菜单构建时捕获，之后的选择、搜索与目录变化不能扩大破坏性操作范围。
    func fileActionEntries(for entry: FileEntry, contextSelection: Set<URL>? = nil) -> [FileEntry] {
        if let contextSelection { return displaySnapshot.entries(for: contextSelection) }
        if selectedURLs.contains(entry.url) { return selectedFileEntries }
        return displaySnapshot.byURL[entry.url].map { [$0] } ?? []
    }

    private func beginFileOperation(_ title: String, total: Int, replacingUndo: Bool = true) -> FileOperationControl {
        let control = FileOperationControl(title: title, total: total)
        operationControl = control
        fileOperationProgress = control.progress
        fileOperationSummary = nil
        actionError = nil
        if replacingUndo { fileOperationUndo = [] }
        Task { [weak self, weak control] in
            while let control, self?.operationControl === control {
                let progress = control.progress
                if self?.fileOperationProgress != progress { self?.fileOperationProgress = progress }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return control
    }

    func cancelFileOperation() {
        operationControl?.cancel()
        fileOperationProgress = operationControl?.progress
    }

    private func finishFileOperation(_ control: FileOperationControl, succeeded: Int, failures: [String],
                                     warnings: [String] = [], unattempted: Int) {
        let state = control.progress
        operationControl = nil
        fileOperationProgress = nil
        let details = failures + warnings
        fileOperationSummary = "\(state.title)\(state.cancellationRequested ? "已停止" : "完成")：成功 \(succeeded)，失败 \(failures.count)，未执行 \(unattempted)，共 \(state.total) 项。"
            + (details.isEmpty ? "" : "\n" + details.joined(separator: "\n"))
    }

    func dismissFileOperationSummary() { fileOperationSummary = nil }

    /// 只撤销最近一批成功项；冲突、被替换项目和取消后未执行的项目保留，允许用户排除问题后重试。
    func undoLastFileOperation() async {
        guard !isFileOperationBusy, !fileOperationUndo.isEmpty else { return }
        let records = fileOperationUndo
        isImporting = true
        let control = beginFileOperation("撤销文件操作", total: records.count, replacingUndo: false)
        let result = await Task.detached(priority: .userInitiated) {
            FileOperationUndo.perform(records, control: control)
        }.value
        fileOperationUndo = result.remaining
        finishFileOperation(control, succeeded: result.succeeded, failures: result.failures,
                            unattempted: records.count - control.progress.completed)
        completeFileRelocation(result.moved)
        isImporting = false
    }

    /// 移入废纸篓不回退为永久删除；一项失败不阻止其他项，并保持用户操作期间的新导航。
    @discardableResult
    func trashFiles(_ files: [FileEntry], using trashItem: WorkspaceFileTrash.TrashItem? = nil,
                    trashAndLocate: @escaping WorkspaceFileTrash.LocatedTrashItem = WorkspaceFileTrash.systemTrash) async -> WorkspaceFileTrash.Result? {
        guard !files.isEmpty else { return nil }
        guard !isFileOperationBusy else { actionError = "正在处理文件，请稍后再试。"; return nil }
        let files = WorkspaceFileTrash.unique(files)
        isTrashing = true
        let control = beginFileOperation("移到废纸篓", total: files.count)
        let result = await Task.detached(priority: .userInitiated) {
            WorkspaceFileTrash.perform(files, using: trashItem, trashAndLocate: trashAndLocate, control: control)
        }.value
        fileOperationUndo = result.undo
        finishFileOperation(control, succeeded: result.succeeded.count, failures: result.failures.map { "\($0.file.name)：\($0.message)" },
                            warnings: result.warnings, unattempted: result.unattempted)
        actionError = result.failureSummary
        // 只刷新最新浏览位置，失败项仅在身份仍匹配时保留选择。
        refresh()
        isTrashing = false
        return result
    }

    /// 只有磁盘重命名成功才同步工作区；完成时读取最新导航状态，不跳回发起操作的目录。
    @discardableResult
    func rename(_ entry: FileEntry, to name: String) async throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw NSError(domain: "FileDeck.FileOperation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请输入有效文件名称，不能包含路径分隔符。"])
        }
        guard name != entry.name else { return entry.url }
        let destination = try await Task.detached(priority: .userInitiated) {
            guard let identity = entry.identity, try FileSystem.identity(at: entry.url) == identity else {
                throw NSError(domain: "FileDeck.FileOperation", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "文件已发生变化，请刷新后重试。"])
            }
            let destination = entry.url.deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: entry.url.hasDirectoryPath)
            // 内核排他重命名拒绝覆盖同名文件或链接；验证失败时浏览状态保持原样。
            guard renamex_np(entry.url.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                if code == EEXIST {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                                  userInfo: [NSLocalizedDescriptionKey: "已存在同名文件，请使用其他名称。"])
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            return destination
        }.value
        completeFileRelocation([(entry.url, destination)])
        return destination
    }

    @discardableResult
    func copySelectedFiles(to pasteboard: NSPasteboard = .general) -> Bool {
        copyFiles(selectedFileURLs, to: pasteboard)
    }

    /// 写入标准文件 URL，Finder 与其他应用可直接粘贴；空选择不得清空用户剪贴板。
    @discardableResult
    func copyFiles(_ urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        let files = urls.map(fileReference)
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else { copiedFiles = nil; return false }
        copiedFiles = (pasteboard.name, pasteboard.changeCount, files)
        return true
    }

    /// 原生复制菜单写入提供器后再记下剪贴板代次；身份在用户发起复制时冻结。
    func copyFileItems() -> [NSItemProvider] {
        let files = selectedFileURLs.map(fileReference)
        guard !files.isEmpty else { return [] }
        DispatchQueue.main.async { [weak self] in
            let board = NSPasteboard.general
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard urls == files.map(\.url) else { return }
            self?.copiedFiles = (board.name, board.changeCount, files)
        }
        return files.map { NSItemProvider(object: $0.url as NSURL) }
    }

    func pasteFiles(from pasteboard: NSPasteboard = .general, into target: URL? = nil, move: Bool = false) {
        guard let directory = target ?? currentDirectory else {
            actionError = "请先选择可访问的目标文件夹。"
            return
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { actionError = "剪贴板中没有可粘贴的文件。"; return }
        if move {
            // 移动只认本窗口复制时冻结的身份，不能把外部剪贴板路径或同名替换项当成原文件。
            guard let copiedFiles, copiedFiles.board == pasteboard.name, copiedFiles.change == pasteboard.changeCount,
                  copiedFiles.files.map(\.url) == urls, copiedFiles.files.allSatisfy({ $0.identity != nil }) else {
                actionError = "请先在 FileDeck 中重新复制要移动的文件，再执行“移动到此处”。"
                return
            }
            transferFiles(copiedFiles.files, into: directory, move: true)
            return
        }
        transferFiles(urls.map { BrowserFileReference(url: $0, identity: nil) }, into: directory, move: false, renameConflicts: true)
    }

    /// 拖动开始时冻结选择与磁盘身份，异步读取载荷后也不能移动后续选中的其他文件。
    func beginFileDrag(_ url: URL, includingSelection: Bool) -> UUID {
        let urls = includingSelection && selectedURLs.contains(url) ? selectedFileURLs : [url]
        let files = urls.map(fileReference)
        // 原生 List 为多选的每一行请求提供器，同一批文件必须共用一个有效令牌。
        if let drag = activeFileDrag, drag.files == files { return drag.id }
        let id = UUID()
        activeFileDrag = (id, files)
        if includingSelection && !selectedURLs.contains(url) {
            let previousSelection = selectedURLs
            let previousPrimary = selectedURL
            // List 正在同步请求 NSItemProvider；此时发布选择会让 SwiftUI 重建拖动源。
            // 先冻结载荷，回调返回后再更新提示，并避免旧拖动覆盖用户的新选择。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeFileDrag?.id == id,
                      self.selectedURLs == previousSelection, self.selectedURL == previousPrimary else { return }
                self.selectedURL = url
            }
        }
        return id
    }

    /// Finder 同卷拖出可能直接移动磁盘文件；回到工作台时只在来源确有变化后刷新。
    func refreshAfterExternalDrag() {
        guard let drag = activeFileDrag else { return }
        activeFileDrag = nil
        let changed = drag.files.contains { reference in
            guard let identity = try? FileSystem.identity(at: reference.url) else { return true }
            return identity != reference.identity
        }
        if changed { refresh() }
    }

    func canDropActiveDrag(into directory: URL) -> Bool {
        guard let drag = activeFileDrag, !drag.files.isEmpty else { return false }
        let target = directory.resolvingSymlinksInPath().standardizedFileURL
        return drag.files.allSatisfy {
            let source = $0.url.standardizedFileURL
            return source.deletingLastPathComponent().path != target.path
                && !Self.contains(target, in: source.resolvingSymlinksInPath())
        }
    }

    func dropActiveDrag(token: UUID, into directory: URL, copy: Bool) {
        guard let drag = activeFileDrag, drag.id == token, canDropActiveDrag(into: directory) else { return }
        activeFileDrag = nil
        transferFiles(drag.files, into: directory, move: !copy)
    }

    /// 外部拖入保持复制语义；目标来自落点快照，而非异步加载完成时的当前目录。
    func importFiles(_ urls: [URL], into target: URL? = nil) {
        guard let directory = target ?? currentDirectory else {
            actionError = "请先选择可访问的目标文件夹。"
            return
        }
        transferFiles(urls.map { BrowserFileReference(url: $0, identity: nil) }, into: directory, move: false)
    }

    private func transferFiles(_ files: [BrowserFileReference], into directory: URL, move: Bool, renameConflicts: Bool = false) {
        guard !files.isEmpty else { return }
        guard !isFileOperationBusy else { actionError = "正在处理文件，请稍后再试。"; return }
        guard directory.isFileURL, let identity = try? FileSystem.identity(at: directory) else {
            actionError = "目标文件夹不可访问，请重新选择。"
            return
        }
        let files = WorkspaceFileTransfer.unique(files)
        isImporting = true
        let control = beginFileOperation(move ? "移动" : "复制", total: files.count)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                WorkspaceFileTransfer.perform(files, into: directory, expectedIdentity: identity, move: move,
                                              renameConflicts: renameConflicts, control: control)
            }.value
            self.fileOperationUndo = result.undo
            self.finishFileOperation(control, succeeded: result.succeeded, failures: result.failures,
                                     warnings: result.warnings, unattempted: result.unattempted)
            if !result.failures.isEmpty { self.actionError = result.failures.joined(separator: "\n") }
            // 状态同步期间继续持有忙碌门禁，防止被动目录同步插入旧路径快照。
            if move { self.completeFileRelocation(result.moved) }
            else { self.refresh(); self.saveWorkspace() }
            self.isImporting = false
        }
    }

    /// 重命名与拖动移动共用同一次状态提交，旧路径缓存和在途恢复不能再次带回已失效的位置。
    private func completeFileRelocation(_ moved: [(source: URL, destination: URL)], preservingList: Bool = false) {
        guard !moved.isEmpty else { refresh(); return }
        func relocated(_ url: URL) -> URL {
            guard let change = moved.first(where: { Self.contains(url, in: $0.source) }) else { return url }
            let suffix = String(url.path.dropFirst(change.source.path.count))
            return URL(fileURLWithPath: change.destination.path + suffix, isDirectory: url.hasDirectoryPath)
        }
        cancelExternalRequests()
        func relocatedEntry(_ entry: FileEntry) -> FileEntry {
            let url = relocated(entry.url)
            return FileEntry(url: url, name: url.lastPathComponent, isDirectory: entry.isDirectory,
                             isPackage: entry.isPackage, isSymbolicLink: entry.isSymbolicLink, size: entry.size,
                             modifiedAt: entry.modifiedAt, typeIdentifier: entry.typeIdentifier, identity: entry.identity)
        }
        func relocatedEntries(_ entries: [FileEntry]) -> [FileEntry] {
            // 真实迁移项覆盖目标路径旧缓存，避免同一 URL 两行导致索引构造崩溃。
            let destinations = Set(entries.compactMap { relocated($0.url) == $0.url ? nil : relocated($0.url) })
            return entries.compactMap { entry in
                if relocated(entry.url) == entry.url && destinations.contains(entry.url) { return nil }
                return relocatedEntry(entry)
            }
        }
        let previousTree = treeChildren
        var mappedTree = previousTree.filter { relocated($0.key) == $0.key }.mapValues(relocatedEntries)
        for (url, children) in previousTree where relocated(url) != url {
            mappedTree[Self.directoryURL(relocated(url))] = relocatedEntries(children)
        }
        let previousIdentities = directoryIdentities
        directoryIdentities = previousIdentities.filter { relocated($0.key) == $0.key }
        for (url, identity) in previousIdentities where relocated(url) != url {
            directoryIdentities[Self.directoryURL(relocated(url))] = identity
        }
        entries = relocatedEntries(entries)
        let previousBookmarks = bookmarks
        // 目标路径可能已有失效的管理引用。先保留未迁移项，再让真实迁移对象覆盖同路径旧书签。
        bookmarks = previousBookmarks.filter { relocated($0.key) == $0.key }
        for (original, bookmark) in previousBookmarks where relocated(original) != original {
            let destination = relocated(original)
            // rememberBookmark 失败会清除此键，因此不会把失效目标书签误当成刷新成功。
            rememberBookmark(for: destination)
            // 暂时无法生成新书签时保留源对象旧数据，而不是目标路径下已失效对象的书签。
            if bookmarks[destination] == nil { bookmarks[destination] = bookmark }
        }
        var relocatedScopes = scopedURLs.filter { relocated($0.key) == $0.key }
        for (path, scoped) in scopedURLs where relocated(path) != path {
            let destination = relocated(path)
            // 保留真实迁移对象最初获得的令牌，仅释放被替代的旧目标授权，不能依赖字典遍历顺序。
            if let replaced = relocatedScopes.updateValue(scoped, forKey: destination) {
                replaced.stopAccessingSecurityScopedResource()
            }
        }
        scopedURLs = relocatedScopes
        var seenRoots: Set<URL> = []
        managedRoots = managedRoots.map { Self.directoryURL(relocated($0)) }.filter { seenRoots.insert($0).inserted }
        currentDirectory = currentDirectory.map { Self.directoryURL(relocated($0)) }
        rootURL = rootURL.map { Self.directoryURL(relocated($0)) }
        history = history.map { Self.directoryURL(relocated($0)) }
        expandedDirectories = Set(expandedDirectories.map { Self.directoryURL(relocated($0)) })
        let previousNavigationRoots = navigationRoots
        navigationRoots = previousNavigationRoots.filter { relocated($0.key) == $0.key }
        for (directory, root) in previousNavigationRoots where relocated(directory) != directory {
            // 历史中的失效目标路径可能与新路径重合，实际迁移子树的根归属应优先于旧目标的导航记录。
            navigationRoots[Self.directoryURL(relocated(directory))] = Self.directoryURL(relocated(root))
        }
        let selection = Set(selectedURLs.map(relocated))
        setSelection(selection, primary: selectedURL.map(relocated))
        selectionAnchor = selectionAnchor.map(relocated)
        activePreviewSnapshotID = nil
        currentRestoreID = nil
        if activeFileDrag?.files.contains(where: { relocated($0.url) != $0.url }) == true { activeFileDrag = nil }
        // 先作废旧请求，再按新路径加载树；直接 refresh 会重新枚举缓存中的旧目录名称。
        clearTree()
        if preservingList {
            treeChildren = mappedTree
            updateSearchSelection()
            updateObservationTargets()
            for url in observedPrimaryDirectories { markExternalChange(url) }
        } else {
            loadDirectory()
            reloadVisibleTree()
            updateObservationTargets()
        }
        saveWorkspace()
    }

    func openSelectedWithDefaultApp() {
        guard let entry = selectedEntry else { return }
        NSWorkspace.shared.open(entry.url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.actionError = error.localizedDescription }
        }
    }

    func revealSelected() {
        if let selectedURL { NSWorkspace.shared.activateFileViewerSelecting([selectedURL]) }
    }

    func loadChildren(of location: URL) {
        let url = Self.directoryURL(location)
        guard treeChildren[url] == nil, !treeLoading.contains(url) else { return }
        // 树加载独立于列表请求。快速切换目录会作废旧列表，不能因此丢掉已展开节点的加载。
        treeLoading.insert(url)
        treeErrors[url] = nil
        let generation = treeGeneration
        let hidden = showHidden
        let version = externalVersion
        treeTickets[url] = directoryLoader.request(url, hidden: hidden, generation: generation) { [weak self] result in
            guard let self, generation == self.treeGeneration else { return }
            self.treeTickets[url] = nil
            self.treeLoading.remove(url)
            guard self.treeChildren[url] == nil else { return }
            switch result {
            case .success(let snapshot):
                self.treeChildren[url] = snapshot.entries.filter(\.isBrowsableDirectory)
                if let identity = snapshot.identity { self.directoryIdentities[url] = identity }
                self.consumeExternalChange(url, through: version)
                self.updateObservationTargets()
            case .failure(let error): if !(error is CancellationError) { self.treeErrors[url] = Self.message(for: error) }
            }
        }
    }

    func toggleExpanded(_ location: URL) {
        let url = Self.directoryURL(location)
        if expandedDirectories.contains(url) {
            expandedDirectories.remove(url)
            // 收起祖先时，保留后代展开意图，但取消现在看不见的排队读取。
            cancelInvisibleTreeLoads()
        } else {
            expandedDirectories.insert(url)
            reloadVisibleTree()
        }
        saveWorkspace()
        updateObservationTargets()
    }

    private func expandAncestors(of url: URL) {
        guard let rootURL, Self.contains(url, in: rootURL) else { return }
        var ancestor = url.deletingLastPathComponent()
        while Self.contains(ancestor, in: rootURL) {
            expandedDirectories.insert(ancestor)
            if ancestor == rootURL { break }
            ancestor.deleteLastPathComponent()
        }
    }

    private func clearTree() {
        treeGeneration = UUID()
        for ticket in treeTickets.values { directoryLoader.cancel(ticket) }
        treeTickets = [:]
        treeChildren = [:]
        treeErrors = [:]
        treeLoading = []
    }

    private func isVisibleExpandedDirectory(_ url: URL) -> Bool {
        guard expandedDirectories.contains(url),
              let root = (managedRoots + (rootURL.map { [$0] } ?? []))
                .filter({ Self.contains(url, in: $0) }).max(by: { $0.path.count < $1.path.count }) else { return false }
        var ancestor = url
        while ancestor != root {
            ancestor.deleteLastPathComponent()
            guard expandedDirectories.contains(ancestor) else { return false }
        }
        return true
    }

    private func cancelInvisibleTreeLoads() {
        for pending in Array(treeTickets.keys) where !isVisibleExpandedDirectory(pending) {
            directoryLoader.cancel(treeTickets.removeValue(forKey: pending))
            treeLoading.remove(pending)
        }
    }

    private func reloadVisibleTree() {
        for url in expandedDirectories where isVisibleExpandedDirectory(url) { loadChildren(of: url) }
    }

    private func loadDirectory() {
        guard let currentDirectory else { return }
        let request = UUID()
        loadID = request
        isLoading = true
        directoryError = nil
        directoryIssue = nil
        directoryIsTrulyEmpty = false
        let previousSelection = selectedURL.map(fileReference)
        let previousSelections = Set(selectedURLs.map(fileReference))
        pendingSelectionReferences = Dictionary(uniqueKeysWithValues: previousSelections.map { ($0.url, $0) })
        entries = []
        let hidden = showHidden
        let version = externalVersion
        directoryLoader.cancel(listTicket)
        listTicket = directoryLoader.request(currentDirectory, hidden: hidden, generation: treeGeneration, foreground: true) { [weak self] result in
            guard let self, self.loadID == request else { return }
            self.listTicket = nil
            self.pendingSelectionReferences = [:]
            self.isLoading = false
            self.startupPhase = .ready
            self.revision = UUID()
            switch result {
            case .success(let snapshot):
                let items = snapshot.entries
                let trulyEmpty = snapshot.trulyEmpty
                self.directoryIsTrulyEmpty = trulyEmpty
                self.entries = items
                if let identity = snapshot.identity { self.directoryIdentities[currentDirectory] = identity }
                self.consumeExternalChange(currentDirectory, through: version)
                self.treeChildren[currentDirectory] = items.filter(\.isBrowsableDirectory)
                self.treeErrors[currentDirectory] = nil
                self.restoreSelection(previousSelections, primary: previousSelection)
                self.updateObservationTargets()
            case .failure(let error):
                self.selectedURL = nil
                self.directoryIssue = Self.classify(error)
                self.directoryError = Self.message(for: error)
                self.treeErrors[currentDirectory] = Self.message(for: error)
                self.updateObservationTargets()
            }
        }
    }

    /// vnode 不保证所有卷的通知可靠；回到前台始终做一次合并校验，并重试失败的订阅。
    func checkForExternalChanges() {
        guard observesExternalChanges else { return }
        updateObservationTargets(retry: true)
        for url in observedPrimaryDirectories { markExternalChange(url) }
    }

    private var observedPrimaryDirectories: Set<URL> {
        guard observesExternalChanges, startupPhase == .ready else { return [] }
        var paths = Set(expandedDirectories.filter(isVisibleExpandedDirectory))
        if let currentDirectory { paths.insert(currentDirectory) }
        return paths
    }

    private func updateObservationTargets(retry: Bool = false) {
        guard let directoryObserver else { return }
        let primary = observedPrimaryDirectories
        // 优先当前目录和父目录，再按深度分配可见分支，避免极大展开树耗尽 fd。
        // 超出上限的分支仍在回前台时校验；父目录只监听，不枚举其内容。
        var ordered: [URL] = []
        var seen: Set<URL> = []
        func append(_ url: URL) {
            if seen.insert(url).inserted { ordered.append(url) }
            let parent = Self.directoryURL(url.deletingLastPathComponent())
            if seen.insert(parent).inserted { ordered.append(parent) }
        }
        if let currentDirectory { append(currentDirectory) }
        for url in primary.sorted(by: { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }) { append(url) }
        let paths = Array(ordered.prefix(BrowserDirectoryObserver.maximumSubscriptions))
        observedDirectories = Set(paths)
        directoryIdentities = directoryIdentities.filter { primary.contains($0.key) || observedDirectories.contains($0.key) }
        for (url, request) in externalRequests where !primary.contains(url) {
            externalRequests[url] = nil
            directoryLoader.cancel(request.ticket)
        }
        externalDirty = externalDirty.filter { primary.contains($0.key) }
        directoryObserver.setTargets(paths.map { BrowserDirectoryObserver.Target(url: $0, identity: directoryIdentities[$0]) }, retry: retry)
        isSynchronizingExternalChanges = !externalRequests.isEmpty
    }

    private func receiveDirectoryEvent(_ event: BrowserDirectoryObserver.Event) {
        let url = Self.directoryURL(event.url)
        guard observedDirectories.contains(url) else { return }
        if let identity = event.identity {
            guard directoryIdentities[url] == nil || directoryIdentities[url] == identity else { return }
            directoryIdentities[url] = identity
            if let destination = event.destination {
                externalMoves[url] = (identity, Self.directoryURL(destination))
            }
        }
        for primary in observedPrimaryDirectories where primary == url || primary.deletingLastPathComponent().path == url.path {
            markExternalChange(primary)
        }
        scheduleExternalSynchronization()
    }

    private func markExternalChange(_ url: URL) {
        externalVersion &+= 1
        externalDirty[url] = externalVersion
        scheduleExternalSynchronization()
    }

    private func scheduleExternalSynchronization() {
        guard observesExternalChanges, !externalDirty.isEmpty || !externalMoves.isEmpty else { return }
        externalDebounce?.cancel()
        externalDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.externalDebounce = nil
            self.synchronizeExternalChanges()
        }
    }

    private func cancelExternalRequests() {
        externalEpoch = UUID()
        let requests = externalRequests.values
        externalRequests = [:]
        for request in requests { directoryLoader.cancel(request.ticket) }
        isSynchronizingExternalChanges = false
    }

    private func consumeExternalChange(_ url: URL, through version: UInt64) {
        if let dirty = externalDirty[url], dirty <= version { externalDirty[url] = nil }
    }

    private func synchronizeExternalChanges() {
        // 打开的预览/草稿由文档自己的冲突门处理；仅暂存目录变化，关闭后才校验浏览快照。
        guard !isLoading, !isFileOperationBusy, activePreviewSnapshotID == nil else { return }
        let moves = externalMoves.sorted { $0.key.path.count < $1.key.path.count }
        externalMoves = [:]
        var accepted: [(source: URL, destination: URL)] = []
        for (source, move) in moves where directoryIdentities[source] == move.identity {
            if !accepted.contains(where: { Self.contains(source, in: $0.source) }) {
                accepted.append((source, move.destination))
            }
        }
        if !accepted.isEmpty { completeFileRelocation(accepted, preservingList: true) }
        let epoch = externalEpoch
        let generation = UUID()
        for url in observedPrimaryDirectories where externalDirty[url] != nil && externalRequests[url] == nil {
            let version = externalVersion
            let expectedIdentity = directoryIdentities[url]
            let requestID = UUID()
            let ticket = directoryLoader.request(url, hidden: showHidden, generation: generation,
                                                foreground: currentDirectory == url, expectedIdentity: expectedIdentity) { [weak self] result in
                guard let self, self.externalEpoch == epoch,
                      self.externalRequests[url]?.id == requestID else { return }
                self.externalRequests[url] = nil
                defer {
                    self.isSynchronizingExternalChanges = !self.externalRequests.isEmpty
                    if !self.externalDirty.isEmpty || !self.externalMoves.isEmpty { self.scheduleExternalSynchronization() }
                }
                // 请求途中打开编辑器或开始文件操作时，结果也必须暂存，不能只在发起阶段检查。
                guard !self.isLoading, !self.isFileOperationBusy, self.activePreviewSnapshotID == nil else { return }
                self.consumeExternalChange(url, through: version)
                guard self.observedPrimaryDirectories.contains(url) else { return }
                self.applyExternalSnapshot(result, at: url)
            }
            externalRequests[url] = (requestID, ticket)
        }
        isSynchronizingExternalChanges = !externalRequests.isEmpty
    }

    private func applyExternalSnapshot(_ result: Result<BrowserDirectorySnapshot, Error>, at url: URL) {
        switch result {
        case .success(let snapshot):
            let oldFolders = url == currentDirectory ? entries.filter(\.isBrowsableDirectory) : treeChildren[url] ?? []
            let folders = snapshot.entries.filter(\.isBrowsableDirectory)
            let newURLs = Set(folders.map(\.url))
            let byIdentity = Dictionary(grouping: folders.compactMap { entry in entry.identity.map { ($0, entry.url) } }, by: { $0.0 })
            let moves = oldFolders.compactMap { entry -> (source: URL, destination: URL)? in
                guard !newURLs.contains(entry.url), let identity = entry.identity,
                      let candidates = byIdentity[identity], candidates.count == 1 else { return nil }
                return (entry.url, candidates[0].1)
            }
            if !moves.isEmpty { completeFileRelocation(moves, preservingList: true) }
            if let identity = snapshot.identity { directoryIdentities[url] = identity }
            if currentDirectory == url {
                // 用户可在后台读取期间继续改选/筛选，提交时捕获最新选择，不使用请求开始时的旧快照。
                let selection = Set(selectedURLs.map(fileReference))
                let primary = selectedURL.map(fileReference)
                let anchor = selectionAnchor.map(fileReference)
                let changed = entries != snapshot.entries || directoryIssue != nil || directoryIsTrulyEmpty != snapshot.trulyEmpty
                if entries != snapshot.entries { entries = snapshot.entries }
                if directoryIsTrulyEmpty != snapshot.trulyEmpty { directoryIsTrulyEmpty = snapshot.trulyEmpty }
                if directoryError != nil { directoryError = nil }
                if directoryIssue != nil { directoryIssue = nil }
                restoreSelection(selection, primary: primary, anchor: anchor)
                if changed { revision = UUID() }
            }
            if treeChildren[url] != folders { treeChildren[url] = folders }
            if treeErrors[url] != nil { treeErrors[url] = nil }
            updateObservationTargets()
        case .failure(let error):
            // 读取失败不是空目录；保留最后快照和选择，显示已有错误面板，前台/后续事件可以重试。
            if currentDirectory == url {
                let issue = Self.classify(error), message = Self.message(for: error)
                if directoryIssue != issue { directoryIssue = issue }
                if directoryError != message { directoryError = message }
            }
            let message = Self.message(for: error)
            if treeErrors[url] != message { treeErrors[url] = message }
        }
    }

    private func savedWorkspace() -> SavedWorkspace? {
        if let data = defaults.data(forKey: workspaceKey), let saved = try? JSONDecoder().decode(SavedWorkspace.self, from: data) {
            return saved
        } else if let path = defaults.string(forKey: savedRootKey) {
            // 迁移旧版单根记录；不存在的根仍保留，由枚举结果显示恢复操作。
            let location = SavedLocation(path: path, bookmark: nil)
            return SavedWorkspace(roots: [location], currentPath: path, activeRoot: location, expandedPaths: [path])
        }
        return nil
    }

    /// 从欢迎页选择新目录或外部打开文件时保留管理目录，但不能让旧路径恢复抢回导航。
    private func restoreManagedRootsForExplicitOpen() {
        guard var saved = pendingWorkspace else { return }
        pendingWorkspace = nil
        saved.currentPath = nil
        saved.activeRoot = nil
        restore(saved)
    }

    private func restore(_ saved: SavedWorkspace) {
        startupPhase = .restoring
        managedRoots = saved.roots.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        // 各根解析独立完成，先保留全部旧书签，避免先完成的根保存工作区时清掉仍待恢复的授权。
        for location in saved.roots + (saved.activeRoot.map { [$0] } ?? []) {
            if let bookmark = location.bookmark {
                bookmarks[URL(fileURLWithPath: location.path, isDirectory: true)] = bookmark
            }
        }
        expandedDirectories = Set(saved.expandedPaths.map { URL(fileURLWithPath: $0, isDirectory: true) })
        rootURL = saved.activeRoot.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        currentDirectory = saved.currentPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        isLoading = currentDirectory != nil
        let request = UUID()
        currentRestoreID = request
        // 先恢复路径和三栏，再独立解析书签。慢卷不会阻塞主线程或其他根目录。
        finishRestoringMetadata()
        for savedRoot in saved.roots {
            let original = URL(fileURLWithPath: savedRoot.path, isDirectory: true)
            Task {
                let resolved = await Task.detached(priority: .userInitiated) { Self.resolveLocation(savedRoot) }.value
                guard self.managedRoots.contains(original) else { return }
                self.applyResolvedLocation(resolved, replacing: original)
                self.loadChildren(of: resolved.url)
            }
        }
        if let path = saved.currentPath {
            let active = saved.activeRoot ?? SavedLocation(path: path, bookmark: nil)
            Task {
                let resolved = await Task.detached(priority: .userInitiated) { Self.resolveLocation(active) }.value
                // 用户已经导航或返回空状态时，旧恢复请求不得覆盖最新选择。
                guard self.currentRestoreID == request else { return }
                let original = URL(fileURLWithPath: active.path, isDirectory: true)
                self.applyResolvedLocation(resolved, replacing: original)
                self.rootURL = resolved.url
                self.navigate(to: Self.remapDirectory(path, from: original, to: resolved.url))
            }
        } else {
            currentRestoreID = nil
        }
    }

    private func applyResolvedLocation(_ resolved: ResolvedLocation, replacing original: URL) {
        retainAccess(to: resolved.url)
        bookmarks[resolved.url] = resolved.bookmark
        guard original != resolved.url else { saveWorkspace(); return }
        if let index = managedRoots.firstIndex(of: original) {
            managedRoots[index] = resolved.url
            // 多份旧书签可能最终指向同一个目录，保留首个管理位置。
            var seen: Set<URL> = []
            managedRoots = managedRoots.filter { seen.insert($0).inserted }
        }
        expandedDirectories = Set(expandedDirectories.map { Self.remapDirectory($0.path, from: original, to: resolved.url) })
        if let current = currentDirectory, Self.contains(current, in: original) {
            if currentRestoreID == nil {
                rootURL = resolved.url
                navigate(to: Self.remapDirectory(current.path, from: original, to: resolved.url))
            }
        } else { saveWorkspace() }
    }

    nonisolated private static func remapDirectory(_ path: String, from original: URL, to replacement: URL) -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard contains(url, in: original) else { return url }
        return URL(fileURLWithPath: replacement.path + path.dropFirst(original.path.count), isDirectory: true)
    }

    private func finishRestoringMetadata() {
        // 磁盘可能缓慢或暂时断开。启动页只等待本地状态恢复，目录枚举继续在三栏内展示加载态。
        Task { await Task.yield(); if self.startupPhase == .restoring { self.startupPhase = .ready } }
    }

    private func saveWorkspace() {
        // 当前路径尚未随书签映射时不能保存半恢复快照，否则下次启动会失去旧路径映射依据。
        guard persistsWorkspace, currentRestoreID == nil else { return }
        let saved = SavedWorkspace(roots: managedRoots.map(savedLocation), currentPath: currentDirectory?.path,
                                   activeRoot: rootURL.map(savedLocation), expandedPaths: expandedDirectories.map(\.path).sorted())
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: workspaceKey) }
        // 移除末根后不能被旧版兼容键重新带回。
        defaults.removeObject(forKey: savedRootKey)
    }

    private func savedLocation(_ url: URL) -> SavedLocation { SavedLocation(path: url.path, bookmark: bookmarks[url]) }

    private func rememberBookmark(for url: URL) {
        // 本地临时签名版本不要求沙箱；仍保存安全作用域书签，供系统允许时恢复授权。
        bookmarks[url] = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    nonisolated private static func resolveLocation(_ saved: SavedLocation) -> ResolvedLocation {
        let fallback = ResolvedLocation(url: URL(fileURLWithPath: saved.path, isDirectory: true), bookmark: saved.bookmark)
        guard let data = saved.bookmark else { return fallback }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            // 授权撤销或磁盘断开时保留原引用，不弹窗也不主动挂载外部磁盘。
            return fallback
        }
        let accessed = resolved.startAccessingSecurityScopedResource()
        defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }
        let refreshed = stale ? (try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) : nil
        return ResolvedLocation(url: directoryURL(resolved), bookmark: refreshed ?? data)
    }

    private func retainAccess(to url: URL) {
        let path = url.standardizedFileURL
        guard scopedURLs[path] == nil else { return }
        if url.startAccessingSecurityScopedResource() { scopedURLs[path] = url }
    }

    /// Foundation 的目录 URL 是否带尾斜杠会影响 Hashable；所有目录状态统一构造，
    /// 防止同一路径在原生面板、书签、拖放与测试入口中变成不同的管理节点。
    nonisolated private static func directoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    nonisolated private static func contains(_ child: URL, in root: URL) -> Bool {
        child.path == root.path || child.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    static func classify(_ error: Error) -> DirectoryIssue {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError { return .permission }
            if nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError { return .unavailable }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(EACCES) || nsError.code == Int(EPERM) { return .permission }
            if nsError.code == Int(ENOENT) || nsError.code == Int(ENODEV) || nsError.code == Int(ENOTDIR) { return .unavailable }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError { return classify(underlying) }
        return .readFailure
    }

    private static func message(for error: Error) -> String {
        switch classify(error) {
        case .permission: return "需要获得此文件夹的访问权限，才能查看其中的文件。"
        case .unavailable: return "文件夹可能已移动、删除，或所在磁盘尚未连接。"
        case .readFailure: return error.localizedDescription
        }
    }
}

/// 工作线程只写一个快照，主线程定时读取；大批次不会为每个项目排队发布 SwiftUI 更新。
final class FileOperationControl: @unchecked Sendable {
    struct Progress: Equatable, Sendable {
        let title: String
        let total: Int
        var completed = 0
        var current: String? = nil
        var cancellationRequested = false
    }
    private let lock = NSLock()
    private var value: Progress
    init(title: String, total: Int) { value = Progress(title: title, total: total) }
    var progress: Progress { lock.lock(); defer { lock.unlock() }; return value }
    var isCancelled: Bool { progress.cancellationRequested }
    func cancel() { lock.lock(); value.cancellationRequested = true; lock.unlock() }
    func begin(_ name: String) { lock.lock(); value.current = name; lock.unlock() }
    func complete() { lock.lock(); value.completed += 1; value.current = nil; lock.unlock() }
}

/// 只保留最近一批成功项，随窗口关闭或下一批操作开始失效；不扫描用户废纸篓推测恢复路径。
struct FileOperationUndo: Sendable {
    enum Kind: Sendable { case copy, relocation }
    let kind: Kind
    let original: URL
    let current: URL
    let identity: FileIdentity
    let originalParentIdentity: FileIdentity
    let currentParentIdentity: FileIdentity

    static func capture(kind: Kind, original: URL, current: URL, originalParent: FileIdentity, expectedIdentity: FileIdentity) throws -> Self {
        guard try FileSystem.identity(at: current) == expectedIdentity else {
            throw WorkspaceFileTransfer.failure("操作后的项目已被替换，未登记撤销。")
        }
        return Self(kind: kind, original: original, current: current, identity: expectedIdentity,
             originalParentIdentity: originalParent,
             currentParentIdentity: try FileSystem.identity(at: current.deletingLastPathComponent()))
    }

    struct Result: Sendable {
        var remaining: [FileOperationUndo] = []
        var moved: [(source: URL, destination: URL)] = []
        var failures: [String] = []
        var succeeded = 0
    }

    static func perform(_ records: [Self], control: FileOperationControl,
                        trash: WorkspaceFileTrash.LocatedTrashItem = WorkspaceFileTrash.systemTrash) -> Result {
        var result = Result()
        let reversed = Array(records.reversed())
        for (index, record) in reversed.enumerated() {
            if control.isCancelled { result.remaining += reversed[index...]; break }
            control.begin(record.current.lastPathComponent)
            defer { control.complete() }
            let accessed = record.current.startAccessingSecurityScopedResource()
            defer { if accessed { record.current.stopAccessingSecurityScopedResource() } }
            do {
                guard try FileSystem.identity(at: record.current) == record.identity,
                      try FileSystem.identity(at: record.current.deletingLastPathComponent()) == record.currentParentIdentity else {
                    throw WorkspaceFileTransfer.failure("项目或所在文件夹已变化，未执行撤销。")
                }
                if record.kind == .copy {
                    // 撤销副本采用系统废纸篓，不永久删除；复制后原地修改的内容也能由 Finder 找回。
                    _ = try trash(record.current)
                } else {
                    guard try FileSystem.identity(at: record.original.deletingLastPathComponent()) == record.originalParentIdentity else {
                        throw WorkspaceFileTransfer.failure("原文件夹已变化，请手动恢复。")
                    }
                    _ = try WorkspaceFileTransfer.move(record.current, to: record.original, expectedIdentity: record.identity)
                    result.moved.append((record.current, record.original))
                }
                result.succeeded += 1
            } catch {
                result.remaining.append(record)
                result.failures.append("\(record.current.path) → \(record.original.path)：\(error.localizedDescription)")
            }
        }
        // 重试仍从上次撤销的顺序继续，不重复触碰已经完成的项目。
        result.remaining.reverse()
        return result
    }
}

/// 冻结的逐项废纸篓批次。只按路径去重，硬链接共享 inode 仍是两个可单独移走的目录项。
enum WorkspaceFileTrash {
    typealias TrashItem = @Sendable (URL) throws -> Void
    typealias LocatedTrashItem = @Sendable (URL) throws -> URL
    static let systemTrash: LocatedTrashItem = { url in
        var location: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &location)
        guard let location else { throw WorkspaceFileTransfer.failure("系统已移走项目，但未返回恢复位置；请在 Finder 废纸篓中检查。") }
        return location as URL
    }
    struct Failure: Sendable { let file: FileEntry; let message: String }
    struct Result: Sendable {
        var succeeded: [FileEntry] = []
        var failures: [Failure] = []
        var undo: [FileOperationUndo] = []
        var warnings: [String] = []
        var unattempted = 0
        var count: Int { succeeded.count + failures.count + unattempted }
        var failureSummary: String? {
            guard !failures.isEmpty else { return nil }
            return "已将 \(succeeded.count) 个项目移到废纸篓，\(failures.count) 个项目未完成（共 \(count) 个）。\n"
                + failures.map { "\($0.file.name)：\($0.message)" }.joined(separator: "\n")
        }
    }

    static func unique(_ files: [FileEntry]) -> [FileEntry] {
        var seen: Set<String> = []
        return files.filter { seen.insert($0.url.isFileURL ? $0.url.standardizedFileURL.path : $0.url.absoluteString).inserted }
    }
    static func perform(_ files: [FileEntry], using trashItem: TrashItem? = nil,
                        trashAndLocate: LocatedTrashItem = systemTrash, control: FileOperationControl? = nil) -> Result {
        var result = Result()
        let files = unique(files)
        for (index, file) in files.enumerated() {
            if control?.isCancelled == true { result.unattempted = files.count - index; break }
            control?.begin(file.name)
            defer { control?.complete() }
            let url = file.url
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                // 身份必须来自菜单快照，不能在点击后补 stat 接管同名替换文件。
                guard url.isFileURL, let identity = file.identity, try FileSystem.identity(at: url) == identity else {
                    throw WorkspaceFileTransfer.failure("文件已发生变化，请刷新后重试。")
                }
                let parent = try FileSystem.identity(at: url.deletingLastPathComponent())
                if let trashItem { try trashItem(url); result.succeeded.append(file) }
                else {
                    let location = try trashAndLocate(url)
                    result.succeeded.append(file)
                    do { result.undo.append(try .capture(kind: .relocation, original: url, current: location, originalParent: parent, expectedIdentity: identity)) }
                    catch { result.warnings.append("\(file.name)：已移到 \(location.path)，无法登记撤销：\(error.localizedDescription)") }
                }
            } catch { result.failures.append(Failure(file: file, message: error.localizedDescription)) }
        }
        return result
    }
}

/// 排他提交副本。复制失败只清理本次创建的隔离目录，绝不删除同名目标或其他批次的项目。
enum WorkspaceFileTransfer {
    struct IO: Sendable {
        var rename: @Sendable (URL, URL) throws -> Void = { source, destination in
            guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        var copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    }
    struct Result: Sendable {
        var moved: [(source: URL, destination: URL)] = []
        var failures: [String] = []
        var undo: [FileOperationUndo] = []
        var warnings: [String] = []
        var succeeded = 0
        var unattempted = 0
    }

    static func unique(_ files: [BrowserFileReference]) -> [BrowserFileReference] {
        var seen: Set<URL> = []
        return files.filter { seen.insert($0.url.standardizedFileURL).inserted }
    }
    static func perform(_ files: [BrowserFileReference], into directory: URL,
                        expectedIdentity: FileIdentity, move: Bool, renameConflicts: Bool = false,
                        control: FileOperationControl? = nil, io: IO = IO()) -> Result {
        var result = Result()
        let files = unique(files)
        for (index, file) in files.enumerated() {
            if control?.isCancelled == true { result.unattempted = files.count - index; break }
            let source = file.url
            control?.begin(source.lastPathComponent)
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                guard source.isFileURL, directory.isFileURL else { throw failure("只能处理本机文件。") }
                guard try FileSystem.identity(at: directory) == expectedIdentity else { throw failure("目标文件夹已变化，请重新拖放。") }
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      !FileSystem.isPackageDirectory(directory, values: values) else { throw FileSystemError.notBrowsableDirectory(directory) }
                let identity = try FileSystem.identity(at: source)
                if move || file.identity != nil {
                    guard identity == file.identity else { throw failure("文件已变化，请刷新后重试。") }
                }
                let parent = try FileSystem.identity(at: source.deletingLastPathComponent())
                let resolvedSource = source.standardizedFileURL.resolvingSymlinksInPath().path
                let target = directory.resolvingSymlinksInPath().path
                guard target != resolvedSource,
                      !target.hasPrefix(resolvedSource.hasSuffix("/") ? resolvedSource : resolvedSource + "/") else {
                    throw failure("不能将文件夹拖到自身或其子目录中。")
                }
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                if !renameConflicts && source.standardizedFileURL.path == destination.standardizedFileURL.path { throw failure("来源与目标相同，未执行。") }
                let completed: URL
                let completedIdentity: FileIdentity
                if move {
                    // 单个移动/废纸篓调用不可安全中断：取消只阻止下一个项目，当前项完成后仍登记撤销。
                    completedIdentity = try self.move(source, to: destination, expectedIdentity: identity, io: io)
                    completed = destination
                    result.moved.append((source, destination))
                } else {
                    let copied = try stagedCopy(source, to: destination, expectedParent: expectedIdentity,
                                                renameConflicts: renameConflicts, control: control, io: io)
                    if let warning = copied.warning { result.warnings.append(warning) }
                    guard let destination = copied.destination, let identity = copied.identity else {
                        result.unattempted = files.count - index
                        break
                    }
                    completed = destination
                    completedIdentity = identity
                }
                result.succeeded += 1
                do { result.undo.append(try .capture(kind: move ? .relocation : .copy, original: source, current: completed, originalParent: parent, expectedIdentity: completedIdentity)) }
                catch { result.warnings.append("\(completed.path)：已完成但无法登记撤销：\(error.localizedDescription)") }
            } catch { result.failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
            control?.complete()
        }
        return result
    }

    /// 跨卷移动先提交完整副本，再删除原件；删除失败明确列出两端残留，不冒险自动删除完整副本。
    static func move(_ source: URL, to destination: URL, expectedIdentity: FileIdentity? = nil, io: IO = IO()) throws -> FileIdentity {
        let identity = try FileSystem.identity(at: source)
        if let expectedIdentity, identity != expectedIdentity { throw failure("原件已变化，未移动。") }
        do { try io.rename(source, destination); return identity }
        catch {
            let error = error as NSError
            guard error.domain == NSPOSIXErrorDomain, error.code == Int(EXDEV) else { throw error }
        }
        let parent = try FileSystem.identity(at: destination.deletingLastPathComponent())
        let copy = try stagedCopy(source, to: destination, expectedParent: parent, renameConflicts: false, control: nil, io: io)
        do {
            if let warning = copy.warning { throw failure(warning) }
            guard try FileSystem.identity(at: source) == identity else { throw failure("原件已变化，未删除原件。") }
            try io.remove(source)
        } catch { throw failure("跨卷副本已保留于 \(destination.path)；原件可能仍有残留于 \(source.path)，请检查后手动处理：\(error.localizedDescription)") }
        guard let copiedIdentity = copy.identity else { throw failure("跨卷副本未提交，请检查两端路径。") }
        return copiedIdentity
    }

    private static func stagedCopy(_ source: URL, to destination: URL, expectedParent: FileIdentity,
                                   renameConflicts: Bool, control: FileOperationControl?, io: IO) throws -> (destination: URL?, identity: FileIdentity?, warning: String?) {
        let directory = destination.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".FileDeck-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let identity: FileIdentity
        do { identity = try FileSystem.identity(at: staging) }
        catch { throw failure("无法核验隔离目录，未尝试清理；临时残留位置：\(staging.path)：\(error.localizedDescription)") }
        let payload = staging.appendingPathComponent("payload")
        var outcome: URL?
        var committedIdentity: FileIdentity?
        var warning: String?
        var problem: Error?
        do {
            try io.copy(source, payload)
            let payloadIdentity = try FileSystem.identity(at: payload)
            if control?.isCancelled != true {
                guard try FileSystem.identity(at: directory) == expectedParent else { throw failure("目标文件夹已变化，未提交副本。") }
                var target = destination, duplicate = 0
                while true {
                    if control?.isCancelled == true { break }
                    do { try io.rename(payload, target); outcome = target; committedIdentity = payloadIdentity; break }
                    catch {
                        let error = error as NSError
                        guard renameConflicts && error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) else { throw error }
                    }
                    duplicate += 1
                    let suffix = duplicate == 1 ? " 副本" : " 副本 \(duplicate)"
                    let ext = source.pathExtension
                    let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
                    target = directory.appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
                }
            }
        } catch { problem = error }
        do {
            guard try FileSystem.identity(at: staging) == identity else { throw failure("隔离目录身份已变化，未清理。") }
            try io.remove(staging)
        } catch {
            // 即使最终文件已经提交，也不能把清理失败静默当成功；完整路径供用户核对残留。
            let detail = "临时残留：\(staging.path)，清理失败：\(error.localizedDescription)"
            if outcome != nil { warning = detail }
            else { throw failure("\(problem?.localizedDescription ?? "复制已取消")；\(detail)") }
        }
        if let problem { throw problem }
        return (outcome, committedIdentity, warning)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "FileDeck.FileTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
