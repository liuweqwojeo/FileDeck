# FileDeck 居中弹窗验收

更新：2026-10-21；macOS 14.7.2、Apple Silicon。本次使用真实 AppKit/WebKit、磁盘文件和系统对话框；测试样本、偏好、profile 均隔离，不使用用户业务文件。

## 当前交付与证据

最终构建、签名及断网应用回归均通过（[汇总与产物摘要](../build/modal-final-verification.json)）。产品为 `build/FileDeck.app`。目录树和文件列表常驻，文件预览默认只读，文本主动编辑；独立弹窗会话负责关闭、焦点、请求取消与资源释放。最终构建、验签及断网应用回归分别保存在：

- [原生构建](../build/modal-app-build.log)、[最终包检查](../build/modal-final-bundle.log)、[最终应用断网回归](../build/modal-final-smoke.log)。
- [38 项实际宿主交互报告](../build/native-host-tests/run.f0HQxW/fixtures/report.json)（[执行日志](../build/modal-native-hosts-final.log)）：完整原生类参与编译，实际文件行双击、键盘、列表滚动、调整窗口及 WK 编辑。
- [14 项文档安全](../build/modal-document-tests/run.kM7Ir3/fixtures/report.json)：真实 WK、原生确认和系统 NSSavePanel；另存通过真实 Return 确认，确认前不自动重建被删除路径。
- [真实视频播放与释放](../build/modal-preview-runtime/report.json)：播放时间实际推进，再验证停止、释放 playerItem/view.player 和重复关闭安全。
- [109 项 Swift](../build/modal-swift-tests.log)、[86 项构建工具](../build/modal-buildtools-tests.log)、[20 项编辑资源](../build/modal-editor-tests.log)。其中快照恢复使用真实设备/inode/创建时间身份，覆盖多选、筛选、排序、网格、重命名、删除、同名替换和过期快照。

最终应用回归检查 DOCX/XLSX/PPTX 新建、真实输入、保存、关闭、重开和查找；混合文本/PDF 与 Office 保存路由；并要求 `modalWindowCloseProtected`、`modalQuitProtected`、`modalDiscardClosed` 均为 true，不能用旧版本报告代替。

最终包运行报告：[断网回归](<../build/onlyoffice/smoke/fw-office-smoke-中文 路径-j9a9o36z/verification.json>)；[签名与资源检查](../build/onlyoffice/bundle-verification-a31fda578d8341589f47c133a20334b7.json)。

## 18 个场景对应证据

| # | 场景 | 实际验证 |
|---|---|---|
| 1 | 双击打开后关闭仍选中 | 向真实文件列表发送双击事件，默认只读；关闭保留原文件、目录和原列表对象 |
| 2 | 保留列表滚动 | 180 个真实文件滚动到中段，关闭后核对原 NSScrollView 的水平/垂直位置；本轮水平为布局当前值，没有另造非零横向溢出 |
| 3 | 保留多个展开目录 | 同时展开两个真实子目录，关闭后比较展开集合 |
| 4 | Markdown 修改后 Esc | 实际 WK 输入，Esc 进入真实未保存确认；若有补全或查找浮层，先关闭该浮层 |
| 5 | 取消保留草稿和光标 | 同一个 WK/CodeMirror，实际核对正文、光标/选区、滚动、模式、编辑焦点与撤销重做 |
| 6 | 保存成功才关闭 | 确认“保存”，比对真实磁盘全文后验证弹窗卸载与选择恢复 |
| 7 | 保存失败不丢内容 | 对专用样本父目录移除写权限，实际写入失败后保留草稿、dirty 和窗口；恢复权限可保存 |
| 8 | 预览期间删除 | 实际删除文件，关闭仅清理失效选择，不自动选择其他文件；脏文件保留草稿，经系统另存明确确认后才写入 |
| 9 | 读取中快速关闭 | WK 初始化和异步文件读取尚未完成时关闭，迟到结果不能重开或改写当前会话 |
| 10 | 重复关闭 | 连续请求关闭只出现一个确认，不重复提交保存；失败保留会话 |
| 11 | 确认隔离背景焦点 | 实际原生 sheet 为最上层，响应者位于 sheet，不进入背景列表；普通弹窗 Tab 也只在内部循环 |
| 12 | 取消后回编辑器 | 真实取消后保留同一 WK，确认焦点回编辑区域而非背景列表 |
| 13 | 主窗口尺寸变化 | 实际缩小窗口，最大化弹窗保留安全边距，关闭控件所在区域不越界 |
| 14 | 最大化不清草稿 | 对带真实未保存内容的弹窗最大化再恢复，正文与 dirty 保留 |
| 15 | 关闭视频停止释放 | 真实本地 H.264 MOV 已播放，再关闭验证 rate=0、item=nil、view.player=nil |
| 16 | 快速 A/B 切换 | 连续打开不同真实文件，只显示最后一个文件的标题和正文；异步预览另有过期结果测试 |
| 17 | 键盘导航继续 | 关闭后焦点回原列表，继续发送方向键能正常选择下一文件；补验 Tab/ShiftTab 可访问网页模式按钮 |
| 18 | 外部修改不静默覆盖 | 实际改写磁盘文件，保存被外部变更检查拒绝，本地草稿与磁盘外部版本均保留 |

