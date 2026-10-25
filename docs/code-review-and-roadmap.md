# FileDeck 代码审查、优化建议与功能缺口

审查日期：2026-10-25（Asia/Shanghai）  
代码基线：`main`，提交 `00a4d5e`；开始审查时工作区干净。  
范围：Swift 浏览及文件操作、原生文档宿主、文本/CSV/PDF/图片编辑、本地 JavaScript 资源、ONLYOFFICE 集成和构建发布脚本。  
交付性质：审查与后续任务清单，并跟踪优先问题修复。**R1、R2、R3 已修复并发布构建 6；R4、R5 已完成后续源码修复与回归。** 前三项见第 9–11 节，编辑资源和打包门禁见第 12 节。R6/R7、性能优化及功能候选仍待处理。

## 1. 结论与优先级

核心功能链路已经具备：多目录浏览、工作区恢复、文件创建/复制/移动、预览、文本及 Office 编辑、CSV/PDF/图片基础工具、正常关闭时的未保存确认、外部修改冲突保护。当前更值得优先投入的是**保存保真、故障恢复、目录状态一致性和构建校验**，随后再处理大文件响应速度及日常操作缺口。

本次整理了 **7 项优先修复或工程风险、4 类性能优化、9 项功能完善候选**。这些并不都属于已经发生的故障；每项明确标注证据级别。未发现足以断言必须全面重写架构的依据，也不能以现有测试通过推断没有缺陷。

| 优先级 | 含义 | 建议顺序 |
| --- | --- | --- |
| P1 | 涉及原文件保真或未保存内容的可恢复性 | 下一次对外发布前优先处理 |
| P2 | 状态错误、可用性、性能或发布校验缺口 | 随后修复，并补对应回归 |
| P3 | 维护性改善及可选产品能力 | 根据实际使用频率安排 |

证据级别：**已复现**指运行了当前代码的最小验证；**代码确认**指调用链明确但没有执行完整 GUI 场景；**边界风险**指触发条件可由代码推导，尚未实测其极端输入；**功能候选**不代表 README 已承诺却未交付。

## 2. 优先修复与工程风险

### R1 · P1 · 未修改 JPEG 直接保存仍会有损重编码并丢失元数据

**当前状态：已修复并补回归；最终安装包已通过真实 Cmd+S、系统同格式另存、旋转和重复保存验收，见第 10 节。以下保留审查基线的问题证据。**

- 触发：从“打开文件”进入 JPEG 编辑器，不作修改，执行普通保存。
- 原因：宿主没有跳过未修改的普通保存；图片保存固定执行解码后以 `quality: 0.92` 重新编码。输出只设置压缩质量，没有迁移源图片的 TIFF/EXIF 等属性。
- 影响：用户仅执行保存就可能改变原始像素，并丢失拍摄/描述类元数据。图片编辑后保存也需要明确元数据保留策略。
- 代码：`NativeOffice/Workbench/FWDocumentHost.swift:196`；`NativeOffice/Workbench/FWImageContent.swift:81`、`:184`；`Sources/FileWorkbench/MediaOperations.swift:263`。

实际探针使用仓库 `ImageOperations`：将带 TIFF Artist/ImageDescription 的 128×128、质量 1.0 JPEG 经当前等价编码路径处理，文件由 **58,952 字节变为 18,953 字节**，TIFF 属性变为 `nil`；解码后 65,536 个 RGBA 通道中 46,361 个发生变化。该样本证明此路径会损失数据，数值不代表所有图片的变化比例。

建议：未修改的原路径普通保存不重编码；区分“保存”和“导出/格式转换”；编辑后保存保留适用元数据，并正确处理方向、尺寸等因变换失效的属性。不要盲目复制旧 EXIF 方向。

验收：未编辑 JPEG/PNG 普通保存前后字节一致；编辑后像素变化符合操作，约定保留的元数据仍在；另存转格式、外部冲突和 HEIC 路径继续有效。

### R2 · P1 · WebKit 进程终止后，内存草稿缺少可用恢复入口

**当前状态：已实现内存草稿另存及编辑器重建；最终安装包通过真实系统面板取消、草稿保存与释放验收，见第 10 节。故障通过真实 WK 的公开委托注入，未执行系统级进程 kill。以下保留审查基线的问题证据。**

- 触发：文本已经修改、部分或全部内容已同步到 Swift session 后，WebKit 内容进程终止。
- 原因：故障处理设置 `failure` 并清除 `editorReady`，可用操作集合随即为空。保存/另存又必须调用 WebKit 获取正文，因此无法直接导出仍在 Swift 内存中的内容。
- 影响：界面提示“内存中的文本仍保留”，但缺少实际抢救入口；关闭时依然面对保存或丢弃选择。尚未传到 Swift 的最后一段输入是否可恢复不能保证。
- 代码：`NativeOffice/Workbench/FWTextContent.swift:23`、`:231`、`:267`、`:338`、`:349`。宿主重载仅在保存冲突分支出现：`FWDocumentHost.swift:234`；该重载读取磁盘，不能替代草稿恢复。

建议：提供不依赖 WebKit 的“另存内存草稿”；保留最后确认收到的文本及版本号，再从 session 重建 WebView。故障信息应说明恢复范围，避免暗示所有输入都一定安全。

验收：已修改文档模拟内容进程终止后，仍可将已同步草稿写入新文件；取消关闭不丢草稿；恢复编辑后保存与撤销状态符合定义。

### R3 · P2 · 目录重命名没有同步管理根、历史和展开路径

**当前状态：已统一重命名与移动后的路径同步，并补状态层回归；最终安装包已通过实际右键重命名、历史导航和正常重启恢复验收，见第 10 节。以下保留审查基线的问题证据。**

- 触发：同时管理父目录和其中的 `Old` 子目录，浏览 `Old/Child` 后返回父目录，将 `Old` 重命名为 `New`。
- 原因：重命名成功仅执行 `refresh()`。拖动移动已经实现的路径重映射，没有被重命名复用。
- 影响：文件列表显示 `New`，管理根仍包含 `Old`；后退可能进入不存在的旧路径，显示“目录暂时不可用”。
- 代码：`Sources/FileWorkbench/ContentView.swift:618`、`:635`；`Sources/FileWorkbench/BrowserStore.swift:635`、`:642`。

最小探针执行与成功回调等价的“磁盘重命名 + refresh”：列表为 `[New]`，管理根仍含 `Old`，历史保留 2 条旧路径、展开状态保留 1 条旧路径，`goBack()` 后为 `.unavailable`。

建议：将重命名和移动成功统一表示为 `(source, destination)`，集中更新管理根、导航、展开、选择与书签；同步评估已打开编辑会话的路径提示。已存在的拖动移动映射可复用。

验收：重命名含多层子目录及嵌套管理根的目录后，侧栏、后退/前进、展开、重启恢复全部使用新路径；失败时保留原状态。

### R4 · P2 · 编辑器源码与打包资源缺少一致性门禁

**当前状态：已补齐输入/输出摘要及只读重建比较，并补回归，见第 12 节。以下保留审查时的校验缺口。**

- 触发：修改 `EditorAssets/src` 或依赖锁后，遗漏手工运行编辑资源构建，直接构建原生应用。
- 原因：默认构建只调用原生构建/打包；资源 manifest 有输出摘要和依赖锁摘要，但没有源码输入摘要，原生校验也未检查依赖锁摘要。
- 影响：构建成功及资源校验通过，仍可能交付旧 JavaScript/CSS/HTML 行为。
- 代码：`scripts/build-app.sh:43`；`EditorAssets/build.mjs:37`；`scripts/onlyoffice/native_sources.py:143`、`:167`、`:177`。

隔离验证：将资源副本 manifest 的 `dependenciesLockSHA256` 改为 64 个 `0`，调用 `verify_editor_bundle` 仍通过。副本位于临时目录，没有修改仓库资源。

