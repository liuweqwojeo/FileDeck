# FileDeck 实施状态

更新时间：2026-10-25。此文档区分源码回归、本机安装验收与公开发布，历史测试不替代当前包验证。

## 构建 8 本机验收

R6/R7 与系统另存修复已重建为 v0.1.2 构建 8，2026-10-25 17:06 安装至 `/Applications/FileDeck.app`。完整清单、静态门禁、严格签名、禁网 Office/混合工作台及真实恢复草稿面板取消/保存均通过。系统另存专项与完整文档 45 项断言、146 项 Swift、155 项 Python、23 项 Node 和 11 组原生媒体回归通过，见[第 15 节](code-review-and-roadmap.md#15-系统另存确认修复与构建-8-验收2026-10-25)及[构建 8 说明](release-build8.md)。修复源码 `854d9f6` 及标签 [v0.1.2-build8](https://github.com/liuweqwojeo/FileDeck/releases/tag/v0.1.2-build8) 已推送并公开发布，README 下载与校验值已更新。最终 ZIP 解压运行、静态门禁及远程附件大小/摘要通过，4 个构建 7 旧应用副本已移入废纸篓；正常运行的日常安装包为构建 8。

## R6/R7 源码修复（构建 8 内容）

PDF/图片缓冲区在接收变换结果前执行与保存一致的 256 MiB 上限检查；PDF 合并、图片追加和图片新建 PDF 的批量输入按累计字节预算读取。超限保留当前内容、保存基线、撤销/重做分支及源文件。查找、撤销、重做按文档实际能力、历史、只读/忙碌/关闭状态启用，CSV/图片/Quick Look 未实现的查找禁用，文本历史来自真实 CodeMirror 桥接。实现、验证及限制见[第 14 节](code-review-and-roadmap.md#14-媒体变换边界与菜单能力修复2026-10-25)。

源码阶段仅完成编译的状态已由上方构建 8 本机验收替代；构建 7 作为历史发布及可下载回退基线保留。

## 构建 7 本机验收与发布（历史基线）

R4/R5 已重新构建为 v0.1.2 构建 7 并安装本机。新源包/暂存包门禁、缺资源反例、安装全清单及签名检查、Office 三格式及混合工作台禁网运行均通过，详见[第 13 节](code-review-and-roadmap.md#13-构建-7-重建与安装验收2026-10-25)及[构建 7 说明](release-build7.md)。修复源码 `e58d73e` 已推送，标签 [v0.1.2-build7](https://github.com/liuweqwojeo/FileDeck/releases/tag/v0.1.2-build7) 已公开发布，README 下载及校验值已更新。最终 ZIP 解压后的静态门禁和禁网运行亦通过，GitHub 两个附件大小与 SHA-256 均匹配。5 个旧本机应用副本已移入废纸篓，正常运行的安装包为构建 7；回退可下载构建 6 Release。

## 后续源码修复（历史阶段）

R4 编辑资源一致性与 R5 打包门禁已完成源码修复和对应回归，详见[审查报告第 12 节](code-review-and-roadmap.md#12-编辑资源一致性与打包门禁修复2026-10-25)。该阶段尚未发布；现已由上文构建 7 的本机验收与公开发布结论替代。

## 构建 6 本机与发布记录（历史）

发布更新：修复源码已提交并推送为 `e9e0a12`，构建 6 使用独立标签 [v0.1.2-build6](https://github.com/liuweqwojeo/FileDeck/releases/tag/v0.1.2-build6) 发布，README 下载已更新。旧本机应用副本已按用户要求移入废纸篓；下文构建 4 备份路径仅为安装阶段历史记录。当前回退从原 v0.1.2 Release 下载构建 5，见[构建 6 发布说明](release-build6.md)。下文“未发布”描述均对应此前的本机安装阶段。

**R1 JPEG 保存保真、R2 WebKit 故障草稿真实另存、R3 目录重命名与重启恢复，均已修复并在最终安装包通过验收。** 2026-10-25 14:11:37，v0.1.2 构建 6 已安装至 `/Applications/FileDeck.app`，安装清单与签名检查通过，主程序 SHA-256 为 `676762a23f681c6cf2ad41e10dacc62ec142e7dce866bcfb8eb76106fa1d89e2`。实际系统面板、JPEG 原字节与重复写盘、旋转方向/尺寸/标准元数据、目录嵌套根/选择/历史/展开和重启均有对应证据；Office 三格式与混合文档运行退出 0，最终 Python **146 项通过、0 跳过**。隔离修正后的最终验收前后，正式工作区 5 个偏好键摘要相同；测试进程已退出，已确认不带测试变量的日常安装包进程正常运行。

源码阶段见[第 9 节](code-review-and-roadmap.md#9-优先问题修复与回归2026-10-25)。故障通过公开 WK 委托注入，并非系统级进程 kill；恢复限于存活 Swift 会话的已同步草稿，不包含应用崩溃后的持久恢复。图片 GUI 本轮覆盖保存/另存/旋转；未遍历所有工具，未重跑完整应用压缩资源专项，两项真实 Hunspell 单测已通过。

部署顺序、验证矩阵及回滚见[第 10 节](code-review-and-roadmap.md#10-本机安装与验收2026-10-25)。正式回滚优先保留 `build/previous-apps/FileDeck-before-priority-fixes-20261025-135754.app`（构建 4）；最终安装另存的中间构建 6 不替代此基线。本轮未 commit、push、公开发布或上传安装包，[README](../README.md) 的公开下载仍为 v0.1.2 构建 5。

## 2026-10-21 交付记录（历史）

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
