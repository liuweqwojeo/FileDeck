import AppKit
import Darwin
import SwiftUI

/// 工作台始终保留目录和列表；预览作为独立的临时模态会话呈现。
@MainActor
struct ContentView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var editor: WorkspaceEditorBridge
    @State private var directoryQuery = ""
    @State private var creationRequest: FileCreationRequest?
    @State private var newFileName = ""
    @State private var creationError: String?
    @State private var renamingEntry: FileEntry?
    @State private var renamedName = ""
    @State private var renameError: String?
    @State private var fileOperationBusy = false
    @FocusState private var gridFocused: Bool

    init(store: BrowserStore, editor: WorkspaceEditorBridge? = nil) {
        self.store = store
        self.editor = editor ?? WorkspaceEditorBridge()
    }

    private var browsable: Bool { store.currentDirectory != nil && store.directoryError == nil && !store.isLoading }
    private var hasFilter: Bool { !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.typeFilter != .all }
    private var gridView: Bool { store.gridView }
    private var displayedEntries: [FileEntry] {
        store.orderedEntries
    }

    var body: some View {
        Group {
            switch store.startupPhase {
            case .welcome, .restoring:
                WorkspaceStartupView(isRestoring: store.startupPhase == .restoring,
                                     hasPreviousWorkspace: store.hasPreviousWorkspace,
                                     chooseFolder: store.chooseFolder, skipWelcome: store.skipWelcome)
            case .ready:
                workbench
            }
        }
        .tint(WorkspacePalette.accent)
        .foregroundStyle(WorkspacePalette.primary)
        .onChange(of: store.showHidden) { _, _ in store.refresh() }
        .alert("操作未完成", isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) {
            Button("知道了", role: .cancel) { store.actionError = nil }
        } message: { Text(store.actionError ?? "") }
        .sheet(item: $creationRequest) { request in creationSheet(request) }
        .sheet(item: $renamingEntry) { entry in renameSheet(entry) }
    }

    private var workbench: some View {
        VStack(spacing: 0) {
            globalToolbar
            Divider()
            WorkspaceSplitView(showPreview: false) {
                sidebar
            } content: {
                fileList
            } preview: {
                EmptyView()
            }
            Divider()
            statusBar
        }
        .background(WorkspacePalette.background)
    }

    private var globalToolbar: some View {
        GeometryReader { geometry in
            globalToolbarContent(compact: geometry.size.width < 1200)
        }.frame(height: 52)
    }

    private func globalToolbarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 8) {
            tool("后退", "chevron.left", disabled: !store.canGoBack, action: store.goBack)
            tool("前进", "chevron.right", disabled: !store.canGoForward, action: store.goForward)
            tool("上级", "arrow.up", disabled: !store.canGoUp, action: store.goUp)
            tool("刷新", "arrow.clockwise", disabled: store.currentDirectory == nil, action: store.refresh)
            toolbarDivider
            tool("添加目录", "folder.badge.plus", action: store.chooseFolder)
            tool("打开文件", "doc.viewfinder") {
                if editor.isAvailable { editor.command("open") } else { store.chooseFile() }
            }
            NewFileMenu(directory: store.currentDirectory, disabled: !browsable || fileOperationBusy, create: beginCreation)
                .menuStyle(.borderlessButton).fixedSize().help("在当前目录中新建文件或文件夹")
            if !compact { tool("复制路径", "link", disabled: store.selectedURL == nil) { copyPath(store.selectedURL) } }
            toolbarDivider
            Toggle(isOn: $store.showHidden) {
                Label("隐藏文件", systemImage: store.showHidden ? "eye" : "eye.slash")
                    .font(.system(size: 11)).padding(.horizontal, 5).frame(height: 32)
                    .contentShape(Rectangle())
            }
                .toggleStyle(.button).buttonStyle(.borderless)
                .help("显示或隐藏以点开头的文件（⇧⌘.）").accessibilityLabel("显示隐藏文件")
            Spacer(minLength: compact ? 4 : 12)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkspacePalette.tertiary)
                TextField("搜索当前目录", text: $store.query).textFieldStyle(.plain)
                    .accessibilityLabel("搜索当前目录")
                if !store.query.isEmpty {
                    Button(action: store.clearSearch) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(WorkspacePalette.tertiary).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 10).frame(width: compact ? 180 : 220, height: 32)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkspacePalette.separator, lineWidth: 1))
            Picker("文件视图", selection: $store.gridView) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 76).help("列表或网格视图")
        }.padding(.horizontal, compact ? 10 : 16).frame(height: 52).background(Color.white.opacity(0.5))
    }

    private var toolbarDivider: some View { Divider().frame(height: 20).padding(.horizontal, 4) }

    private func tool(_ title: String, _ symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(title).font(.system(size: 10)).lineLimit(1)
            }.frame(minWidth: 38, minHeight: 40).padding(.horizontal, 3).contentShape(Rectangle())
        }
            .buttonStyle(.borderless).disabled(disabled).opacity(disabled ? 0.35 : 1).help(title).accessibilityLabel(title)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("文件导航").font(.system(size: 14, weight: .semibold)).padding(.top, 22).padding(.bottom, 14)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                TextField("搜索目录…", text: $directoryQuery).textFieldStyle(.plain).accessibilityLabel("搜索目录")
                if !directoryQuery.isEmpty {
                    Button { directoryQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除目录搜索")
                }
            }.font(.system(size: 12)).foregroundStyle(WorkspacePalette.secondary).padding(.horizontal, 10)
                .frame(height: 34).background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("快速访问").padding(.top, 24).padding(.bottom, 5)
                    quickLocation("桌面", icon: "desktopcomputer", directory: .desktopDirectory)
                    quickLocation("下载", icon: "arrow.down.circle", directory: .downloadsDirectory)
                    quickLocation("文稿", icon: "doc.text", directory: .documentDirectory)
                    Divider().padding(.vertical, 17)
                    HStack {
                        sectionTitle("我的管理目录")
                        Spacer()
                        Button(action: store.chooseFolder) { Image(systemName: "plus").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).help("添加目录").accessibilityLabel("添加管理目录")
                    }.padding(.bottom, 5)
                    if store.managedRoots.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 38, weight: .light))
                                .foregroundStyle(Color(red: 0.65, green: 0.72, blue: 0.80))
                            Text("还没有添加管理目录").font(.system(size: 13, weight: .semibold))
                            Text("选择一个本地文件夹，开始集中管理文件。")
                                .font(.system(size: 12)).foregroundStyle(WorkspacePalette.secondary).multilineTextAlignment(.center)
                            Button(action: store.chooseFolder) { Label("添加本地目录", systemImage: "plus") }
                                .buttonStyle(.plain).foregroundStyle(WorkspacePalette.accent).font(.system(size: 12))
                        }.padding(.horizontal, 8).padding(.vertical, 30).frame(maxWidth: .infinity)
                    } else {
                        ForEach(store.managedRoots, id: \.self) { root in
                            FolderBranch(store: store, url: root, root: root, depth: 0, query: directoryQuery, creationDisabled: fileOperationBusy, create: beginCreation)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            Button(action: store.chooseFolder) {
                Label("添加本地目录", systemImage: "plus").font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 36)
            }.buttonStyle(.plain).foregroundStyle(WorkspacePalette.accent)
                .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkspacePalette.separator, lineWidth: 1))
                .padding(.bottom, 16)
        }.padding(.horizontal, 16).background(WorkspacePalette.sidebar)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(WorkspacePalette.secondary)
    }

    @ViewBuilder private func quickLocation(_ name: String, icon: String, directory: FileManager.SearchPathDirectory) -> some View {
        if directoryQuery.isEmpty || name.localizedStandardContains(directoryQuery),
           let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            Button { store.openQuickLocation(url) } label: {
                Label(name, systemImage: icon).font(.system(size: 13)).labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 36)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("directory.quick.\(url.path)")
                .contextMenu { NewFileMenu(directory: url, disabled: fileOperationBusy, create: beginCreation) }
                .foregroundStyle(store.currentDirectory?.path == url.path ? WorkspacePalette.accent : WorkspacePalette.primary)
                .background(store.currentDirectory?.path == url.path ? WorkspacePalette.accent.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(store.currentDirectory?.lastPathComponent ?? "我的工作台").font(.system(size: 18, weight: .semibold)).lineLimit(1)
                if browsable { Text("\(store.visibleEntries.count) 个项目").font(.system(size: 12)).foregroundStyle(WorkspacePalette.tertiary) }
                Spacer()
                tool("刷新当前目录", "arrow.clockwise", disabled: store.currentDirectory == nil, action: store.refresh)
            }.padding(.horizontal, 20).frame(height: 54)
            breadcrumb
            Divider()
            HStack(spacing: 12) {
                NewFileMenu(directory: store.currentDirectory, disabled: !browsable || fileOperationBusy, create: beginCreation)
                Spacer(minLength: 0)
                Menu {
                    Picker("文件类型", selection: $store.typeFilter) {
                        Text("全部类型").tag(FileTypeFilter.all)
                        Text("文件夹").tag(FileTypeFilter.folders)
                        Text("文档").tag(FileTypeFilter.documents)
                        Text("图片").tag(FileTypeFilter.images)
                        Text("音视频").tag(FileTypeFilter.media)
                        Text("压缩包").tag(FileTypeFilter.archives)
                    }
                } label: { Label(store.typeFilter == .all ? "全部类型" : "已筛选", systemImage: "line.3.horizontal.decrease") }
                .fixedSize()
                Menu {
                    Button("名称") { store.sortByModified = false }
                    Button("修改时间") { store.sortByModified = true }
                } label: { Label(store.sortByModified ? "修改时间" : "名称", systemImage: "arrow.up.arrow.down") }.fixedSize()
            }.font(.system(size: 12)).buttonStyle(.borderless).padding(.horizontal, 20).frame(height: 48)
            Divider()
            if !gridView { listHeader }
            listContents
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu {
                    NewFileMenu(directory: store.currentDirectory, disabled: !browsable || fileOperationBusy, create: beginCreation)
                    Button("刷新当前目录", action: store.refresh).disabled(store.currentDirectory == nil)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard browsable, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
                    store.importFiles(urls)
                    return true
                }
            Divider()
            HStack {
                Text(store.currentDirectory == nil ? "尚未选择目录" : store.isLoading ? "正在读取目录…" : "\(store.visibleEntries.count) 个项目")
                if let entry = store.selectedEntry { Text("· 已选择 \(store.selectedURLs.count) 个\(entry.displaySize.isEmpty ? "" : " · " + entry.displaySize)") }
                Spacer()
            }.font(.system(size: 11)).foregroundStyle(WorkspacePalette.secondary).padding(.horizontal, 20).frame(height: 30)
        }.background(.white)
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(WorkspacePalette.tertiary)
            if let current = store.currentDirectory {
                if let root = store.rootURL, current.path.hasPrefix(root.path + "/") {
                    Button(root.lastPathComponent) { store.navigate(to: root) }.buttonStyle(.plain)
                    Image(systemName: "chevron.right").font(.system(size: 8))
                }
                Text(current.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(current.path)
            } else { Text("本地文件") }
            Spacer(minLength: 0)
        }.font(.system(size: 12)).foregroundStyle(WorkspacePalette.secondary).padding(.horizontal, 20).frame(height: 38)
    }

    private var listHeader: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Text("文件名称").frame(width: proxy.size.width * 0.42, alignment: .leading)
                Text("文件类型").frame(width: proxy.size.width * 0.18, alignment: .leading)
                Text("文件大小").frame(width: proxy.size.width * 0.15, alignment: .trailing)
                Text("修改日期").frame(width: proxy.size.width * 0.25, alignment: .trailing)
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(WorkspacePalette.secondary).frame(height: 36)
        }.padding(.horizontal, 20).frame(height: 36).background(WorkspacePalette.background.opacity(0.8))
    }

    @ViewBuilder private var listContents: some View {
        if store.currentDirectory == nil {
            WorkspaceEmptyState(title: "选择一个目录开始浏览", icon: "folder", detail: "从左侧快速访问中选择目录，或添加需要管理的本地文件夹。") { EmptyView() }
        } else if store.isLoading {
            VStack(spacing: 12) { ProgressView().controlSize(.small); Text("正在读取目录…").font(.system(size: 13)).foregroundStyle(WorkspacePalette.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let issue = store.directoryIssue {
            directoryFailure(issue)
        } else if store.visibleEntries.isEmpty && hasFilter {
            WorkspaceEmptyState(title: "没有找到匹配的文件", icon: "doc.text.magnifyingglass", detail: "请尝试其他关键词，或清除筛选条件。") {
                HStack(spacing: 10) {
                    Button("清除搜索", action: store.clearSearch).buttonStyle(.borderedProminent).disabled(store.query.isEmpty)
                    Button("重置筛选", action: store.resetFilters).buttonStyle(.bordered)
                }.controlSize(.large)
            }
        } else if store.visibleEntries.isEmpty && !store.directoryIsTrulyEmpty {
            WorkspaceEmptyState(title: "文件已被隐藏", icon: "eye.slash", detail: "此目录包含隐藏项目，开启显示后即可浏览。") {
                Button("显示隐藏文件") { store.showHidden = true }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        } else if store.visibleEntries.isEmpty {
            WorkspaceEmptyState(title: "此文件夹为空", icon: "folder", detail: "你可以拖入文件，或右键新建文档、图片和文件夹。") {
                HStack(spacing: 10) {
                    NewFileMenu(directory: store.currentDirectory, disabled: fileOperationBusy, create: beginCreation)
                        .menuStyle(.borderlessButton).fixedSize()
                    Button("在 Finder 中显示") { revealCurrent() }.buttonStyle(.bordered)
                }.controlSize(.large)
            }
        } else if gridView {
            fileGrid
        } else {
            // 原生 List 负责鼠标与键盘的选择语义；再叠加单击 toggle 会让 ⌘ 单击执行两次。
            List(selection: Binding(get: { store.selectedURLs }, set: { updateListSelection($0) })) {
                ForEach(displayedEntries) { entry in
                    FileRow(entry: entry).tag(entry.url).listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .contentShape(Rectangle()).onTapGesture(count: 2) { activate(entry) }
                        .simultaneousGesture(TapGesture().onEnded {
                            // 原生选择提交后只记录实际点击的主项目，不重复修改 ⌘/Shift 选中集合。
                            DispatchQueue.main.async {
                                if store.selectedURLs.contains(entry.url) {
                                    store.setSelection(store.selectedURLs, primary: entry.url)
                                }
                            }
                        })
                        .accessibilityElement(children: .combine)
                        .accessibilityAction { selectForPreview(entry) }
                        .contextMenu { entryActions(entry) }
                }
            }.listStyle(.plain)
                .onKeyPress(.space) {
                    guard let entry = store.selectedEntry, !entry.isBrowsableDirectory else { return .ignored }
                    editor.preview(entry.url, source: "space")
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let entry = store.selectedEntry else { return .ignored }
                    activate(entry, source: "keyboard")
                    return .handled
                }
        }
    }

    private var fileGrid: some View {
        ScrollViewReader { scroll in
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 16) {
                        ForEach(displayedEntries) { entry in
                            VStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 52, height: 52)
                                Text(entry.name).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).frame(height: 112)
                                .background(store.selectedURLs.contains(entry.url) ? WorkspacePalette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { activate(entry) }
                                .onTapGesture { gridFocused = true; selectForPreview(entry) }
                                .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                                .accessibilityLabel(entry.name)
                                .accessibilityAction { gridFocused = true; selectForPreview(entry) }
                                .contextMenu { entryActions(entry) }
                                .id(entry.url)
                        }
                    }.padding(20)
                }
                .focusable()
                .focused($gridFocused)
                .accessibilityLabel("文件网格")
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return, "a"], phases: [.down, .repeat]) { press in
                    handleGridKey(press, columns: max(1, Int((geometry.size.width - 24) / 126)), scroll: scroll)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateListSelection(_ selection: Set<URL>) {
        let added = selection.subtracting(store.selectedURLs)
        let primary = displayedEntries.first(where: { added.contains($0.url) })?.url
            ?? store.selectedURL.flatMap { selection.contains($0) ? $0 : nil }
            ?? displayedEntries.first(where: { selection.contains($0.url) })?.url
        store.setSelection(selection, primary: primary)
    }

    private func handleGridKey(_ press: KeyPress, columns: Int, scroll: ScrollViewProxy) -> KeyPress.Result {
        if press.key == "a", press.modifiers.contains(.command) {
            store.setSelection(Set(displayedEntries.map(\.url)), primary: store.selectedURL ?? displayedEntries.first?.url)
            return .handled
        }
        if press.key == .space || press.key == .return {
            guard let entry = store.selectedEntry else { return .ignored }
            if press.key == .space {
                guard !entry.isBrowsableDirectory else { return .ignored }
                editor.preview(entry.url, source: "space")
            } else { activate(entry, source: "keyboard") }
            return .handled
        }
        let offset: Int
        switch press.key {
        case .upArrow: offset = -columns
        case .downArrow: offset = columns
        case .leftArrow: offset = -1
        case .rightArrow: offset = 1
        default: return .ignored
        }
        guard !displayedEntries.isEmpty else { return .ignored }
        let index = displayedEntries.firstIndex { $0.url == store.selectedURL }
        let next = index.map { min(max($0 + offset, 0), displayedEntries.count - 1) } ?? 0
        let entry = displayedEntries[next]
        store.select(entry, extending: press.modifiers.contains(.shift))
        scroll.scrollTo(entry.url)
        return .handled
    }

    @ViewBuilder private func directoryFailure(_ issue: DirectoryIssue) -> some View {
        switch issue {
        case .permission:
            WorkspaceEmptyState(title: "无法访问此文件夹", icon: "folder", detail: "需要获得此文件夹的访问权限，才能查看其中的文件。", badge: "lock.fill") {
                HStack(spacing: 10) {
                    Button("选择文件夹并授权", action: store.authorizeCurrentDirectory).buttonStyle(.borderedProminent)
                    Button("返回") { if store.canGoBack { store.goBack() } else { store.clearCurrentDirectory() } }.buttonStyle(.bordered)
                }.controlSize(.large)
            }
        case .unavailable:
            WorkspaceEmptyState(title: "目录暂时不可用", icon: "folder.badge.questionmark", detail: "文件夹可能已移动、删除，或所在磁盘尚未连接。") {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        Button("重新定位目录") {
                            if let root = store.rootURL, store.managedRoots.contains(root) { store.relocateManagedRoot(root) }
                            else { store.chooseFolder() }
                        }
                            .buttonStyle(.borderedProminent)
                        Button("重试访问", action: store.refresh).buttonStyle(.bordered)
                    }.controlSize(.large)
                    if let root = store.rootURL, store.managedRoots.contains(root) {
                        Button("从管理列表移除") { store.removeManagedRoot(root) }.buttonStyle(.plain).foregroundStyle(WorkspacePalette.secondary)
                            .help("仅移除工作台中的引用，不删除磁盘上的文件")
                    }
                }
            }
        case .readFailure:
            WorkspaceEmptyState(title: "无法读取此文件夹", icon: "folder.badge.questionmark", detail: store.directoryError ?? "请检查此文件夹的状态后重试。", iconColor: .orange) {
                HStack {
                    Button("重试访问", action: store.refresh).buttonStyle(.borderedProminent)
                    Button("在 Finder 中显示") { revealCurrent() }.buttonStyle(.bordered)
                }.controlSize(.large)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("当前目录：\(store.currentDirectory?.lastPathComponent ?? "未选择")").lineLimit(1)
            Spacer()
            if store.isImporting {
                ProgressView().controlSize(.mini)
                Text("正在复制文件…")
            }
            if browsable { Text("\(store.visibleEntries.count) 个项目 · 已选择 \(store.selectedURLs.count) 个") }
            Spacer()
            Label("本地离线", systemImage: "lock.shield").foregroundStyle(WorkspacePalette.secondary)
        }.font(.system(size: 11)).foregroundStyle(WorkspacePalette.secondary).padding(.horizontal, 16).frame(height: 30)
    }

    /// 菜单打开时冻结目录身份，避免命名期间目录被移动/替换后写入错误位置。
    private func beginCreation(_ template: NewFileTemplate, in directory: URL) {
        guard !fileOperationBusy else { return }
        do {
            let identity = try FileSystem.identity(at: directory)
            newFileName = template.defaultName
            creationError = nil
            creationRequest = FileCreationRequest(template: template, directory: directory, identity: identity)
        } catch { store.actionError = "无法访问新建位置：\(error.localizedDescription)" }
    }

    private func creationSheet(_ request: FileCreationRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建\(request.template.title)").font(.system(size: 18, weight: .semibold))
            Text("位置：\(request.directory.path)").font(.system(size: 12))
                .foregroundStyle(WorkspacePalette.secondary).lineLimit(2).textSelection(.enabled)
            TextField("名称（包含扩展名）", text: $newFileName).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("creation.name")
                .onSubmit { createFile(request) }.disabled(fileOperationBusy)
            if request.template == .custom {
                Text("输入完整文件名和扩展名。已支持的格式使用相应模板；其他文本扩展名创建空白文件。")
                    .font(.system(size: 12)).foregroundStyle(WorkspacePalette.secondary)
            }
            if let creationError { Text(creationError).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                if fileOperationBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) { creationRequest = nil }.keyboardShortcut(.cancelAction).disabled(fileOperationBusy)
                Button("创建") { createFile(request) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(fileOperationBusy || newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440).interactiveDismissDisabled(fileOperationBusy)
    }

    private func createFile(_ request: FileCreationRequest) {
        guard !fileOperationBusy else { return }
        let name = newFileName
        fileOperationBusy = true
        creationError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try NewFileCreator.create(template: request.template, name: name, directory: request.directory,
                                                  expectedDirectoryIdentity: request.identity) }
            }.value
            fileOperationBusy = false
            switch result {
            case .success(let url):
                creationRequest = nil
                // 显示实际创建的目录和文件；目录树与列表会一起接收新的磁盘快照。
                if url.lastPathComponent.hasPrefix(".") { store.showHidden = true }
                store.navigate(to: request.directory, selecting: url)
            case .failure(let error): creationError = error.localizedDescription
            }
        }
    }

    private func revealCurrent() { if let url = store.currentDirectory { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    private func copyPath(_ url: URL?) { guard let url else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
    private func activate(_ entry: FileEntry, source: String = "doubleClick") {
        selectPrimary(entry)
        if entry.isBrowsableDirectory { store.enter(entry) }
        else { editor.preview(entry.url, source: source) }
    }
    private func selectForPreview(_ entry: FileEntry) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        store.select(entry, extending: flags.contains(.shift), toggling: flags.contains(.command))
    }
    private func selectPrimary(_ entry: FileEntry) {
        if store.selectedURLs.contains(entry.url) { store.setSelection(store.selectedURLs, primary: entry.url) }
        else { store.selectedURL = entry.url }
    }
    @ViewBuilder private func entryActions(_ entry: FileEntry) -> some View {
        NewFileMenu(directory: entry.isBrowsableDirectory ? entry.url : store.currentDirectory,
                    disabled: fileOperationBusy, create: beginCreation)
        Divider()
        if entry.isBrowsableDirectory { Button("打开目录") { activate(entry) } }
        else { Button("预览") { selectPrimary(entry); editor.preview(entry.url, source: "contextMenu") } }
        if !entry.isBrowsableDirectory {
            Button("使用默认应用打开") { NSWorkspace.shared.open(entry.url) }
        }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Button("复制路径") { copyPath(entry.url) }
        Divider()
        Button("重命名…") {
            store.selectedURL = entry.url
            renamedName = entry.name
            renameError = nil
            renamingEntry = entry
        }.disabled(fileOperationBusy)
        Button("移到废纸篓", role: .destructive) { trash(entry) }.disabled(fileOperationBusy)
    }

    private func renameSheet(_ entry: FileEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名").font(.system(size: 18, weight: .semibold))
            TextField("文件名称", text: $renamedName).textFieldStyle(.roundedBorder)
                .onSubmit { rename(entry) }.disabled(fileOperationBusy)
            if let renameError { Text(renameError).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { renamingEntry = nil }.keyboardShortcut(.cancelAction).disabled(fileOperationBusy)
                Button("重命名") { rename(entry) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(fileOperationBusy || renamedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 400).interactiveDismissDisabled(fileOperationBusy)
    }

    private func rename(_ entry: FileEntry) {
        guard !fileOperationBusy else { return }
        let name = renamedName
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            renameError = "请输入有效文件名称，不能包含路径分隔符。"
            return
        }
        guard name != entry.name else { renamingEntry = nil; return }
        let directory = store.currentDirectory
        fileOperationBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.renameOnDisk(entry, name: name) }
            }.value
            fileOperationBusy = false
            switch result {
            case .success:
                renamingEntry = nil
                if store.currentDirectory == directory { store.refresh() }
            case .failure(let error): renameError = error.localizedDescription
            }
        }
    }

    private func trash(_ entry: FileEntry) {
        guard !fileOperationBusy else { return }
        let directory = store.currentDirectory
        fileOperationBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try Self.requireSameFile(entry)
                    try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                }
            }.value
            fileOperationBusy = false
            switch result {
            case .success: if store.currentDirectory == directory { store.refresh() }
            case .failure(let error): store.actionError = error.localizedDescription
            }
        }
    }

    nonisolated private static func requireSameFile(_ entry: FileEntry) throws {
        guard let identity = entry.identity, try FileSystem.identity(at: entry.url) == identity else {
            throw NSError(domain: "FileDeck.FileOperation", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件已发生变化，请刷新后重试。"])
        }
    }

    nonisolated private static func renameOnDisk(_ entry: FileEntry, name: String) throws {
        try requireSameFile(entry)
        let destination = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        // 排他重命名在内核中拒绝已存在的目标，避免预检查后出现同名文件被覆盖。
        guard renamex_np(entry.url.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "已存在同名文件，请使用其他名称。"])
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
}