建议：manifest 记录源码、构建脚本和 lock 摘要；原生构建检查输入与产物一致性；发布流水线从锁文件重建资源并比较差异。继续允许消费者直接使用已提交的离线资源，不要求运行应用时安装 Node。

验收：只改源码不构建、只改 lock、不匹配 manifest、遗漏资源，均应阻止发布或明确要求重建；正常离线资源复制仍通过。

### R5 · P2 · 打包入口没有统一执行完整工作台内容校验

**当前状态：打包入口已统一检查源应用与最终暂存应用，失败保留原发布入口；回归及真实应用副本验证见第 12 节。以下保留审查时的门禁缺口。**

- 来源检查只要求指定可执行文件存在及 CEF 目录存在。打包后运行签名校验，随后替换目标应用。
- `--package-only` 跳过原生构建中的部分架构和编辑资源验证。
- 现有独立 `verify_bundle.py` 有 Office 资源/架构检查，但必需清单尚未覆盖 `FileWorkbenchEditors`；打包入口也没有统一调用这些检查。
- 代码：`scripts/onlyoffice/package_app.py:39`、`:96`、`:101`；`scripts/build-app.sh:43`；`scripts/onlyoffice/verify_bundle.py:35`；`scripts/onlyoffice/native_sources.py:167`。

影响：漏拷贝本地文本编辑器资源、输入旧上游包等问题，不能仅靠重新签名发现。源码构建通过、签名通过、包内功能齐全应分别验证。

建议：在暂存应用替换目标之前，统一检查 Office 内核/模板、本地编辑资源、架构、构建标识和资源摘要；运行验收作为后续发布步骤。记录源码提交与最终产物摘要。

验收：分别删去一个必需编辑资源、模板或内核文件，打包失败且原应用保持原样；正常 `--package-only` 也经过相同门禁。

### R6 · P2 · PDF 变换可能产生当前保存层无法保存的结果

**状态：边界风险，未执行超过 256 MiB 的大文件实验。**

- 触发：合并多份各自低于 256 MiB 的 PDF，或追加多张图片后，输出超过 256 MiB。
- 原因：每份输入有大小上限，`FWBinaryState.transform/replace` 接收结果时没有输出上限检查；PDF 序列化只检查非空。后续保存层统一拒绝大于 256 MiB 的数据。
- 影响：结果先成为当前编辑状态，随后普通保存、另存及保存同样 PDF 数据的导出都失败。现有撤销仍可回退，因此不能描述为已经丢失原文件。
- 代码：`NativeOffice/Workbench/FWBinaryState.swift:27`、`:35`、`:55`；`NativeOffice/Workbench/FWPDFContent.swift:149`；`Sources/FileWorkbench/MediaOperations.swift:181`；`Sources/FileWorkbench/SafeFileIO.swift:53`、`:77`。

建议：替换编辑缓冲区前校验统一输出上限；批量输入增加累计内存预算；超限时保留原状态并说明可拆分处理。不要仅提高保存阈值而忽略内存峰值。

验收：通过可注入的小阈值验证变换超限后原缓冲区、撤销、脏状态均不变，再做真实大文件压力验证。

### R7 · P2 · 查找菜单没有按文档实际能力启用

**状态：代码确认。**

- CSV 没有实现 `find()`，沿用协议的空实现；菜单只检查“有原生文档且不忙”，仍显示可用。
- 图片及其他未实现查找的原生内容也应按能力处理；撤销/重做的菜单启用条件同样较粗。
- 代码：`NativeOffice/Workbench/FWNativeContent.swift:21`；`NativeOffice/Workbench/FWWorkbenchCoordinator.mm:455`、`:462`；`NativeOffice/Workbench/FWDocumentHost.swift:407`。

建议：增加 `canFind/canUndo/canRedo` 等实际能力状态，未实现的操作先禁用；CSV 搜索作为单独功能实现，不让菜单点击后没有反馈。

验收：逐种文档、只读/忙碌/有无撤销记录的状态核对菜单；CSV 未实现查找前应禁用，实现后应有定位与未命中反馈。

## 3. 性能与结构优化

### O1 · P2 · CSV 单格编辑扫描和序列化全表

`CSVDocument.setCell` 校验全表，随后 `FWCSVContent.mutate` 调用 `serialize` 再次校验并生成整份文本，最终 `reloadData()` 刷新表格。原生控制器在主线程执行这条链路。

代码：`Sources/FileWorkbench/CSVDocument.swift:81`、`:161`、`:289`；`NativeOffice/Workbench/FWCSVContent.swift:197`、`:278`。

本机 `swiftc -O` 探针，10 列、每格单字符，每档连续修改 5 次；计时只包含 `setCell + serialize`，不包含 UI、撤销和整表刷新：

| 行数 | 单元格数 | 输入字节 | 中位耗时 |
| --- | ---: | ---: | ---: |
| 1,000 | 10,000 | 20,000 | 1.36 ms |
| 10,000 | 100,000 | 200,000 | 13.72 ms |
| 100,000 | 1,000,000 | 2,000,000 | 139.26 ms |

这些输入仍在公开编辑上限内。数据说明成本随表格规模增长，不是生产设备的统一性能保证。

建议：缓存每行序列化长度并维护总字节数；单格修改只校验受影响字段/行；延迟完整序列化到保存或必要快照；局部刷新行/列；撤销记录优先使用操作差量。保留混合换行、短行字段数、Unicode 字节保真等既有语义。

验收：同一数据集比较修改前后中位数和 P95；补边界长度、撤销、保存期间继续输入的正确性测试，不能用性能改造破坏保存保护。

### O2 · P2 · 文本每次输入回传全文，隐藏 Markdown 预览也重新渲染

`mode=source` 只把预览隐藏，`renderPreview` 仍执行 Markdown 全文转换及 `innerHTML`；每次输入还恢复全篇换行并通过桥接发送完整正文。

代码：`EditorAssets/src/workbench.mjs:72`、`:84`、`:86`；`EditorAssets/src/line-endings.mjs:53`；`NativeOffice/Workbench/FWTextContent.swift:127`。

已有依赖中的 jsdom + 真实 `createWorkbench` 探针确认：111,011 字节 Markdown 在源码模式输入一个字符，隐藏预览重建 1 次，消息正文为 111,012 字节。未把 jsdom 耗时当作真实 WebKit 延迟。

建议按收益分步做：隐藏预览跳过渲染；可见时合并短时间内更新；大文档必要时采用带版本号的增量同步。保存、关闭和故障恢复必须保留完整快照确认，避免节流导致最后输入未保存。

### O3 · P2 · 图片重复解码、PDF 多行高亮反复处理整份文档

- 图片打开先在后台验证解码，随后主线程再次解码；旋转/裁剪/缩放同步生成 PNG，再解码显示。
- PDF 多行选区每一行都重新解析并序列化整份文档；之后还要安装/刷新展示文档。
- 撤销保留整份数据，固定次数不能代表固定内存上限。

代码：`NativeOffice/Workbench/FWImageContent.swift:46`、`:120`、`:148`；`NativeOffice/Workbench/FWPDFContent.swift:113`；`Sources/FileWorkbench/MediaOperations.swift:127`。

建议：复用初次解码结果；重变换放入有状态保护的后台任务；在同一 PDF 模型上批量添加高亮，只序列化一次；撤销历史同时设定字节预算。使用目标系统上可行的图像跨任务传递方式，不简单取消主线程隔离。

验收：高像素图片、多页 PDF 和多行高亮，记录主线程最长阻塞、峰值内存、撤销正确性。当前只有代码成本依据，尚无 GUI 性能基准。

### O4 · P2/P3 · 大目录重复筛选、选择恢复和树枚举

