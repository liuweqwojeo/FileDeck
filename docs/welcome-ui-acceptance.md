# FileDeck 欢迎页自适应验收

本次在现有 SwiftUI / AppKit 架构内改造欢迎页，没有引入依赖，也未修改 BrowserStore 的业务逻辑。
以用户提供的图片作为视觉参考，但适配现有技术栈和真实业务逻辑。

## 原因与实现

- 原欢迎页内容固定为 520 pt 宽，两个应用入口默认内容尺寸均为 1600×1000，造成内容集中与留白。
- 默认欢迎窗口外框为 1280×720，首次出现时按当前屏幕可见区域等比缩小、居中；没有设置 contentAspectRatio。
- 内容宽度达到 1020 pt 时，以 HStack 分为 44% 插画与 56% 操作区；低于断点使用 VStack，插画改为横向摘要。
- 根据可用高度收紧图标、字号和间距。欢迎页没有 ScrollView，也没有通过裁剪或隐藏滚动条掩盖溢出。
- 欢迎页最小内容尺寸为 640×600，工作台为 1040×660；外框还包含系统标题栏。NSHostingView 会重新计算最小窗口尺寸，因此根视图与窗口共用相同约束。
- 进入工作台时仅补足所需最小尺寸，已有足够空间的用户窗口保持大小；外部直接打开工作区的初始尺寸为 1440×900。之后可独立调整宽高。
- 沿用包内 FileDeck 图标、系统字体与 SF Symbols。左侧示意对辅助技术隐藏，不伪装为真实文件入口。
- 主、次按钮仍分别调用原有 skipWelcome / chooseFolder，按照 hasPreviousWorkspace 保留首次使用时的语义；恢复中状态仍保留。

## 文件

| 文件 | 具体改动 |
| --- | --- |
| Sources/FileWorkbench/WorkspaceStartupView.swift | 响应式分栏、矢量示意、视觉层级、主次按钮及隐私说明；取消滚动 |
| Sources/FileWorkbench/WorkspaceDesign.swift | 共用默认窗口与阶段最小尺寸、屏幕适配和一次性窗口配置 |
| Sources/FileWorkbench/ContentView.swift | 根据阶段应用最小内容约束，并挂载窗口配置探针 |
| Sources/FileWorkbench/FileWorkbenchApp.swift | 独立 SwiftUI 入口复用默认窗口规则 |
| NativeOffice/Workbench/FWWorkbenchCoordinator.mm | 移除完整应用入口的旧 1600×1000 和重复最小尺寸设置 |
| Tests/FileWorkbenchTests/WorkspaceWindowLayoutTests.swift | 默认比例、屏幕边界、自由缩放与工作台切换的 3 项真实 NSWindow 测试 |
| scripts/test-welcome.swift | 独立偏好域与测试目录中的原生渲染、实际 NSButton 点击、恢复与取消检查 |
| scripts/test-welcome.sh | 编译并运行独立验收应用，保留截图和 JSON 报告 |

## 实际验证

- Swift 完整测试：137 项通过，0 失败。日志：`build/welcome-swift-tests.log`。
- 原生源码同步：8 项通过。日志：`build/welcome-native-sources-tests.log`。
- 完整 ONLYOFFICE-arm / FileDeck 原生应用：Xcode build 成功，ARM64、深度严格签名检查通过。日志：`build/welcome-native-build.log`。
- 原生欢迎页宿主实跑：32 项通过。检测无 NSScrollView、两个真实按钮在可见区域，点击后检查业务状态与真实目录内容。
- 已验证：无历史进入空工作台、原生目录授权面板打开与取消、取消其他文件夹不丢失历史、继续恢复真实目录及文件、窄窗进入工作台补足宽度、历史目录不存在时沿用原提示。
- 六种尺寸均有实际 NSHostingView 位图，并逐一目视检查标题、三项能力、按钮、隐私说明无重叠与溢出。

下表为实际窗口尺寸；请求 600 pt 外框高度时，系统按最小内容尺寸加标题栏限制到 628 pt。截图文件名保留测试的请求尺寸。

| 实际窗口外框（pt） | 实际内容（pt） | 布局 |
| --- | --- | --- |
| 1280×720 | 1280×692 | 双栏 |
| 1040×628 | 1040×600 | 双栏 |
| 1000×720 | 1000×692 | 纵向 |
| 800×720 | 800×692 | 纵向 |
| 640×628 | 640×600 | 纵向 |
| 1600×900 | 1600×872 | 双栏 |

- [运行报告](/Users/jiangpeng/work/repository/sc/nanwang/file-workbench/build/welcome-acceptance/run.vl6uml/report.json)
- [有历史工作区的欢迎页截图](/Users/jiangpeng/work/repository/sc/nanwang/file-workbench/build/welcome-acceptance/run.vl6uml/welcome-with-history.png)
- [最小欢迎页截图](/Users/jiangpeng/work/repository/sc/nanwang/file-workbench/build/welcome-acceptance/run.vl6uml/welcome-640x600.png)
- [恢复后的工作台截图](/Users/jiangpeng/work/repository/sc/nanwang/file-workbench/build/welcome-acceptance/run.vl6uml/workbench-restored.png)
- [完整本地应用](/Users/jiangpeng/work/repository/sc/nanwang/file-workbench/build/welcome-ui/FileDeck.app)
- [最终 bundle 静态验证](/Users/jiangpeng/work/repository/sc/nanwang/file-workbench/build/onlyoffice/welcome-final-bundle-verification.json)

## 范围与限制

- 桌面自动化 getApp / 可访问性读取多次超时。完整应用已启动；详细布局与按钮结果来自运行中的原生测试宿主，按钮用 NSButton.performClick 进入真实业务回调。
- 系统文件选择器确认选择的外部点击没有完成端到端验证；程序调用 NSOpenPanel.ok 不等价于系统面板中的真实点击，未将该尝试记为通过。原生面板打开、目录模式和取消行为已通过，真实目录枚举和恢复已验证。
- 当前字体沿用项目的系统字体；尚未做多显示器、不同系统显示缩放、VoiceOver 和额外大字体设置的完整矩阵测试。
- Office 内核未修改，没有重复进行复杂文档编辑验收。
- simplify 采用 Standard / refactor，检查 quality、repo_fit、reuse；将最小内容约束统一到 ContentView 和公共窗口规则，修复 NSHostingView 覆盖窗口最小值的实际问题。修正后完整 Swift 测试与原生运行检查重新通过。
- 已按用户要求安装至 `/Applications/FileDeck.app`，版本 v0.1.2、构建 4；二进制摘要与验证产物一致，安装前后深度严格验签通过，已确认安装入口进程在前台运行。旧版保存在 `/Users/jiangpeng/work/repository/sc/nanwang/file-workbench/build/previous-apps/FileDeck-before-welcome-20261025-115851.app`；安装记录见 `build/welcome-ui/install-receipt.json`。用户已确认安装版欢迎页的实际效果，本次欢迎页改动按确认结果进行本地提交；未推送或上传。暂停中的旧发行 ZIP 不包含本次 UI，后续发布需重新打包。
