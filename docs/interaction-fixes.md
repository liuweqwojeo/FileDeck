# 八项交互修复与验证

适用范围：当前工作树，2026-10-27。修复已随 v0.1.2 构建11（Release / ARM64）安装到 `/Applications/FileDeck.app`，未发布远程版本。安装路径、专项与实际运行的验证范围见 [Release 安装验收](../build/release-install/report.md)。仓库内其他未提交工作保持原样。

## 修复后的行为

| 编号 | 问题 | 当前行为 | 主要实现 |
| --- | --- | --- | --- |
| I1 | 查找框撤销正文 | 查找词和替换词各自使用 CodeMirror 历史；正文撤销独立，空输入历史不回退到正文 | `EditorAssets/src/workbench.mjs`、`FWPreviewModal.swift`、`FWTextContent.swift` |
| I2 | CSV 未选目标时删除末尾行列 | 没有选中目标时禁用删除且 action 本身拒绝执行；提示明确行列；撤销仍恢复原表格 | `FWCSVContent.swift` |
| I3 | Tab 离开代码编辑器 | 正文 Tab/Shift+Tab 缩进，Ctrl+Tab/Shift+Ctrl+Tab 切换焦点；查找字段和只读内容仍走焦点环 | `FWPreviewModal.swift`、`workbench.mjs` |
| I4 | 搜索结果不能直达命中行 | 行号随原文件路径传递，打开后选中命中行并居中；JSON/Markdown 按原始源码坐标，CSV 按物理文本行 | `ContentView.swift`、`WorkspaceEditorBridge.swift`、`FWBrowserHost.swift`、`FWPreviewModal.swift`、`FWDocumentHost.swift` |
| I5 | 不同类型编辑入口和返回方式不一致 | PDF/CSV/图片从预览原位进入原生编辑；Office 从同文件进入既有 CEF 内核。均提供保存并返回，需转换格式时仍要求另存 | `FWPreviewModal.swift`、`FWWorkbenchCoordinator.mm` |
| I6 | 多选菜单混用单项与批量操作 | 多选仅显示有明确批量语义的动作，标明数量；复制、路径和 Finder 显示使用菜单打开时的相同范围 | `ContentView.swift` |
| I7 | 重复编辑工具栏和错误的 JSON 操作 | 编辑动作统一在网页工具栏；只有 JSON 显示并允许 JSON 排版；查找面板使用中文文案 | `FWTextContent.swift`、`workbench.mjs` |
| I8 | 新建类型仍需手工填写后缀 | 省略后缀时自动补齐，错误类型后缀仍拒绝；自定义名称、目录身份与排他创建规则不变 | `NewFileTemplate.swift`、`ContentView.swift` |

## 验证入口

```sh
cd EditorAssets
npm test
npm run verify
cd ..
swift test --disable-sandbox --cache-path .build/cache
FW_NATIVE_HOST_TEST_CASE=interaction-fixes bash scripts/test-native-hosts.sh
bash scripts/test-modal-documents.sh
python3 -B scripts/onlyoffice/smoke.py --app build/onlyoffice/DerivedData/Build/Products/Debug/ONLYOFFICE.app --workbench
```

Swift 测试在受限环境中需设置仓库内的 `CLANG_MODULE_CACHE_PATH` 和 `SWIFTPM_MODULECACHE_OVERRIDE`；完整回归需要 macOS 剪贴板、窗口和图片编解码服务。原生脚本使用隔离偏好域、源码快照与临时样本；批量路径测试在结束后恢复剪贴板，不记录原剪贴板内容。

`NativeOffice/Tests/InteractionRegression.swift` 的专项通过真实按键、NSButton、NSMenu 和文件系统验证八条任务路径，并检查外部冲突和未保存关闭取消。Office 辅助宿主只证明同文件路由与命令转发；完整应用的 `FWOfficeSmoke.mm` 额外点击真实“保存并返回”，等待保存完成、浏览页恢复，再检查 OOXML 文件和重开结果。`smoke.py` 要求 `officeSaveAndReturnVerified`，不能用旧报告替代这项证据。

## 保存与资源边界

- 文本、CSV、PDF 和图片仍通过原有 DocumentIO/SafeFileIO 保存，保留外部修改、目录身份、重名和关闭保护。
- Office 使用原内核的成功/取消通知；只有原标签仍被选中、已确认保存完成且没有新修改时返回。取消、失败、切换标签或超时均保留编辑器。
- 搜索定位只改选区和滚动，不修改文本、编码、换行、dirty 或撤销历史。CSV 从搜索源码预览切到表格时清理旧只读宿主，过期回调不能替换新编辑器。
- 编辑资源从本地打包并逐字节校验，不增加运行时网络请求。

最终测试计数、截图、源码摘要与实际运行路径见 `build/interaction-fixes-report.md`；该文件由本轮验证结果生成。