- `visibleEntries` 每次计算重新过滤，排序也重复执行。
- 保存/恢复多选时，每个选中项反复线性扫描目录，约为 `O(n × m)`，且在 `@MainActor` 上执行。
- 刷新重新枚举曾加载过的树节点，包括已收起目录；后台旧任务仅丢弃结果，没有合并重复 I/O 或限制并发。

代码：`Sources/FileWorkbench/BrowserStore.swift:132`、`:326`、`:449`、`:453`、`:681`、`:728`。

建议：一次快照建立 URL/文件身份索引，复用可见列表，使选择恢复接近 `O(n+m)`；只刷新受影响或可见分支，合并相同 URL 的请求。不要因为代码文件较长就一次性拆散所有逻辑：先把文件操作、工作区持久化、目录加载职责拆到有清晰边界的组件。

验收：万级目录全选、刷新、关闭预览恢复、多次快速切目录和慢卷场景；同时核验硬链接身份歧义及过期结果保护。当前未测得这条路径的实际延迟，不给出虚构性能数字。

## 4. 功能缺口与产品候选

以下与前面的缺陷区分：README 对不少边界已有说明，不能把它们直接认定为未兑现的承诺。

| 编号 | 功能 | 当前实现/缺口证据 | 建议与验收重点 | 优先级 |
| --- | --- | --- | --- | --- |
| F1 | 多选移到废纸篓 | 列表右键选择集合只取首项；`ContentView.swift:351`、`:600`、`:643`。复制和内部拖动已支持多项 | 冻结 N 项及身份、显示数量、汇总部分失败；若暂不支持，应明确操作只针对一项 | P2 |
| F2 | 外部文件变动自动同步 | 前台事件仅处理本应用拖出；没有普通目录监听。`ContentView.swift:53`、`BrowserStore.swift:585` | Finder 普通新增/删除/改名后自动反映；先做前台变化检查，再按需增加防抖监听，保护当前选择 | P2/P3 |
| F3 | 非 Office 草稿持久化与崩溃恢复 | 文本、CSV、PDF、图片当前主要保留内存状态；正常关闭提示不能覆盖崩溃/断电。`TextDocumentSession.swift`、`FWBinaryState.swift` | 定期保存独立恢复副本，下次启动让用户选择恢复；明确清理策略和存储上限。Office 内核恢复能力需另查，不作全应用一概而论 | P2 |
| F4 | 文件操作进度、取消、撤销 | 整批 `isImporting` 与通用忙碌提示，没有数量/字节进度及用户取消。`BrowserStore.swift:620`、`:941` | 先实现已完成数量、当前文件和失败详情；再补取消及残留清理，分别定义移动/复制/废纸篓撤销 | P2/P3 |
| F5 | 递归名称搜索和内容搜索 | 只过滤当前目录文件名，README 已明确。`BrowserStore.swift:132` | 根据资料检索需求再引入递归/内容索引；可取消、可限定目录、排除大目录与包，不默认全盘扫描 | P3 |
| F6 | 预览直接进入对应编辑器 | 弹窗主要提供文本编辑；Office/CSV/PDF/图片完整编辑走“打开文件”，README 已说明 | 可考虑统一“编辑”入口，根据能力进入现有宿主；保留未保存确认和返回目录状态，不必重新造编辑器 | P3 |
| F7 | CSV/TSV 表格效率 | 缺 CSV 查找；TSV 目前按文本路由，CSV 模型支持 Tab。`FWCSVContent.swift`、`FileCapabilities.swift:143` | 先补搜索定位、表格区域复制粘贴，再评估排序/过滤；TSV 默认分隔符与另存格式应一致。菜单空操作先按 R7 修正 | P2/P3 |
| F8 | 图片查看与 PDF 进阶操作 | 图片 `.scaleNone` 原尺寸显示；PDF 表单/既有批注编辑被禁用，锁定 PDF 直接拒绝。`FWImageContent.swift:68`、`FWPDFContent.swift:199`、`MediaOperations.swift:34` | 图片优先适应窗口/缩放，区别于修改实际尺寸；PDF 密码输入、表单填写、批注编辑按需求单独设计和验收 | P3 |
| F9 | Markdown 本地相对资源 | 图片与链接受主动资源限制。`EditorAssets/src/markdown.mjs`、`EditorAssets/src/index.html` | 若项目文档阅读是高频场景，可增加授权目录内的相对图片；校验真实路径、符号链接越界及类型，不能直接放开任意文件或远程资源 | P3 |

目前不应当列为“缺少”：Office 三格式基本编辑、文本查找替换、CSV 行列编辑、文档撤销重做、保存冲突保护、真实新建模板、Finder 双向拖放和复制粘贴，这些已有实现。具体兼容性仍以对应验收场景为准。

## 5. 构建、发布与维护建议

### 5.1 建立分层 CI，发布测试不得因条件缺失而静默跳过

仓库没有发现已跟踪的 CI 配置。现有测试入口比较丰富，但依赖人工执行；新克隆未获取上游源码时，部分补丁/工程接线测试会跳过。

建议分三层：

1. 普通代码回归：Swift、Node、Python；区分需要 macOS 图形/系统服务的测试与纯模型测试。
2. 固定上游集成：获取锁定源码，验证补丁重复应用、Swift 工程接线、资源构建输入一致性。
3. 最终应用发布：静态内容/架构/签名核验、压缩帮助与词典真实读取、离线打开编辑保存重开、退出链和最终 ZIP 核验。

本轮两个 Hunspell 测试因默认库路径不存在而跳过。发布阶段应显式设置 `FW_HUNSPELL_TEST_LIBRARY`；现有逻辑对显式指定但缺失或能力不足的库会失败，能避免将跳过误当验收成功。见 `Tests/BuildToolsTests/test_compress_dictionaries.py:201`、`:225`、`:256`。

### 5.2 记录构建来源，收紧内核复用条件

上游 HEAD 有检查，但没有完整排除未登记的工作区修改；复用内核主要判断目录存在；二进制内容锁未覆盖全部依赖，部分工具锁还位于被忽略的 `build/` 中。

证据：`scripts/onlyoffice/common.py:37`；`scripts/onlyoffice/build.py:88`；`scripts/onlyoffice/binary-dependencies.lock.json:3`；`docs/onlyoffice-build.md:33`。

建议记录上游 SHA、项目补丁摘要、工具链版本、核心依赖哈希及源码提交；复用前校验，允许明确登记的补丁/生成文件。补齐可重复获取的工具锁。没有做线上依赖版本或漏洞核验，本报告不宣称依赖存在已知漏洞。

### 5.3 正式分发与文档状态

- 当前构建脚本使用临时签名，README 明确未完成 Developer ID 签名和公证；正式分发前需补齐这条链路。App Sandbox 未启用本身不等于缺陷，是否采用应由分发方式和目录访问设计决定。
- 审查时 README 已记录 v0.1.2 构建 5，而欢迎页验收仍保留构建 4 的阶段描述，实施状态的交付与计数也较旧。本轮已在 [实施状态](implementation-status.md) 区分当前本机构建 6、公开构建 5 和历史证据；欢迎页文档仍作为对应构建的专项记录。
- 建议版本索引统一记录版本/构建号/源码 SHA/包摘要/验证矩阵。涉及最终产物的结论不能仅沿用旧构建报告。
- 目前本地验收详情大量位于被忽略的 `build/`；可提交脱敏的小型验证汇总，使其他开发者无需访问作者电脑即可理解发布依据。

审查阶段没有修改发布状态文档，也没有重新核验线上下载或本机安装包。后续本机状态更新见第 10 节；线上下载仍不在本次验收范围。

## 6. 审查阶段验证结果与边界

环境：macOS 14.7.2、ARM64、Swift 6.0.3、Python 3.9.6、Node 22.22.2。