private struct FileCreationRequest: Identifiable, Sendable {
    let id = UUID()
    let template: NewFileTemplate
    let directory: URL
    let identity: FileIdentity
}

/// 工具栏、树节点和列表空白处共用同一模板清单，防止不同入口遗漏类型。
private struct NewFileMenu: View {
    let directory: URL?
    var disabled = false
    let create: (NewFileTemplate, URL) -> Void

    private var categories: [String] {
        NewFileTemplate.allCases.filter { $0 != .folder && $0 != .custom }
            .reduce(into: []) { if !$0.contains($1.category) { $0.append($1.category) } }
    }

    var body: some View {
        Menu {
            item(.folder)
            Divider()
            ForEach(categories, id: \.self) { category in
                Menu(category) {
                    ForEach(NewFileTemplate.allCases.filter { $0.category == category }) { template in item(template) }
                }
            }
            Divider()
            item(.custom)
        } label: { Label("新建", systemImage: "doc.badge.plus") }
            .disabled(directory == nil || disabled)
            .accessibilityLabel("新建文件或文件夹")
    }

    private func item(_ template: NewFileTemplate) -> some View {
        Button(template.title) { if let directory { create(template, directory) } }
            .disabled(!NewFileTemplate.bundledAvailableTemplates.contains(template))
    }
}

