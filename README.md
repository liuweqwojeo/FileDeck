# FileDeck

面向 macOS 14 及以上、Apple Silicon 的本地文件工作台。在同一浏览页面中预览和编辑文件，Office 编辑内核与文本、CSV、PDF、图片工具随应用一起打包。

默认入口为完整的 `build/FileDeck.app`。用户操作和验收边界见 [实施状态](docs/implementation-status.md)，内部集成关系见 [浏览页编辑集成](docs/native-integration.md)。

应用包、主程序、窗口/系统菜单和欢迎页统一显示 FileDeck；沿用原 bundle 标识以保留已有工作区设置。

应用图标采用蓝色 FileDeck 标识，Finder、Dock 和启动页共用同一资源；图标源文件与生成方式见 [图标说明](docs/filedeck-icon.md)。

## 源码与运行

以下命令均在项目根目录执行，不依赖固定的本机路径。

以下命令构建完整工作台，需要 Xcode，并按 [ONLYOFFICE 构建说明](docs/onlyoffice-build.md) 准备固定源码和 ARM64 内核。已打包应用的日常运行无需 Node、Python 或额外办公软件。

```bash
bash scripts/build-app.sh
open build/FileDeck.app
```

可在 Finder 中双击 `build/FileDeck.app`。每次普通启动先显示欢迎页；已有记录时点击“继续上次工作区”恢复，也可选择其他本地文件夹。首次使用可跳过添加目录进入工作台。管理目录、上次浏览位置、目录展开和分栏宽度会保留。显式 `--open` 或外部打开文件仍直接处理指定路径。预览与编辑在同一窗口的居中弹窗内完成。打开 `Package.swift` 或运行 `bash scripts/build-app.sh --browser-only` 仅用于浏览 UI 开发，输出独立的“FileDeck浏览验证.app”。

为临时测试指定目录且不改变记住的根目录：

```bash
open build/FileDeck.app --args --open /absolute/path/to/folder
```

## 浏览和页面内编辑

- 左侧显示桌面、下载、文稿和多个管理目录。文件列表提供搜索、类型筛选、排序、列表/网格和多选。
- 单击只选中；双击文件、按 Space/Return 或右键“预览”打开居中只读弹窗；双击目录进入目录。
- 文本、Markdown、代码、JSON、YAML 在弹窗内点击“编辑”后进入真实编辑器。最大化与恢复保持同一编辑器和草稿。
- 关闭、Esc、⌘W、切换预览文件、窗口关闭与退出应用统一检查未保存内容。保存真实写盘成功后才关闭；取消保留光标、滚动、模式、撤销历史与焦点。
- 弹窗关闭后保留当前目录、筛选、排序、视图、目录树展开、多选和文件列表滚动，焦点回到原列表。文件已删除时清理失效选择。
- 文件外部修改时阻止静默覆盖；已删除文件的草稿保留，只有明确确认系统“另存为”后才写入新目标。
- 应用菜单的新建/打开继续使用原生 Office、CSV、PDF 和图片工具，呈现在同一居中工作层；Office 保存仍由原内核处理。

顶部按钮显示中文名称。目录树名称后的空白区可单击进入，展开箭头独立展开/收起子目录。

在目录树、文件/目录项目和列表空白处右键“新建”，或使用顶部“新建”菜单，可在目标目录命名创建文件夹、Word/Excel/PPT、PDF、CSV/TSV/RTF、文本/Markdown、常见代码与配置文件、PNG/JPEG/SVG。Office 复用完整应用自带模板，PDF 和图片生成有效文档；自定义扩展名支持其他空白文本，已有格式使用相应模板，未支持的二进制格式会提示而不会生成伪文件。创建失败保留名称供修改，创建成功显示并选中新文件。

支持拖入复制、重命名与移到废纸篓。同名冲突拒绝覆盖，操作前复核文件身份。“从管理列表移除”仅取消引用。目录树不递归符号链接，应用包按文件展示。