| 验证 | 本轮结果 | 边界 |
| --- | --- | --- |
| Swift 全套测试 | 137 项通过，0 失败 | 首次受限沙箱出现 16 个失败断言，涉及剪贴板、拖动提供器、HEIC、窗口；在允许系统服务的环境重跑同一套后全部通过，没有改代码或跳过断言 |
| Python 构建测试 | 139 项：137 通过，2 跳过 | 缺少默认路径真实 Hunspell framework，两项不是通过 |
| Node 编辑器测试 | 22 项通过 | 直接运行 `node --test`，没有执行 npm test 前置的资源重建；不能据此证明源码与已打包 JS 一致 |
| JPEG 重编码探针 | 数据变化和 TIFF 属性丢失已复现 | 调用真实底层图片代码，未操作完整 GUI |
| 目录重命名探针 | 旧根/历史/展开路径残留已复现 | 执行状态层等价路径，未自动点击重命名面板 |
| CSV 性能探针 | 100 万格单次修改+序列化中位数 139.26 ms | 优化编译，5 次样本，不含 UI |
| Markdown 隐藏预览探针 | 隐藏预览仍重建且全文回传 | 使用 jsdom，不代表 WebKit 实际延迟 |
| 编辑资源校验探针 | 错误依赖锁摘要未被拒绝 | 隔离资源副本，未修改当前 bundle |

可重跑的常规入口：

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox --cache-path "$PWD/.build/cache"

python3 -B -m unittest discover -s Tests/BuildToolsTests -v