/// 目录搜索仅过滤已加载树，不触发磁盘递归扫描；保留匹配子节点的祖先链。
private struct FolderBranch: View {
    @ObservedObject var store: BrowserStore
    let url: URL
    let root: URL
    let depth: Int
    let query: String
    let creationDisabled: Bool
    let create: (NewFileTemplate, URL) -> Void
    @State private var hovered = false
    private var expanded: Bool { store.expandedDirectories.contains(url) }
    private var matches: Bool {
        query.isEmpty || url.lastPathComponent.localizedStandardContains(query) || descendantMatches(url)
    }
    private func descendantMatches(_ parent: URL) -> Bool {
        (store.treeChildren[parent] ?? []).contains { $0.name.localizedStandardContains(query) || descendantMatches($0.url) }
    }
    var body: some View {
        if matches {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Button { store.toggleExpanded(url) } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 24, height: 34)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("directory.expand.\(url.path)")
                        .help(expanded ? "收起子目录" : "展开子目录")
                        .accessibilityLabel("\(expanded ? "收起" : "展开") \(url.lastPathComponent)")
                    Button { store.navigate(to: url) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").font(.system(size: 17))
                                .foregroundStyle(store.treeErrors[url] == nil ? WorkspacePalette.accent.opacity(0.78) : WorkspacePalette.tertiary)
                            Text(url.lastPathComponent).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 0)
                            if store.treeErrors[url] != nil { Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange).accessibilityLabel("目录不可用") }
                        }.padding(.leading, 4).padding(.trailing, 8)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            // plain 样式不会自动把 Spacer 作为点击区；形状必须放在按钮 label 内。
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("directory.navigate.\(url.path)")
                        .accessibilityLabel("打开目录 \(url.lastPathComponent)")
                }.padding(.leading, CGFloat(min(depth, 12)) * 16 + 4)
                    .background(store.currentDirectory == url ? WorkspacePalette.accent.opacity(0.12) : hovered ? .black.opacity(0.035) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .onHover { hovered = $0 }.help(store.treeErrors[url] ?? url.path)
                    .contextMenu {
                        NewFileMenu(directory: url, disabled: creationDisabled, create: create)
                        Divider()
                        Button("打开目录") { store.navigate(to: url) }
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
                        Button("刷新") { store.refresh() }
                        if url == root {
                            Divider()
                            Button("重新定位目录") { store.relocateManagedRoot(root) }
                            Button("从管理列表移除") { store.removeManagedRoot(root) }
                        }
                    }
                if expanded || !query.isEmpty {
                    if store.treeLoading.contains(url) {
                        ProgressView().controlSize(.mini).padding(.leading, CGFloat(min(depth, 12)) * 16 + 28)
                    } else {
                        ForEach(store.treeChildren[url] ?? []) { child in
                            AnyView(FolderBranch(store: store, url: child.url, root: root, depth: depth + 1, query: query, creationDisabled: creationDisabled, create: create))
                        }
                    }
                }
            }.onAppear { if expanded { store.loadChildren(of: url) } }
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 22, height: 22)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                }.frame(width: proxy.size.width * 0.42, alignment: .leading)
                Text(entry.typeLabel).foregroundStyle(WorkspacePalette.secondary).lineLimit(1).frame(width: proxy.size.width * 0.18, alignment: .leading)
                Text(entry.displaySize.isEmpty ? "—" : entry.displaySize).foregroundStyle(WorkspacePalette.secondary).frame(width: proxy.size.width * 0.15, alignment: .trailing)
                Text(entry.modifiedAt?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) ?? "—")
                    .foregroundStyle(WorkspacePalette.secondary).lineLimit(1).frame(width: proxy.size.width * 0.25, alignment: .trailing)
            }.font(.system(size: 12)).frame(height: 38)
        }.frame(height: 38).help(entry.name)
    }
}

