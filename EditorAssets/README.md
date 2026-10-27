# 离线文本编辑器资源

CodeMirror 6 和 markdown-it 已通过 `FWTextContent` / `FWDocumentHost` 接入完整 FileDeck 工作台，提供文本、代码和 Markdown 的预览与编辑。构建产物位于 `../Resources/Editors/`，与许可证一起随应用打包；运行时不需要 Node.js 或网络。独立浏览验证应用不包含这套完整原生编辑会话。

```sh
cd EditorAssets
npm ci --ignore-scripts --no-audit --no-fund --registry=https://registry.npmjs.org
npm test
npm run build
```

依赖版本与完整性摘要固定在 package-lock.json。需要 Node.js 22.12 或更新版本构建；不影响应用的 macOS 14 运行要求。

## 构建一致性门禁

`manifest.json` 使用 schema 2，记录全部 `src/` 文件、`build.mjs`、`package.json`、依赖锁及五份运行资源的 SHA-256。普通原生构建与所有打包入口都会核对源码输入、依赖锁和输出；修改输入后遗漏资源重建会失败。新增、删除输入或资源以及旧 schema 1 清单也不能通过。

发布前使用 `npm ci --ignore-scripts --no-audit --no-fund` 从锁安装依赖，再执行 `npm run verify`。校验模式在临时目录重建并逐字节比较，不会覆盖已提交资源；失败时先执行 `npm run build`，检查并提交实际资源差异，再重新验证。`bash scripts/build-app.sh release`（包括 `--package-only`）自动执行这两项发布检查。

应用内资源也必须与当前检出一致。更改编辑资源后应先运行正常原生构建以同步 Xcode 资源，随后才能重打包；仅在仓库重建 JS，不会自动更新已构建 `.app`。已发布构建 6 的 schema 1 包仍可正常运行，但不能直接通过新版门禁，需要重新构建；检查历史包时使用对应版本的源码和校验脚本。

真实 macOS WebKit 验收从项目根目录执行（若刚完成上面的命令，先用 `cd ..` 返回根目录）。验收在独立辅助窗口中运行，完成后自动关闭：

```sh
bash scripts/test-editors.sh
```

从项目根目录运行。脚本使用系统 Swift/WebKit 编译独立宿主，将二进制、模块缓存、编译日志、运行日志与 `report.json` 放入 `build/editor-tests/`，不修改工作台入口或系统设置。验收包括真实桥接、中文文本插入、混合换行、JSON 大整数排版、撤销重做、nonce 样式、Markdown 防注入、CSP `securitypolicyviolation` 和原生导航拒绝。安全探针只使用环回地址，必须观察到 CSP 的 enforce 事件，不能仅凭连接失败判定通过。系统中文输入法组合、候选窗和标签切换期间输入仍需人工验证。

## WKWebView 协议

本地加载 `Resources/Editors/index.html`，注册 `WKScriptMessageHandler` 名称 `workbench`。宿主应仅允许该资源目录的读取权限，并拒绝所有网络导航和新窗口；不要把用户文本插入 JavaScript 字符串模板，使用 `callAsyncJavaScript` 的结构化 `arguments`。

```js
window.workbench.open({ id: "tab-session-id", text: "完整原始文本", language: "markdown", readOnly: false, bridgeMode: "patch-v1" });
window.workbench.getText("tab-session-id"); // 返回原始换行的全文；过期 id 返回 null
window.workbench.getSnapshot("tab-session-id"); // {version, text, canUndo, canRedo}；保存/关闭的完整确认边界
window.workbench.undo("tab-session-id");
window.workbench.redo("tab-session-id");
window.workbench.search("tab-session-id");
window.workbench.formatJSON("tab-session-id");
window.workbench.markSaved({ id: "tab-session-id", text: "实际成功写入磁盘的全文" });
```

`getText/undo/redo/search/formatJSON` 可省略 id 以操作当前会话；原生异步回调必须传 id，防止标签切换后操作错误文件。再次 `open` 会重新建立文档及历史，宿主应先保留旧会话文本，不能用 `open` 刷新未保存文档。

消息通过 `window.webkit.messageHandlers.workbench.postMessage` 发送：

- `ready`：资源可用，尚无文档。
- `opened`：`id/readOnly/canUndo/canRedo`；不包含 dirty，不触发变更消息。差量模式另含 `bridgeMode=patch-v1/version=0`。
- `patch`：差量模式普通编辑即时发送 `id/baseVersion/version/edits/canUndo/canRedo`，不生成全文。`edits` 的 `{from,to,text}` 基于同一份编辑前原始正文 UTF-16 偏移，范围左闭右开、按升序且不重叠，接收方先验证全部范围再倒序应用。插入文本包含原始 CRLF/CR/LF；不能把偏移当成 UTF-8 或规范化 LF 的位置。
- `change`：`id/text/dirty/canUndo/canRedo`；全文包含原始 CRLF/CR/LF。未指定 `bridgeMode` 的兼容模式逐次发送；差量模式只在原始行尾恢复 effect 无法用编辑区差量完整表达时回退，并携带 `version`。
- `state`：保存确认后的完整 `id/text/dirty/canUndo/canRedo`；差量模式另含当前 `version`。若保存期间继续输入，dirty 保持 true。
- `error`：`id/code/message`；`invalidJSON` 表示语法错误，`formatLimit` 表示排版深度或输出大小超限。两者都保留原文、dirty 与撤销历史。

