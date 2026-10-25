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

/// 管理多根目录、原生授权、懒加载树与导航历史。磁盘枚举只接收最后一次请求。
@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var managedRoots: [URL] = []
    @Published private(set) var startupPhase: WorkspaceStartupPhase = .welcome
    @Published private(set) var rootURL: URL?
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var entries: [FileEntry] = []
    @Published var selectedURL: URL? {
        didSet {
            guard !updatingSelection else { return }
            selectedURLs = selectedURL.map { [$0] } ?? []
            selectionAnchor = selectedURL
        }
    }
    @Published private(set) var selectedURLs: Set<URL> = []
    @Published var sortByModified = false {
        didSet { if persistsWorkspace { defaults.set(sortByModified, forKey: "FileWorkbench.sortByModified") } }
    }
    @Published var gridView = false {
        didSet { if persistsWorkspace { defaults.set(gridView, forKey: "FileWorkbench.gridView") } }
    }
    @Published var query = "" { didSet { updateSearchSelection() } }
    @Published var typeFilter: FileTypeFilter = .all { didSet { updateSearchSelection() } }
    @Published var showHidden = false
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
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
    private var updatingSelection = false
    private var selectionAnchor: URL?
    private var activePreviewSnapshotID: UUID?
    private var activeFileDrag: (id: UUID, files: [BrowserFileReference])?

    var visibleEntries: [FileEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { typeFilter.includes($0) && (term.isEmpty || $0.name.localizedStandardContains(term)) }
    }
    var selectedEntry: FileEntry? { visibleEntries.first { $0.url == selectedURL } }
    var orderedEntries: [FileEntry] {
        guard sortByModified else { return visibleEntries }
        return visibleEntries.sorted {
            if $0.isBrowsableDirectory != $1.isBrowsableDirectory { return $0.isBrowsableDirectory }
            if $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var hasActiveFilters: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || typeFilter != .all || (!isLoading && directoryIssue == nil && currentDirectory != nil && entries.isEmpty && !directoryIsTrulyEmpty) }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex + 1 < history.count }
    var canGoUp: Bool { currentDirectory != nil && currentDirectory != rootURL }
    var hasPreviousWorkspace: Bool {
        pendingWorkspace.map { !$0.roots.isEmpty || $0.currentPath != nil } ?? false
    }

    init(restoreLastLocation: Bool = true, defaults: UserDefaults = .standard,
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        self.persistsWorkspace = restoreLastLocation
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

    func navigate(to url: URL, recordHistory: Bool = true, selecting file: URL? = nil) {
        guard url.isFileURL else { return }
        activePreviewSnapshotID = nil
        let target = Self.directoryURL(url)
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
        }
        currentDirectory = target
        navigationRoots[target] = rootURL
        // 先进入加载态再清除过滤，避免 didSet 把待恢复的文件选择当作旧快照清空。
        isLoading = true
        selectedURL = file
        query = ""
        typeFilter = .all
        expandAncestors(of: target)
        saveWorkspace()
        loadDirectory()
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
        navigate(to: currentDirectory.deletingLastPathComponent())
    }

    func refresh() {
        let loadedURLs = Set(treeChildren.keys).union(managedRoots)
        clearTree()
        loadDirectory()
        for url in loadedURLs { loadChildren(of: url) }
        if let rootURL { loadChildren(of: rootURL) }
    }

    /// 返回中性空状态时保留管理根与树展开，但取消待返回的旧列表和预览。
    func clearCurrentDirectory() {
        activePreviewSnapshotID = nil
        currentRestoreID = nil
        loadID = UUID()
        isLoading = false
        rootURL = nil
        currentDirectory = nil
        entries = []
        selectedURL = nil
        directoryError = nil
        directoryIssue = nil
        directoryIsTrulyEmpty = false
        query = ""
        typeFilter = .all
        history = []
        historyIndex = -1
        navigationRoots = [:]
        startupPhase = .ready
        saveWorkspace()
    }

    func clearSearch() { query = "" }
    func resetFilters() { query = ""; typeFilter = .all }

    func updateSearchSelection() {
        guard !isLoading else { return }
        let visible = Set(visibleEntries.map(\.url))
        setSelection(selectedURLs.intersection(visible), primary: selectedURL.flatMap { visible.contains($0) ? $0 : nil })
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
        if extending, let anchor = selectionAnchor,
           let start = orderedEntries.firstIndex(where: { $0.url == anchor }),
           let end = orderedEntries.firstIndex(where: { $0.url == entry.url }) {
            let range = Set(orderedEntries[min(start, end)...max(start, end)].map(\.url))
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
        let result = await Task.detached(priority: .userInitiated) {
            Result { () -> ([FileEntry], Bool) in
                if let identity = snapshot.directoryIdentity, try FileSystem.identity(at: directory) != identity {
                    throw FileSystemError.notBrowsableDirectory(directory)
                }
                let items = try FileSystem.entries(at: directory, showHidden: snapshot.showHidden)
                let trulyEmpty = items.isEmpty && !snapshot.showHidden
                    ? try FileSystem.entries(at: directory, showHidden: true).isEmpty : items.isEmpty
                return (items, trulyEmpty)
            }
        }.value
        guard activePreviewSnapshotID == snapshot.id, loadID == request, currentDirectory == directory else { return }
        activePreviewSnapshotID = nil
        query = snapshot.query
        typeFilter = snapshot.typeFilter
        showHidden = snapshot.showHidden
        sortByModified = snapshot.sortByModified
        gridView = snapshot.gridView
        expandedDirectories = snapshot.expandedDirectories
        isLoading = false
        revision = UUID()
        switch result {
        case .success(let (items, trulyEmpty)):
            entries = items
            directoryIsTrulyEmpty = trulyEmpty
            directoryError = nil
            directoryIssue = nil
            treeChildren[directory] = items.filter(\.isBrowsableDirectory)
            treeErrors[directory] = nil
            restoreSelection(snapshot.selection, primary: snapshot.primarySelection, savedURL: savedURL)
        case .failure(let error):
            entries = []
            selectedURL = nil
            directoryIsTrulyEmpty = false
            directoryIssue = Self.classify(error)
            directoryError = Self.message(for: error)
            treeErrors[directory] = Self.message(for: error)
        }
        saveWorkspace()
    }

    private func fileReference(_ url: URL) -> BrowserFileReference {
        BrowserFileReference(url: url, identity: entries.first(where: { $0.url == url })?.identity ?? (try? FileSystem.identity(at: url)))
    }

    private func restoreSelection(_ references: Set<BrowserFileReference>, primary: BrowserFileReference?, savedURL: URL? = nil) {
        func resolve(_ reference: BrowserFileReference) -> URL? {
            if reference.url == savedURL, visibleEntries.contains(where: { $0.url == savedURL }) { return savedURL }
            guard let identity = reference.identity else { return nil }
            // 多个硬链接可共享身份；只有原路径仍匹配或唯一候选时才跟随，不能猜测另一个文件。
            if let samePath = visibleEntries.first(where: { $0.url == reference.url && $0.identity == identity }) { return samePath.url }
            let matches = visibleEntries.filter { $0.identity == identity }
            return matches.count == 1 ? matches.first?.url : nil
        }
        let selection = Set(references.compactMap(resolve))
        setSelection(selection, primary: primary.flatMap(resolve))
        selectionAnchor = selectedURL
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

    var selectedFileURLs: [URL] { orderedEntries.filter { selectedURLs.contains($0.url) }.map(\.url) }

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
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    func pasteFiles(from pasteboard: NSPasteboard = .general, into target: URL? = nil) {
        guard let directory = target ?? currentDirectory else {
            actionError = "请先选择可访问的目标文件夹。"
            return
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { actionError = "剪贴板中没有可粘贴的文件。"; return }
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
        guard !isImporting else { actionError = "正在处理文件，请稍后再试。"; return }
        guard directory.isFileURL, let identity = try? FileSystem.identity(at: directory) else {
            actionError = "目标文件夹不可访问，请重新选择。"
            return
        }
        isImporting = true
        actionError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                WorkspaceFileTransfer.perform(files, into: directory, expectedIdentity: identity, move: move, renameConflicts: renameConflicts)
            }.value
            self.isImporting = false
            if !result.failures.isEmpty { self.actionError = "部分文件未能\(move ? "移动" : "复制")：\n" + result.failures.joined(separator: "\n") }
            // 刷新来源与落点的树缓存，但不抢回用户在操作期间切换到的目录。
            if move { self.completeFileRelocation(result.moved) }
            else { self.refresh(); self.saveWorkspace() }
        }
    }

    /// 重命名与拖动移动共用同一次状态提交，旧路径缓存和在途恢复不能再次带回已失效的位置。
    private func completeFileRelocation(_ moved: [(source: URL, destination: URL)]) {
        guard !moved.isEmpty else { refresh(); return }
        func relocated(_ url: URL) -> URL {
            guard let change = moved.first(where: { Self.contains(url, in: $0.source) }) else { return url }
            let suffix = String(url.path.dropFirst(change.source.path.count))
            return URL(fileURLWithPath: change.destination.path + suffix, isDirectory: url.hasDirectoryPath)
        }
        let loadedDirectories = Set(treeChildren.keys).union(treeLoading).map(relocated)
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
        loadDirectory()
        for url in Set(loadedDirectories).union(managedRoots) { loadChildren(of: url) }
        if let rootURL { loadChildren(of: rootURL) }
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
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileSystem.folders(at: url, showHidden: hidden) }
            }.value
            guard generation == self.treeGeneration else { return }
            self.treeLoading.remove(url)
            // 列表枚举若先完成，以它的更新快照为准，防止较早的树请求覆盖结果。
            guard self.treeChildren[url] == nil else { return }
            switch result {
            case .success(let folders): self.treeChildren[url] = folders
            case .failure(let error): self.treeErrors[url] = Self.message(for: error)
            }
        }
    }

    func toggleExpanded(_ location: URL) {
        let url = Self.directoryURL(location)
        if expandedDirectories.contains(url) { expandedDirectories.remove(url) }
        else { expandedDirectories.insert(url); loadChildren(of: url) }
        saveWorkspace()
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
        treeChildren = [:]
        treeErrors = [:]
        treeLoading = []
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
        entries = []
        let hidden = showHidden
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let items = try FileSystem.entries(at: currentDirectory, showHidden: hidden)
                    // 隐藏文件被过滤后仍不是空文件夹；只在空列表时额外确认，避免日常双重枚举。
                    let trulyEmpty: Bool
                    if items.isEmpty && !hidden { trulyEmpty = try FileSystem.entries(at: currentDirectory, showHidden: true).isEmpty }
                    else { trulyEmpty = items.isEmpty }
                    return (items, trulyEmpty)
                }
            }.value
            guard self.loadID == request else { return }
            self.isLoading = false
            self.startupPhase = .ready
            self.revision = UUID()
            switch result {
            case .success(let snapshot):
                let (items, trulyEmpty) = snapshot
                self.directoryIsTrulyEmpty = trulyEmpty
                self.entries = items
                self.treeChildren[currentDirectory] = items.filter(\.isBrowsableDirectory)
                self.treeErrors[currentDirectory] = nil
                self.restoreSelection(previousSelections, primary: previousSelection)
            case .failure(let error):
                self.selectedURL = nil
                self.directoryIssue = Self.classify(error)
                self.directoryError = Self.message(for: error)
                self.treeErrors[currentDirectory] = Self.message(for: error)
            }
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

