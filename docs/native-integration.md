# 居中预览与原生编辑集成

更新时间：2026-10-27。适用于锁定的 `desktop-apps` 提交 `8f452c7f703b795dcc09012ba6517df4ca47f9bc`；运行证据见 [弹窗验收](modal-preview-acceptance.md)、[文本性能回归](code-review-and-roadmap.md#17-o2-可见预览合并与版本差量桥接2026-10-26)、[媒体性能回归](code-review-and-roadmap.md#18-o3-图片像素复用后台变换与-pdf-批量高亮2026-10-26)及[目录性能回归](code-review-and-roadmap.md#19-o4-大目录显示快照选择索引与受控枚举2026-10-26)。

## 工作台与临时会话

`FWBrowserHost` 常驻一个 SwiftUI `ContentView`，目录树与文件列表始终挂载。`WorkspaceEditorBridge.preview` 传递稳定文件引用、触发来源和可选命中行号；单击仅选中，双击文件、Space/Return 和右键预览进入独立 `FWPreviewModal`。它在原窗口内容上叠加遮罩与 AppKit 对话框，不更换窗口控制器或重建工作台。当前本机安装为 v0.1.2 构建11，安装/源码辅助宿主证据分别见 [实施状态](implementation-status.md) 和 [八项交互修复](interaction-fixes.md)。

打开前，`BrowserStore.capturePreviewSnapshot` 保存目录/文件身份、多选、筛选、排序、视图与展开节点；弹窗另外弱引用原响应者及原生滚动容器位置。普通预览默认只读且聚焦中性容器；选区“编辑”/⌘E 对安全文本类型在同一宿主就绪后直接进入源码编辑并聚焦正文。背景不接收输入，可访问性隐藏；正文 Tab/Shift+Tab 缩进，Ctrl+Tab/Shift+Ctrl+Tab 在模态控件中切换焦点，查找/替换输入各自撤销而不改变正文历史。

`FWDocumentHost.openPreview` 为文本、代码、JSON、YAML、Markdown 提供真实只读内容，用户点击“编辑”后复用同一个 WKWebView/CodeMirror。搜索命中按原始源码行定位；CSV 搜索先用物理文本行预览，再切换原生表格。PDF/CSV/图片从预览原位进入已有原生编辑器，Office 进入同文件的既有 CEF 宿主；各类型均有“返回浏览”和“保存并返回”。原生保存经最终同步与关闭门禁，Office 等真实保存完成且原标签仍选中/无新修改才返回，失败/冲突/另存取消保留编辑。其余预览由 `FilePreviewSession` 管理，独立请求序号、Task 取消和资源清理避免迟到结果覆盖新文件。

关闭经同一文档关闭门处理；脏状态、保存执行中、弹窗生命周期、预览请求与工作台快照分别维护。确认取消时保留编辑器实例和撤销历史；保存只有真实成功后才更新保存路径。关闭清理弹窗资源后局部枚举原目录，按身份恢复选择、滚动及有效焦点；读取期间保留输入门，避免旧快照覆盖新导航。

## 界面层级与外观

整体规则见 [DESIGN.md](../DESIGN.md)，逐项问题、改法与验证见 [交互验收](interaction-verification.md)。顶部精简为导航、当前目录筛选、子目录/内容搜索、视图与工作区菜单；选区条显示预览/编辑/操作，批量操作复用右键菜单捕获的身份与范围。结果面板默认紧凑摘要，展开详情，撤销入口持续可见。侧栏提供添加目录、继续编辑和恢复草稿。

SwiftUI 与 AppKit 工作层跟随系统浅深色；移除窗口强制 Aqua，使用动态语义色。最小工作窗 860×660，⌥⌘S 折叠侧栏并把焦点交给可见筛选框；⌘F 聚焦当前目录筛选，⇧⌘F 打开递归搜索。隐藏的内容面和侧栏同时禁用交互、快捷键与可访问性。浏览快捷键通过 `WorkspaceBrowserShortcuts` 的当前窗口事件分发，`isPresented`/`isPreviewPresented` 排除原生工作层，系统 sheet 直接放行。Office、PDF、图片的实际文档纸张色仍由各内核管理。

## 大目录显示与读取调度

BrowserStore 的显示快照随目录元数据/搜索词/类型/排序失效，缓存可见和排序数组、URL/身份/显示位置索引；选择与网格切换复用快照。选择捕获/恢复平均为 `O(n+m)`，排序仍有 `O(n log n)` 与线性缓存内存。硬链接歧义不自动跟随，原路径必须同身份，只有真实保存成功的 savedURL 可以重绑原子替换；连续刷新列表清空期间沿用首次身份，防止新同名文件继承选择。

列表、树、预览关闭共享有订阅的在途枚举，最多两个工作器；同 URL/隐藏策略/刷新代次合并，当前列表优先。收起和切走会移除无订阅排队项；已经阻塞于系统调用的任务仍占槽直到实际返回。无订阅的旧结果不允许后来请求重新加入，各消费者继续独立校验请求/树代次和预览会话。关闭预览强制新读取并验证原目录身份，取消也会结束等待，期间保留列表与树对象。

刷新/重命名后只重新读取祖先均展开的可见树分支及当前列表，收起缓存失效、后代展开意图保留。隐藏空列表仍额外确认是否仅含系统隐藏项。O4 本身未新增递归搜索或 OS 级 I/O 强制中止，后续 F2 的目录监听见下节；两个旧慢任务同时阻塞时当前目录仍可能等待。真实万文件采样和可控慢卷回归范围见[第 19 节](code-review-and-roadmap.md#19-o4-大目录显示快照选择索引与受控枚举2026-10-26)。

## 外部文件变动与被动同步

BrowserDirectoryObserver 在专用串行队列核验目录路径/fd 身份并监听 vnode；当前目录、可见展开分支及其父目录最多 128 个有效订阅，优先当前目录。父目录不枚举，收起/移除根/释放 owner 取消源并关闭描述符。注册补查、180 ms 尾沿防抖、变化版本和回前台检查共同覆盖新增/删除/改名；无法订阅、超出配额或通知不可靠的卷依赖前台补查，不引入周期轮询或全盘递归扫描。

自动同步复用两个后台目录工作器，不进入清空列表的加载态；不变快照不重建显示缓存，提交时恢复最新多选与 Shift 锚点。原路径需同身份，唯一身份才跟随改名，替换/硬链接歧义不继承选择。目录 fd 通过 F_GETPATH 定位同身份新路径，并复用原路径迁移同步管理根、历史、书签、作用域、展开及缓存；真实迁移对象覆盖失效目标缓存。目录读取前后均校验身份，失败保留最后快照/原选择并显示不可用状态，用户显式刷新才接受同路径后来目录。

预览/编辑或文件批次占用时暂存事件，读取发起/提交均检查；关闭取消不触碰 WK 草稿，关闭完成后同步，保存冲突语义保持。预览关闭时旧目录被改名导致读取失败也保留原身份快照，允许监听随后迁移选择。模型、原生列表滚动/焦点及草稿证据与边界见[审查第 21 节](code-review-and-roadmap.md#21-f2-外部文件变动自动同步与浏览状态保护2026-10-26)。

## 多选废纸篓与文件操作

List 以系统右键选择集合确定范围；网格右键选中项沿用多选，未选项仅操作该项。菜单持有冻结的 FileEntry/身份数组并显示数量，不在点击后重新解析当前选择或为缺失身份补 stat。目标按显示索引排序，复用随选择/显示快照失效的缓存，避免网格菜单重复扫描整目录。

BrowserStore 的 trashFiles 在后台逐项校验原身份再调用系统 FileManager.trashItem；逐项失败继续执行并汇总成功/失败/总数及原因，按路径去重而不合并硬链接。没有永久删除回退或整批事务回滚；当前批次取消与最近一批撤销由 FileOperationControl/文件操作记录管理，见下方文件批次说明。身份检查与系统调用不具有原子性。符号链接保持目录项 URL，不主动解析目标。

isTrashing 与复制/移动的忙碌状态组合，防止重入并禁用 UI 写入入口；完成后只刷新最新浏览状态，不回旧目录。失败项仅在原身份仍匹配时保持选择。对应模型、实际系统和完整浏览回归见[审查第 20 节](code-review-and-roadmap.md#20-f1-多选移到废纸篓身份保护与部分失败2026-10-26)。

## 非 Office 持久草稿与崩溃恢复

FWDocumentHost 通过 FWDraftCheckpoint 跟随文本、CSV、PDF 和图片的真实修改状态：750 ms 防抖、连续输入最长 5 s 触发提交，主 actor 仅捕获 COW 状态，CSV 序列化/摘要/写盘在 DraftRecoveryStore actor 执行。每宿主最多一份在途快照与一个待刷新标记；界面显示待更新、已更新或失败，超限/写入失败保留旧完整副本。正常保存且无新编辑或明确丢弃后清理，取消关闭不清理，generation 拒绝迟到复活。

副本默认保存在 `~/Library/Application Support/FileDeck/DraftRecovery-v1/`，UUID 记录头及 SHA-256 正文以临时写入/fsync/rename 提交，目录 0700/文件 0600。全局 flock 协调配额与清理，owner 锁在进程死亡时自动释放，仍活跃的记录不能被另一会话认领/删除。单份正文 256 MiB，已提交记录 512 MiB/20 份，原子替换时最多另有一份同上限临时文件；可识别未占用记录保留 30 天，恢复列表/检查点触发清理，损坏结构/新版本由用户明确删除。配额不静默淘汰未过期草稿，详细字节上限、临时空间及清理规则见[审查第 22 节](code-review-and-roadmap.md#22-f3-非-office-草稿持久化与崩溃恢复2026-10-26)。

欢迎页与“工作台 → 恢复未保存草稿…”进入恢复列表，支持恢复、稍后与二次确认删除。恢复为独立未命名且 dirty 的文档，原路径仅用于提示，首次保存另存并继续使用原 SafeFileIO 保护；文本/CSV 保留检查点正文与选择编码/分隔符，PDF/图片保留编辑缓冲区字节。原文件外部修改/删除/改名不影响独立恢复，撤销历史、尚未桥接/提交的输入和在途变换不在保证内，Office 恢复仍由原内核负责。

## 原生窗口和兼容编辑器边界

- 入口仍是 `main.mm → AppDelegate → ASCTitleWindowController → ASCCommonViewController`，保留原窗口 `contentViewController` 与上游退出链。
- `FWWorkbenchCoordinator` 仍持有原 `NSTabView` 和原生文档会话；应用菜单创建/打开的 Office、CSV、PDF、图片会话使用兼容模式的居中工作层。
- 只移动整个 `NSTabView`；Office 的 `NSCefView` 仍为 `NSTabViewItem.view` 的直接子视图，原保存和退出路径保持有效。
- 原生会话用 `fw:<UUID>` 标识，`webView` 为 nil，不能强转为 CEF 或将标识转整数后销毁 Office 实例。
- 现代文本弹窗开启时，菜单保存路由到该弹窗；不能误写后台 Office 标签。窗口关闭及应用退出先检查现代弹窗，再进入原有文档关闭链。
- Office dirty/保存真值仍来自原内核；原生文档由 `FWDocumentHost` 和 `SafeFileIO` 处理，不另写一套 Office 保存实现。

## 文件批次的进度、取消与撤销

`BrowserStore` 持有单批 `FileOperationControl` 与最近一批内存撤销记录；后台更新加锁快照，主线程每 100 ms 发布实际变化。浏览页顶部显示数量、当前文件、取消、结果和撤销；复制/移动/废纸篓及撤销均保留原忙碌门禁，状态同步完成后才放行被动目录同步。

复制在目标私有 0700 暂存目录完成后以 `RENAME_EXCL` 提交；未提交的取消/失败只清理身份匹配的本次暂存。取消不强行中断当前系统调用；已完成项保留，失败继续逐项汇总。已提交但清理失败仍登记成功/撤销并显示残留警告，无法清理的暂存及跨卷源删除失败列出路径供人工检查。

撤销副本使用系统废纸篓；移动和废纸篓按精确位置/身份排他恢复原位，后者使用系统返回的位置，不扫描废纸篓。原父目录/当前位置父目录/对象替换、同名占位等失败不覆盖，失败和未执行项可重试。仅保留本窗口最近一批，下一批替换、关窗/退出失效，不提供重做或持久撤销；移动撤销复用路径迁移同步，详情和限制见[审查第 23 节](code-review-and-roadmap.md#23-f4-文件操作进度取消与撤销2026-10-26)。

## 限定目录的递归搜索

`ContentView` 的内嵌搜索工作区使用 `DirectorySearchSession`，不替换浏览 `query` 或目录快照。范围默认当前目录，其他范围复用系统授权面板但不添加管理根；明确启动后由唯一后台工作器绑定根身份，持续重搜只保留最新请求，旧系统调用未返回不追加工作器，过期/关闭结果不回写界面。定位前后台逐段复核路径与身份，“定位”成功才正常导航到父目录并选中；“预览”验证后在原工作层查看，不改浏览位置，关闭后继续同一结果。关闭搜索取消在途定位任务，即使再打开也不能执行旧请求。

`DirectorySearchEngine` 使用相对 fd 枚举/读取，拒绝链接、文档包、特殊文件和其他卷；正文按 64 KiB 分块，复用 `DocumentIO.decode` 和 `TextPreviewLoader.isTextFile`，不解析 Office/PDF。默认可修改的依赖/构建目录排除；5 万枚举、1000 结果、64 层、单文件 2 MiB/总读取 256 MiB、20 条错误详情和 200 标量摘要限制资源占用。取消等待单次调用返回，部分/超限/跳过可见，结果不提供持久索引或实时刷新。完整范围和一致性边界见[审查第 24 节](code-review-and-roadmap.md#24-f5-限定目录的递归名称与内容搜索2026-10-26)。

## 文件写入与资源

文本完整编辑上限 10 MiB，截断预览不能直接保存。文本、CSV、PDF、图片共用 `SafeFileIO` 的快照与外部变更检测；删除后保留草稿并要求系统另存，移动位置无法可靠识别时不自动写向同名文件。Markdown 不自动请求外部资源，相对路径资源保持原安全限制。

系统另存明确选择已删除的原路径时，允许以排他新建方式重建它；普通保存仍报告外部变更。目标已存在、链接变化或写入期间出现其他版本时仍拒绝覆盖，不能因选择“另存”就跳过这些保护。

PDF/图片的 `FWBinaryState` 初始化、替换、异步变换结果与最终保存采用相同的 256 MiB 上限，超限结果在提交前拒绝，原内容和撤销历史保留。PDF 合并、图片追加及图片新建 PDF 通过 `SafeFileIO.openMediaBatch` 逐份读取；累计输入预算包含当前 PDF 缓冲区，超过剩余额度时停止读取后续文件。该预算约束压缩输入字节和最终缓冲区，不等于 PDFKit/ImageIO 解码、序列化或撤销历史的总内存硬上限。

图片打开和重新读取只解码一次，SDK 声明 Sendable 的不可变 CGImage 随文件结果返回；NSImageView 仍由主 actor 更新。旋转/裁剪/缩放与保留元数据的 PNG 编码在后台，编码字节和像素共同通过预算/取消检查后安装；当前像素直接用于显示、PNG/JPEG 转码、单页 PDF 导出与撤销，不再为显示重复解码。JPEG 原字节/已编码缓存保持不变。

媒体控制器一直保持处理占用，直到显示与撤销项安装完成；取消、失败或超限不提交。图片变换允许在旧保存进行时捕获并更新草稿，旧保存只推进所写快照的基线；PDF 批量变换与保存互斥。真实 PDFView 选区只在主线程提取逐行页码/矩形，批量模型在工作器上一次解析/序列化，一次刷新展示并注册一项撤销；不把可变 PDFDocument 跨 actor 共享。

FWMediaHistory 为 UndoManager 动作分配可移除票据，默认 12 个动作/128 MiB 记账预算；计入编码数据及图片像素估算，裁剪共享 backing 按原规模保守计入。淘汰释放最旧动作，单项超额时清旧分支，避免撤销跨过当前修改；跳过 Cocoa 空组，清理时保持调用方分组配对。该预算不覆盖库内部缓存、当前内容、保存基线、编码缓存及在途分配，大图撤销次数可能少于 12。具体证据及心跳/RSS 采样见第 18 节。

`FWNativeContent` 对查找/撤销/重做默认返回不可用；实现者根据真实能力和历史提供状态。`FWDocumentHost` 门面、标准 responder 校验与 `FWWorkbenchCoordinator` 菜单共用这些状态，忙碌及关闭时禁用命令。文本的历史标志来自 CodeMirror 的 change/state 消息，重新读取/重建清空旧标志；只读文本和 PDF 可以查找，CSV/图片/Quick Look 的查找禁用。CSV 搜索属于尚未实现的独立功能。

CSV 单格提交只重算受影响行的转义长度和签名，并在通过总字节预算后更新模型；单格 UndoManager 记录旧值与短行字段数，局部刷新目标单元格。结构操作仍保存模型快照并重建缓存。dirty 优先用签名排除相等，签名相同必须完整比较 UTF-8，不能把哈希作为相等证明。原文可选引号等字节在无改动或完整撤销时保留，编辑后的规范化规则与此前一致。

CSV 保存捕获修订号、编码、模型和可选原文，在后台生成文本。保存成功只推进磁盘指纹及所写内容的基线，不覆盖等待期间的新编辑或编码选择；失败保留草稿。结构/保存快照可能触发下一次编辑的写时复制，基线相同时仍需遍历正文确认 dirty；大表优化不等于所有操作都是常数成本。可复现原生控制器基准见 `python3 -B scripts/onlyoffice/benchmark_csv.py --baseline-ref 59b5591da06ef586cf92a44971003eca380bde61`，测量范围与数据见[审查报告第 16 节](code-review-and-roadmap.md#16-csv-增量编辑与隐藏-markdown-预览优化2026-10-25)。

文本原生宿主通过 `bridgeMode=patch-v1` 启用即时版本差量，位置基于原始正文 UTF-16。`TextDocumentSession.applyEdits` 在任何修改前验证全部排序、范围与代理对边界，倒序应用后仍用真实 UTF-8 与保存基线计算 dirty；组合附加符可以独立编辑。版本缺口/非法范围会请求完整 `getSnapshot`，重同步最多重取三次，失败进入保留最近同步草稿的恢复态。旧版本不回写会话，重新读取和编辑器重建都重置版本，迟到的旧 WK 消息仍被原会话/实例门禁拒绝。

保存与关闭先确认完整快照；等待期间已接收的新差量优先，旧快照不能将其覆盖。保存成功仍只确认实际写盘正文。Markdown 帧任务仅合并可见预览，不延迟差量；交互捕获/暂停前立即刷新，切换或关闭取消旧帧任务。行尾偏移缓存每会话只保留最近一份，普通同一行输入复用行尾映射；新增/删除换行仍可能扫描映射。原生 NSString 重建、Swift 保存基线比较以及每次实际预览转换仍有全文成本，未测总内存峰值或实机输入延迟。

`FilePreviewSession.cancel` 同步暂停 AVPlayer、移除 item/observer、清空 AVPlayerView，以及取消并清理 Quick Look。所有异步结果检查有效请求，关闭后不能重新呈现。

`native_sources.py` 显式同步原生源码和资源；`003–008` 保留已有桥接、工作台与品牌，`009` 注册弹窗，`010` 注册新建模板，`011/012` 注册草稿恢复和递归搜索。补丁链支持重复应用。编辑资源位于 bundle 的 `FileWorkbenchEditors/`，与上游 `editors/` 分开，运行不需要 Node/Python。

## 性能基准复现约定

三个 `benchmark_*.py` 入口仅在 `build/` 的新目录中复制源码、编译探针和生成样本；它们不挂载应用窗口，也不替代安装版交互验证。每个基线只使用对应 Git 提交存在的源码，后续新增的草稿/搜索文件不会混入旧版本；两侧使用同一份冻结探针，报告记录实际输入摘要、编译器、系统、目标、执行顺序和遗漏的旧版本路径。

媒体 PDF 探针按各自版本是否提供 `PDFOperations.addHighlights` 选择批量或旧逐行路径，并记录 `pdfHighlightMode`；默认 `--baseline-ref HEAD` 若已含批量实现，两侧都使用批量。需要历史对照时显式指定下方构建8提交。CSV 计单格提交，图片心跳/RSS 与目录状态层分别保持原边界；基线先运行且为一次非独占采样，不把它们称为 UI 帧延迟或稳定的中位数收益。完整历史数据和本轮入口复核见 [审查报告](code-review-and-roadmap.md)。

## 验证入口

- `swift test --filter DirectorySearchTests`：F5 范围/排除/编码/预算、取消/最新请求合并、文件与目录替换、定位检查、错误上限和摘要边界。
- `FW_NATIVE_HOST_TEST_CASE=search bash scripts/test-native-hosts.sh`：真实工具栏/搜索面板/输入/模式/取消/结果定位与浏览状态保护；取消用隔离工作器闸门，真正搜索使用 UUID 文件树，不代表慢卷硬件。

- `swift test --filter BrowserDirectoryPerformanceTests`：O4 万项身份/筛选缓存、慢卷并发/队列与取消、过期结果及连续刷新保护。
- `python3 -B scripts/onlyoffice/benchmark_browser.py --baseline-ref 59b5591da06ef586cf92a44971003eca380bde61`：同一真实万文件目录与探针比较状态层耗时，保存源码摘要；不测完整 UI 绘制或真实慢卷。
- `swift test --filter FileOperationTests`：F4 暂存清理、复制/移动/废纸篓取消、三类撤销/冲突/身份替换、注入 EXDEV 及残留失败回归。
- `FW_NATIVE_HOST_TEST_CASE=file-operations bash scripts/test-native-hosts.sh`：F4 真实进度/取消/撤销控件、系统废纸篓和同卷移动/复制，UUID 样本恢复；CGEvent 仍需明确授权及有效焦点，跨卷失败由模型注入验证。
- `bash scripts/test-native-hosts.sh`：实际文件列表双击、键盘、焦点、精确滚动、调整窗口、保存失败、快速切换、F1 两项系统废纸篓/部分失败、F2 自动目录同步/草稿保护及 F4 进度/取消/撤销及 F5 递归搜索。
- `FW_NATIVE_HOST_TEST_CASE=trash bash scripts/test-native-hosts.sh`：只执行 F1 8 项真实菜单/系统废纸篓专项，未知专项失败；UUID 样本按身份恢复，未触碰用户其他废纸篓项目。
- `FW_NATIVE_HOST_MOUSE_DRIVER=cgevent bash scripts/test-native-hosts.sh`：在明确授权且已有辅助功能权限的本机使用备用真实鼠标路径；每次仅投递至当前测试前台/key 窗口内容区，失焦则拒绝。该入口不取消原有业务/模态断言，默认仍用 NSEvent。
- `bash scripts/test-draft-recovery.sh`：隔离 writer 实际编辑四类文档，确认自动检查点后核验 PID/可执行路径并 SIGKILL，再由新 reader 走恢复/清理/取消面板、另存及原文件保护；测试不会替换日常安装。
- `swift test --filter DraftRecoveryStoreTests`：实际文件锁、版本、配额、过期清理、损坏/链接/FIFO/根替换及跨实例预算。
- `bash scripts/test-modal-documents.sh`：真实 WebKit、原生确认与 NSSavePanel，验证取消恢复、外部冲突和删除后另存。
- 系统面板由 `NativeOffice/Tests/SystemSavePanelDriver.swift` 在外部按真实 AX 按钮，需已有 Accessibility 权限；本进程不投递 Return、不调用 `NSSavePanel.ok` 或伪造完成回调。助手核对随机令牌、进程/可执行文件、面板标题及文件名，拒绝错误令牌；缺权限或没有真实系统回调均失败。`FW_MODAL_DOCUMENT_TEST_CASE=save-panel` 可单独运行此场景。
- `FW_MODAL_DOCUMENT_TEST_CASE=menu-capabilities bash scripts/test-modal-documents.sh`：真实 WK 输入、撤销重做、只读/载入/故障/关闭状态及 responder 菜单校验。
- `FW_MODAL_DOCUMENT_TEST_CASE=incremental-bridge bash scripts/test-modal-documents.sh`：丢弃真实差量后完整重同步、重复消息、故障草稿另存与旧快照等待期间输入的保存竞态；环境需要时仅对精确隔离测试 PID 的已出现窗口外部置前，不删除活动窗口前置条件。
- `python3 -B scripts/onlyoffice/test_native_content.py`：真实 PDF/图片/CSV 会话、可注入大小边界、正常批量处理及撤销、各类菜单能力。
- `python3 -B scripts/onlyoffice/benchmark_media.py --baseline-ref 59b5591da06ef586cf92a44971003eca380bde61`：同探针比较 12 MP 图片和 20 页/120 处高亮；5 ms 主队列心跳、独立进程 RSS 高水位及输出检查，不代替完整应用绘制性能验收。
- `FW_NATIVE_HOST_TEST_CASE=external-sync bash scripts/test-native-hosts.sh`：F2 独立进程文件变动及真实 vnode/原生 List/WK 草稿专项，含预览期间目录改名；默认无专项变量仍运行完整流程。独立文件进程与 Finder 产生同类目录通知，但不等同于操作 Finder UI。
- `python3 scripts/onlyoffice/smoke.py --app build/FileDeck.app --workbench`：隔离 profile、禁用网络，验证 Office 三格式与混合文档，以及真实窗口关闭/退出应用的取消保护。
- `Tests/BuildToolsTests/test_swift_workbench.py`：源码映射、ARM 目标、资源及补丁链重复应用。

独立 `--browser-only` 入口仅用于浏览 UI 开发，完整居中编辑与退出链以 `build/FileDeck.app` 为准。系统中文输入法组合输入、复杂 Office 排版、无开发工具的另一台机器仍需独立验收。
