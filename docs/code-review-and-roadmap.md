# FileDeck 代码审查、优化建议与功能缺口

审查日期：2026-10-25（Asia/Shanghai）  
代码基线：`main`，提交 `00a4d5e`；开始审查时工作区干净。  
范围：Swift 浏览及文件操作、原生文档宿主、文本/CSV/PDF/图片编辑、本地 JavaScript 资源、ONLYOFFICE 集成和构建发布脚本。  
交付性质：审查与修复历史。**R1–R7 的历史发布记录见第 9–15 节；O1–O4、F1–F5 及必要基础实现已随本地提交 `58a9310` 保存。常见语言支持、八项交互修复与 F6 统一编辑入口已安装为 v0.1.2 构建11（Release / ARM64），未远程发布。** 当前行为和验证边界见 [实施状态](implementation-status.md) 与 [八项交互修复](interaction-fixes.md)。README 下载链接仍指向构建8。

第 9–24 节保留各轮历史证据、测试计数与当时未完成项，其中“当前检出”“本轮未安装”等仅指对应轮次；不能用旧源码摘要证明今天的文件一致，也不能把历史安装状态当作当前安装。性能基准入口的本轮复核见第 25 节。

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

**当前状态：已补齐编辑缓冲区输入/结果上限、批量累计读取预算及回归，见第 14 节。使用小阈值覆盖真实序列化和状态事务；尚未执行超过 256 MiB 的实机压力测试。以下保留审查基线的风险证据。**

- 触发：合并多份各自低于 256 MiB 的 PDF，或追加多张图片后，输出超过 256 MiB。
- 原因：每份输入有大小上限，`FWBinaryState.transform/replace` 接收结果时没有输出上限检查；PDF 序列化只检查非空。后续保存层统一拒绝大于 256 MiB 的数据。
- 影响：结果先成为当前编辑状态，随后普通保存、另存及保存同样 PDF 数据的导出都失败。现有撤销仍可回退，因此不能描述为已经丢失原文件。
- 代码：`NativeOffice/Workbench/FWBinaryState.swift:27`、`:35`、`:55`；`NativeOffice/Workbench/FWPDFContent.swift:149`；`Sources/FileWorkbench/MediaOperations.swift:181`；`Sources/FileWorkbench/SafeFileIO.swift:53`、`:77`。

建议：替换编辑缓冲区前校验统一输出上限；批量输入增加累计内存预算；超限时保留原状态并说明可拆分处理。不要仅提高保存阈值而忽略内存峰值。

验收：通过可注入的小阈值验证变换超限后原缓冲区、撤销、脏状态均不变，再做真实大文件压力验证。

### R7 · P2 · 查找菜单没有按文档实际能力启用

**当前状态：已按文档能力启用查找、撤销、重做，并补真实 WebKit/媒体会话回归，见第 14 节。CSV 查找仍未实现，菜单现为禁用。以下保留审查基线的证据。**

- CSV 没有实现 `find()`，沿用协议的空实现；菜单只检查“有原生文档且不忙”，仍显示可用。
- 图片及其他未实现查找的原生内容也应按能力处理；撤销/重做的菜单启用条件同样较粗。
- 代码：`NativeOffice/Workbench/FWNativeContent.swift:21`；`NativeOffice/Workbench/FWWorkbenchCoordinator.mm:455`、`:462`；`NativeOffice/Workbench/FWDocumentHost.swift:407`。

建议：增加 `canFind/canUndo/canRedo` 等实际能力状态，未实现的操作先禁用；CSV 搜索作为单独功能实现，不让菜单点击后没有反馈。

验收：逐种文档、只读/忙碌/有无撤销记录的状态核对菜单；CSV 未实现查找前应禁用，实现后应有定位与未命中反馈。

## 3. 性能与结构优化

### O1 · P2 · CSV 单格编辑扫描和序列化全表

**当前状态：已完成受影响行校验、增量长度/签名、单格差量撤销、局部刷新和延迟序列化，见第 16 节。以下为修复前审查基线，其计时范围与新版原生控制器探针不同。**

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

**当前状态：隐藏预览和 DOM 复用见第 16 节，可见预览按帧合并及即时版本差量桥接已完成，见第 17 节。以下为修复前证据。**

`mode=source` 只把预览隐藏，`renderPreview` 仍执行 Markdown 全文转换及 `innerHTML`；每次输入还恢复全篇换行并通过桥接发送完整正文。

代码：`EditorAssets/src/workbench.mjs:72`、`:84`、`:86`；`EditorAssets/src/line-endings.mjs:53`；`NativeOffice/Workbench/FWTextContent.swift:127`。

已有依赖中的 jsdom + 真实 `createWorkbench` 探针确认：111,011 字节 Markdown 在源码模式输入一个字符，隐藏预览重建 1 次，消息正文为 111,012 字节。未把 jsdom 耗时当作真实 WebKit 延迟。

建议按收益分步做：隐藏预览跳过渲染；可见时合并短时间内更新；大文档必要时采用带版本号的增量同步。保存、关闭和故障恢复必须保留完整快照确认，避免节流导致最后输入未保存。

### O3 · P2 · 图片重复解码、PDF 多行高亮反复处理整份文档

**当前状态：已复用图片解码/变换像素、后台处理重变换、按事务批量高亮，并对图片/PDF 历史增加字节预算，见第 18 节。以下为修复前证据。**

- 图片打开先在后台验证解码，随后主线程再次解码；旋转/裁剪/缩放同步生成 PNG，再解码显示。
- PDF 多行选区每一行都重新解析并序列化整份文档；之后还要安装/刷新展示文档。
- 撤销保留整份数据，固定次数不能代表固定内存上限。

代码：`NativeOffice/Workbench/FWImageContent.swift:46`、`:120`、`:148`；`NativeOffice/Workbench/FWPDFContent.swift:113`；`Sources/FileWorkbench/MediaOperations.swift:127`。

建议：复用初次解码结果；重变换放入有状态保护的后台任务；在同一 PDF 模型上批量添加高亮，只序列化一次；撤销历史同时设定字节预算。使用目标系统上可行的图像跨任务传递方式，不简单取消主线程隔离。

验收：高像素图片、多页 PDF 和多行高亮，记录主线程最长阻塞、峰值内存、撤销正确性。当前只有代码成本依据，尚无 GUI 性能基准。

### O4 · P2/P3 · 大目录重复筛选、选择恢复和树枚举

**当前状态：源码优化及对应回归已补齐，最终验证和性能范围见第 19 节。以下保留审查基线的问题证据。**

- `visibleEntries` 每次计算重新过滤，排序也重复执行。
- 保存/恢复多选时，每个选中项反复线性扫描目录，约为 `O(n × m)`，且在 `@MainActor` 上执行。
- 刷新重新枚举曾加载过的树节点，包括已收起目录；后台旧任务仅丢弃结果，没有合并重复 I/O 或限制并发。

代码：`Sources/FileWorkbench/BrowserStore.swift:132`、`:326`、`:449`、`:453`、`:681`、`:728`。

建议：一次快照建立 URL/文件身份索引，复用可见列表，使选择恢复接近 `O(n+m)`；只刷新受影响或可见分支，合并相同 URL 的请求。不要因为代码文件较长就一次性拆散所有逻辑：先把文件操作、工作区持久化、目录加载职责拆到有清晰边界的组件。

验收：万级目录全选、刷新、关闭预览恢复、多次快速切目录和慢卷场景；同时核验硬链接身份歧义及过期结果保护。审查时未测得实际延迟；后续同探针真实万文件目录采样见第 19 节，不把状态层计时当作 UI 绘制或慢卷保证。

## 4. 功能缺口与产品候选

以下与前面的缺陷区分：README 对不少边界已有说明，不能把它们直接认定为未兑现的承诺。

| 编号 | 功能 | 当前实现/缺口证据 | 建议与验收重点 | 优先级 |
| --- | --- | --- | --- | --- |
| F1 | 多选移到废纸篓 | **实现已安装构建11，未远程发布，见第 20 节历史验收。** 审查基线仅取右键集合首项 | 列表/网格按菜单目标冻结 N 项与身份，逐项校验，汇总部分失败；12 项模型回归和真实系统废纸篓通过 | P2 · 源码完成 |
| F2 | 外部文件变动自动同步 | **实现已安装构建11，未远程发布，见第 21 节历史验收。** 审查基线仅处理本应用拖出 | 当前/可见展开目录防抖监听与前台检查；新增、删除、身份改名同步，保留选择/导航/草稿，超限分支前台补查 | P2/P3 · 源码完成 |
| F3 | 非 Office 草稿持久化与崩溃恢复 | **实现已安装构建11，未远程发布，见第 22 节历史验收。** 审查基线仅保留内存草稿 | 四类草稿独立检查点，欢迎页/工作台菜单恢复、确认清理、配额和保留期限；实际 SIGKILL 后新进程恢复，原文件不自动覆盖 | P2 · 源码完成 |
| F4 | 文件操作进度、取消、撤销 | **实现已安装构建11，未远程发布，见第 23 节历史验收。** 审查基线只有整批忙碌状态 | 数量/当前项、协作取消、私有暂存清理、三类撤销、失败重试与残留详情；最近一批内存记录，冲突不覆盖 | P2/P3 · 源码完成 |
| F5 | 递归名称搜索和内容搜索 | **实现已安装构建11，未远程发布，见第 24 节历史验收。** 审查基线只过滤当前目录文件名 | 显式限定目录，名称/文本字面搜索、取消/最新请求合并、排除目录/文档包/链接与读量预算，定位前重验身份 | P3 · 源码完成 |
| F6 | 预览直接进入对应编辑器 | **已随八项交互修复完成并安装构建11，见 [I5](interaction-fixes.md)。** PDF/CSV/图片原位进入原生编辑，Office 路由同一文件至原 CEF 宿主 | 均提供保存并返回，取消、失败、冲突或保存期间新修改仍保留编辑；需转换时要求另存 | P3 · 已实现 |
| F7 | CSV/TSV 表格效率 | 缺 CSV 查找；TSV 目前按文本路由，CSV 模型支持 Tab。`FWCSVContent.swift`、`FileCapabilities.swift:143` | 先补搜索定位、表格区域复制粘贴，再评估排序/过滤；TSV 默认分隔符与另存格式应一致；未实现的查找动作已按 R7 禁用 | P2/P3 |
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

## 14. 媒体变换边界与菜单能力修复（2026-10-25）

### 14.1 R6：拒绝无法保存的编辑结果

`FWBinaryState` 的初始化、同步替换、异步变换结果、重新读取和编码保存使用同一上限，默认仍为 `SafeFileIO.maximumMediaBytes`（256 MiB）。变换先生成候选结果，大小合法才提交到编辑缓冲区；超限或处理失败不推进数据、路径和保存基线，控制器也不注册新撤销项。保存编码结果仍经同一上限的安全写入，不能绕过既有原子保存及外部冲突检查。

PDF 合并、追加图片、新建图片 PDF 改用 `SafeFileIO.openMediaBatch` 按剩余预算逐份读取，累计包括当前 PDF 缓冲区；超限时停止读取后续文件。这是保守的输入预算，即使合并后可能压缩到较小体积，也不会先读入超预算的一批输入。追加图片还检查中间 PDF 大小，再由缓冲区检查最终合并结果。超限对话框建议减少输入、拆分处理，原编辑内容保留。

回归使用可注入的小阈值与真实文件/PDF 序列化，覆盖：超限初始化/同步替换/异步变换/保存编码、恰好到达上限仍可保存、干净和已修改会话、保留原字节与撤销/重做分支、正常合并/追加及撤销，以及累计输入超过预算后不再访问后续文件。原 256 MiB 阈值没有提高。

**边界：**累计预算约束压缩输入字节与最终编辑缓冲区；PDFKit/ImageIO 解码、序列化、旧快照和撤销历史仍可能同时占用内存，不是进程总内存硬上限。本轮未执行超过 256 MiB 的真实压力测试，也未实施 O3 的历史字节预算或后台图像性能改造。

### 14.2 R7：按实际能力启用菜单

`FWNativeContent` 增加 `canFind/canUndo/canRedo`，默认关闭未实现的命令。CSV、图片和 PDF 的撤销/重做来自真实 UndoManager；文本来自现有 CodeMirror change/state 消息的历史标志，重新读取或重建编辑器时清空旧历史标志。Swift 会话仍独立计算脏状态，不信任页面的 dirty 布尔值。