本次目录点击、启动页和新建菜单修复的行为、验证及源码位置见 [交互修复验收](docs/interaction-repair-acceptance.md)。

## 文件预览

安全解码的文本使用本地 WKWebView + CodeMirror，Markdown 默认展示阅读视图；编辑读取完整文档，限制 10 MiB。其他类型使用有界预览或系统 Quick Look，音视频使用 AVPlayerView，不自动播放。关闭同步停止播放并释放预览资源，过期读取结果不能重新打开弹窗。

[QLPreviewView](https://developer.apple.com/documentation/quicklookui/qlpreviewview) 没有公开的渲染失败回调；创建控件不等于格式渲染完成。Office、PDF 等格式的预览保真程度由 macOS 与本机预览扩展决定。暂不支持的格式保留文件属性和默认应用打开入口。Markdown 相对路径图片与链接仍受现有资源访问限制。

## 权限与数据

文件通过本机文件系统和 macOS 预览服务读取。本地编辑无需云服务，打包的临时签名版本默认不自动检查上游更新。对 iCloud 或网络盘文件，系统服务可能按文件提供方的行为加载内容。

读取受保护目录时，macOS 可能提示目录访问授权；没有权限时界面会显示错误并支持重新选择。

本地构建是未启用 App Sandbox 的临时签名应用，仅面向本机使用；正式分发需要开发者签名、公证，以及单独设计沙箱和持久目录授权。

## 源码结构

- `BrowserStore.swift`：后台目录加载、多根目录与授权书签、工作区恢复、导航历史、目录树缓存、错误分类。
- `FileSystem.swift`：文件元数据、排序、隐藏项和包／链接边界。
- `NewFileTemplate.swift`：统一的新建格式、有效模板、目录身份验证与排他写入。
- `ContentView.swift`：目录树、文件列表、多选、空状态与预览入口。
- `WorkspaceEditorBridge.swift` / `NativeOffice/Workbench/FWBrowserHost.swift`：常驻工作台与独立预览会话。
- `NativeOffice/Workbench/FWPreviewModal.swift`：居中弹窗、焦点隔离、关闭保护、滚动恢复与资源清理。
- `NativeOffice/Workbench/FWWorkbenchCoordinator.mm`：文档标签、菜单路由与保存/关闭保护。
- `WorkspaceStartupView.swift` / `WorkspaceDesign.swift`：欢迎页、恢复页和统一视觉组件。
- `WorkspaceSplitView.swift`：分栏布局与宽度持久化。
- `FileMetadataView.swift`：后台读取文件属性与路径复制。
- `FilePreviewView.swift`：文本与 Quick Look 预览、刷新和清理。
- `TextPreviewLoader.swift`：文本编码识别、有界读取。
- `FileWorkbenchApp.swift`：独立浏览验证入口；完整应用保留原生窗口入口。
- `scripts/build-app.sh`：默认构建并打包完整应用；发布前验签，旧应用保留在 `build/previous-apps/`。

## 测试

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox --cache-path "$PWD/.build/cache"
```

单元测试只使用临时目录，不读取或修改用户业务文件。GUI 和具体文档渲染需在 macOS 中使用实际文件验证。

### 当前弹窗版本验证（2026-10-21）

Swift 109 项、构建工具 86 项、编辑资源 20 项、真实原生宿主 38 项和独立文档安全 14 项检查通过。实际验证真实文件保存、权限失败、外部冲突、系统另存为、光标/焦点/滚动恢复、快速切换与读取中关闭；视频真实播放后停止并释放资源也已验证。

18 个验收场景、最终应用回归与未覆盖范围见 [弹窗验收](docs/modal-preview-acceptance.md)。旧三栏与浏览页编辑的历史验证见 [实施状态](docs/implementation-status.md)，不能替代当前版本证据。

测试辅助应用需要脚本参数，不作为产品入口。无参数启动返回 64，避免旧版本 `NativeHostTests` 的启动数组越界；日常使用请打开 `build/FileDeck.app`。
