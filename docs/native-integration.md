# 居中预览与原生编辑集成

更新时间：2026-10-25。适用于锁定的 `desktop-apps` 提交 `8f452c7f703b795dcc09012ba6517df4ca47f9bc`；运行证据见 [弹窗验收](modal-preview-acceptance.md)及[后续源码回归](code-review-and-roadmap.md#14-媒体变换边界与菜单能力修复2026-10-25)。

## 工作台与临时会话

`FWBrowserHost` 常驻一个 SwiftUI `ContentView`，目录树与文件列表始终挂载。`WorkspaceEditorBridge.preview` 传递稳定文件引用和触发来源；单击仅选中，双击文件、Space/Return 和右键预览进入独立 `FWPreviewModal`。它在原窗口内容上叠加遮罩与 AppKit 对话框，不更换窗口控制器或重建工作台。

打开前，`BrowserStore.capturePreviewSnapshot` 保存目录/文件身份、多选、筛选、排序、视图与展开节点；弹窗另外弱引用原响应者及原生滚动容器位置。打开默认只读且聚焦中性容器；背景不接收输入，可访问性隐藏，Tab 限于模态控件。

`FWDocumentHost.openPreview` 为文本、代码、JSON、YAML、Markdown 提供真实只读内容，用户点击“编辑”后复用同一个 WKWebView/CodeMirror。其余预览由 `FilePreviewSession` 管理，独立请求序号、Task 取消和资源清理避免迟到结果覆盖新文件。

关闭经同一文档关闭门处理；脏状态、保存执行中、弹窗生命周期、预览请求与工作台快照分别维护。确认取消时保留编辑器实例和撤销历史；保存只有真实成功后才更新保存路径。关闭清理弹窗资源后局部枚举原目录，按身份恢复选择、滚动及有效焦点；读取期间保留输入门，避免旧快照覆盖新导航。

## 原生窗口和兼容编辑器边界

- 入口仍是 `main.mm → AppDelegate → ASCTitleWindowController → ASCCommonViewController`，保留原窗口 `contentViewController` 与上游退出链。
- `FWWorkbenchCoordinator` 仍持有原 `NSTabView` 和原生文档会话；应用菜单创建/打开的 Office、CSV、PDF、图片会话使用兼容模式的居中工作层。
- 只移动整个 `NSTabView`；Office 的 `NSCefView` 仍为 `NSTabViewItem.view` 的直接子视图，原保存和退出路径保持有效。
- 原生会话用 `fw:<UUID>` 标识，`webView` 为 nil，不能强转为 CEF 或将标识转整数后销毁 Office 实例。
- 现代文本弹窗开启时，菜单保存路由到该弹窗；不能误写后台 Office 标签。窗口关闭及应用退出先检查现代弹窗，再进入原有文档关闭链。
- Office dirty/保存真值仍来自原内核；原生文档由 `FWDocumentHost` 和 `SafeFileIO` 处理，不另写一套 Office 保存实现。

## 文件写入与资源

文本完整编辑上限 10 MiB，截断预览不能直接保存。文本、CSV、PDF、图片共用 `SafeFileIO` 的快照与外部变更检测；删除后保留草稿并要求系统另存，移动位置无法可靠识别时不自动写向同名文件。Markdown 不自动请求外部资源，相对路径资源保持原安全限制。

系统另存明确选择已删除的原路径时，允许以排他新建方式重建它；普通保存仍报告外部变更。目标已存在、链接变化或写入期间出现其他版本时仍拒绝覆盖，不能因选择“另存”就跳过这些保护。

PDF/图片的 `FWBinaryState` 初始化、替换、异步变换结果与最终保存采用相同的 256 MiB 上限，超限结果在提交前拒绝，原内容和撤销历史保留。PDF 合并、图片追加及图片新建 PDF 通过 `SafeFileIO.openMediaBatch` 逐份读取；累计输入预算包含当前 PDF 缓冲区，超过剩余额度时停止读取后续文件。该预算约束压缩输入字节和最终缓冲区，不等于 PDFKit/ImageIO 解码、序列化或撤销历史的总内存硬上限。

`FWNativeContent` 对查找/撤销/重做默认返回不可用；实现者根据真实能力和历史提供状态。`FWDocumentHost` 门面、标准 responder 校验与 `FWWorkbenchCoordinator` 菜单共用这些状态，忙碌及关闭时禁用命令。文本的历史标志来自 CodeMirror 的 change/state 消息，重新读取/重建清空旧标志；只读文本和 PDF 可以查找，CSV/图片/Quick Look 的查找禁用。CSV 搜索属于尚未实现的独立功能。

`FilePreviewSession.cancel` 同步暂停 AVPlayer、移除 item/observer、清空 AVPlayerView，以及取消并清理 Quick Look。所有异步结果检查有效请求，关闭后不能重新呈现。

`native_sources.py` 显式同步原生源码和资源；`003–008` 保留已有桥接、工作台与品牌，`009` 注册弹窗。补丁链支持重复应用。编辑资源位于 bundle 的 `FileWorkbenchEditors/`，与上游 `editors/` 分开，运行不需要 Node/Python。

## 验证入口

- `bash scripts/test-native-hosts.sh`：实际文件列表双击、键盘、焦点、精确滚动、调整窗口、保存失败和快速切换。
- `bash scripts/test-modal-documents.sh`：真实 WebKit、原生确认与 NSSavePanel，验证取消恢复、外部冲突和删除后另存。
- 系统面板由 `NativeOffice/Tests/SystemSavePanelDriver.swift` 在外部按真实 AX 按钮，需已有 Accessibility 权限；本进程不投递 Return、不调用 `NSSavePanel.ok` 或伪造完成回调。助手核对随机令牌、进程/可执行文件、面板标题及文件名，拒绝错误令牌；缺权限或没有真实系统回调均失败。`FW_MODAL_DOCUMENT_TEST_CASE=save-panel` 可单独运行此场景。
- `FW_MODAL_DOCUMENT_TEST_CASE=menu-capabilities bash scripts/test-modal-documents.sh`：真实 WK 输入、撤销重做、只读/载入/故障/关闭状态及 responder 菜单校验。
- `python3 -B scripts/onlyoffice/test_native_content.py`：真实 PDF/图片/CSV 会话、可注入大小边界、正常批量处理及撤销、各类菜单能力。
- `python3 scripts/onlyoffice/smoke.py --app build/FileDeck.app --workbench`：隔离 profile、禁用网络，验证 Office 三格式与混合文档，以及真实窗口关闭/退出应用的取消保护。
- `Tests/BuildToolsTests/test_swift_workbench.py`：源码映射、ARM 目标、资源及补丁链重复应用。

独立 `--browser-only` 入口仅用于浏览 UI 开发，完整居中编辑与退出链以 `build/FileDeck.app` 为准。系统中文输入法组合输入、复杂 Office 排版、无开发工具的另一台机器仍需独立验收。