`FWDocumentHost` 同时检查宿主操作状态与内容能力，标准 responder 校验和 Objective-C++ 协调器菜单消费同一状态；直接命令调用也检查能力，避免禁用期间消耗撤销历史。只读文本/PDF 可查找；CSV、图片、Quick Look 未实现的查找禁用。加载、保存、故障和关闭时禁用相应命令，重新读取后按新历史恢复。

真实回归覆盖 CSV/图片/PDF 的空历史、编辑、撤销、重做、保存忙碌、重新读取和关闭，并核对三种只读文件及 Quick Look。WebKit 专项通过真实输入/撤销/重做验证宿主和 responder 菜单，不以硬编码能力值替代真实编辑历史。CSV 搜索定位及未命中反馈仍作为 F7 功能候选，不在本次实现。

### 14.3 验证与当前交付边界

- Swift 全量 145 项通过；累计输入预算的 3 项保存层测试另行定向通过。
- Python 构建工具 155 项通过、0 跳过。
- 原生媒体/CSV 11 组真实会话回归通过，包含原有 JPEG 保真与保存期间继续编辑场景。
- 真实 WebKit 菜单专项 6 项断言通过，报告：`build/modal-document-tests/run.6ENvSn/fixtures/report.json`。
- 不含系统远程另存面板确认的文档分组 42 项断言通过，包含上述菜单场景，覆盖结构化预览、保存/关闭保护和草稿恢复；报告：`build/modal-document-tests/run.7Pacqw/fixtures/report.json`。两组有重叠，不合计为 48 项独立场景。
- 完整原生 Debug 集成编译、ARM64 和严格签名检查通过，日志：`build/r6-r7-native-build.log`，包含 Swift 导出属性与 Objective-C++ 菜单调用的真实编译。

完整 `test-modal-documents.sh` 曾在“已删除文件→系统另存面板→投递 Return 确认”处超时，进程退出 1、报告 passed=false：`build/modal-document-tests/run.G7uXBt/fixtures/report.json`。面板出现及确认前保护已通过，但没有获得远程系统面板完成回调；不能计为系统另存成功。其余分组通过不替代这项端到端验收，也不把构建 6 的历史面板结果当作本轮通过。

上述为源码阶段历史结果；系统确认及明确另存的根因现已修复，完整回归和构建 8 实机面板验收见第 15 节，原失败报告保留。