(cd EditorAssets && node --test tests/*.test.mjs)
```

三套常规测试的原始日志（含 Swift 首轮沙箱日志）、CSV/JPEG 探针源码及输出放在本机 `build/code-review-2026-10-25/`，该目录被 Git 忽略；其余探针的关键结果已写入本报告，未承诺保留临时脚本。报告结论不依赖临时目录存在。

审查阶段未重建完整 ONLYOFFICE 应用，也未重跑真实 WK/原生宿主；后续源码验证见第 9 节，最终安装包的 Office 三格式及 R1–R3 界面验收见第 10 节。最终 ZIP、首次授权、拔盘、中文输入法、多显示器、VoiceOver 和另一台机器仍未重新验收。历史报告可作为定位线索，不能替代这些场景的当前验证。

## 7. 建议实施批次与完成标准

| 批次 | 内容 | 完成标准 |
| --- | --- | --- |
| A：先保住内容 | R1 图片保存保真、R2 WebKit 草稿恢复 | 数据保真回归和真实故障恢复场景通过 |
| B：统一状态与能力 | R3 重命名、R7 菜单能力、F1 多选删除 | 文件操作后的根/历史/选择一致；菜单与实际功能一致 |
| C：发布可验证 | R4/R5 资源与打包门禁、分层 CI | 漏资源/旧资源/缺真实测试依赖时不能发布 |
| D：大文件可用性 | O1–O4、R6 输出预算 | 用同一数据集记录耗时和内存改善，原有保存与撤销语义保持 |
| E：高频功能补齐 | F2/F3/F4，随后按需求选择 F5–F9 | 明确产品范围、交互和异常路径，再进入实现 |

建议先做 A、B、C，不为增加功能数量而立即扩展复杂 PDF 编辑、全盘内容索引或更多 Office 格式。

## 8. 待确认信息与参考依据

下列信息影响后续优先级，不阻塞本次审查交付：

| 待确认项 | 影响 | 建议来源 |
| --- | --- | --- |
| 最常用文件类型、目录条目数、图片/PDF/CSV规模 | 决定性能优化及功能先后 | 实际工作样本，避免使用敏感原件做探针 |
| 图片保存是否必须保留 EXIF、色彩信息和拍摄元数据 | 决定保存/导出契约 | 产品约定及代表性图片 |
| 草稿恢复覆盖范围、存储周期和容量预算 | 决定恢复文件格式及清理策略 | 使用者偏好与故障演练 |
| 近期仅预览版分发还是正式对外分发 | 决定签名、公证及发布 CI 优先级 | 发布计划 |
| CSV 搜索/批量粘贴、相对图片、PDF 表单是否为刚需 | 避免无依据扩大产品范围 | 高频工作流程 |

仓库依据：[README](../README.md)、[实施状态](implementation-status.md)、[原生集成](native-integration.md)、[构建说明](onlyoffice-build.md)、[模态预览验收](modal-preview-acceptance.md)、[欢迎页验收](welcome-ui-acceptance.md)。正文代码行号均基于审查提交，后续修改后应重新定位。

已读取的项目笔记仅用于了解历史适用范围，没有把其旧验证结果计入本轮测试，也未回写 Obsidian：

- [文件夹拖出时序与安装验收](/Users/jiangpeng/Desktop/项目知识库/Codex/FileDeck/2026-10-25-文件夹拖出时序与安装验收.md)
- [欢迎页自适应与窗口尺寸](/Users/jiangpeng/Desktop/项目知识库/Codex/FileDeck/2026-10-25-欢迎页自适应与窗口尺寸.md)

## 9. 优先问题修复与回归（2026-10-25）

适用范围：本节记录基于上述审查提交的源码修复阶段。此阶段测试不能单独证明应用包包含修复；后续安装产物及界面验收见第 10 节。此次仅处理 R1–R3，R4–R7 及功能候选保持未完成。

### 9.1 实现行为

| 问题 | 修复后的行为 | 主要源码 |
| --- | --- | --- |
| R1 JPEG 保存保真 | 未编辑的 JPEG/PNG 普通保存及同格式另存直接复用原始字节，仍执行冲突检查与原子写入。已编辑 JPEG 保存后缓存实际写出字节，按输入快照和输出格式命中；后续未改动保存不再编码。导出副本不覆盖当前文件缓存，保存期间新编辑仍保持未保存状态。 | [FWImageContent.swift](../NativeOffice/Workbench/FWImageContent.swift)、[FWBinaryState.swift](../NativeOffice/Workbench/FWBinaryState.swift) |
| R1 变换元数据 | 旋转、裁剪、缩放的 PNG 中间快照及最终编码迁移可用标准元数据，方向归一为 1，更新 EXIF 尺寸；清理失效坐标、私有 MakerNote 及编码相关字段。 | [MediaOperations.swift](../Sources/FileWorkbench/MediaOperations.swift) |
| R2 WebKit 故障恢复 | 故障时关闭普通保存，提供“另存内存草稿…”和“恢复编辑器”。另存直接使用 Swift 已同步正文，默认副本名加“恢复草稿”；重建保留正文、磁盘指纹和实际保存基线。旧 WK 消息与迟到回调不能污染新实例。 | [FWTextContent.swift](../NativeOffice/Workbench/FWTextContent.swift)、[TextDocumentSession.swift](../Sources/FileWorkbench/TextDocumentSession.swift)、[FWDocumentHost.swift](../NativeOffice/Workbench/FWDocumentHost.swift) |
| R2 写盘后桥接失败 | 磁盘写入成功后，若网页保存确认失败，仍报告实际写盘成功，并单独进入可恢复的编辑器故障态；后续已同步的新输入不会被误标为已保存。普通加载无需重复传输保存基线，仅草稿与基线不同时补发。 | 同上 |
| R3 目录重命名 | 重命名与移动共用路径提交，更新管理根、当前目录、导航历史、展开、多选、选择锚点、书签及树缓存；保留原 security-scope lease，并阻止旧恢复请求覆盖新路径。与已失效目标根发生路径合并时，管理根保序去重，真实迁移对象的书签、授权和历史根归属优先。失败不修改工作区，完成后不抢回操作期间切换的目录。 | [BrowserStore.swift](../Sources/FileWorkbench/BrowserStore.swift)、[ContentView.swift](../Sources/FileWorkbench/ContentView.swift) |

JPEG 边界：未编辑时保留全部原字节；真实变换仍需有损编码 JPEG，只承诺迁移 ImageIO 支持的标准描述/拍摄信息，不承诺保留任意 XMP、厂商私有数据或原色彩配置。回归验证了中文 TIFF 作者/描述、EXIF 时间、GPS、方向与尺寸。本机 ImageIO 生成中文 EXIF UserComment 样本时已出现损坏，因此该字段使用先验证原值的 ASCII 样本，避免把样本生成问题归因于保存代码。

恢复边界：只覆盖 WebKit 内容进程故障后、仍存活的 Swift 会话；最后尚未同步的输入和原 WK 撤销历史无法保证恢复。不包含应用退出、主进程崩溃或机器重启后的持久草稿恢复。

目录边界：本次同步的是浏览工作区及持久化书签。独立编辑会话仍按原文件快照执行冲突保护，没有新增跨标签跟踪外部重命名的能力。真实授权面板授予的 security-scope lease 续用、首次授权和拔盘场景仍需专项验收。

### 9.2 回归覆盖与结果

- [MediaContentRegression.swift](../NativeOffice/Tests/MediaContentRegression.swift)：未编辑 JPEG/PNG 原字节保存与同格式另存、编辑后重复保存、格式导出后保存、方向/元数据、外部冲突、保存期间继续编辑；保留既有 CSV/PDF/HEIC 回归。
- [MediaOperationsTests.swift](../Tests/FileWorkbenchTests/MediaOperationsTests.swift)：旋转、裁剪、缩放经 PNG 快照再输出 JPEG 的元数据与尺寸。
- [BrowserRenameTests.swift](../Tests/FileWorkbenchTests/BrowserRenameTests.swift)：嵌套管理根、历史/展开/选择、祖先改名、重新创建 store 恢复书签、同名拒绝、过期文件身份、操作期间导航，以及目标路径已有失效管理根时的去重与书签/导航归属。
- [test-modal-documents.swift](../scripts/test-modal-documents.swift)：真实 WK 输入，公开进程终止委托注入，取消关闭、目标冲突、恢复 dirty 基线、新实例继续编辑、旧回调隔离、移除网页 API 后真实另存、释放视图，以及写盘后 JS 确认失败。
- [test_native_content.py](../scripts/onlyoffice/test_native_content.py)：保留原生媒体断言输出，测试失败时返回非零退出码，避免仅显示子进程异常而隐藏失败原因。

修复前反例：JPEG 新增原字节断言在旧实现失败；目录旧成功回调的等价实现触发 19 个状态断言失败；WebKit 旧实现无法在故障后提供草稿另存。失败证据已保留，未用跳过断言使其通过。

| 收尾验证 | 结果 | 范围与限制 |
| --- | --- | --- |
| Swift 全套 | **144 项通过，0 失败** | 最终 R3 碰撞修复后重跑；含新增 6 项目录重命名回归和 1 项图片元数据回归 |
| 原生媒体/CSV 会话 | **8 组通过** | 真实 ImageIO、文件系统与原生控制器；未操作完整应用图片工具栏 |
| WebKit 故障恢复专项 | **12 项通过** | 真实 WK 输入和重建、NSAlert、文件写入；终止通过公开委托回调注入 |
| 原生宿主完整脚本 | **44 项通过** | 所有 Swift 原生/浏览 UI 类编译，真实预览、焦点、关闭、保存及冲突链路；此轮先于 R3 失效管理根清理，后者由最终 Swift 全套覆盖 |
| Python 构建工具 | **139 项：137 通过、2 跳过** | 两项需要默认路径中已构建的真实 Hunspell framework，缺失项不算通过 |
| 差异与文档链接检查 | **通过** | `git diff --check` 无异常；本文本地链接目标均存在 |

Node/编辑资源构建在源码修复阶段未重跑，因为没有修改 JavaScript 或打包资源；第 6 节的 22 项属于审查阶段结果。本节测试当时尚未重建完整 ONLYOFFICE 包、替换已安装应用或运行最终 Office 三格式验收；这些后续动作见第 10 节。

可重跑命令（macOS，涉及 AppKit/WebKit/ImageIO 的测试需要允许访问系统服务）：

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox --cache-path "$PWD/.build/cache"

python3 -B scripts/onlyoffice/test_native_content.py
FW_MODAL_DOCUMENT_TEST_CASE=webkit-recovery bash scripts/test-modal-documents.sh
bash scripts/test-native-hosts.sh
python3 -B -m unittest discover -s Tests/BuildToolsTests -v
```

源码阶段恢复专项通过显式测试路径执行真实文件 I/O，并单独验证按钮派发。最初尝试真实 NSSavePanel，面板出现且“恢复草稿”默认文件名正确，但自动确认超时（包括 AppKit `ok` 动作阻塞）；独立 watchdog 结束了该次测试进程，因此该阶段未将系统面板确认计为通过。后续第 10 节通过外部辅助功能操作真实系统按钮补验，生产保存流程没有替换为测试捷径。故障仍通过公开委托回调注入，不代表系统级进程 kill。

原始回归日志与反例汇总位于本机 `build/priority-fixes/`（Git 忽略），真实 WK/宿主的报告另位于各脚本输出的 `build/*-tests/run.*/fixtures/report.json`。源码、断言及此汇总可纳入版本管理，结论不依赖临时日志可访问。

收尾采用 simplify Standard / bugfix，复核 blast_radius、repo_fit、quality、efficiency。独立交叉检查促成了普通加载去掉重复全文桥接，以及重命名撞上失效管理根时的路径/书签去重；调整后分别重跑 WebKit 专项与完整 Swift 回归，未遗留必修项。

变更影响：修改本地保存、恢复及浏览状态代码和对应测试；无 SQL、数据库、配置迁移、中间件或对外 API 变更。源码修复阶段未替换安装包；后续安装见第 10 节。未提交 Git、未发布应用，撤销源码修改不涉及数据迁移。

## 10. 本机安装与验收（2026-10-25）

本节保留发布前的安装阶段快照。提交、公开发布与旧应用清理以第 11 节为当前结论；第 10 节所记旧版备份路径已不再作为有效回退入口。

### 10.1 概述与验收结论

**最终 v0.1.2 构建 6 已安装至 `/Applications/FileDeck.app`，R1 JPEG 保存、R2 故障草稿真实另存、R3 重命名及工作区重启恢复全部通过。** 本次验证实际运行已安装二进制，包含外部 AX 操作真实系统面板、文件字节/身份复核和独立 suite 重启；最终包的 Office 三格式、混合文档及退出链也已通过，进程正常退出 0。

本次工作基于 `00a4d5eb2ec44f73687650afc53a231f3337b87d` 及未提交修改。未执行 Git commit、push、公开 Release 或上传下载包；[README](../README.md) 的公开下载仍为 v0.1.2 构建 5。本节不改变公开发布状态。

| 最终产物登记 | 当前记录 |
| --- | --- |
| 版本 / 构建 / 安装路径 | v0.1.2 / 6 / `/Applications/FileDeck.app` |
| 最终构建 / 安装时间 | 2026-10-25 14:11:14 / 14:11:37（Asia/Shanghai）；`build-result.json`、`installation.json` |
| 源码输入 SHA-256 | `61ca31bd5742dced3cdb12157926f1fb2f41ec0a7977e7b1c980f3acdcd9a7af` |
| 安装后主程序 SHA-256 | `676762a23f681c6cf2ad41e10dacc62ec142e7dce866bcfb8eb76106fa1d89e2`，与最终构建一致 |
| 完整内容清单 SHA-256 | `d35b2228dcd24357ea7c82ebfc9efcbed3b355f04285d7ece21830506ca4b185`；5,649 个普通文件、124 个符号链接，安装后全清单比对与签名验证通过 |
| 本次正式回滚基线 | `build/previous-apps/FileDeck-before-priority-fixes-20261025-135754.app`，原安装 v0.1.2 构建 4，必须保留 |
| 最终安装时另存的中间构建 6 备份 | `build/previous-apps/FileDeck-before-priority-fixes-20261025-141129.app`；此备份不能替代上述构建 4 回滚基线 |

本机证据统一放在 `build/priority-fixes-install/`（Git 忽略）。`source-receipt.json` 记录编译输入，`app-content-manifest.json` 记录包内文件/链接，`bundle-verification.json` 记录静态检查，`installation.json` 记录实际替换与备份。重新构建会更新部分文件，应先归档上一阶段记录，再登记最终摘要。

### 10.2 部署前准备与环境依赖

1. 在 macOS 14.7.2 / ARM64 本机操作，使用既有 Xcode、Swift 6.0.3、Python 3.9.6 和已构建的 ONLYOFFICE/CEF 依赖；本轮完整应用按 `Debug` 配置构建，保留临时签名，不视为 Developer ID 公证分发包。
2. 正常保存并退出正在运行的 FileDeck，确认 `/Applications/FileDeck.app/Contents/MacOS/FileDeck` 已结束。不得直接覆盖在用应用或强制丢弃用户文档。安装需要 `/Applications` 写权限及足够空间保存新包、暂存包、原构建 4 和中间构建 6。
3. 核对固定构建 4 备份仍存在、版本正确且签名可验证；检查当前源码输入收据、完整包清单和静态校验结果对应同一构建。
4. GUI 验收仅使用 `build/priority-fixes-install/ui-fixtures/` 内生成的图片和目录样本。先记录原字节、inode、mtime 和嵌套文件哈希；外部 AX/CGEvent 操作限定已授权的 FileDeck 测试进程和当前实际界面。
5. 最终工作区验收设置 `FW_WORKBENCH_TEST_SUITE=local.fileworkbench.ui-test-<UUID>`，跨重启使用相同 suite。Office smoke 使用本次私有目录和独立 profile；仅设置 `CFFIXED_USER_HOME` 不作为 SwiftUI/BrowserStore 已隔离的充分证据。正式日常启动不设置测试变量，也不使用 `--open` 验收持久恢复。

### 10.3 SQL、配置与中间件变更

| 类别 | 本轮处理与执行时机 |
| --- | --- |
| SQL / 数据库 | 无业务 SQL、数据库结构或数据迁移，无安装前后脚本 |
| 正式配置 | 无用户配置迁移，继续使用既有 bundle ID `local.fileworkbench.desktop`；不覆盖用户文档与偏好文件 |
| 验收配置 | 显式启用上述独立测试 suite；恢复面板流程仅由 `--recovery-panel`、私有目录/令牌及期限门禁启用；验收结束正常退出，日常启动不携带这些变量 |
| Redis / MQ / 外部中间件 | 无变更；CEF、ONLYOFFICE 及离线资源继续随应用打包，无服务端部署或兼容性切换 |

### 10.4 构建与安装顺序

1. 记录源码输入与未提交差异，按锁定上游执行原生构建，再打包 v0.1.2 构建 6：

   ```bash
   python3 -B scripts/onlyoffice/build.py --phase app --configuration Debug --jobs 4
   python3 -B scripts/onlyoffice/package_app.py --configuration Debug --version 0.1.2 --build-number 6 --compress-offline-resources
   ```

2. 对新 `build/FileDeck.app` 完成 ARM64、资源、包内链接、动态库和深度严格签名检查，生成该包的完整内容清单。检查失败时不进入安装步骤。
3. 确认旧进程已正常退出，运行本次本机安装工具 `python3 build/priority-fixes-install/install-local.py`。工具先复制到 `/Applications` 暂存包，逐文件核对哈希/模式/链接并验签，再将旧应用移入 `build/previous-apps/`，替换安装位置；替换后再次检查，失败则恢复本次刚移出的旧包。该工具是本机 ignored 验收产物，不是公开安装器。
4. 登记最终 `installation.json` 的安装时间、旧包备份路径和主程序摘要；与构建清单比对。此次若备份的是中间构建 6，应另行保留固定构建 4 基线。
5. 从 `/Applications/FileDeck.app` 启动最终二进制，按下表依次验证；所有 GUI/重启证据必须关联本次最终安装摘要。最后正常退出测试进程，再按日常方式启动。

### 10.5 验证矩阵与证据

| 项目 | 操作与通过标准 | 当前状态 / 证据 |
| --- | --- | --- |
| 最终包身份 | 安装路径、版本、主程序 SHA-256、完整文件/链接清单、深度严格签名均与最终构建一致 | **通过**；最终 `build-result.json`、`app-content-manifest.json`、`bundle-verification.json`、`installation.json` |
| Office 与混合文档 | 安装二进制在禁止网络的环境完成 DOCX/XLSX/PPTX 编辑、保存、重开；文本/PDF 菜单路由、关闭/退出取消与放弃正常 | **通过**；`runtime/fw-office-smoke-中文 路径-2wl3utij/verification.json`：`executionVerified=true`、退出码 0 |
| R1 未编辑 JPEG 保存 | 由“打开文件”进入正式图片编辑器，⌘S 后 SHA-256/长度与原件相同，inode 或 mtime 改变；⇧⌘S 经真实系统面板另存新副本，逐字节相同且原件未变 | **通过**；`ui-saved.json`、`ui-save-as.json` 全部检查为 true；基线 `ui-fixtures-baseline.json` |
| R1 旋转与重复保存 | 原样本 96×64、Orientation 6，显示 64×96；点击“右转 90°”后保存为 96×64、Orientation 1、EXIF 尺寸一致，作者/描述/拍摄时间保留；再次 ⌘S 字节不变且存在新写盘证据 | **通过**；`ui-rotated.json`、`ui-repeated.json` 全部检查为 true |
| R2 故障草稿真实另存 | 真实 WK 输入后注入公开进程终止委托；外部取消第一次 NSSavePanel，保留 dirty/原路径/原文件；第二次真实面板保存新副本，正文完整、`lastSavedURL` 与面板 URL 一致、dirty 清除，正常关闭并释放 WK | **通过**；最终 runtime 的恢复流程 11 项布尔检查均为 true；`final-recovery-cancel-ui.json`、`final-recovery-save-ui.json` 记录外部真实 AX 操作对应面板 |
| R3 重命名与运行期状态 | 真实添加父目录、Old 与 Old/Child 为管理根；父目录列表右键重命名 Old→New；嵌套 inode/文件 hash 不变，管理根/展开同步并选中 New；两次后退依次到 New/Child、New，再前进回 New/Child | **通过**；`ui-renamed.json` 12 项为 true，`ui-after-rename.json` 显示选中与新路径，`ui-history-result.json` 三次导航的实际界面与 suite 匹配 |
| R3 重启恢复 | 停在 New/Child，正常退出后用同一 suite、同一最终程序重启；roots/currentPath/activeRoot/expandedPaths 一致，真实窗口显示 Child 与“保留内容.txt”，没有 Old 路径 | **通过**；`ui-restarted-workspace.json` 全部检查为 true，`ui-restarted.json` 与 `manual-ui-session.json` 补充实际窗口和两次启动身份；history/selection 只验运行期 |
| 正式工作区隔离 | 修正为专用 suite 后，最终验收前后正式工作区的 5 个相关偏好键摘要相同；比较基线为 14:05，不追溯首轮验收 | **通过**；`workspace-isolation-verification.json`，未输出原始用户配置 |
| 最终 Python 构建工具回归 | 完整构建工具、suite 门禁、恢复面板校验器与真实 Hunspell 回归 | **146 项通过、0 跳过**；`final-buildtools-tests.log`。第 9 节计数保留为此前源码阶段记录 |

`verify-ui-fixtures.py` 仅读取测试目录和显式指定的隔离 suite，隐藏书签内容，拒绝输出测试目录外的路径。其“未操作 Save”负向对照 `verifier-no-save-negative.json` 已正确失败：字节相同但 inode/mtime 未变，不能冒充实际保存通过。脚本证据需与真实面板/AX 观测配对，不能替代 UI 操作。

最终 Office/R2 运行目录为 `runtime/fw-office-smoke-中文 路径-2wl3utij/`，suite 为 `local.fileworkbench.ui-test-03dadd76-0341-42a9-9f91-0b3553d1fd90`；手动 JPEG/R3 使用 `local.fileworkbench.ui-test-5183d029-0444-46ed-9abf-ff8cb79b65a7`，两次启动均记录同一最终主程序摘要。测试进程已正常退出，`ordinary-launch.json` 与 `ordinary-running-processes.json` 记录不带测试变量的日常启动，并确认仅一个安装包主进程运行；`acceptance-summary.json` 汇总本轮通过结论。

### 10.6 风险与验证边界

- 相同“构建 6”存在多个中间产物，必须以源码输入、主程序和完整清单摘要区分；最终重建后旧报告仅作阶段证据。
- 故障通过公开 WK 委托回调注入，没有执行系统级进程 kill；只恢复存活 Swift 会话中已同步的草稿，不覆盖应用崩溃、重启恢复或未同步输入。
- 图片变换后的 JPEG 仍有一次有损编码，标准元数据保留范围见 9.1；本轮完整应用 GUI 覆盖保存、同格式另存和旋转，未遍历所有图片工具。目录改名不会替独立编辑标签跟踪外部文件改名。首次授权、拔盘、复杂 Office 文档、中文输入法候选窗及另一台机器未因此获得验收结论。
- 最终 smoke 的 `compressedResourcesVerified=false`，没有重跑完整应用压缩帮助/词典专项。最终 Python 回归中的两项真实 Hunspell 检查（拼写/建议/用户词一致性与缓冲区末条目）均通过，两者的验证范围不能混用。

### 10.7 可操作回滚

**后续状态更新：用户已要求删除旧应用，本地备份在构建 6 发布后移入废纸篓。以下为安装阶段的历史方案；当前回退改从原 v0.1.2 Release 下载构建 5，见第 11 节。**

正式回滚优先使用固定构建 4 备份，保留其原件。安装工具的异常自动恢复只保证回到“本次安装前”的包，该包可能已是中间构建 6。

1. 先保存或另存当前需要保留的文档，正常退出 FileDeck，确认主进程结束；不要用旧包覆盖仍运行的新包。
2. 在仓库根目录核验构建 4，复制到新的暂存位置并验签；备份缺失或验证失败时停止，不猜测其他包的版本：

   ```bash
   rollback_source="$PWD/build/previous-apps/FileDeck-before-priority-fixes-20261025-135754.app"
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$rollback_source/Contents/Info.plist"
   /usr/bin/codesign --verify --deep --strict "$rollback_source"
   ```

   第一条应输出 `4`。使用 `ditto "$rollback_source" /Applications/.FileDeck-rollback-stage.app` 创建不存在的暂存包，再对暂存包执行同一签名检查；若暂存路径已存在，换一个新的明确名称，不能合并覆盖。
3. 将现有 `/Applications/FileDeck.app` 移到新的 `build/previous-apps/FileDeck-failed-<本次时间>.app`，再将通过验证的暂存包改名为 `/Applications/FileDeck.app`。第二次移动若失败，立即把刚移出的应用移回原安装路径。不要移动或删除固定构建 4 原件。
4. 对恢复后的安装路径再次读取版本并验签，正常启动，检查目录浏览和专用文档打开/保存/关闭。回滚只替换应用，不撤销用户已经保存的文件或磁盘目录重命名；本轮无 SQL、偏好结构或中间件回滚。记录实际恢复路径、时间及结果，保留失败包和日志供追查。

### 10.8 本轮操作检查清单

- [x] 源码修复阶段的测试和能力边界已单独记录在第 9 节。
- [x] 原安装构建 4 已保存在固定回滚路径，中间构建 6 另存备份。
- [x] JPEG 与嵌套目录原始字节、身份基线及验证工具已准备；无业务 SQL、配置迁移和中间件变更。
- [x] 最终独立 suite 包构建/安装完成，源码摘要、完整清单、主程序摘要及中间包备份路径已按 14:11 安装收据登记。
- [x] 最终安装包 Office/R2、R1 JPEG、R3 运行期/重启验证通过，证据与最终主程序摘要对应。
- [x] 最终 Python 146 项全部通过；独立 suite 修正后的最终验收前后，正式工作区 5 个偏好键保持一致。
- [x] 正常退出验收进程，随后执行不带测试环境变量的日常启动，安装版本仍为 v0.1.2 构建 6。

公开发布不在本轮范围内；未 commit、push、上传安装包或修改公开下载。Developer ID 公证、公开 ZIP 和发布说明更新应在独立发布任务中处理。

## 11. 构建 6 发布与旧应用清理（2026-10-25）

本节更新此前本机安装阶段的“未提交、未公开发布”状态。修复、回归及验收文档已提交并推送至 `main`，源码提交为 `e9e0a12393b7f2a533122e7b425c66877d2ff15d`，独立标签为 `v0.1.2-build6`。后续提交仅更新发布文档与 README。

- 发布：[v0.1.2-build6](https://github.com/liuweqwojeo/FileDeck/releases/tag/v0.1.2-build6)，开发预览版。
- 安装包：`FileDeck-v0.1.2-build6-macOS-arm64.zip`，793,603,822 字节。
- ZIP SHA-256：`10747caa0cf8f89251e9e08eefe1c1b1c90f90ac297098220fd7237254a87f0d`，与发布附件 `SHA256SUMS.txt` 对应。
- ZIP CRC、6,877 项解压内容比对、文件字节/权限、链接目标及严格签名通过。仅允许 ditto 对 CEF 单条链接权限的已知规范化。
- 解压应用通过禁网 Office 三格式及混合工作台运行验收，退出 0；最终 ZIP 应用与已安装验收包字节一致，系统面板及 JPEG/目录 GUI 证据沿用第 10 节，不宣称对新副本重复执行了全部界面步骤。

按用户要求，旧本机 FileDeck 应用副本和本轮中间备份移入废纸篓，保留当前安装、最终构建和构建 6 分发副本；用户文档和工作区偏好不属于清理范围。清理清单位于 `build/releases/v0.1.2-build6/old-app-cleanup.json`。

第 10 节构建 4 备份路径保留为历史依据。当前回退顺序：从[原 v0.1.2 Release](https://github.com/liuweqwojeo/FileDeck/releases/tag/v0.1.2) 下载构建 5 ZIP 与校验文件；校验、保存文档并正常退出构建 6；解压替换应用，启动后核对构建号 5。回退不撤销已保存文件及目录改名，无 SQL、配置或中间件回滚。

完整升级及风险说明见[构建 6 发布说明](release-build6.md)。GitHub 附件大小及 SHA-256 与最终 ZIP 一致；本机发布记录位于 `build/releases/v0.1.2-build6/release-after.json`。

## 12. 编辑资源一致性与打包门禁修复（2026-10-25）

本节对应 R4/R5 的后续工作区源码修改，不改变第 11 节已发布构建 6 的下载、校验值及验收结论。本轮没有重新安装或发布应用，无 SQL、用户配置、API 或中间件迁移。

后续进展：第 12 节为源码修复阶段记录；按用户进一步授权执行的构建 7 重建、安装和发布见第 13 节。

### 12.1 编辑资源一致性

- `EditorAssets/build.mjs` 生成 schema 2：覆盖全部 `src/` 输入、构建脚本、package.json、package-lock.json 及五份运行资源摘要；构建前后核对输入快照，变化时拒绝登记产物。
- `native_sources.editor_inputs` 校验准确输入集合、依赖锁摘要、输出清单和文件字节；只改源码/锁/构建规则、增删输入、错误清单、遗漏资源或链接输入均失败，且原生同步前即拒绝。
- `npm --prefix EditorAssets run verify` 在临时目录重建并逐字节比较，失败也不覆盖已提交资源。发布入口 `bash scripts/build-app.sh release` 先执行锁定依赖安装和只读比较，`release --package-only` 同样执行。
- 普通开发构建依靠 Python 摘要门禁，仍能消费已提交且与源码一致的离线资源。Node/npm 是资源构建及发布检查工具，不是应用运行依赖。

### 12.2 统一打包检查

`package_app.py` 在复制前验证源应用，在压缩、去重、重新签名后验证最终暂存应用，二者共用 `verify_bundle`。检查 Office SDK、模板、CEF/内核/Hunspell/辅助程序 ARM64、依赖与包内链接、工作台标识/版本/构建号、本地编辑资源输入及输出摘要和严格签名。最终暂存检查失败时不移走原发布应用，异常回滚继续沿用原事务。

资源优化报告新增 `bundleValidation`，记录检查结果、构建身份、编辑 manifest 和主程序 SHA-256；`runtimeVerified=false`，静态门禁不代替实际文档运行验收。

### 12.3 回归与验证依据

最终结果：**Python 构建工具 155 项通过、0 跳过；编辑资源 Node 测试 23 项通过；只读重建比较通过；真实应用副本正向打包与三类缺资源反例均通过预期断言。** `git diff --check` 和构建入口 shell 语法检查通过。

- Python 覆盖源码/锁/构建规则变更、输入增删及链接、旧/错误 manifest、输出篡改；验证失败发生在同步或发布之前。
- 真实 shell 入口配合隔离工具探针，验证 release 的 `--package-only` 先安装锁定依赖并只读比较，比较失败不执行打包。
- 打包集成回归仅替代系统工具输出，实际执行统一检查器；删除源包/暂存包的编辑资源、Office 模板或内核，复制/优化过程中丢资源，以及错误身份/架构均被拦截，原应用字节保持不变。既有复制、压缩、签名失败及替换回滚测试继续通过。
- 编辑资源 Node 回归在隔离副本修改源码、锁、构建脚本、package.json 和产物，确认 `--check` 拒绝且不回写资源。
- 本机真实应用副本使用真实 `otool/lipo/codesign/ditto` 验证：旧 schema 1 包被拒绝；分别删除编辑脚本、模板、内核均失败且原目标保留；更新资源并重新签名后，源包和最终暂存检查通过、正常打包成功。副本及替换目标只存在于临时验收目录，完成后清理。

本机日志位于 `build/priority-gates/`，真实检查汇总为 `real-package-validation.json`。此轮 JavaScript/CSS/HTML 运行资源及许可文件字节与此前一致，仅清单升级；没有重跑 WebKit/Office GUI，也不将静态通过计为运行通过。

可重跑：

```bash
npm --prefix EditorAssets test
npm --prefix EditorAssets run verify
python3 -B -m unittest discover -s Tests/BuildToolsTests -v
```

### 12.4 清单升级与使用边界

旧 schema 1 应用仍可正常运行，但不能直接通过新门禁。更改编辑输入后先 `npm --prefix EditorAssets run build`，检查并纳入源资源差异，再执行正常原生构建，使新 manifest 与资源复制进应用；之后才能使用 `--package-only`。校验历史应用时，应使用相应源码版本的校验器。

`npm run verify` 使用当前已安装依赖；正式发布入口先 `npm ci --ignore-scripts --no-audit --no-fund`，防止本地 node_modules 偏离锁文件。缺依赖、安装失败或资源不一致会直接终止发布构建。动态库相对路径完整解析、任意 Office 资源语义和文档兼容性仍属于独立验证范围。

## 13. 构建 7 重建与安装验收（2026-10-25）

R4/R5 已按用户要求重新构建为 v0.1.2 构建 7，并安装至 `/Applications/FileDeck.app`；本节更新第 12 节仅完成源码修复的阶段状态。发布使用独立标签 `v0.1.2-build7`，最终公开下载和校验值以 README 及该 Release 登记为准。

- 从 package-lock.json 重新安装依赖后，只读重建比较、23 项编辑资源 Node 测试和 155 项 Python 构建工具测试全部通过，0 跳过。
- 使用 Debug 配置重建原生应用，资源清单已同步为 schema 2，ARM64 和严格签名检查通过；打包明确指定版本 0.1.2、构建 7，并启用既有无损帮助/词典压缩。
- 源应用和最终暂存应用均通过统一门禁；真实副本中分别删除编辑脚本、Office 模板或内核，打包均失败且原目标保留；完整副本正常打包通过。旧 schema 1 源包也被明确拒绝。
- 2026-10-25 16:24 安装完成，5,649 个普通文件、124 个符号链接与构建清单一致，安装后再执行新静态检查通过。
- 安装后真实离线运行验收通过：DOCX/XLSX/PPTX 编辑、保存、重开及混合文本/PDF、菜单保存、关闭/退出保护，进程退出 0。使用独立 profile 与工作区 suite，不使用正式用户文档作为样本。
- 主程序 SHA-256：`3843e38c137fd68a16d6b2b72c1876f62d6677d09b6f795899e3cbd70341ebe9`。
- 编辑资源 manifest SHA-256：`b20c89827accf83bc812d45d67e6683925d8d9fcfaed4f9a7b80ad172d8bfe13`。

本机证据位于 `build/releases/v0.1.2-build7/`：`build-result.json`、`source-inputs.json`、`installation.json`、`real-package-validation.json`、各阶段日志及 `installed-smoke/fw-office-smoke-中文 路径-3spgzhxv/verification.json`。安装后的静态报告为 `build/onlyoffice/build7-installed-verification.json`。144 项源码文件摘要在构建、验收及提交前保持一致；准确提交随包内 SOURCE-CODE.md 提供。

发布前另外核对 ZIP CRC、解压文件字节/权限/链接及严格签名，GitHub 附件大小与 SHA-256 一致后才公开。旧本机应用副本在发布后移入废纸篓，保留当前构建 7，用户文档和偏好不属于清理范围。需要回退时从[构建 6 Release](https://github.com/liuweqwojeo/FileDeck/releases/tag/v0.1.2-build6)下载旧包及校验文件，正常退出新版后替换并核对构建号 6。

无 SQL、用户配置、Redis/MQ、API 或错误码迁移；临时签名、动态依赖解析与运行兼容性边界见[构建 7 发布说明](release-build7.md)。本轮未重复执行构建 6 的所有物理 JPEG/系统草稿面板操作，不将新门禁的静态结果替代这些运行证据。

### 13.1 构建 7 最终发布与清理

修复提交 `e58d73e` 及标签 `v0.1.2-build7` 已推送，预览 Release 已公开；README 下载指向本次 ZIP 与配套 SHA256SUMS.txt。ZIP 为 793,603,803 字节，SHA-256：`c478d8109873333c0c7f3e5f5c6678cd79aef8b9945ea17e6bb508377a522d9a`。CRC、6,877 项解压清单、普通文件字节/权限、链接目标、严格签名均通过；仅 CEF 根链接的已知权限归一差异有单独记录。解压后的应用再次通过新静态门禁与禁网真实运行，退出 0，GitHub 两个附件大小及摘要一致。

发布后已将 5 个构建 6 旧应用副本移入废纸篓，保留构建 7 及历史 ZIP，不清理用户文档或偏好。日常启动已确认运行 `/Applications/FileDeck.app` 的构建 7。清理及发布证据：`archive-verification.json`、`publication-checks.json`、`release-after.json`、`old-app-cleanup.json`、`normal-launch.json` 和 `extracted-smoke/`，均位于本节上述构建 7 证据目录。构建 6 远程 Release 保留用于回退。