/// 磁盘操作共用边界检查；符号链接作为项目本身移动，不递归跟随其内容。
enum WorkspaceFileTransfer {
    struct Result: Sendable {
        var moved: [(source: URL, destination: URL)] = []
        var failures: [String] = []
    }

    static func perform(_ files: [BrowserFileReference], into directory: URL,
                        expectedIdentity: FileIdentity, move: Bool, renameConflicts: Bool = false) -> Result {
        var result = Result()
        for file in files {
            let source = file.url
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                guard source.isFileURL, directory.isFileURL else { throw failure("只能拖动本机文件。") }
                guard try FileSystem.identity(at: directory) == expectedIdentity else {
                    throw failure("目标文件夹已变化，请重新拖放。")
                }
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      !FileSystem.isPackageDirectory(directory, values: values) else {
                    throw FileSystemError.notBrowsableDirectory(directory)
                }
                if move || file.identity != nil {
                    guard let identity = file.identity, try FileSystem.identity(at: source) == identity else {
                        throw failure("文件已变化，请刷新后重试。")
                    }
                }
                let resolvedSource = source.standardizedFileURL.resolvingSymlinksInPath().path
                let target = directory.resolvingSymlinksInPath().path
                // 同时检查路径边界和链接解析结果，拒绝把祖先复制/移动到自己的后代。
                guard target != resolvedSource,
                      !target.hasPrefix(resolvedSource.hasSuffix("/") ? resolvedSource : resolvedSource + "/") else {
                    throw failure("不能将文件夹拖到自身或其子目录中。")
                }
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                if !renameConflicts && source.standardizedFileURL.path == destination.standardizedFileURL.path { continue }
                if move {
                    // 同卷使用内核排他重命名；跨卷由 Foundation 复制后删除，失败保留错误信息。
                    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                        let code = errno
                        guard code == EXDEV else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                        try FileManager.default.moveItem(at: source, to: destination)
                    }
                    result.moved.append((source, destination))
                } else {
                    try copy(source, to: destination, renameConflicts: renameConflicts)
                }
            } catch { result.failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }

    /// 粘贴遇到冲突时生成副本名；由 copyItem 排他创建，包含悬空链接和并发创建的同名目标。
    private static func copy(_ source: URL, to destination: URL, renameConflicts: Bool) throws {
        var target = destination
        var duplicate = 0
        while true {
            do { try FileManager.default.copyItem(at: source, to: target); return }
            catch {
                let value = error as NSError
                let exists = (value.domain == NSCocoaErrorDomain && value.code == NSFileWriteFileExistsError)
                    || (value.domain == NSPOSIXErrorDomain && value.code == EEXIST)
                guard renameConflicts && exists else { throw error }
                duplicate += 1
                let suffix = duplicate == 1 ? " 副本" : " 副本 \(duplicate)"
                let ext = source.pathExtension
                let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
                target = destination.deletingLastPathComponent().appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "FileDeck.FileTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