本轮日志前缀为 `build/r6-r7-`，重跑入口：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift test --disable-sandbox --cache-path "$PWD/.build/cache"
python3 -B -m unittest discover -s Tests/BuildToolsTests -v
python3 -B scripts/onlyoffice/test_native_content.py
FW_MODAL_DOCUMENT_TEST_CASE=menu-capabilities bash scripts/test-modal-documents.sh
FW_MODAL_DOCUMENT_TEST_CASE=non-panel bash scripts/test-modal-documents.sh
python3 -B scripts/onlyoffice/build.py --phase app --configuration Debug --jobs 4
```

源码修复和文档留在当前工作区；本轮未提交、推送或发布，不替换 `/Applications/FileDeck.app` 与 README 的构建 7 下载入口。下一次发布需要对新安装包补齐系统另存面板确认及最终离线验收。无 SQL、用户配置、Redis/MQ 或对外 API 迁移。

收尾按 simplify Standard / bugfix 检查影响范围、仓库约定、代码质量及批量读取效率；复用既有保存上限、错误类型和历史桥接，没有引入第二套保存流程或修改编辑资源产物。未发现需要继续扩大的清理项；最终媒体、菜单与保存保护回归及原生集成编译覆盖本次改动路径。

## 15. 系统另存确认修复与构建 8 验收（2026-10-25）

### 15.1 根因与修复

问题包含两个环节：本进程投递的 Return 不能可靠确认远程系统保存面板，内部调用 `NSSavePanel.ok` 同样发生阻塞；改用外部真实 AXPress 后，又确认保存层将“明确另存到已删除原路径”误判为普通原路径冲突。

`SafeFileIO.save` 现在仅在调用方明确传入目的地、目标是原路径且该文件仍不存在时允许重建；普通保存仍报冲突。已存在的外部版本、符号链接变化、写入期间竞态检查和排他重命名保护保留。新增真实 I/O 回归同时覆盖普通保存拒绝、明确重建成功、成功后指纹推进和外部版本保护。

原生回归通过 `SystemSavePanelDriver.swift` 外部按系统保存按钮；助手核对本次随机令牌、PID/应用/可执行文件、面板标题及临时文件名，错误令牌必须失败。测试只报告 checkpoint，不接受回传 URL 或完成结果；真实产品流程必须收到系统回调并核对落盘。无 Accessibility 权限时明确失败，不静默跳过。该助手未接入产品日常构建。

### 15.2 重建与本机验证

- 系统另存专项 3 项断言通过：`build/modal-document-tests/run.j0v7SW/fixtures/report.json`；完整文档回归 45 项断言通过：`build/modal-document-tests/run.wdRbhZ/fixtures/report.json`。包含真实系统另存确认、取消保护、权限/外部冲突、草稿恢复和菜单状态，两个报告有重叠。
- 从锁安装依赖及资源只读重建比较通过；23 项 Node、155 项 Python（0 跳过）、146 项 Swift 和 11 组原生媒体/CSV 会话回归通过。
- 145 个源码/资源/脚本输入冻结后完成原生 Debug 重建；ARM64、签名、源包及暂存包门禁通过，打包明确版本 0.1.2、构建号 8。
- 2026-10-25 17:06 正常退出旧版后安装，5,649 个普通文件和 124 个符号链接与构建清单一致；安装后再次执行静态门禁通过。
- 安装副本禁网完成 DOCX/XLSX/PPTX 编辑、保存、重开、混合文本/PDF、窗口关闭/退出保护，退出 0。真实恢复草稿面板由外部 AX 实际取消一次、保存一次，来源原字节、完整草稿、选择 URL/实际保存路径、脏状态及对象释放均通过。
- 主程序 SHA-256：`b1ded42612999ead526ee400666ada649cbf534c0f3f581a4c3da9677a9dab6b`；编辑资源 manifest：`b20c89827accf83bc812d45d67e6683925d8d9fcfaed4f9a7b80ad172d8bfe13`。

证据目录：`build/releases/v0.1.2-build8/`，含 `source-inputs.json`、`build-result.json`、`installation.json`、`recovery-panel-ax.json` 及阶段日志；安装运行报告为 `installed-smoke/fw-office-smoke-中文 路径-8i_kt4rc/verification.json`，独立检查全部恢复字段通过。安装静态报告：`build/onlyoffice/build8-installed-verification.json`。

构建 8 的 ZIP、远程附件及清理结果随最终发布登记；此前构建 7 Release 保留用于回退。未新增 SQL、配置、Redis/MQ 或对外 API 迁移，临时签名、压力及 WebKit 恢复边界见[构建 8 发布说明](release-build8.md)。

### 15.3 构建 8 最终发布与清理

修复提交 `854d9f6` 与标签 `v0.1.2-build8` 已推送，预览 Release 已公开，README 下载及校验值已更新。最终 ZIP 为 793,612,924 字节，SHA-256：`65dd899f1db7be446863c46314b83fa872e7c4ea8e09224d147b4aa203fedb20`；CRC、6,877 项解压清单及文件字节/权限/链接核对通过，仅保留已知 CEF 根链接权限归一差异。解压包再次通过静态门禁、严格签名及禁网运行，退出 0。远程两附件大小和 SHA-256 匹配。

4 个构建 7 旧应用副本已移入废纸篓：上一安装包、上一打包应用、构建 7 分发目录及最终解压目录中的应用。构建 8、历史 ZIP、用户文档与偏好保留，远程构建 7 Release 可用于回退。日常运行确认是 `/Applications/FileDeck.app` 的构建 8。最终证据为上述构建 8 目录下 `archive-verification.json`、`publication-checks.json`、`release-after.json`、`old-app-cleanup.json`、`normal-launch.json` 及 `extracted-smoke/`。

构建 8 收尾复核保存/外部冲突影响范围、仓库约定、外部 AX 助手的目标约束和发布摘要；复用既有安全保存与系统面板，未引入 URL/完成回调注入或第二套保存流程。完整文档、媒体、Swift/Node/Python、原生编译、安装及最终分发回归覆盖该版本路径，无遗留必须修复项。

## 16. CSV 增量编辑与隐藏 Markdown 预览优化（2026-10-25）

### 16.1 实现与兼容性

- `CSVDocument` 缓存每行序列化字节数、行签名及总长度。单格编辑先在受影响行校验单元格、转义后的大小和 10 MiB 总预算，全部合法后再提交；解析和结构变更重建缓存。原有 10 万行、1024 列、100 万格及单格 1 MiB 上限不变。
- `FWCSVContent` 单格撤销只保存行列、旧值、原字段数及原文引用，避免每次持有整表快照；仅刷新目标单元格。普通不同值的编辑不再序列化全表，状态读取使用缓存。结构/编码/分隔符操作仍使用完整模型快照。
- 签名只用于证明正文不同；签名相同仍逐字节比较完整 UTF-8 后才清除 dirty。原文可选引号、混合 CR/LF/CRLF、短行字段数和 Unicode 字节保持既有语义：撤销回原文可恢复原始字节，实际编辑后按既有规范生成 CSV；只把值手动改回去，不会把与原文不同的规范化输出误判为已保存。
- 保存时捕获模型、原文、编码和修订号，在后台生成文本并交给原 `DocumentIO`/`SafeFileIO`；成功后只推进实际写入的基线。保存期间继续编辑、外部变更失败、确认覆盖及另存不改源文件均有回归。
- Markdown 在源码模式不做转换或 DOM 替换；重新显示时渲染最新正文，同一不可变 CodeMirror 正文在预览/双栏间切换时复用 DOM 与滚动。新会话清空缓存，避免旧文档内容残留。全文 change/state 消息仍即时发送，保存、关闭及 WebKit 草稿恢复协议不变。

### 16.2 同探针性能比较

新增可复现入口：

```sh
python3 -B scripts/onlyoffice/benchmark_csv.py --baseline-ref 59b5591da06ef586cf92a44971003eca380bde61
```

脚本只读指定 Git 基线和当前检出，使用相同 `CSVPerformance.swift`、`swiftc -O` 和本机 ARM64 环境分别编译（本次 macOS 14.7.2、Apple Swift 6.0.3）。每档 10 列、单字符单元格，先预热 2 次，再交替提交 21 次等长修改；计时包含真实控制器单格提交、UndoManager 注册与 dirty/状态更新，**不挂载表格，不含打开、保存和界面绘制**。每档另验真实另存、源文件不变、撤销和重做。墙钟耗时不设自动通过阈值。

| 行数 / 单元格数 | 输入字节 | 基线中位数 | 当前中位数 | 基线 P95 | 当前 P95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1,000 / 10,000 | 20,000 | 1.4485 ms | 0.0107 ms | 1.4978 ms | 0.0121 ms |
| 10,000 / 100,000 | 200,000 | 14.1332 ms | 0.0100 ms | 14.9225 ms | 0.0106 ms |
| 100,000 / 1,000,000 | 2,000,000 | 139.2860 ms | 0.0108 ms | 142.6046 ms | 0.0116 ms |

缓存将普通单格编辑的主要工作移到受影响行，但有明确代价：该次 10 万行打开计时从 113.89 ms 增至 188.93 ms；每行两个 64 位缓存数组约增加 16 字节，10 万行约 1.6 MB，不包含容器、模型和历史内存。没有测进程峰值内存，也没有声称实机键入绘制耗时达到该微基准数值。结构快照或进行中的保存仍可能让下一次编辑发生写时复制；回到保存基线时的完整比较、结构操作、切换分隔符和保存仍可遍历全表。

本机原始证据位于 `build/csv-performance/run-4b3mtnsu/comparison.json`，含 Git 基线、源码 SHA-256、21 次原始样本及保存/撤销结果；日志 `build/csv-performance-comparison.log`。`build/` 不提交，后续可用上述命令重测。最终源码相对探针快照只整理了缩进和注释，无运行逻辑差异。

### 16.3 回归与交付状态

- Swift 模型新增缓存与重新解析一致性、混合换行/Unicode/短行撤销、结构变化、失败原子性及 100 万格快照独立性测试；完整 **148 项通过**，`build/full-swift-tests.log`。
- 原生媒体/CSV **12 组通过**，覆盖 UTF-16 原字节撤销另存、手动改回保存值、可选引号 dirty 判定、外部冲突与覆盖、保存期间继续编辑，以及挂载表格的单格刷新/选择保持、结构与单格交错撤销重做；`build/full-native-content-tests.log`。
- Node **24 项通过**，其中大 Markdown 隐藏编辑不替换 DOM、即时全文桥接、显示最新正文、滚动/DOM 复用及跨会话清理均有断言；`build/markdown-preview-tests.log`。资源已重建，`npm --prefix EditorAssets run verify` 只读比较通过，`build/markdown-preview-verify.log`。
- 真实 WebKit **21 项通过**，新增隐藏输入同步和模式切换 DOM 复用，原 Markdown 防注入、CSP 和导航断言保留；`build/full-editor-tests.log`、`build/editor-tests/report.json`。
- Python 构建工具 **155 项通过、0 跳过**；`build/full-python-tests.log`。
- 完整原生应用 Debug 集成编译 **BUILD SUCCEEDED**，`build/csv-preview-app-compile.log`；现有三个上游脚本阶段缺少 outputs 的 Xcode 警告保留，未改动该构建逻辑。
- **2026-10-26 解锁后完整文档/系统另存回归 45 项通过**，报告 `build/modal-document-tests/run.wLfBqC/fixtures/report.json`，最终日志 `build/full-modal-document-tests-unlocked-activated.log`。真实系统保存按钮由原外部 AX 助手确认，错误令牌反例亦通过；复核系统回调、所选路径和实际落盘 UTF-8 正文“删除后保留的草稿”，SHA-256 为 `d410936c81edf998c76c6c2aba71109c7337bbf551ca6ab6715539a20d938b68`。Markdown 取消确认后正文/选择/滚动/模式/焦点与撤销重做保持，正常保存、权限失败、外部冲突、WebKit 恢复及恢复草稿另存均通过。
- 验收边界：系统 NSSavePanel 端到端用例覆盖已删除源路径的明确另存；WebKit 故障用例验证按钮派发后向显式临时路径写入草稿、来源不变、基线更新，并非故障草稿面板的键鼠端到端。本轮运行的是隔离源码辅助应用，不是重新安装后的构建 8 验收。
- 环境历史保留：2026-10-25 锁屏时无法激活窗口；2026-10-26 解锁后首次直接运行仍在活动窗口前置条件超时（`build/full-modal-document-tests-unlocked.log`）。随后仅在精确可执行路径匹配的隔离 PID 窗口出现后，通过外部 Accessibility 置前，确认 `ModalDocumentTests, true, 1` 后完整验收通过，进程退出 0。未修改产品焦点逻辑、测试断言或注入系统保存完成结果。旧失败报告 `build/modal-document-tests/run.gg8tdy/fixtures/report.json` 继续保留。
- 独立复核 `build/modal-document-tests/run.wLfBqC/verification.json` 确认 18 份 Swift 源码和 6 份编辑资源副本与当前检出逐字节一致，并核对系统另存正文、恢复草稿、源文件 CRLF 字节和不可覆盖目标共 4 份实际文件，保存其 SHA-256；本次复验未修改产品代码。

本批不打包、不安装或发布，README 与当前安装/公开下载继续指向构建 8。本节交付时 O2 可见预览/全文桥接仍待处理，现已由第 17 节更新；本节交付时 O3/O4 仍待处理，现分别由第 18/19 节更新；第 4 节功能候选继续保留。

### 16.4 收尾复核

使用 simplify Standard 的 refactor 路径，依次自查质量、仓库约定、复用和效率。保留现有 DocumentIO、UndoManager、CodeMirror 正文与安全渲染器，未引入第二套保存或同步协议；签名相等仍完整比较，避免碰撞清除 dirty。修正基准脚本首次运行时 `build/` 不存在导致目录创建失败的问题，入口 `--help` 检查通过；模型仅整理缩进及缓存边界注释，无需因注释重复执行已通过的全套测试。完整桌面回归已于 2026-10-26 解锁并外部置前后通过，环境前提和历史失败证据按上节保留。

## 17. O2 可见预览合并与版本差量桥接（2026-10-26）

### 17.1 实现与保存边界

- `workbench.mjs` 可见 Markdown 只保留一个待执行的 requestAnimationFrame，同一帧连续修改只转换最终正文。隐藏源码模式不转换；显式模式切换、确认前捕获交互及暂停编辑立即刷新，取消遗留帧；同一正文仍复用 DOM/滚动，切换文档与关闭释放任务和缓存。
- `FWTextContent` 请求 `bridgeMode=patch-v1`。每次编辑事务同步发送 `baseVersion/version` 与 `{from,to,text}` 差量及真实历史状态；不为普通输入生成或回传完整正文。旧独立宿主未指定协议时仍使用完整 change 消息。`markSaved/state`、保存/关闭的 `getSnapshot` 和异常重同步保留完整正文。
- `text-bridge.mjs` 将 CodeMirror 的规范化 LF 坐标映射成原始正文 UTF-16 偏移，插入值恢复 CR/LF/CRLF。普通同一行输入复用行尾映射，偏移前缀每个会话只缓存最近一份；若恢复 effect 还改变编辑区以外的原始行尾，退回带版本全文，避免差量遗漏字节。
- `TextDocumentSession.applyEdits` 先验证全部范围、排序和 UTF-16 代理对边界，再倒序原子应用；允许组合附加符独立编辑，拒绝半个 emoji。Swift 仍根据真实 UTF-8 与实际保存基线计算 dirty，不信任网页布尔值。
- 原生忽略过期/重复版本；基线版本缺口或非法范围请求完整快照，最多重取三次。若仍不一致，保留最近已同步草稿并提供恢复入口，不能静默继续套用错位差量。重新读取、重建和旧 WK 会话门禁一起重置版本。
- 保存/关闭读取完整版本快照；await 期间已接受的新差量不能被旧快照覆盖。保存完成只确认实际写入正文，后续输入继续为 dirty。预览帧合并不延迟草稿消息，后台帧暂停也不影响桥接；真实进程死亡前尚未抵达 Swift 的最后输入仍不在恢复保证内。

### 17.2 工作量与传输量证据

Node 使用真实 createWorkbench/CodeMirror 和 jsdom，构造 **100,000 行、2,100,006 字节 UTF-8** 正文，40 次等长单字编辑均即时发送差量：实际 JSON 消息合计 **5,861 字节**，原全文方案仅 text 内容就需 **84,000,240 字节**（未含 JSON 转义与其他字段）。回归同时检查最终全文、40 个连续版本及行尾数组复用，见 `build/o2-node-tests.log` 的诊断输出。没有把 jsdom 墙钟耗时当成 WebKit 延迟。

可见预览的受控 Node 帧测试确认：初次显示后同一帧的三次输入，在帧执行前不替换 DOM，执行后只转换一次并显示第三份正文。真实 WK 执行三次 contenteditable 输入，等待 DOM 微任务而不跨渲染帧，观察到 **beforeFrame=0 / afterFrame=1、3 条差量、最新标题与完整快照正确**；见 `build/o2-webkit-tests.log`。

本轮减少的是冗余转换、全文生成和桥接序列化/传输。实际可见预览仍执行完整 Markdown 转换；包含新增/删除换行的输入仍可能重建行尾映射和偏移前缀。原生 NSString 更新及 Swift 基线比较仍可能遍历/复制正文，没有改成 rope，也没有测峰值内存、低配设备延迟或宣称所有编辑都为常数成本。整篇粘贴、格式化、保存/关闭和必要恢复快照仍可能传输完整正文。

### 17.3 最终回归与证据

| 验证 | 当前结果 | 主要证据 |
| --- | --- | --- |
| Swift 全套 | 150 项通过 | `build/o2-full-swift-tests.log`；新增 UTF-16 多区编辑、混合换行、NFC/NFD、代理对/重叠/越界原子拒绝，并覆盖保存等待期间差量输入 |
| Node | 27 项通过 | `build/o2-node-tests.log`；差量往返、历史/格式化、原始行尾全文回退、同帧合并、确认刷新、旧任务失效和大文档负载 |
| 编辑资源 | 只读重建比较通过 | `build/o2-resource-verify.log`；已重建 editor.js 和 schema 2 清单，新增模块纳入源码摘要 |
| 真实 WebKit | 23 项通过 | `build/o2-webkit-tests.log`、`build/editor-tests/report.json`；新增帧合并与版本差量，原 CSP/导航/Markdown 防注入保留 |
| 完整原生文档/系统面板 | 50 项通过，退出 0 | `build/o2-modal-tests.log`、`build/modal-document-tests/run.CSn9Uu/fixtures/report.json`；原 45 项加真实差量缺口、旧消息、故障另存及快照竞态 5 项 |
| 原生媒体/CSV | 12 组通过 | `build/o2-native-content-tests.log`；保留上一批大表撤销/保存及 JPEG/PDF 等覆盖 |
| Python 构建工具 | 155 项通过、0 跳过 | `build/o2-python-tests.log` |
| 完整原生 Debug 应用 | BUILD SUCCEEDED | `build/o2-app-compile.log`；仅编译同步资源，未打包或安装 |

`build/modal-document-tests/run.CSn9Uu/verification.json` 独立确认 18 份 Swift 辅助源码与当前检出一致、6 份运行资源与最终辅助应用/Debug 应用均逐字节匹配，并核对系统另存正文、原文件 CRLF、故障草稿、版本恢复草稿及竞态另存共 6 份实际文件。系统面板继续由令牌/精确进程约束的外部 AX 助手按真实按钮，错误令牌反例通过；外部置前只作用于已出现窗口的隔离测试 PID。故障草稿测试是显式临时路径另存，不代替安装包中该面板的端到端验收。`build/` 为本机证据，不提交。

### 17.4 收尾与交付状态

使用 simplify Standard/refactor，按质量、仓库约定、复用和效率自查。复用 CodeMirror 事务/换行映射、原 TextDocumentSession 保存与冲突保护；移除冗余已保存字符串状态，补上 dispose/destroy 的帧与正文缓存清理，并将偏移缓存由按历史映射保留改为每会话最近一份，避免额外内存随撤销映射增长。清理后重新通过 Node、真实 WK、完整原生文档及集成编译，无本批遗留必须修复项。

本批完成 O2 源码优化与对应回归，尚未提交或推送。本节交付时 O3/O4 待处理，O3/O4 现分别由第 18/19 节更新；功能候选继续保留。按用户要求，全部问题处理完成前不打包、安装或发布；README 的下载链接与日常安装仍为构建 8。

## 18. O3 图片像素复用、后台变换与 PDF 批量高亮（2026-10-26）

### 18.1 行为与状态保护

- 图片打开只在工作器解码一次，将归一方向的不可变 CGImage 连同文件快照返回；重新读取的验证直接返回解码结果，避免再解码。目标 SDK 已声明 CGImage 为 Sendable，未给可变 PDFDocument/视图添加 unchecked Sendable，也未移除控制器 MainActor 隔离。
- 旋转/裁剪/缩放和元数据保留的 PNG 编码在后台执行。工作器同时返回编码字节和已得到的像素，完成后安装像素而不解码 PNG；撤销/重做复用对应像素快照。PNG/JPEG 转码和单页 PDF 导出也复用当前像素，同格式原字节保存及已编码 JPEG 缓存保持原有语义。
- FWBinaryState 的后台事务支持返回 Sendable 结果，先校验取消与 256 MiB 输出预算再提交。图片保留保存期间编辑能力：保存捕获旧快照，后台变换可提交新草稿，旧保存完成只推进自己的基线。PDF 批量变换仍不与保存并发。
- 控制器占用处理状态直到字节、像素/显示模型和撤销项全部安装完成，期间禁止冲突的新变换、保存、重新读取和关闭。失败、取消、无效几何或输出超限不替换当前内容、不消耗原撤销/重做分支。
- PDFOperations.addHighlights 在同一私有 PDF 模型上先验证全部页码/矩形，再逐行添加原有 QuadPoints 高亮，只序列化一次。工具栏只在主线程捕获真实多行选区与页面坐标，后台执行整批；安装时仅刷新一次展示模型，保存模型与只读展示标记继续分离。单条 addHighlight 也委托此实现，权限/几何规则一致。

### 18.2 历史预算与限制

FWMediaHistory 复用 UndoManager 分组/重做，为每个快照分配独立票据；默认最多保留 12 个动作和 **128 MiB 历史记账预算**，超额先淘汰最旧动作。PDF 记录编码字节，图片记录编码字节加已知像素缓冲估算。裁剪可能共享原始像素 backing，沿用原缓冲规模记账，不能按裁剪后的小宽高低估。单个前态已超过预算时不记录该撤销，并清掉旧分支，避免下一次撤销跨过当前修改；超预算的大重做快照也不保留。

移除票据可能留下 Cocoa 空组，因此菜单能力来自仍保留的动作，并在执行时跳过空组。预算清理不关闭调用方仍持有的分组，避免 endUndoGrouping 失配。重新读取成功或关闭时释放历史；失败保留原分支。

预算只约束这份历史的记账，不是进程内存硬上限：当前像素/编码内容、保存基线、编码结果缓存、在途工作器、PDFView/ImageIO/PDFKit 内部引用与临时分配不全部包含在内。大图可能只保留少量撤销，甚至当前修改没有可用撤销；不得保证固定 12 次。源文件大小、64 MP 像素及 256 MiB 输出限制保持原规则。

### 18.3 可复现采样

```sh
python3 -B scripts/onlyoffice/benchmark_media.py --baseline-ref 59b5591da06ef586cf92a44971003eca380bde61
```

同一 MediaPerformance.swift 探针、swiftc -O、macOS 14.7.2 / Swift 6.0.3 / ARM64，分别编译 Git 基线与当前源码。图片场景为 4000×3000（12 MP）PNG 打开并连续旋转两次，实际另存、源文件保留和撤销/重做均复核；PDF 场景为 20 页、120 个合成行矩形，基线按行循环解析/写出，当前一次批量后台处理，最后核对每页 6 个高亮。

| 场景 | 基线总耗时 | 当前总耗时 | 基线主队列最大心跳间隔 | 当前主队列最大心跳间隔 |
| --- | ---: | ---: | ---: | ---: |
| 12 MP 图片打开 | 105.13 ms | 77.56 ms | 59.91 ms | 27.64 ms |
| 同图连续旋转 2 次 | 414.15 ms | 255.78 ms | 414.19 ms | 6.28 ms |
| 20 页/120 处高亮 | 1616.61 ms | 32.19 ms | 1699.17 ms | 12.21 ms |

独立图片进程在旋转阶段的生命周期 RSS 高水位：**212.70 → 203.36 MiB**；独立 PDF 进程：**129.19 → 22.89 MiB**。原始数据与源码 SHA-256 在 `build/media-performance/run-0bpky1f6/comparison.json`，最终源码逐项匹配；入口日志 `build/o3-performance.log`。较早试跑 `run-14ja1b5f` 不作为最终表格来源。

解释边界：这是同机一次非独占采样，不是中位数/P95 或生产保证；主队列用 5 ms timer 观察调度间隔，并非精确函数阻塞或屏幕帧延迟，间隔还受系统负载影响。RSS 为内核 getrusage 的独立进程生命周期高水位，包含样本生成及缓存，不能当作某一步额外内存；PDF 计时包含高亮模型、结果核验/写文件，不包含控制器安装/完整 PDFView 绘制。两个版本都不挂载可见窗口；真实工具栏语义由下节独立回归覆盖。

### 18.4 回归与最终证据

- **153 项 Swift 通过**，`build/o3-full-swift-tests.log`。新增跨页/旋转页批量高亮、QuadPoints、原批注/标题/几何保持、无效页/矩形/空选择整批拒绝及已解码像素直接 PDF 导出；原方向、逐像素旋转/裁剪和元数据测试保留。
- **15 组原生媒体/CSV 回归通过**，`build/o3-native-tests.log`。新增后台旋转/裁剪/缩放与失败后 redo、重新读取失败、预算淘汰/空组/超预算 redo、裁剪 backing 记账、取消和忙碌保护；用保存工作器闸门确定性覆盖“旧保存尚未结束，新变换已提交”的基线和下一次保存。原 JPEG 原字节、元数据、重复保存、保存期间编辑及 CSV/PDF 限额/冲突回归保留。
- 真正可选文字的两页 PDF，挂载真实 PDFView，选取全文后点击“高亮选中文字”按钮，确认每行一条高亮、一次撤销回到原始字节；不是仅调用模型 API。展示只读标志不写入保存文件，60 处跨页批次、失败后 redo 以及输出超限也有断言。
- **155 项 Python 构建工具通过、0 跳过**，`build/o3-python-tests.log`；编辑资源只读重建比较通过，`build/o3-resource-verify.log`。本轮未修改 JS，上一批 27 项 Node、23 项独立 WK 专项未重复运行，不能写成新增测试计数。
- **完整原生 Debug 编译通过**，`build/o3-app-compile.log`；仅保留上游 3 个脚本阶段缺少 outputs 的既有警告。
- **完整文档/系统面板 50 项通过、退出 0**，最终日志 `build/o3-modal-tests-retry.log`，报告 `build/modal-document-tests/run.IIbwoA/fixtures/report.json`。首轮助手因文件名尚未匹配而安全拒绝，保留 `build/o3-modal-tests.log` / `run.1spLKk` 的失败证据；未放宽令牌、进程或文件名门禁，原样重跑通过。恢复草稿专项仍为显式临时目标另存，不代替安装包的故障草稿面板端到端验收。

`run.IIbwoA/verification.json` 复核 18 份辅助 Swift 源码、6 份辅助/Debug 编辑资源与最终检出一致、6 份系统另存/恢复/竞态文件字节和性能源码摘要，并记录最终原生回归测试源码摘要。build 证据不提交，不代表已安装新包。

### 18.5 收尾与交付状态

按 simplify Standard/refactor 自查质量、仓库约定、复用和效率。保留共享安全保存与既有图片编码缓存；没有跨线程共享可变 PDFDocument/NSView。补齐处理完成到像素/撤销安装间的占用窗口，保守计入裁剪 backing，并在预算清理时保留 Cocoa 分组配对；上述边界均在最终回归覆盖，无本批遗留必须修复项。

O3 源码与回归完成。本节交付时 O4 待处理，现由第 19 节更新；功能候选继续保留。尚未提交或推送；按用户要求，所有问题修复完成前不打包、安装或发布，README 下载和日常安装继续使用构建 8。


## 19. O4 大目录显示快照、选择索引与受控枚举（2026-10-26）

### 19.1 实现与保留语义

`BrowserDisplaySnapshot` 按 entries、query、typeFilter、sortByModified 失效，复用可见数组、排序数组、可见 URL 索引、身份索引和显示位置。选择/焦点/网格切换不使快照失效；重复读取列表不再次筛选、排序。元数据安装时建立全列表 URL 索引，捕获预览或拖出多选从逐项扫描变为直接查询；Shift 范围用显示位置索引。

选择恢复遍历一次可见列表建立身份索引，再遍历选中项，平均复杂度约 `O(n+m)`（修改时间排序仍为 `O(n log n)`）；这些索引占用线性额外内存。原路径必须匹配原身份；仅唯一身份允许跟随重命名。多个硬链接保留“歧义”状态，不能让字典后写入项代替唯一性判断。只有明确成功保存回调提供的 savedURL 允许原子写入后重新绑定。

连续刷新清空列表期间，保留第一次捕获的选择身份，避免第二次刷新逐项同步 stat，也避免把同名替换的新 inode 继承为原选择。结果提交或返回中性状态时清理临时引用。关闭预览保持原列表、树缓存和非加载态，筛选状态批量恢复，不用每个属性触发旧列表重算；关闭读取必须是保存之后的新请求，并验证原目录身份。

### 19.2 枚举调度与边界

`BrowserDirectoryLoader` 只负责在途读取与订阅，不另建跨刷新磁盘缓存。列表与树按规范目录 URL、隐藏策略、刷新代次合并；预览关闭另起新代次并带目录身份要求。一次读取结果同时提供列表和文件夹子集，根目录列表/树不重复枚举。同名 URL 的显式刷新属于新代次，不能复用刷新前结果。

- 每个 BrowserStore **最多 2 个目录工作器**。当前列表优先于尚未开始的树请求；快速导航取消旧列表订阅，收起或快捷根切走取消不可见树订阅，无订阅排队项不会执行。
- 已经进入系统调用的磁盘读取不能可靠中止，仍占并发槽直到实际返回；不能取消外层 Task 后释放计数，再制造无界工作器。两个慢读取均阻塞时，新目录仍可能等待；本轮没有物理拔盘/网络卷专项结果。
- 无订阅的运行结果不再允许后来同路径导航加入；旧工作器结束时凭任务 ID 区分同路径新任务。树、列表、弹窗继续分别校验代次/会话/路径，旧结果不改变新选择。
- 刷新及重命名路径同步仅重读祖先均展开的可见分支和当前列表；已收起缓存失效但不重读，后代展开意图保留，重新展开时按需加载。管理根迁移、书签、历史与作用域令牌语义保持。
- 隐藏策略仍遵循系统 `.skipsHiddenFiles`；可见列表为空时额外确认是否仅有隐藏文件，因此这类目录仍可能做第二次底层读取。树搜索仍只过滤已加载节点，不引入递归磁盘搜索或监听。

### 19.3 可复现真实目录采样

入口：`python3 -B scripts/onlyoffice/benchmark_browser.py --baseline-ref 59b5591da06ef586cf92a44971003eca380bde61`。同一探针、同一个本地真实 **10,000 文件目录/10,000 项选择**，分别编译基线和当前源码，验证全选捕获、刷新与关闭后主选择及集合完全相等；使用 `-O`、ARM64 macOS 14。样本生成不在计时中，窗口不挂载。

| 场景 | 基线 | 当前 |
| --- | ---: | ---: |
| 打开目录并等待列表/树 | 3491.63 ms | 2248.70 ms |
| 反复读取可见/排序/主选择 12 次 | 403.70 ms | 25.23 ms |
| 捕获 10,000 项选择 | 10155.01 ms | 9.67 ms |
| 刷新并恢复 10,000 项选择 | 87728.84 ms | 2164.17 ms |
| 关闭预览并恢复 10,000 项选择 | 75762.27 ms | 2186.16 ms |

最终原始结果与两版源码 SHA-256：`build/browser-performance/run-a0untajc/comparison.json`，入口日志 `build/o4-performance-final.log`；macOS 14.7.2 ARM64 / Swift 6.0.3。同一探针分别编译两版，当前源码摘要已逐项复核；较早 `run-sz352g62` 只作为试跑，不作为最终表格来源。

这是同机一次非独占采样，基线先执行、当前后执行，存在系统缓存/负载差异，不是多次随机顺序中位数/P95。打开/刷新/关闭耗时包括后台本地磁盘枚举和主 actor 的状态安装/选择恢复，不能分摊成纯 I/O 或主线程阻塞时长；12 次显示读取是状态 API 调用，不含 SwiftUI 布局/实际滚动绘制。未测峰值内存、真实慢卷或物理拔盘，不能据此承诺任意目录的交互延迟。

### 19.4 回归与源码一致性证据

新增 `BrowserDirectoryPerformanceTests.swift` **11 项回归**：万项选择/刷新/预览恢复与显示快照复用；query/type/排序/元数据失效；真实硬链接原路径与歧义改名；列表树合并；收起父节点不重读后代、再展开恢复；可控慢卷的并发上限/队列优先/取消；隐藏策略及旧代次；预览关闭取消等待；12 个快捷根切换和无订阅结果不得再用；同路径目录替换；连续刷新同名原子替换；仅隐藏文件/失败重试语义。其中万项单测使用确定性元数据，真实万文件 I/O 由上节探针单独覆盖。

- **164 项 Swift 全量通过**，`build/o4-full-swift-tests-final.log`；包含新增 11 项 O4 回归，原重命名/移动、工作区授权、身份恢复及其他编辑器回归保留。
- **155 项 Python 构建工具通过、0 跳过**，`build/o4-python-tests.log`。本批未改 JS 或媒体会话，未重复运行独立 Node/WK、媒体 15 组及系统面板 50 项专项；上一批结果保留为其原范围，不加进本批计数。
- **44 项真实原生浏览/文本宿主检查通过，退出 0**，最终日志 `build/o4-native-host-tests-verified.log`，报告 `build/native-host-tests/run.4zItuO/fixtures/report.json`。覆盖真实目录行导航/展开、文件单击与双击、预览关闭后的原列表对象、多选/树/精确滚动/焦点、继续方向键、读取取消/快速切换、保存失败与关闭取消。首轮受限环境辅助进程退出 134、未计为成功，保留 `build/o4-native-host-tests.log` / `run.1NpFPT`；允许 GUI 服务的环境中按原门禁重跑，没有放宽窗口/对话框条件。
- **完整原生 Debug 编译、ARM64 与严格签名检查通过**，`build/o4-app-compile-verified.log`；保留上游 3 个脚本阶段缺少 outputs 的既有警告。没有生成分发包或替换日常应用。
- `build/o4-verification.json` 复核最终助手的 **29 份源码**与检出及隔离副本完全一致、Debug 同步输入 **30 份**与检出一致、助手/Debug 的 **6 份编辑资源**与当前资源完全一致，记录 O4 测试和最终性能源码摘要。辅助 Swift 检查没有挂载万项 UI，不能将其解释为万行屏幕绘制验收。
- `git diff --check` 通过。性能与辅助证据存于忽略的 build 目录，不随源码提交。

### 19.5 收尾与交付状态

执行 simplify **Standard/refactor**，自查 quality、repo_fit、reuse、efficiency。合并列表/树/关闭读取调度，移除过时的“所有曾加载节点重读”分支，复用可见 URL 索引清理选择，不再构造第二份可见 URL Set；补齐无订阅任务不能重用、连续刷新身份保持及预览取消 continuation 唤醒。最终测试覆盖上述清理，未留下本批必须修复项。

O1–O4 的源码优化均完成；第 4 节功能候选、真实慢卷/大规模可见列表绘制等专项边界仍保留，不将候选功能都算作已承诺缺陷。尚未提交或推送；按用户要求，整体问题处理完成前不打包、安装或发布。README 下载链接与日常安装继续为构建 8，本节 Debug 产物不替代安装包验收。


## 20. F1 多选移到废纸篓、身份保护与部分失败（2026-10-26）

### 20.1 操作范围与逐项执行

列表右键使用 `contextMenu(forSelectionType:)` 提供的 URL 集合；网格右键已选项目沿用当前多选，右键未选项目只针对该项。菜单构建时捕获有序 `FileEntry` 数组和原文件身份，标题显示“移到废纸篓（N 个项目）”；之后改选、改搜索词、切目录都不会扩大已捕获的操作集合。只索引所选 URL，复用与显示快照同代次的选择缓存；选择/筛选/排序/元数据变化均更新缓存，避免新增网格菜单重新扫描整目录。

`BrowserStore.trashFiles` 将冻结批次交给后台 `WorkspaceFileTrash.perform`，逐项在系统调用前检查本机 URL 与原 `FileIdentity`。缺失身份不能在点击后补读成新身份；文件缺失、同名原子替换或权限/系统废纸篓失败，只记录该项错误，继续其余项。按规范路径去重，不能按 inode 去重硬链接；包/目录和符号链接以目录项本身操作，不解析为链接目标。每项保留安全作用域的开始/结束配对。

正式入口始终调用 macOS `FileManager.trashItem`，不增加永久删除回退。身份检查与系统废纸篓调用是两个步骤，仍不构成原子系统调用；本批覆盖项与项之间的变化，没有声明消除所有外部并发替换窗口。已经成功移走的项目不因另一项失败而自动恢复；通用取消、进度和撤销仍属于 F4。

### 20.2 结果与浏览状态

结果保存成功项目及每个失败项目/原因，统一显示“成功 X、未完成 Y、共 N”及失败名称/原因；全成功不弹失败提示。没有用一次成功代表整批成功，也不会在第一项异常时结束整个循环。

`isTrashing` 与复制/移动的 `isImporting` 合为 `isFileOperationBusy`：拒绝第二批废纸篓和复制/移动的并发提交；UI 同时禁用新建/重命名/粘贴/拖入等写入入口并显示处理中。空批次无操作，失败完成后释放忙碌并允许重试。该状态不代表新增了文件操作的退出保护或用户取消能力。

整批完成后只刷新最新浏览位置，不导航回发起目录，不恢复旧搜索/历史。原身份仍匹配的失败项保持选择，成功项、消失项和同名替换的新对象不继承原选择。管理根引用保持原约定；若用户在处理期间进入被移走的目录，后续读取按已有不可用目录路径处理。

### 20.3 回归与真实系统验收

- **176 项 Swift 全量通过**，`build/f1-full-swift-tests-final.log`。新增 `FileTrashTests.swift` **12 项**：列表显式右键集合/网格范围、菜单冻结、选择缓存随排序/过滤/刷新更新、重复路径、正常批量、部分/全部失败与重试、缺失/同名替换/无身份/非文件 URL、逐项而非仅开头校验、硬链接/符号链接/文档包、并发忙碌、处理期间改选/导航、导入中拒绝及空操作。模型测试将项目移入隔离测试目录，真实 lstat 校验不替换为模拟结果；不把该后端称为系统废纸篓。
- **155 项 Python 构建工具通过、0 跳过**，`build/f1-python-tests-final.log`。本批未改 JS/媒体，独立 Node/WK、媒体和系统另存专项未重复运行，保留前批原始范围。
- **52 项完整原生浏览/文本宿主检查通过，退出 0**，`build/f1-native-host-tests-activated.log`；报告 `build/native-host-tests/run.49ZLl9/fixtures/report.json`，明确 `testCase=all`、`mouseDriver=cgevent`。原 44 项与新增 **8 项 F1 实际系统检查**全部执行：真实 List 选中两行，打开真实右键菜单并确认 N=2，执行两项系统废纸篓并逐项在实际废纸篓核对原身份；第二轮在菜单打开后原子替换第二项并改选第三项，确认仅第一项被移走，替换内容/新选择完整保留，显示“成功 1、失败 1”及失败名称，并关闭真实错误提示。
- 样本名含本次 UUID，助手只核验这些精确名称/原身份，恢复本次已移走样本，不扫描或清空用户废纸篓；`trash-samples.json` 及最终源码/字节核对见 `build/f1-verification.json`。列表/网格的目标推导都有模型回归；本轮实际系统右键验收为 List，不额外宣称网格鼠标全流程已测。
- **完整原生 Debug 编译、ARM64 和严格签名检查通过**，`build/f1-app-compile-final.log`。没有打分发包或替换本机日常安装。

专项入口为 `FW_NATIVE_HOST_TEST_CASE=trash bash scripts/test-native-hosts.sh`。`run.x3uSQr/fixtures/report.json` 独立 8 项通过；默认不传专项变量则仍执行完整流程，未知专项/鼠标驱动会报错。普通鼠标入口继续用 NSEvent；已获本会话授权的备用入口 `FW_NATIVE_HOST_MOUSE_DRIVER=cgevent bash scripts/test-native-hosts.sh` 使用真实 CGEvent，需已有辅助功能权限。每次投递前要求本测试应用活动、窗口为 key、落点位于内容区；外部置前也先核对新建测试目录、PID 和可执行路径，仅置前一次，证据 `run.49ZLl9/activation.json`。没有放宽菜单、对话框、身份或文件字节断言。

保留失败证据：`run.ls7XHY` 已完成第一轮双项系统移走，但助手在刷新后继续引用旧 NSTableView，第二轮选择超时；已改为每轮重新取得当前挂载列表。其后 `run.uG7W2a`、`run.YnkJCg`、`run.wI6ID1` 分别在旧目录箭头、预览就绪、目录点击步骤失败。最终同一产品源码用已授权 CGEvent 备用路径完成 52 项；这些失败不计成功，也未据此断言已定位默认 NSEvent 路径不稳定的全部根因。菜单观测改为主 actor 对象、主队列回调限定，避免新增跨线程 NSMenu 捕获警告。

### 20.4 收尾与交付状态

执行 simplify **Standard/feature**，自查 repo_fit、quality、reuse、efficiency。把单项视图 I/O 收敛为可测试的批次命令/结果；复用 O4 显示索引与选择缓存，避免每个网格菜单全目录扫描；共享复制/移动忙碌门禁；修正助手跨刷新使用旧 List 引用及菜单 actor 边界。清理后的 Swift、构建工具、真实系统专项/完整原生流程与 Debug 编译均通过，无 F1 必须修复项遗留。`git diff --check` 通过。

F1 交付时源码及对应验收完成、F2–F9 仍保留；后续 F2 由第 21 节更新。默认 NSEvent 路径的稳定性也需继续观察；按用户要求，整体问题处理完成前不打包、安装或发布。本批未提交/推送，README 与日常安装仍为构建 8。build 证据被 Git 忽略，不代表新安装包或已发布版本。

## 21. F2 外部文件变动自动同步与浏览状态保护（2026-10-26）

### 21.1 通知范围与读取调度

`BrowserDirectoryObserver` 在专用串行队列上用 `O_EVTONLY | O_CLOEXEC | O_NOFOLLOW` 打开目录，核验 fd 与路径的 `FileIdentity` 后建立 vnode 订阅。当前目录、祖先均展开的可见树分支及其父目录进入目标集合；父目录只监听，不枚举其内容。管理目录多于可见范围时不递归扫描，不监视所有曾经访问的目录。

每个 BrowserStore 最多保留 **128 个有效目录订阅**，优先当前目录及其父目录，然后按深度/路径分配可见分支。超出配额的分支及不可靠卷通知由回到前台的合并检查补齐；这不是所有目录、网络卷或任意规模树的实时通知保证。收起、移除根、清空工作区与释放 owner 均取消无效源，cancel handler 关闭 fd；已在途的内核回调仍由当前目标/身份门拒绝。

连续事件采用 **180 ms 尾沿防抖**，只标记受影响目录；同一目录已有读取时不逐事件开新任务。变化版本保留读取期间的新事件，旧结果只清除发起前的版本，必要时再读取一次。列表/树/关闭仍复用 O4 的最多两个目录工作器；切走或收起取消无效订阅，旧代次不能抢回导航。注册后补一次合并检查，覆盖首次枚举与安装监听之间的间隙；无法订阅只报告一次，父目录变化或回前台再尝试，避免失败重读循环。

自动更新不调用清空列表的 `refresh`，不设置整页加载态。相同元数据不重建显示快照或推进 revision；后台读取期间用户的新选择/筛选在提交时捕获，而不是恢复请求开始时的旧选择。目录身份在枚举前后都检查，真实快照也记录其目录身份；同路径替换目录不会自动继承原目录身份，需用户显式刷新/重新导航才接受新对象。

### 21.2 选择、重命名与草稿边界

选择恢复复用 O4 身份索引：原路径且原身份优先，仅唯一身份允许跟随重命名，硬链接歧义不猜测；同名原子替换不继承选择。删除仅移除失效项，主选择消失不自动替选另一项；Shift 范围选择的原锚点也按身份恢复。搜索词、类型、排序、列表/网格、历史及前进/后退状态保持。

当前目录或祖先改名时，监听 fd 用 `F_GETPATH` 找到仍同身份的对象，按身份复用原订阅，支持连续改名；父目录快照也能识别子目录的唯一身份迁移。复用原重命名提交路径同步当前目录、管理根、书签、安全作用域、历史、展开节点、树缓存和选择，不跳转或清空列表。真实迁移项覆盖目标路径已有的失效缓存，避免重复 URL 使索引构造崩溃。

预览/编辑打开期间只暂存事件；关闭取消保留同一 WK 文档、脏状态和草稿。复制/移动/废纸篓批次期间同样延后。发起和完成两个阶段均检查占用状态，防止枚举途中打开编辑器后被迟到结果干扰。关闭完成或批次结束再校验元数据；不会把目录监听当成编辑器的自动重载，也不会改写草稿、放宽保存冲突或改变文档保存目标。

读取失败保留最后成功的元数据与原身份选择并显示原有错误状态，不把失败当成空目录。预览关闭读取失败也复用这一策略：目录在预览期间被改名后，监听仍可迁移原选择；同路径新目录的内容始终被身份门拒绝。最后快照不代表磁盘对象仍存在，文件操作继续校验身份。

### 21.3 回归与验收

- **196 项 Swift 全量通过**，日志 `build/f2-full-swift-tests-complete.log`。新增 `ExternalDirectorySyncTests.swift` **20 项**：真实 vnode 新增/删除/改名、多选/Shift 锚点、原子替换/硬链接、读取途中改选、事件风暴与尾随读取、导航/前进历史、可见树/收起分支、连续祖先及子目录改名、预览延后/途中打开/目录改名、目录删除/同路径重建、前台无变化/显式禁用、根移除、批次占用、订阅数量/释放、fd 身份和枚举期间目录替换。既有显式刷新单测显式关闭监听以隔离原读取次数断言；新增 F2 和完整原生流程使用默认开启的真实监听。
- **155 项 Python 构建工具通过，0 跳过**，`build/f2-python-tests.log`。本批未改 JS/媒体会话，独立 Node/WK、媒体与系统保存面板专项未重跑，不把前批结果合入本批计数。
- **61 项完整原生浏览/文本宿主检查通过，退出 0**，日志 `build/f2-native-host-tests-complete.log`；最终报告 `build/native-host-tests/run.eeIOu3/fixtures/report.json`，`testCase=all`、`mouseDriver=cgevent`。保留原 52 项及新增 **9 项 F2**：真实 List 多选、自动新增/删除/身份改名后的筛选/历史、原列表对象/精确滚动/焦点；真实 WK 草稿在通知和取消关闭后完全保留，放弃草稿后补齐元数据；当前目录改名同步根/历史，以及预览期间目录改名延后、关闭后恢复原身份选择。
- 原生外部文件操作由独立 `/usr/bin/touch`、`/bin/mv`、`/bin/rm` 进程作用于本次 UUID 夹具，收到真实内核通知，**并非驱动 Finder UI**；覆盖 Finder 同类操作的文件系统语义。最终外部样本字节、消失/新增文件及 F1 三个恢复样本均已复核。F1 仍仅按本次精确名称/原身份操作与恢复，不扫描或清空用户废纸篓。
- **完整原生 Debug 编译、ARM64 与严格签名检查通过**，`build/f2-app-compile-complete.log`。保留上游 3 个脚本阶段缺少 outputs 的既有警告；受限 Xcode 环境也报告 Simulator/XPC 服务不可用信息，最终编译和校验均退出 0。没有打分发包或替换日常应用。
- `build/f2-verification.json` 核验最终助手 **29 份源码**、Debug 同步输入 **30 份**及双方 **6 份编辑资源**与当前检出一致，记录 F2 测试、原生助手、验证日志摘要和实际样本字节。`git diff --check` 通过。上述 build 证据被 Git 忽略，不随源码提交。

专项入口：`FW_NATIVE_HOST_TEST_CASE=external-sync bash scripts/test-native-hosts.sh`；默认不指定专项继续完整流程，未知专项/鼠标驱动仍失败。早期独立专项 `run.P8jgVl` 的 8 项通过是补入“预览期间目录改名”前的阶段结果，最终以完整 `run.eeIOu3` 的 9 项 F2 为准。已授权备用 CGEvent 路径仍检查精确 PID/可执行路径、前台应用、key 窗口和内容区落点，最终 `activation.json` 记录仅对隔离助手的外部置前；未放宽原业务或模态断言。

保留失败依据：最初全量 Swift 在失效目标缓存碰撞时触发重复 URL，日志 `build/f2-full-swift-tests.log`，已修正迁移对象优先与去重并由原重命名回归验证；预览期间目录改名导致关闭丢选择的先失败回归保留在 `build/f2-preview-rename-before-fix.log`，最终同一断言通过。受限环境原生助手 `run.3ILq5o` 启动退出 134；完整流程 `run.6etnkx` 检测窗口失去活动状态后按原门禁拒绝 CGEvent，不计为通过。GUI 环境独立执行的最终 61 项全部通过，没有据此宣称定位了所有失焦或默认 NSEvent 稳定性根因。

### 21.4 收尾与交付状态

执行 simplify **Standard/feature**，自行检查 repo_fit、quality、reuse、efficiency。复用目录工作器、身份索引、原有路径迁移与失败展示，未另建磁盘内容缓存。清理空更新发布、旧身份映射的碰撞顺序及重复 URL；限制订阅范围/数量，避免每次协调都对全部 fd 做 F_GETPATH。补齐预览途中打开、目录在预览期间改名、枚举期间目录替换的竞态回归；最终验证结果以上节为准。

F2 交付时 F1/F2 源码与回归完成、F3–F9 仍保留；后续 F3 由第 22 节更新。默认 NSEvent 路径和真实慢卷/网络卷仍保留原范围限制。按用户要求，整体问题修复完成后再打包发布；本轮不提交、推送、打分发包、安装或发布，README 下载与日常安装继续构建 8。Debug 编译和隔离助手不代替新安装包验收。

## 22. F3 非 Office 草稿持久化与崩溃恢复（2026-10-26）

### 22.1 用户入口与恢复语义

欢迎页新增“恢复未保存草稿…”，完整原生应用的“工作台 → 恢复未保存草稿…”菜单始终可用。列表显示文件名、检查点时间、大小，支持恢复所选、稍后和带二次确认的删除所选；没有待恢复内容时明确提示，损坏/不兼容记录可保留重试或明确删除。不自动打开内容、不自动覆盖原文件，其他仍在编辑的进程/窗口记录不列入待恢复列表。

文本、CSV、PDF、图片均恢复为独立未命名且未保存的文档，首次保存进入另存面板，建议名为原名加“恢复”。原路径只作为列表提示信息，不用于重新读取、授权或重建可直接覆盖原文件的保存状态。即使崩溃后原文件已修改、删除、改名或替换，仍从独立副本恢复；用户显式另存到已有文件时继续走原有存在/覆盖/链接/权限保护。恢复后显示来源提示，原撤销/重做历史不恢复。

- 文本包含最近 Swift 会话已接收的完整正文及编码，保留检查点正文的 Unicode/原行尾。空正文恢复也保持 dirty，必须保存或明确丢弃，不能因为与新建空文档相同就静默关闭。
- CSV 在后台生成当前表格文本，保留分隔符、选择编码和实际序列化内容（包括短行/行尾）；编码变化而正文未改时仍保留原文本。恢复后重新解析表格。文本/CSV 另存为新文件时采用所选编码的默认 BOM，不声称保留原磁盘可选 BOM 的有无。
- PDF 保存当前已提交编辑缓冲区的完整编码字节，恢复前校验可读性，保留当前页序、旋转及批注等已经进入缓冲区的修改。
- 图片保存当前编辑缓冲区字节，不在检查点重复解码或重编码；恢复时解码一次用于显示，并按缓冲区实际格式识别保存类型。原 JPEG 编辑后的缓冲区可能是 PNG，恢复不强行转回原 JPEG；HEIC 沿用只能另存可写格式的约定。

### 22.2 检查点、原子性和占用

每个 `FWDocumentHost` 的 `FWDraftCheckpoint` 跟随内容真实 dirty 状态。仅修改过的内容产生副本，未修改预览和普通空白新建文档不写入。750 ms 尾沿防抖，连续输入最长每 5 s **触发一次提交**，实际落盘还受排队和磁盘速度影响。主 actor 只捕获 COW 文本/表格/Data，CSV 序列化、UTF-8 生成、摘要与文件 I/O 在 `DraftRecoveryStore` actor 上执行。每个宿主最多一份在途内容快照，途中变化仅记待刷新，不不断排队保存旧的大图。界面区分待更新、已更新及失败；失败保留内存草稿和上次成功副本。

记录使用 UUID 文件名，版本化有界 JSON 头 + 原始正文，包含类型、编码/分隔符、原路径提示、时间、字节数和 SHA-256。目录权限 0700，文件 0600，按持有目录 fd 操作，拒绝链接/硬链接/非普通记录；头最多 16 KiB，读取前核验大小，恢复时核验正文摘要与格式。列表只读取头，不为列出 20 份记录读取数 GiB 正文。

全局 flock 串行化跨进程的配额、原子替换和清理。owner 文件创建/持锁也在同一事务内，不能把尚未加锁的新进程误当成遗留项清理；记录占用使用 OS 文件锁，进程被 SIGKILL 后自动释放，避免 PID 重用误判。两个应用不能同时认领同一副本，活跃记录不能从其他会话恢复或删除；打开失败释放认领，保留原副本。全局事务内用 fd 枚举目录，避免路径核验后移动时混入另一目录的配额结果。

先向独立临时文件完整写入并 fsync，再 rename 替换，旧副本在新写入成功前保留；尽力 fsync 目录项。只承诺已完成检查点的进程崩溃恢复，不把它说成断电/硬件故障的绝对持久保证。单调 generation 阻止旧任务复活已清理草稿。保存成功且当前内容已无修改时清理对应记录；保存期间继续编辑仍保留最新草稿。正常关闭成功/明确不保存会等待清理，取消关闭不清理；清理失败显示错误，不静默当成成功删除。

### 22.3 目录、上限与清理策略

默认位置为 `~/Library/Application Support/FileDeck/DraftRecovery-v1/`。这些是本机独立恢复副本，不是云端备份，也不写回原文件目录。正式工作区不使用测试变量；测试进程必须带成对目录/令牌，使用本次 UUID 夹具下的恢复目录。

| 约束 | 策略 |
| --- | --- |
| 单份正文 | 最多 256 MiB；文本/CSV 的编辑/保存能力仍遵循其既有 10 MiB 约束，不因恢复配额提高而放宽 |
| 已提交副本总量 | 最多 512 MiB，包含记录头；最多 20 份，活跃和损坏记录也占用配额 |
| 原子写入临时空间 | 全局事务最多另有一份正文 256 MiB + 16 KiB 头 + 12 字节前缀的暂存文件；逻辑文件峰值不超过约 768 MiB + 16 KiB，不计文件系统块/日志开销 |
| 保留期限 | 从最近成功检查点起 30 天；在打开恢复列表或写检查点时清理，无独立后台守护任务 |
| 自动清理范围 | 可识别且未占用的过期记录、崩溃遗留的临时写入文件、无记录引用且未占用的 owner 锁文件；活跃记录不因到期被清理 |
| 超限/磁盘满/权限失败 | 拒绝新检查点，保留旧完整副本和内存内容并显示失败；不静默淘汰未过期的其他未保存草稿 |
| 损坏或新版本 | 结构无法识别的记录保留供明确删除，仍计配额；正文在恢复时才做摘要校验，头可识别的过期记录仍按上述 30 天策略清理 |
| 用户清理 | 恢复入口按项选择并二次确认，仅删除该恢复副本，不删除原文件，不提供未经确认的清空 |

恢复范围为最近已完成的检查点：尚未从 WebKit 桥接到 Swift 的输入、尚未提交的 CSV 单元格/编辑对话框、在途媒体变换、最后一次提交后新输入及撤销历史不保证恢复。原文件另有外部变更仍保留正常保存冲突门；Office 恢复继续由原内核负责，本批不推断或改变其行为。

### 22.4 回归、真实崩溃与一致性证据

- **217 项 Swift 全量通过**，`build/f3-full-swift-tests-final.log`。新增 **21 项**：`DraftRecoveryStoreTests.swift` 20 项真实目录/文件锁回归，覆盖正文/编码/Unicode/混合行尾/空内容、CSV 分隔符/短行、媒体字节直存、活跃占用/认领/失败释放、generation、单份/数量/总量配额与旧副本保留、过期但活跃不删除、损坏摘要/新版本/有界头/头空白、符号链接/硬链接/FIFO、根替换、遗留临时文件、权限、拒绝 Office 和多实例共享配额；`TextDocumentSessionTests` 新增恢复空正文仍 dirty、拒绝隐式保存、关闭保护及显式另存 BOM/基线回归。
- **155 项 Python 构建工具通过、0 跳过**，`build/f3-python-tests-final.log`。显式源清单及新增 `desktop-apps-011-draft-recovery.patch` 纳入 ARM 目标和完整补丁链幂等校验，没有把新文件只留在 SwiftPM 或测试助手中。
- **30 项真实崩溃恢复检查通过**（writer 4、reader 26），入口 `bash scripts/test-draft-recovery.sh`，最终日志 `build/f3-crash-tests-complete.log`；报告位于 `build/draft-recovery-tests/run.3fgKD7/fixtures/{writer,reader}-report.json`。writer 实际编辑文本/CSV/PDF/图片，连续输入也产生检查点，五份草稿（含独立清理样本）最后状态均确认已更新；父进程再次核验精确 PID/可执行路径，检查点就绪后发送 **SIGKILL**，等待退出码 **-9**，由不同 PID 的全新 reader 恢复。
- reader 实际使用恢复/稍后/删除确认/取消关闭面板，验证四类独立 dirty 文档、文本同一 WK 及正文/行尾、CSV UTF-16/分号/短行、PDF 两页/90° 旋转和图片 4×8 变换像素。四类显式另存真实写盘并清理副本；超限在真实宿主显示失败，保留 dirty、旧完整副本和原文件，明确不保存后才清理。父进程在崩溃后修改文本、删除 CSV、改名 PDF、替换图片，reader 逐项复核外部版本/缺失状态未被覆盖或重建。此专项的另存 I/O 使用显式临时目标，不额外宣称恢复后的每一种系统另存面板都逐个验收。
- `run.3fgKD7/crash.json`、两个 PID/激活记录、`checkpoint-ready.json` 和 `external-sources.json` 保留终止/来源证据；`welcome-minimum.png` 已核验真正的 **640×600** 欢迎页恢复入口与内容不被裁切，另外保留恢复列表、文本恢复及超限提示的视图缓存图。辅助 bundle 不包含日常图标，缓存图中的透明背景/占位图标不代表安装包渲染结果。
- **50 项完整文档/真实系统面板检查通过**，`build/f3-modal-documents-tests-final.log`，报告 `build/modal-document-tests/run.ccVcyi/fixtures/report.json`。继续覆盖未保存取消、失败保存、外部冲突、WebKit 内存恢复、版本差量与系统另存；面板由原精确应用/令牌/标题/文件名门禁的 AX 助手按真实保存按钮，错误令牌被拒绝。仅对本次独立 PID 置前，记录 `activation.json`，没有放宽原断言。
- **61 项完整浏览/文本宿主检查通过**，`build/f3-native-host-tests-final.log`，报告 `build/native-host-tests/run.tCF85O/fixtures/report.json`，`testCase=all`、`mouseDriver=cgevent`。原 F1/F2 以及 List/精确滚动/焦点/关闭/草稿检查完整执行；F1 本次三个 UUID 样本逐项恢复并核对字节，不扫描/清空用户废纸篓。
- **15 组原生媒体/CSV 回归通过**，`build/f3-media-tests-final.log`，继续覆盖 JPEG/PNG 保存与图片变换、CSV 字节/编码/撤销及 PDF 变换/上限/历史。未改动的独立 Node/WK 资源专项未重跑，仍以其原批次范围保留。
- **完整原生 Debug 编译、ARM64 与严格签名通过**，`build/f3-app-compile-final.log`；保留上游 3 个脚本阶段无 outputs 警告及受限环境的既有 Xcode/Simulator/XPC 信息，最终编译和校验退出 0。没有打包、安装或运行替换后的日常应用。
- `build/f3-verification.json` 核验崩溃助手 **30 份源码**、浏览助手 **30 份源码**、系统面板助手 **19 份源码**、Debug 同步输入 **31 份**以及各助手/Debug 的 **6 份编辑资源**与最终检出一致。另存的文本/CSV 实际字节、四类恢复文件摘要、外部版本和 F1 恢复样本均复核；记录测试及验证日志 SHA-256。`git diff --check` 通过。build 证据被忽略，不随源码提交。

保留失败与修正依据：受限环境 `run.z5T41U` 无法执行 ps 核验，助手安全停止、未执行未核验的 SIGKILL；`run.HsynCr` 的 44 次输入实际不足 5 秒，探针错误地要求最长触发器已生效，已改为连续输入超过 5 秒后检查；`run.QuAjTR` 已成功强杀/重启并通过恢复/清理入口，但文本预期误用了输入助手规范化前的行尾。最终以 writer **真实编辑器已经同步的正文**作为崩溃基准，逐字节核对恢复及另存；混合行尾/编码另有存储和会话回归，没有放宽恢复正文断言。受限媒体首轮因 macOS 视图/字体服务触发 SIGTRAP，`build/f3-media-tests.log` 保留；在本机 GUI 服务环境按原检查重跑 15 组通过。

### 22.5 收尾与交付状态

执行 simplify **Standard/feature**，自行检查 repo_fit、quality、reuse、efficiency。复用四类现有保存/另存与内容构造，不为恢复建立自动覆盖原文件的 I/O 分支；合并记录扫描结果，列表不读全部正文；用单在途快照和尾随标记限制慢盘队列。修正 owner 文件创建与清理竞态、目录路径枚举竞态、读取 FIFO 可能阻塞及已更新提示未体现待更新状态，保留对应回归与真实窗口验证。未扩展 Office 的恢复实现。

F3 交付时 F1–F3 源码及对应回归已完成，F4–F9 当时仍保留；F4 后续进展见第 23 节，安装包/真实慢卷/断电等边界不由辅助进程结果替代。按用户要求，整体问题修复完成后再打包发布。本轮未提交、推送、打分发包、安装或发布，README 下载与日常安装继续构建 8。

## 23. F4 文件操作进度、取消与撤销（2026-10-26）

### 23.1 入口、进度与取消边界

复制（导入、粘贴、Option 拖放）、内部移动和多选移到废纸篓共用浏览页顶部的进度与结果区域，显示操作、已处理/总数量、当前文件名、取消及逐项错误。数量按规范路径去重，保留硬链接的不同目录项；不是字节进度，也不提供剩余时间估计。后台只更新加锁快照，主线程最多每 100 ms 取一次变化，避免每个文件排队一次 UI 发布。原有身份检查与互斥门禁保留，目录被动同步在批次状态提交结束后继续。

“取消”是协作停止：阻止后续项目，等待正在执行的 Foundation 复制或系统移动/废纸篓调用结束，不强制终止线程。复制当前项未提交时清理其私有暂存；若已提交则保留并登记成功。移动/废纸篓当前项完成后仍计入成功与撤销；已完成项不自动整批回滚。停止过程中继续显示当前文件与“等待当前项目结束”，门禁保持；慢卷上的单项调用没有立即返回的保证。撤销本身也有进度和取消，已撤销项目不会重复执行。

批次结束显示成功、失败、未执行与总数，并保留各项原因和残留位置。一个项目失败继续处理其余项目，取消后未开始的项目不标为失败；取消当前未提交副本也计入未执行，不把清理成功说成复制成功。部分失败不影响成功项的撤销入口。

### 23.2 复制提交、残留与跨卷处理

复制先在目标目录创建本批独占的 `.FileDeck-transfer-<UUID>/`（0700），用 Foundation 复制为 `payload`，再用 `RENAME_EXCL` 原子提交到最终文件名。提交前复核目标目录身份，遇到已有文件/悬空链接不覆盖；粘贴继续生成“副本”名称。文件夹、文档包和符号链接本身沿用 Foundation 复制语义，不主动解引用符号链接目标。

失败或提交前取消，只在隔离目录身份仍匹配时清理本次暂存，不删除同名最终目标或其他批次目录。清理失败/身份无法确认时保留文件并在结果中列出临时路径及错误；完整副本已提交时仍登记成功/撤销，另附清理警告。目录在操作中被外部改名可能使报告路径失效，应检查原目标的实际位置；不扫描其他目录或自动清除未知隐藏文件。应用崩溃/强制退出时可能留下私有暂存，本轮没有为文件批次新增跨进程恢复或启动自动清理。

同卷移动使用排他重命名。跨卷移动遇到 `EXDEV` 时先提交完整隔离副本，再复核源身份并删除原件；该关键单项过程不响应中途取消。若删除原件失败，保留完整目标副本并报告两端路径，源端也可能只剩部分目录内容；不冒险自动删除完整副本或把不完整移动登记成可安全撤销。用户需核对两端再手动处理，不能不看同名冲突直接重试。身份校验与后续系统调用不是原子事务，不宣称消除所有外部并发修改/替换窗口。

### 23.3 撤销语义与生命周期

| 操作 | 撤销方式 | 安全边界 |
| --- | --- | --- |
| 复制 | 将本次创建的副本移到系统废纸篓 | 不永久删除，不动原件；原地编辑且身份未变的副本内容也留在废纸篓，原子替换的新身份拒绝处理 |
| 移动 | 将成功项从目标排他移回原路径 | 项目、当前位置父目录及原父目录身份均须匹配；原位已有文件或悬空链接时失败并保留两端，不覆盖 |
| 移到废纸篓 | 按系统实际返回的位置排他恢复到原路径 | 不按文件名扫描/猜测废纸篓；跨卷等身份变化或恢复位置无法登记时，显示错误或警告并保留 Finder 手动恢复路径 |

只保留**本窗口最近一批复制/移动/废纸篓成功项**的内存记录，下一批开始即替换，关闭窗口或应用后失效；不含重做，不接管文档编辑的 UndoManager/⌘Z。收起结果不清除仍可撤销的记录。按逆序撤销；失败项和取消后未执行项保留供排除冲突后重试，已成功撤销项立即移除。没有登记成功位置/身份的部分失败只提供人工核对，不猜测回滚。

移动及其撤销复用 `completeFileRelocation`，同步当前路径、管理根、书签/作用域、导航历史、展开树和选择。完成后刷新最新浏览位置，不跳回批次发起位置，不覆盖期间的新查询/选择；废纸篓及复制撤销仍走正常刷新和原身份选择保护。

### 23.4 回归与原生验收

- **236 项 Swift 全量通过，新增 19 项 F4 回归**，`build/f4-full-swift-tests-final.log`。`FileOperationTests.swift` 覆盖开始前取消、复制中取消及已完成项撤销、复制失败后继续/私有清理、清理失败路径、已提交副本清理失败仍可撤销、隔离目录替换不清理、同名/悬空链接与副本命名、原地编辑副本保留到废纸篓、移动当前项取消、撤销冲突重试/取消/身份及父目录替换、提交后目标替换不登记新身份、包/链接复制、EXDEV 成功身份与源删除失败残留，以及工作区进度/查询/导航/管理根同步。跨卷通过受控 I/O 注入，不冒充真实挂载卷验收。
- **155 项 Python 构建工具通过，0 跳过**，`build/f4-python-tests-final.log`。完整 Debug 编译、ARM64 和严格签名通过，`build/f4-app-compile-final.log`；没有生成分发包或替换安装。
- **70 项完整原生浏览/文本宿主检查通过，新增 9 项 F4**，最终 `build/native-host-tests/run.mfxR7Z`，`build/f4-native-host-tests-final.log`。实际点击进度区域的“取消”及三次“撤销”，验证当前系统废纸篓调用结束后停止、后两项未执行、新选择保留、精确系统返回位置恢复、真实同卷移动恢复、副本撤销进入系统废纸篓并保留原件；所有本次 UUID 废纸篓样本均恢复。含 F1 的真实菜单/身份替换/部分失败，以及 F2 的 vnode 同步/选择导航/草稿保护。
- `file-operation-progress.png`、`file-operation-cancelling.png`、`file-operation-result.png` 已检查实际数量、当前文件、等待提示和撤销入口。SwiftUI 进程内树未暴露按钮，最终使用此前明确授权的 CGEvent 路径，按截图核验坐标并保留前台/key 窗口/内容区门禁。早期协议名称编译错误、AX 子树缺失、坐标定位和窗口失焦失败报告保留于 `run.OJr3Vk`、`run.HKE8Qo`、`run.SSb9sA`、`run.x4y9qm`；恢复精确测试窗口焦点后专项 `run.UQn28K` 9 项通过，再由最终完整运行覆盖。
- `build/f4-verification.json` 核对最终助手 **30 份**源码快照、Debug **31 份**同步输入与当前检出 SHA-256 一致，双方 **6 份**编辑资源一致；记录测试/日志摘要与 F1/F4 已恢复样本字节，无本次残留暂存。辅助应用仅运行隔离样本和偏好，未扫描/清空用户废纸篓。
- 本批未改 JS、媒体编辑、系统另存或持久草稿逻辑，独立 Node/WK、媒体、完整文档/系统面板及 SIGKILL 恢复专项未重复运行；其历史证据保留在第 17、18、22 节。未验证真实慢卷、大文件单项停止延迟、真实跨卷硬件/拔盘、断电或文件操作崩溃后的事务恢复，不把模型注入或原生助手结果扩展为这些保证。

### 23.5 收尾与交付状态

按 simplify **Standard/feature** 自行检查 repo_fit、quality、reuse、efficiency：复用既有身份、排他移动与目录迁移路径；复制/移动共用暂存提交，撤销复用相同移动边界；进度只保留一份快照且仅发布变化。收尾合并结果详情拼接、复用单次进度读取，保留“已提交但清理失败”仍有撤销和“提交后被替换不接管新身份”的回归。没有扩展为永久删除、持久化撤销或并发文件任务调度。

F4 交付时 F1–F4 已补齐后续源码与对应回归，F5–F9 当时仍保留；F5 后续进展见第 24 节。按用户要求，整体问题处理完成后再打包发布；本轮未提交、推送、生成分发包、安装或发布，README 下载与日常安装继续构建 8。辅助程序结果不替代正式安装包、真实跨卷/慢卷或中途断电验收。

## 24. F5 限定目录的递归名称与内容搜索（2026-10-26）

### 24.1 入口与检索范围

浏览工具栏在当前目录筛选框旁新增“递归搜索”。原“搜索当前目录”和左侧已加载树过滤保持原语义，不在键入时偷偷启动递归扫描。独立面板默认当前目录，可点“当前目录”或通过系统目录面板选择其他已授权目录；选择范围不添加管理根、不改变导航。明确按“搜索”或 Return 才开始，不默认扫描全盘或全部管理根，不创建后台全文索引。

名称模式匹配子树内项目的**末级名称**（普通目录和普通文件），不匹配整段相对路径，不包含范围根本身。内容模式仅读取 `TextPreviewLoader.isTextFile` 认可的普通文本文件，复用 `DocumentIO.decode` 的 BOM/UTF-8/UTF-16/GB18030、无损往返及二进制判定；不解析 PDF、Office 压缩容器、富文本或图片。空白搜索词拒绝，搜索词去除首尾空白，长度最多 512 个 UTF-16 单元；按字面子串匹配，默认不区分大小写，可切换区分大小写，不提供正则、通配符、全文索引或替换。

每个文件最多一条内容结果，显示首个命中的行号及有限上下文；CRLF、独立 CR 和 LF 按行处理。摘要最多 200 个 Unicode 标量（UTF-8 最多 800 字节），不让一个带大量组合附加符的字素撑大结果。定位只进入父目录并选中文件，不自动打开编辑器或跳转编辑器行号；定位前在后台重新检查根/相对目录路径/对象身份，失效结果提示重搜。定位才显式改变导航/选择并按正常导航清除当前筛选；定位隐藏结果时显示隐藏项。未定位直接取消/关闭不恢复旧快照，不覆盖期间合法发生的新导航、选择或外部同步。

### 24.2 排除规则与预算

默认排除目录名（不区分大小写）：`.git`、`.svn`、`.hg`、`node_modules`、`vendor`、`pods`、`carthage`、`.build`、`build`、`dist`、`deriveddata`、`.next`、`.cache`。面板可修改或清空，用英文/中文逗号或换行分隔；仅接受末级目录名，最多 128 项，每项最多 255 UTF-8 字节，拒绝 `/`、NUL、`.` 和 `..`。这些是常见依赖/版本库/构建目录的名称排除，不会先递归统计大小来判断“大目录”。显式选择名为 `build` 的范围根仍可搜索，只对其子项应用排除规则。

默认跳过点名或系统隐藏标记的项目，可显式包含隐藏项。文档包、符号链接（含链接文件）、FIFO/设备等特殊文件和根卷之外的项目始终跳过；不展开文档包内部，不跟随链接，也不自动遍历其他挂载卷。包判断沿用 `FileSystem.isPackageDirectory`，包括 RTFD 回退，名称模式也不返回被排除的目录/包。硬链接的不同目录项保留各自路径，不按 inode 合并文件结果。

| 预算 | 默认及处理 |
| --- | --- |
| 枚举项目 | 最多 50,000；隐藏/排除/读取失败的目录项也计数，超过停止并标记结果不完整 |
| 结果 | 最多 1,000；达到即停止并显示上限，已收集结果按相对路径作稳定名称排序 |
| 目录深度 | 最多 64 层；到界目录本身可作为名称结果，未枚举子树计入深度跳过 |
| 内容单文件 | 最多 2 MiB，按读取字节限制；超过跳过，不把截断前缀当成完整文件搜索 |
| 内容总量 | 最多 256 MiB，包含已读取但取消/变化/编码不支持的字节；耗尽停止并标记不完整 |
| I/O 错误详情 | 保留总数，最多显示 20 项具体路径/原因；一项失败继续其余项 |

界面显示本次冻结的目录/词/模式、已扫描数量、结果数量、已读取字节、当前相对路径、跳过分类与错误，不使用不可靠的总项目百分比或剩余时间。超限、取消和错误不报告为完整无命中；普通“搜索结束”也同时展示排除/跳过数，大小/深度限制、对象变化或读取错误明确提示结果不完整。遍历次序来自文件系统，达到上限时不是全树按字典序最前的 1,000 项；最终排序只作用于已收集结果。

### 24.3 取消、并发与只读一致性

请求冻结目录路径和检索条件；默认在**唯一后台工作器开始时**绑定该路径的目录身份，表单提交不在主线程执行慢卷 stat。已有快照的调用方可传入预期根身份，拒绝开始前的同名替换。根身份绑定后，在目录读取、正文分块及完成时核验；根被替换/改名使路径失效则停止并提示重选，不把原对象结果当成新目录结果。

使用 `openat`/`O_NOFOLLOW`/`O_NONBLOCK` 按相对组件打开目录和文件，目录枚举使用持有 fd，正文仅接受与快照相同的普通文件。每次正文读取最多 64 KiB，读取前后检查取消；读取后核对对象身份、大小、mtime/ctime、当前目录和名称仍对应原对象，再解码/提交命中。读取中变更或原子替换不作为稳定命中。包属性因 macOS `/dev/fd/<fd>/<child>` 不是可用目录路径，使用候选 URL 并在属性查询前后核验身份；正文仍走描述符边界。检查与系统调用不是原子事务，不宣称消除所有外部并发改名/修改窗口。

一个搜索面板会话最多一个真实工作器；重新搜索请求取消旧工作器，并只保留最新待执行请求。旧工作器的真实系统调用返回前不另开扫描，旧代次不能发布到新结果；关闭/重开和取消排队请求也不复活旧结果。取消保留此前已找到的结果，当前未提交正文不追加；不能强制中断阻塞的单次系统调用或正在运行的解码。工作器快照与界面每 100 ms 合并取样，不逐文件派发 UI 任务。搜索只读且不写回文件、不接管文档草稿/保存流程，结果为一次快照，外部变更后需重搜。

### 24.4 回归与原生验收

- **262 项 Swift 全量通过，新增 26 项 F5**，`build/f5-full-swift-tests-final.log`。`DirectorySearchTests.swift` 覆盖限定子树/仅末级名称/Unicode/字面与大小写、默认/自定义排除/隐藏/显式同名根、文档包/链接/FIFO/模拟其他卷、UTF-8 BOM/UTF-16/GB18030、二进制/容器跳过、混合行尾/首命中、深度/枚举/结果/单文件/总量预算及不完整提示、开始前/正文中取消、I/O 失败继续与详情上限、链接替换不读外部、读取中原子替换/根替换、定位拒绝失效身份/祖先链接/路径越界、最新请求合并/取消排队/清除旧结果、后台绑定与有界组合附加符摘要。扫描预算使用确定性元数据失败覆盖；本机文件系统拒绝创建无效 UTF-8 名称，没有把该分支说成实测通过。
- **155 项 Python 构建工具通过，0 跳过**，`build/f5-python-tests-final.log`。新增文件进入显式同步和 `desktop-apps-012-directory-search.patch`，ARM 目标源码/原生路径与完整补丁链幂等检查通过；其他目标未混入 Swift 文件。最终 Debug 编译、ARM64 和严格签名通过，`build/f5-app-compile-final.log`，没有分发打包/安装。
- **79 项完整原生浏览/文本宿主检查通过，新增 9 项 F5**，最终 `build/native-host-tests/run.l68Rb9`，`build/f5-native-host-tests-final.log`。实际工具栏打开/关闭、输入与 Return 启动、取消按钮响应、名称/文本模式切换、中文首命中行/摘要、定位返回父目录并选中、关闭保留导航/筛选/选择以及只读原字节通过。取消使用隔离工作器等待闸门验证 UI 响应和槽位保留，释放后使用真实 fd 搜索 UUID 树，不冒充物理慢卷。F1/F4 废纸篓样本均精确恢复，F2 外部同步及文本草稿/保存保护继续通过。
- 已检查 `search-entry.png`、`search-running.png`、`search-name-results.png`、`search-content-results.png` 以及工具栏截图。测试使用此前明确授权的 CGEvent，只操作本次隔离窗口，保留前台/KeyWindow/内容范围门禁。早期 `run.F3e6Ww`、`run.Wzth6J` 的点击坐标与 NSHostingView 翻转、`run.S3puYi` 的 List 包装层定位问题已按实际截图修正；专项 `run.tHA87V` 9 项通过。完整套件 `run.CLHY2L`、`run.HZ2jlb` 在既有目录/废纸篓阶段失焦被拒绝，明确恢复对应测试窗口后最终完整运行通过；没有放宽业务断言。
- `build/f5-verification.json` 核对最终助手 **31 份**源码快照、Debug **32 份**同步输入与当前检出 SHA-256 一致，双方 **6 份**编辑资源一致；记录测试/补丁/日志摘要、搜索原文件与 F1/F4 已恢复废纸篓样本字节。搜索不修改源文件、不生成磁盘索引。
- 本轮原生验收使用已打开的当前范围；另选目录的系统授权面板复用既有入口，没有另做系统目录面板按钮驱动验收。真实慢卷/挂载卷/拔盘、全树瞬时一致性和峰值内存未实测。独立 JS/WK、媒体编辑、完整文档/系统另存及 SIGKILL 草稿恢复专项未因本批重复运行，保留第 17、18、22 节的原范围，不把旧助手摘要当成当前源码一致性。没有测试或承诺 PDF/Office 正文提取、全盘索引或编辑器跳行。

### 24.5 收尾与发布状态

执行 simplify **Standard/feature**，自行检查 repo_fit、quality、reuse、efficiency。复用文件身份、包/文本类型和无损解码，独立搜索状态不挤入浏览显示快照；正式 Xcode ARM 源清单及 `desktop-apps-012-directory-search.patch` 同步接入，补丁链仍可重复应用。收尾修正主线程范围 stat、无效文件名预算边界和组合附加符摘要膨胀，保留对应后台绑定/失败计数/有界摘要回归。未扩大为全盘索引、PDF/Office 文本提取、自动扫描、编辑器跳行或搜索替换。

F1–F5 已补齐后续源码及对应回归，F6–F9 继续按审查文档保留。按用户要求整体问题处理完成后再打包发布；本轮未提交、推送、生成分发包、安装或发布，README 下载与日常安装仍为构建 8。Debug/辅助程序和确定性阻塞注入不替代正式安装、真实慢卷、拔盘或断电验收。

## 25. 性能基准与文档提交前复核（2026-10-27）

产品中的 O1–O4 实现已随 `58a9310` 保存。本轮审查剩余三类基准、11项大目录测试和三份文档，修正以下问题：

- **旧基线依赖清单失效**：原脚本用当前清单读取旧 Git 提交，后续加入 DraftRecoveryStore/DirectorySearch 后，文档指定的构建8对比会因缺文件失败。现在浏览探针从各自 Git 树取文件，CSV/媒体跳过旧树中不存在的新增依赖并记录遗漏，不混入新代码。
- **媒体算法比较失真**：原脚本固定让 baseline 逐行高亮，基线取 HEAD 且已优化时也会被人为降级。现在按每个快照的实际 `addHighlights` API 选择批量/逐行路径，报告标记 `pdfHighlightMode`；旧基线为 legacy-loop，当前为 batch。HEAD 同能力的行为由真实源码回归验证。
- **探针与测试失败保护不足**：探针补缺参/非法场景拒绝，冻结两侧共同探针字节并记录编译环境；浏览偏好隔离，图片撤销增加 dirty 断言。取消等待用例加有界完成检查，回归时先超时清理闸门，避免整个测试进程挂起。
- **文档当前状态过期**：统一说明实现已本地提交、构建11已安装、README仍链接构建8，保留历史数字；更新 F6、跨格式保存返回、Tab/撤销及批次撤销的实际行为。

验证：**11项大目录专项通过；159项构建工具中157项通过、2项环境跳过**，其中新增4项覆盖旧树文件选择、旧/新依赖快照、实际摘要及媒体 API 分支。三个真实 `swiftc -O` 基准均使用文档给出的 `59b5591da06ef586cf92a44971003eca380bde61`，完成编译、运行、保存/源文件/撤销或选择恢复断言。三个探针无参数均退出64，媒体非法场景退出64且未生成报告。

本次单机复采样示例：

| 场景及计量范围 | 基线 | 当前 |
| --- | ---: | ---: |
| 10万行×10列 CSV 单格提交，中位数/21次 | 137.7433 ms | 0.0108 ms |
| 20页/120高亮模型处理、校验与输出 | 1484.39 ms | 29.07 ms |
| 万文件刷新、枚举与状态恢复 | 84701.49 ms | 516.31 ms |

这些不是完整 GUI 帧延迟、慢卷保证或跨机器收益；基线先运行且为非独占采样，缓存/负载可影响数值，不设机器相关通过阈值。第16–19节数字仍对应原历史样本。本机原始结果与源码摘要分别在 `build/csv-performance/run-8v9o4xqz/comparison.json`、`build/media-performance/run-qht75y4f/comparison.json`、`build/browser-performance/run-zh84ona_/comparison.json`；本轮汇总在 `build/performance-review/report.md`，`build/` 不随 Git 分发。本轮只修改探针、测试和文档，不改变已安装产品的运行源码。