支持 CodeMirror 6 语言数据库中的代码高亮（含 JSON、YAML、Markdown），查找替换和系统惯用撤销重做快捷键。Markdown 显示源码与预览双栏。未知语言保留纯文本编辑。

代码会话的 `language` 可传完整文件名、语言名或后缀，统一由 `src/languages.mjs` 解析；原生宿主传完整文件名以保留 `Dockerfile`、`build.gradle.kts`、`.env.local` 等规则。优先使用 CodeMirror 的精确语言/文件名/后缀数据库，避免模糊名称误命中；补充大小写后缀、`.pyi/.fsx/.hrl/.sbt` 等变体。`.m` 固定按 Objective-C，`.h` 按 C，C++ 头文件使用 `.hpp/.hh/.hxx`。Svelte 使用固定版本的 [Replit Svelte 模块](https://github.com/replit/codemirror-lang-svelte)，Julia 使用 CodeMirror legacy-modes；两者打入同一离线 bundle，不在运行时下载。

`npm test` 覆盖语言映射、解析后的高亮 token、离线 bundle 实际显示及预览转编辑时的 CRLF/历史保留。`FW_NATIVE_HOST_TEST_CASE=languages bash scripts/test-native-hosts.sh` 验证真实模板创建、原生文件名传递、WKWebView 高亮、编辑和保存。

Markdown 在 `source` 模式跳过转换和预览 DOM 更新；可见时将同一帧连续输入合并为一次最新正文转换。模式切换、确认前捕获交互和暂停编辑立即刷新，避免确认取消后遗留任务再次改写预览。相同正文复用 DOM 与滚动，新会话/关闭取消帧任务并清理缓存。帧调度只影响显示，差量仍在编辑事务内即时发送；后台帧暂停不影响草稿同步。

完整 FileDeck 原生宿主启用 `patch-v1`，拒绝过期会话，忽略重复旧版本；基线版本缺口或非法范围触发完整快照重同步，失败则保留最近已同步草稿并显示恢复入口。保存和关闭仍读取 `getSnapshot`，旧快照不得覆盖 await 期间已经收到的新差量。Swift 独立比较真实正文与保存基线，不信任页面 dirty。该协议减少全文生成与传输；不承诺原生 String 编辑、基线比较或可见 Markdown 全文转换变为常数成本。

JSON 只读预览自动使用无损排版显示缩进；键名、字符串、数字、布尔值和 null 分色显示，配色随系统浅色/深色外观切换。`getText` 始终返回源码，进入编辑恢复原始排版、换行和撤销历史。自动美化不产生 dirty 或写盘；语法错误或排版超限时显示原文，仍允许进入编辑修复。编辑模式的“格式化 JSON”按钮仍是显式、可撤销的文本修改。

YAML（`.yaml`、`.yml`）在预览和编辑中对键名、文本值（含未加引号的值和块文本）、注释、锚点/别名、类型标签和分隔符分类配色，随系统浅色/深色外观切换。仅调整显示，保留原始缩进、注释和换行。

## 文件内容与安全边界

- 原始换行单独建模，普通编辑保留未删除的分隔符；新插入的行沿用原文第一个分隔符，没有换行时使用 LF。映射参与撤销重做。全文 JSON 排版按原序保留已有分隔符，额外分隔符沿用首个。
- JSON 排版只调整 token 之间空白，原样保留整数、指数、负零和字符串转义；`JSON.parse` 仅判断语法，不参与生成结果。最多支持 256 层嵌套，输入和排版输出均不得超过 10 MiB UTF-8 字节，恢复 CRLF 增加的字节也计入上限；超限在提交编辑事务前拒绝。
- Markdown 禁用原始 HTML，不输出可导航的链接。远程图片、相对路径和 file URL 均显示阻止提示，只允许通过 MIME 与文件头校验的 PNG/JPEG/GIF/WebP data URI；拒绝 SVG。
- CSP 默认全部禁止，只开放本地脚本和样式、CodeMirror 样式 nonce、受过滤的 data 图片；禁止连接、字体、媒体、frame、object、表单和 base URL。脚本不使用 CDN 或运行时下载。
- 原生宿主仍负责文件尺寸限制、编码选择、磁盘冲突检查和原子保存；本资源不会直接访问或写入用户文件。

## 原生交互命令

`handleHistoryKey({id, redo})` 按当前焦点处理正文或查找/替换字段的独立历史；字段历史复用 CodeMirror，程序性更新搜索词后同步基线，不调用可能跨输入控件撤销的 WebKit document Undo。`indentSelection({id, backward})` 只处理可编辑正文，其他控件返回 false，由原生焦点环继续处理；Ctrl+Tab 始终切换焦点。`revealLine({id, line})` 按原始源码的正整数行号滚动并选中，不修改正文或历史；JSON 自动排版、Markdown 阅读模式在定位时切到只读源码。

编辑动作统一在网页工具栏，JSON 排版只对 JSON 编辑会话可见且可调用。查找面板文案使用本地中文短语。八项原生交互验证见 [交互修复与验证](../docs/interaction-fixes.md)。
