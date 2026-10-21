# Office 原生离线冒烟验收

此目录提供第一阶段验收驱动，使用固定的 ONLYOFFICE 桌面源码及其真实 CEF 编辑器。它依次新建 DOCX、XLSX、PPTX，通过 SDK 输入上下文写入本次唯一中文标记，发送上游保存事件，正常关闭标签，再重新打开并在编辑器中查找该标记。Python 外层检查正文 OOXML、进程正常退出和所有阶段结果。

**当前完成的是驱动、编译检查和验证器单元测试；没有运行完成的应用时，不能将这些检查写成 Office 引擎验收通过。** 此测试也不覆盖系统输入法候选／组合输入、复杂排版、图片和公式兼容性。

## 可复现的集成方式

采用正式 Xcode 源文件引用，不使用 `#include` 实现文件。补丁为：

`scripts/onlyoffice/patches/desktop-apps-001-smoke-hooks.patch`

构建脚本先将本目录的 `FWOfficeSmoke.h` 与 `FWOfficeSmoke.mm` 同步到：

`vendor/onlyoffice/desktop-apps/macos/ONLYOFFICE/FileWorkbenchSmoke/`

随后对 `vendor/onlyoffice/desktop-apps` 应用补丁。补丁不包含生成文件或整个源码副本；检查上下文失败时应停止，不模糊覆盖。重复构建先用反向 `git apply --check` 判断已应用状态。同步的两个辅助文件属于构建输入，以本目录为权威源；本目录 README 无需放入应用包。

补丁已为 Xcode 的 `Supporting Files` 添加 header/source 引用，并把 `.mm` 加入 `ONLYOFFICE-arm` 的 Sources 阶段。由于其他两个桌面 target 共用被补丁修改的 `main.mm`、`AppDelegate.mm` 和 `ASCHelper.m`，也为 `ONLYOFFICE-v8`、`ONLYOFFICE-x86_64` 添加同一源文件，避免它们出现未定义符号。所有构建配置都编译驱动，是否运行仅由显式测试环境决定；不要另行把 `.mm` 包含进 `main.mm`，否则会重复定义。

## 三个集成点

1. `ASCHelper.applicationDataPath` 开头调用 `FWOfficeSmokeApplicationDataPath()`，非 nil 时立即返回。这样 `createCloudPath`、`recoveryDataPath`、字体缓存和本地编辑器数据都落在本次私有目录的 `profile/` 下。
2. `main.mm` 在 `[ASCEventsController sharedInstance]` **之前**调用 `FWOfficeSmokeInstallDelegate()`。上游事件监听器和 common controller 会缓存外部 delegate，不能等窗口创建后再注册。包装器由静态强引用保活，并持有／转发已有 delegate；其 `onCommonViewDidLoad:` 调用 `FWOfficeSmokeStart(controller)`。
3. `AppDelegate.saveLocalFileWithParams:` 的第一行执行 `if (FWOfficeSmokeHandleSaveParams(params)) return;`。驱动只处理当前测试视图的保存请求，用上游返回的 `supportedFormats` 确定格式编号，提交 `ASC_MENU_EVENT_TYPE_CEF_LOCALFILE_SAVE_PATH`；其他视图仍走原保存面板。

无 `FW_OFFICE_SMOKE_DIR` 时，三个入口分别返回 nil、无操作和 NO，不创建目录、不注册测试观察者、不改用户设置。

## 运行与产物

已构建并完成上述集成后运行：

```sh
python3 -B scripts/onlyoffice/smoke.py \
  --app /absolute/path/ONLYOFFICE.app \
  --deadline-seconds 360
```

脚本在 `build/onlyoffice/smoke/` 下新建随机、权限 `0700` 的 `fw-office-smoke-*` 目录。`--output-parent` 可修改其父目录；不能传入旧测试目录继续写。脚本使用 macOS `sandbox-exec` 的 `(deny network*)` 禁网，未提供该工具时直接失败；子进程共享本次截止时间，超时只终止此次启动的进程组。

每次运行包含：

- `request.json`：随机 UUID 令牌、中文标记、截止时间和离线策略。
- `runtime.log`：本次应用进程的标准输出与错误。
- `profile/`、`preferences-home/`：原生应用数据与 CoreFoundation 偏好隔离目录。
- `word.docx`、`cell.xlsx`、`slide.pptx`：只允许新建，不覆盖既有路径。
- `native-result.json`：原生各阶段结果，仅写一次。
- `verification.json`：外层退出码、正文标记检查及最终结果。

脚本通过进程参数抑制上游“移动到 Applications”提示并关闭窗口恢复，不修改用户已有偏好。原生驱动还会核对 `app_data_path` 是否确实指向本次 profile；缺少数据隔离钩子会失败。

复核已有结果使用 `--verify /absolute/run/directory`。该模式的输出包含 `executionVerified: false` 与 `artifact-verification-only`，它只检查文件，不能证明本次重新启动过应用。正常运行必须同时满足应用退出码 0、原生三种格式的全部七阶段为 true，以及对应正文 XML 中存在中文标记；仅有 ZIP 文件或元数据标记不算通过。

## 当前验证及源码依据

```sh
python3 -B -m unittest discover -s Tests/BuildToolsTests -p test_smoke.py -v
git -C vendor/onlyoffice/desktop-apps apply --check \
  "$PWD/scripts/onlyoffice/patches/desktop-apps-001-smoke-hooks.patch"
```

原生 `.mm` 已使用固定 vendor 的实际头文件执行 `clang++ -fsyntax-only -fobjc-arc -std=c++17 -D_MAC` 检查；正式编译仍以 Xcode 构建结果为准。嵌入 JavaScript 已通过 Node 语法检查；它仅使用本地固定版本中已经核对的 API：

- `ASCCommonViewController` 的 `tabViewWithId:`、`cefViewWithTab:` 及 `ASCTabsControl` 正常移除标签流程。
- `NSAscApplicationWorker.getAppManager()->GetViewById()->ExecuteInAllFrames()`。
- `CEFEventNameEditorDocumentReady`、`CEFEventNameEditorEvent`、`CEFEventNameSave`。
- `ASC_MENU_EVENT_TYPE_CEF_SAVE` 及 `CAscLocalSaveFileDialog` 的原生保存路径回传。
- `sdkjs/common/apiBase_plugins.js` 导出的 `pluginMethod_InputText`，以及三个编辑器导出的 `asc_findText`；PPT 使用 `AddSlide(0)` 建立可输入标题的页面，XLSX 使用 `asc_closeCellEditor()` 提交单元格编辑。

固定提交记录位于 `scripts/onlyoffice/versions.lock.json`。验证器单测使用明确标注的合成 OOXML 夹具，仅证明验证逻辑能拒绝缺阶段、错令牌、错误路径和伪造的元数据标记。