最终完整包另外发起真实 `NSWindow.performClose` 和 `NSApp.terminate`，分别取消后保留同一个编辑器与未保存状态；随后明确“不保存”关闭，核对原始磁盘标记与 CRLF 字节未变。

## 本次崩溃报告

两份报告均为 `NativeHostTests`，不是 FileDeck 主程序；相同二进制 UUID 为 `529e5dff-0b8f-3945-937b-d81f4b1e85b3`。栈显示 `NativeTextTests.init → Array.subscript`：测试程序未收到夹具目录，却在初始化时访问启动参数下标。

已在测试主入口、创建 NSApplication/测试对象前校验参数及隔离测试目录。每次编译后先实际无参数启动，要求正常返回 64，再运行 GUI 验收。本机 7 个旧 NativeHostTests 和 4 个旧 ModalDocumentTests 入口已改为安全退役入口并重新签名，原二进制保留在各自 `archived-executables/`，避免旧 Finder 入口继续触发同类崩溃。

[旧 NativeHostTests 入口验证](../build/native-host-tests/retired-entry-verification.json)；[旧文档测试入口验证](../build/modal-document-tests/retired-entry-verification.json)。产品入口为 `build/FileDeck.app`，测试 `.app` 仅供对应脚本启动。

## 边界与未覆盖项

- 跨目录移动/外部重命名无法可靠定位时显示位置变化，不猜测新路径或覆盖同名文件；保留草稿并提供另存。关闭后的原目录枚举可按稳定身份识别同目录重命名。
- Markdown 相对路径图片/链接继续受现有资源权限限制；没有为展示资源扩大目录授权。QLPreviewView 无公开渲染失败回调，控件创建不证明所有格式渲染成功。
- 实际列表双击、单击选择、方向键与原生菜单保存已验证。右键菜单全部项目、网格多选的完整 GUI 操作、非零横向滚动、中文输入法组合输入、各预览扩展、复杂 Office 排版仍需专项人工验收。
- 无开发工具的另一台机器、首次系统目录授权、外接磁盘物理拔插未在本轮重新验收。本地包为临时签名；独立 `--browser-only` 是 UI 开发入口，不包含完整原生模态/退出链。

## 主要实现位置

- [FWPreviewModal.swift](../NativeOffice/Workbench/FWPreviewModal.swift)：生命周期、焦点循环、资源清理和工作台恢复。
- [FWBrowserHost.swift](../NativeOffice/Workbench/FWBrowserHost.swift)、[FWWorkbenchCoordinator.mm](../NativeOffice/Workbench/FWWorkbenchCoordinator.mm)：独立预览会话与窗口/退出/菜单路由。
- [BrowserStore.swift](../Sources/FileWorkbench/BrowserStore.swift)：稳定身份、会话快照、局部刷新与选择恢复。
- [FWDocumentHost.swift](../NativeOffice/Workbench/FWDocumentHost.swift)、[FWTextContent.swift](../NativeOffice/Workbench/FWTextContent.swift)：真实保存、冲突、关闭确认、编辑器交互恢复。
- [test-native-hosts.swift](../scripts/test-native-hosts.swift)、[test-modal-documents.swift](../scripts/test-modal-documents.swift)：无参数启动保护与真实原生验收。

## 收尾检查

按 simplify Standard / feature 检查 repo_fit、quality、reuse、efficiency，沿用现有 BrowserStore、FWDocumentHost、SafeFileIO、CodeMirror 和原生窗口链。修复了关闭刷新期间过早解除输入门、干净加载无法关闭、背景可访问性设置、标题栏背景交互、过期焦点回调、网页 Tab 被跳过与内部空白误触遮罩关闭等问题；本次范围没有遗留必须修复的审查项。未重新设计第三方 Office 内核或目录安全模型。
