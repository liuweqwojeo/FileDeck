# FileDeck 目录与新建交互修复

更新时间：2026-10-21。

## 行为与原因

- 普通启动始终显示欢迎页。旧版初始化无条件恢复工作区，保存记录或“已完成引导”标记让欢迎页被跳过。现在先读取偏好，点击“继续上次工作区”才恢复；选择其他目录保留已有管理列表。显式 `--open` 和外部打开文件继续直接处理指定路径。
- 目录树的名称后空白、展开箭头都具有完整点击范围；箭头独立展开/收起。快速导航时树请求独立于文件列表请求，避免列表请求被取消后展开节点没有子目录。
- 顶部按钮显示中文名称：后退、前进、上级、刷新、添加目录、打开文件、新建、复制路径、隐藏文件。1040 宽度隐藏次要的复制路径入口，仍可右键复制。
- 工具栏、树节点、快速访问、文件行和列表空白共用新建菜单。28 个选项包含文件夹、办公格式、文本/代码/配置、PNG/JPEG/SVG、自定义扩展名。已知文档使用有效模板；其他文本扩展名可以创建空白文件，不支持的二进制格式明确提示。
- 目标目录在命名面板打开时冻结身份；创建前复核，使用目录描述符与排他提交，拒绝同名覆盖和目录替换。失败保留名称，成功显示并选中新建项目；隐藏文件自动开启显示。

## 验证

- `build/interaction-swift-tests.log`：119 项 Swift 单元测试通过，包含启动、快速切换、有效格式解码、同名/链接/目录替换保护。HEIC 依赖 macOS 编码服务，受限沙箱失败后在允许本机系统服务的环境重跑通过，没有跳过断言。
- `build/interaction-final-focused-tests.log`：最后一次界面补充后的 33 项新建、浏览、工作区测试通过。
- `build/interaction-buildtools-tests.log`：86 项构建工具测试通过，包括新 Swift 文件登记、ARM 目标和整个补丁链重复应用。
- `build/file-creation-tests/run.XlIgOw/fixtures/report.json`：真实 DOCX/XLSX/PPTX 模板新建，逐字节一致、ZIP 完整且核心 XML 可解析；PDF 实际解码一页 A4，PNG/JPEG 实际解码 800×600。
- `build/onlyoffice/interaction-fix-bundle-verification.json`：最终应用的 ARM64、资源、符号链接、签名与动态库静态检查通过。
- `build/interaction-app-build.log`：完整原生应用构建与最终打包签名通过。交付入口是 `build/FileDeck.app`；此前应用由构建脚本保留在 `build/previous-apps/`。

- `build/native-host-tests/run.oCpufi/fixtures/report.json`：44 项真实原生宿主检查全部通过，包含欢迎页、1040 宽度目录行空白/箭头两侧边缘/连续切换、右键选文本模板并中文命名真实落盘，以及原有预览、编辑、保存、焦点、滚动和关闭保护回归。对应源码摘要与最终源码一致。
- 同一目录 `startup.png`、`browser-1040.png`、`context-created.png` 保存渲染截图；测试包欢迎页图标为通用图标，正式应用图标随最终包验证。

Office 编辑内核未修改，本次格式检查不等于重新执行复杂文档编辑兼容性验收。桌面 UI 连接工具超时后采用本进程真实鼠标事件、原生菜单动作和磁盘结果完成交互验证。

## 本次文件位置

| 文件 | 改动位置 |
| --- | --- |
| `Sources/FileWorkbench/BrowserStore.swift` | 初始化/继续恢复、显式打开、独立树加载 |
| `Sources/FileWorkbench/WorkspaceStartupView.swift` | 欢迎页主次入口和恢复说明 |
| `Sources/FileWorkbench/ContentView.swift` | 顶部文字、目录点击形状、共享新建菜单、命名/创建面板 |
| `Sources/FileWorkbench/NewFileTemplate.swift` | 格式定义、Office/图片/PDF 模板、目录身份与排他写入 |
| `Tests/FileWorkbenchTests/WorkspaceStateTests.swift` | 启动恢复与树请求竞态 |
| `Tests/FileWorkbenchTests/NewFileTemplateTests.swift` | 文件格式、安全创建及错误路径 |
| `scripts/onlyoffice/native_sources.py` | 新文件同步清单 |
| `scripts/onlyoffice/patches/desktop-apps-010-new-file-templates.patch` | Xcode ARM 构建登记 |
| `Tests/BuildToolsTests/test_swift_workbench.py` | 新补丁登记与完整链验证 |
| `scripts/test-native-hosts.swift` | 真实目录点击与原有弹窗回归 |
| `scripts/test-file-creation.sh`、`scripts/test-file-creation.swift` | 完整应用模板的新建格式验收 |
| `README.md` | 更新启动/目录/新建使用说明 |

## 收尾审查

执行 simplify Standard / feature，覆盖 repo_fit、quality、reuse、efficiency。修正文案与实际模板逻辑不一致，缓存主应用模板可用性以避免菜单重绘重复同步磁盘检查，增加1040宽度验证。保留目录描述符新建逻辑，因为原有 SafeFileIO 保存接口不提供目标目录身份固定能力；模板读取与图片编码继续复用现有服务。
