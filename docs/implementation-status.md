# FileDeck 实施状态

更新时间：2026-10-21。此文档区分已验证的基础模块与用户可用的应用能力，避免把旧浏览器构建通过当作编辑器交付。

## 当前交付

**完整包为 `build/FileDeck.app`，目录树与文件列表常驻，预览/编辑在同一窗口的居中弹窗完成。** 单击只选中，双击文件或按 Space/Return 打开只读预览，主动点击“编辑”才进入文本编辑。关闭保留导航、多选、筛选、树展开、滚动与焦点；未保存保护统一覆盖预览关闭、切换、窗口关闭和应用退出。

文件包名、主程序、窗口、系统菜单与蓝色图标统一为 FileDeck；保留 `local.fileworkbench.desktop`。上游编译目标、内核、helper 与第三方声明保留各自名称。架构见 [原生集成](native-integration.md)，逐项证据和限制见 [弹窗验收](modal-preview-acceptance.md)。

| 阶段 | 已获得证据 | 范围 |
|---|---|---|
| 基础回归 | Swift 109 项、构建工具 86 项、编辑资源 20 项通过 | 真实文件 I/O、身份与快照、编辑器恢复、构建补丁 |
| 模态工作台 | 38 项真实原生宿主检查通过 | 双击/键盘、原列表对象、滚动/焦点、窗口大小、保存失败、删除和读取竞态 |
| 文档安全 | 14 项真实 WK/原生对话框检查通过 | 光标/撤销恢复、真实写盘、外部冲突、删除后系统另存 |
| 视频释放 | 真实静音 MOV 播放后关闭通过 | 播放已推进、停止、释放 item、移除 view.player |
| 最终应用 | 构建和最终 Office/退出链回归结果见弹窗验收 | 不以旧版本结果替代当前包 |

以下更名与早期浏览页证据为历史结果，描述旧版本交互；当前行为和验证以本节及弹窗验收为准。中文输入法组合输入、复杂 Office 排版、各系统预览扩展、权限首次授权和物理拔盘仍需专项验收。

## FileDeck 更名验证

- `build/filedeck-build.log`：最终原生构建、主程序改名与重新签名成功。
- `build/filedeck-buildtools-tests.log`：86 项构建工具测试通过，包含完整补丁链的重复应用。
- `build/filedeck-brand-verification.json`：包名、主程序与 45 个语言资源中的名称一致；bundle ID 与其他本地化字段保持不变。
- `build/onlyoffice/bundle-verification-b4ea0563a4054c2a8fe46ab4433b5554.json`：最终 `FileDeck.app` 的 ARM64、资源、签名和动态库检查通过。
- `build/onlyoffice/smoke/fw-office-smoke-中文 路径-b4li_gql/verification.json`：改名后的应用在断网环境完成 DOCX/XLSX/PPTX 编辑、保存与重开，浏览页内混合文本/PDF、菜单保存路由和关闭检查均通过，进程退出 0。

此次更名执行 simplify Lite / refactor 与独立只读审查，未发现必须修复的问题。修改位置：`scripts/onlyoffice/package_app.py`（最终包及语言资源），`scripts/onlyoffice/patches/desktop-apps-008-filedeck-brand.patch`（标题栏），`NativeOffice/Workbench/FWWorkbenchCoordinator.mm`（系统菜单），`Sources/FileWorkbench/WorkspaceStartupView.swift`（启动页），以及浏览验证入口和构建文档。已运行的旧应用需正常退出后打开新包才能显示新名称。

## 历史浏览页编辑验证证据（更名前）

- `build/browser-editing-tests.log`：Swift 99 项回归。
- `build/browser-editing-buildtools-tests.log`：构建工具 86 项回归。
- `build/native-host-tests/run.IbsMLD/fixtures/report.json`：真实 WK + FWDocumentHost + FWBrowserHost 的 25 项验收，包含展开收起、后台状态不抢回浏览、原路径保存与关闭取消。
- `build/onlyoffice/smoke/fw-office-smoke-中文 路径-n3ta2qig/verification.json`：最终 `build/文件工作台.app` 的同页 Office 三格式与混合文本/PDF 验收，进程退出 0，网络 deny，隔离 profile；中文 SDK 输入已验证。
- `build/onlyoffice/bundle-verification-8eb317dea2a14e4a91500ddd947aa957.json`：最终包 ARM64、必需资源、签名、符号链接和动态库依赖检查通过。
- `build/browser-editing-native-build.log` 与 `build/browser-editing-package.log`：完整原生构建、ARM64 检查、签名和打包结果。

第一次混合回归被首次启动的更新询问窗占据菜单目标而失败；验收现在关闭测试进程的自动更新检查、激活目标窗口，并等待实际菜单目标匹配后执行保存。最终包默认关闭自动更新检查，不改用户全局偏好。没有跳过保存路由断言。

