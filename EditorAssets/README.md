# 离线文本编辑器资源

仅实现资源和原生桥接协议；尚未接入 Swift 工作台界面。构建产物在 `../Resources/Editors/`，与许可证一起随应用打包。运行时不需要 Node.js 或网络。

```sh
cd EditorAssets
npm ci --ignore-scripts --no-audit --no-fund --registry=https://registry.npmjs.org
npm test
npm run build
```

依赖版本与完整性摘要固定在 package-lock.json。需要 Node.js 22.12 或更新版本构建；不影响应用的 macOS 14 运行要求。

真实 macOS WebKit 验收（独立辅助窗口，完成后自动关闭）：

```sh
bash scripts/test-editors.sh
```

从项目根目录运行。脚本使用系统 Swift/WebKit 编译独立宿主，将二进制、模块缓存、编译日志、运行日志与 `report.json` 放入 `build/editor-tests/`，不修改工作台入口或系统设置。验收包括真实桥接、中文文本插入、混合换行、JSON 大整数排版、撤销重做、nonce 样式、Markdown 防注入、CSP `securitypolicyviolation` 和原生导航拒绝。安全探针只使用环回地址，必须观察到 CSP 的 enforce 事件，不能仅凭连接失败判定通过。系统中文输入法组合、候选窗和标签切换期间输入仍需人工验证。

## WKWebView 协议

本地加载 `Resources/Editors/index.html`，注册 `WKScriptMessageHandler` 名称 `workbench`。宿主应仅允许该资源目录的读取权限，并拒绝所有网络导航和新窗口；不要把用户文本插入 JavaScript 字符串模板，使用 `callAsyncJavaScript` 的结构化 `arguments`。

```js
window.workbench.open({ id: "tab-session-id", text: "完整原始文本", language: "markdown", readOnly: false });
window.workbench.getText("tab-session-id"); // 返回原始换行的全文；过期 id 返回 null
window.workbench.undo("tab-session-id");
window.workbench.redo("tab-session-id");
window.workbench.search("tab-session-id");
window.workbench.formatJSON("tab-session-id");
window.workbench.markSaved({ id: "tab-session-id", text: "实际成功写入磁盘的全文" });
```

`getText/undo/redo/search/formatJSON` 可省略 id 以操作当前会话；原生异步回调必须传 id，防止标签切换后操作错误文件。再次 `open` 会重新建立文档及历史，宿主应先保留旧会话文本，不能用 `open` 刷新未保存文档。

消息通过 `window.webkit.messageHandlers.workbench.postMessage` 发送：

- `ready`：资源可用，尚无文档。
- `opened`：`id/readOnly/canUndo/canRedo`；不包含 dirty，不触发变更消息。
- `change`：`id/text/dirty/canUndo/canRedo`；仅当前会话，全文包含原始 CRLF/CR/LF。
- `state`：保存确认后的 `id/text/dirty/canUndo/canRedo`。若保存期间继续输入，dirty 保持 true。
- `error`：`id/code/message`；`invalidJSON` 表示语法错误，`formatLimit` 表示排版深度或输出大小超限。两者都保留原文、dirty 与撤销历史。

支持 CodeMirror 6 语言数据库中的代码高亮（含 JSON、YAML、Markdown），查找替换和系统惯用撤销重做快捷键。Markdown 显示源码与预览双栏。未知语言保留纯文本编辑。

## 文件内容与安全边界

- 原始换行单独建模，普通编辑保留未删除的分隔符；新插入的行沿用原文第一个分隔符，没有换行时使用 LF。映射参与撤销重做。全文 JSON 排版按原序保留已有分隔符，额外分隔符沿用首个。
- JSON 排版只调整 token 之间空白，原样保留整数、指数、负零和字符串转义；`JSON.parse` 仅判断语法，不参与生成结果。最多支持 256 层嵌套，输入和排版输出均不得超过 10 MiB UTF-8 字节，恢复 CRLF 增加的字节也计入上限；超限在提交编辑事务前拒绝。
- Markdown 禁用原始 HTML，不输出可导航的链接。远程图片、相对路径和 file URL 均显示阻止提示，只允许通过 MIME 与文件头校验的 PNG/JPEG/GIF/WebP data URI；拒绝 SVG。
- CSP 默认全部禁止，只开放本地脚本和样式、CodeMirror 样式 nonce、受过滤的 data 图片；禁止连接、字体、媒体、frame、object、表单和 base URL。脚本不使用 CDN 或运行时下载。
- 原生宿主仍负责文件尺寸限制、编码选择、磁盘冲突检查和原子保存；本资源不会直接访问或写入用户文件。