/// 仅汇总直接子项目；当前目录复用已读快照，选中的子目录才后台读取，避免主线程 I/O。
private struct DirectoryOverview: View {
    let url: URL
    let entries: [FileEntry]?
    let revision: UUID
    let showHidden: Bool
    var compact = false
    @State private var snapshot: [FileEntry]?
    @State private var failed = false
    private var items: [FileEntry]? { entries ?? snapshot }
    var body: some View {
        VStack(spacing: 18) {
            if !compact { Image(systemName: "folder.fill").font(.system(size: 64, weight: .light)).foregroundStyle(WorkspacePalette.accent.opacity(0.55)).padding(.top, 28) }
            Text(url.lastPathComponent).font(.system(size: compact ? 13 : 17, weight: .semibold)).lineLimit(2)
            if let items {
                VStack(spacing: 14) {
                    metric("文件数量", "\(items.filter { !$0.isBrowsableDirectory }.count)")
                    metric("子文件夹数量", "\(items.filter(\.isBrowsableDirectory).count)")
                    let bytes = items.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
                    let hasUnknownSize = items.contains { !$0.isBrowsableDirectory && $0.size == nil }
                    metric(items.contains(where: \.isBrowsableDirectory) ? "本层文件大小" : "文件大小", hasUnknownSize ? "部分大小未计算" : bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
                if !items.isEmpty {
                    Text(showHidden ? "当前目录概览 · 不含子目录内容" : "可见项目概览 · 不含隐藏项目与子目录内容")
                        .font(.system(size: 11)).foregroundStyle(WorkspacePalette.tertiary).multilineTextAlignment(.center)
                }
            } else if failed {
                Text("暂时无法读取目录概览").font(.system(size: 12)).foregroundStyle(WorkspacePalette.secondary)
            } else { ProgressView().controlSize(.small) }
        }.padding(24).frame(maxWidth: .infinity)
            .task(id: "\(url.path)-\(revision)-\(showHidden)") {
                guard entries == nil else { return }
                snapshot = nil; failed = false
                let result = await Task.detached(priority: .userInitiated) { Result { try FileSystem.entries(at: url, showHidden: showHidden) } }.value
                guard !Task.isCancelled else { return }
                switch result { case .success(let value): snapshot = value; case .failure: failed = true }
            }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(WorkspacePalette.secondary); Spacer(); Text(value) }.font(.system(size: 12))
    }
}