本次执行 simplify Standard / feature，检查 repo_fit、quality、reuse、efficiency。修复构建补丁相邻上下文导致的重复应用失败、关闭命令未走公开标签委托、隐藏预览重复渲染与可访问性干扰、窄窗口工具栏拥挤；文件类型文案统一复用。收尾后重跑宿主、构建工具和 Swift 验证，无遗留必须修复的问题。子代理审查因额度不可用，剩余检查由主代理完成。

## 已实现的独立基础

- `DocumentIO.swift`：完整文本读取，UTF-8、UTF-16、GB18030，可选编码；保留实际 BOM 和换行，拒绝无法逐字节往返的解码结果；10 MiB 编辑限额。
- `SafeFileIO.swift`：文本和媒体共用的完整文件快照、外部变更检测、同目录临时文件原子保存、权限/ACL 和符号链接目标保护；新建文件采用排他重命名。PDF、图片控制器复用此接口保存，复杂文档交互仍待专项验收。
- `CSVDocument.swift`：逗号、分号和 Tab；严格引号解析、多行字段、混合行尾；单元格及行列操作，明确的大小限制。
- `MediaOperations.swift`：PDF 页面旋转、合并、提取、文字批注、高亮、图片转 PDF；合并和提取会重映射页内跳转；PNG/JPEG/HEIC 读取及方向归一，裁剪/旋转/缩放和 PNG/JPEG 导出。原生控制器已连接统一保存门面；PDF 标签已通过当前混合回归，图片各类操作仍需完整 GUI 验收。
- `EditorAssets/` 与 `Resources/Editors/`：本地 CodeMirror 6 和 markdown-it，源码、语法高亮、查找替换、撤销重做、Markdown 预览及 JSON 无损格式化；保留大整数和换行，排版限制 256 层及 10 MiB；禁用原始 HTML 与自动外部资源加载，提供依赖锁、许可证和资源摘要。
- `BrowserStore.swift`：修复打开隐藏文件时异步搜索/可见性回调清空待选文件的问题。
- `FileCapabilities.swift`：扩展名和 UTType 路由，建议编辑器与实际可用后端分开；默认仅只读预览，未接入的编辑器不开放操作，HEIC 编辑后必须另存为 PNG/JPEG。
- `scripts/onlyoffice/`：固定源码、环境检查、离线 qmake 准备、分阶段构建；补丁可重复应用并拒绝覆盖不匹配修改，Boost 下载可恢复，CEF 按固定提交和 SHA-256 获取，OpenSSL 安装失败可重试。
- `NativeOffice/Smoke/`：真实 Office 新建、输入、保存、关闭、重开及查找的原生验收钩子；测试使用隔离目录与禁止网络的启动环境。已运行真实三格式验收；报告见下方。混合 Office/文本/PDF 标签入口 `--workbench` 已在当前集成应用执行通过。

## 验证入口与边界

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift test --disable-sandbox --cache-path "$PWD/.build/cache"
python3 -B -m unittest discover -s Tests/BuildToolsTests -v
npm --prefix EditorAssets test
bash scripts/test-editors.sh
```

上述命令在仓库根目录执行。早期版本的 Swift 测试为 99 项（含 HEIC）、编辑资源 Node 测试为 18 项；当前版本数量见上方当前交付。实际 WKWebView 验收已通过 19 项，包括 CSP 生效、中文和 emoji 文本编辑、换行与撤销保真；这不等于手动中文输入法候选窗验收；工作台内接入已有上方单独的真实宿主与混合验收证据。该报告在 `build/editor-tests/report.json`。

HEIC 测试会使用 macOS 图像服务生成临时样本；受限命令沙箱中可能无法连接系统编码服务，应在允许该服务的本机环境运行，不能通过跳过断言报告成功。

基础测试不证明复杂 Office 文档兼容性，不替代最终应用离线回归。当前 `scripts/build-app.sh` 默认生成完整原生应用；`--browser-only` 才生成独立浏览验证入口。

## 历史 Office 构建依据

- `build/onlyoffice/smoke/fw-office-smoke-中文 路径-yn_gw_4m/verification.json`：进程退出码 0、网络 deny、隔离 profile；三格式正文均含本次唯一中文标记，已在原生编辑器重开并查找验证。
- `build/onlyoffice/bundle-verification-4c71eef87ca34d969111180e11c9b96c.json`：ARM64 必需二进制、资源、签名、符号链接与库依赖检查通过。该报告对应工作台改造前的原生应用，当前集成包的检查见上方本次验证证据。
- 工作台代码位于 `NativeOffice/Workbench/`，源同步清单与 Xcode 补丁位于 `scripts/onlyoffice/`；默认打包脚本已更新为完整原生应用。
