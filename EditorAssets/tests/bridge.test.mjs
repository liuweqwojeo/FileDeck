import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import { EditorState } from "@codemirror/state";
import { createWorkbench } from "../src/workbench.mjs";
import { MAX_JSON_FORMAT_DEPTH } from "../src/json-format.mjs";

async function withWorkbench(run, languageLoader = async () => []) {
  const dom = new JSDOM('<main><div id="editor"></div><div id="preview"></div></main><span id="status"></span>', { pretendToBeVisual: true });
  const { window } = dom;
  const previous = new Map();
  for (const name of ["window", "document", "MutationObserver", "HTMLElement", "Node", "DOMRect", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"]) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value: window[name].bind?.(window) ?? window[name] });
  }
  window.Range.prototype.getClientRects = () => [];
  window.Range.prototype.getBoundingClientRect = () => new window.DOMRect();
  const messages = [];
  const controller = createWorkbench({
    editorRoot: window.document.querySelector("#editor"), previewRoot: window.document.querySelector("#preview"),
    statusRoot: window.document.querySelector("#status"), nonce: "test-style-nonce", postMessage: (message) => messages.push(message), languageLoader,
  });
  try { await run({ ...controller, controller, messages, document: window.document }); }
  finally {
    controller.destroy();
    window.close();
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  }
}

test("open 不发 dirty，变更回传全文和历史状态，undo 恢复干净状态", async () => {
  await withWorkbench(async ({ controller, messages }) => {
    const { api } = controller;
    api.open({ id: "one", text: "a\r\nb\rc\nd", language: "text", readOnly: false });
    assert.equal(messages.length, 1);
    assert.equal(messages[0].type, "opened");
    assert.equal(Object.hasOwn(messages[0], "dirty"), false);
    controller.view.dispatch({ changes: { from: 1, insert: "!\n" } });
    assert.deepEqual(messages.at(-1), { type: "change", id: "one", text: "a!\r\n\r\nb\rc\nd", dirty: true, canUndo: true, canRedo: false });
    assert.equal(api.undo("one"), true);
    assert.equal(api.getText("one"), "a\r\nb\rc\nd");
    assert.equal(messages.at(-1).dirty, false);
    assert.equal(messages.at(-1).canRedo, true);
  });
});

test("保存确认不清除保存期间的后续修改，过期 id 不得操作当前会话", async () => {
  await withWorkbench(async ({ controller, messages }) => {
    const { api } = controller;
    api.open({ id: "a", text: "old" });
    controller.view.dispatch({ changes: { from: 3, insert: "new" } });
    api.markSaved({ id: "a", text: "old" });
    assert.equal(messages.at(-1).dirty, true);
    api.open({ id: "b", text: '{"number":9223372036854775807}' });
    assert.equal(api.getText("a"), null);
    assert.equal(api.undo("a"), false);
    assert.equal(api.redo("a"), false);
    assert.equal(api.formatJSON("a"), false);
    assert.equal(api.markSaved({ id: "a", text: "stale" }), false);
    assert.equal(api.getText("b"), '{"number":9223372036854775807}');
  });
});

test("只读禁止修改命令，JSON 语法失败不改文档，Markdown 可进入阅读模式", async () => {
  await withWorkbench(async ({ controller, messages, document }) => {
    const { api } = controller;
    api.open({ id: "readonly", text: '{"a":1}', readOnly: true });
    assert.equal(api.formatJSON(), false);
    assert.equal(api.undo(), false);
    assert.equal(document.querySelector(".cm-content").getAttribute("contenteditable"), "false");
    api.open({ id: "bad", text: '{"a":1,}' });
    assert.equal(api.formatJSON(), false);
    assert.equal(api.getText(), '{"a":1,}');
    assert.equal(messages.at(-1).code, "invalidJSON");
    api.open({ id: "markdown", text: "# 标题\n\n![remote](https://bad.invalid/a.png)", language: "md", readOnly: true, mode: "preview" });
    assert.equal(document.querySelector("#preview").hidden, false);
    assert.equal(document.querySelector("#preview h1").textContent, "标题");
    assert.equal(document.querySelectorAll("#preview img").length, 0);
  });
});

test("阅读转编辑与确认取消保留同一编辑器、光标、滚动、模式和撤销历史", async () => {
  await withWorkbench(async ({ controller, document }) => {
    const { api } = controller;
    api.open({ id: "modal", text: "# 标题\n正文", language: "markdown", readOnly: true, mode: "preview" });
    const view = controller.view;
    assert.equal(document.querySelector("#editor").hidden, true);
    assert.notEqual(document.activeElement, view.contentDOM);
    assert.equal(api.setEditing({ id: "modal", enabled: true }), true);
    assert.equal(controller.view, view);
    assert.equal(document.querySelector("#editor").hidden, false);
    assert.equal(document.querySelector("#preview").hidden, true);
    view.dispatch({ changes: { from: view.state.doc.length, insert: "\n草稿" }, selection: { anchor: 3, head: 5 } });
    api.setMode({ id: "modal", mode: "split" });
    view.contentDOM.focus();
    view.scrollDOM.scrollTop = 123;
    view.scrollDOM.scrollLeft = 37;
    api.captureInteraction("modal");
    api.suspend({ id: "modal", suspended: true });
    assert.equal(view.contentDOM.getAttribute("contenteditable"), "false");
    assert.equal(api.undo("modal"), false);
    api.suspend({ id: "modal", suspended: false });
    api.restoreInteraction("modal");
    assert.equal(view.state.selection.main.anchor, 3);
    assert.equal(view.state.selection.main.head, 5);
    assert.equal(view.scrollDOM.scrollTop, 123);
    assert.equal(view.scrollDOM.scrollLeft, 37);
    assert.equal(document.activeElement, view.contentDOM);
    assert.equal(document.querySelector("main").classList.contains("markdown-layout"), true);
    assert.equal(api.getText("modal"), "# 标题\n正文\n草稿");
    assert.equal(api.undo("modal"), true);
    assert.equal(api.getText("modal"), "# 标题\n正文");
    assert.equal(api.redo("modal"), true);
    assert.equal(api.getText("modal"), "# 标题\n正文\n草稿");
  });
});

test("JSON 只读预览自动美化，进入编辑恢复源码、换行与高亮且没有格式化撤销项", async () => {
  await withWorkbench(async ({ controller, messages, document }) => {
    const { api } = controller;
    const source = '{\r\n"id":9223372036854775807,"value":1e+09,"text":"中文\\u4e2d","items":[true,null,{}]}';
    api.open({ id: "json-preview", text: source, language: "JSON", readOnly: true });
    const view = controller.view;
    assert.match(view.state.doc.toString(), /\n  "id": 9223372036854775807,/);
    assert.match(view.state.doc.toString(), /"items": \[\n    true,\n    null,\n    \{\}/);
    assert.match(view.state.doc.toString(), /1e\+09/);
    assert.match(view.state.doc.toString(), /中文\\u4e2d/);
    assert.equal(api.getText(), source);
    assert.equal(document.querySelector(".cm-content").getAttribute("contenteditable"), "false");
    assert.deepEqual(messages.map(({ type }) => type), ["opened"]);
    api.markSaved({ id: "json-preview", text: source });
    assert.equal(messages.at(-1).dirty, false);
    assert.equal(messages.at(-1).text, source);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(view.state.facet(EditorState.tabSize), 7);
    api.setEditing({ id: "json-preview", enabled: true });
    assert.equal(controller.view, view);
    assert.equal(view.state.doc.toString(), source.replaceAll("\r\n", "\n"));
    assert.equal(view.state.facet(EditorState.tabSize), 7);
    assert.equal(api.getText(), source);
    assert.equal(api.undo(), false);
    assert.equal(document.querySelector("#status").textContent, "已保存");
    view.dispatch({ changes: { from: view.state.doc.length, insert: " " }, selection: { anchor: 4 } });
    api.setEditing({ id: "json-preview", enabled: false });
    assert.equal(api.getText(), source + " ");
    api.setEditing({ id: "json-preview", enabled: true });
    assert.equal(view.state.selection.main.anchor, 4);
    assert.equal(api.undo(), true);
    assert.equal(api.getText(), source);
    assert.equal(api.redo(), true);
    assert.equal(api.getText(), source + " ");
  }, async () => EditorState.tabSize.of(7));
});

test("JSON 预览语法错误或排版超限保留原文，并且不影响后续文件", async () => {
  await withWorkbench(async ({ controller, messages }) => {
    const { api } = controller;
    const deep = "[".repeat(MAX_JSON_FORMAT_DEPTH + 1) + "0" + "]".repeat(MAX_JSON_FORMAT_DEPTH + 1);
    for (const source of ['{"a":1,}', deep]) {
      api.open({ id: "fallback", text: source, language: "json", readOnly: true });
      assert.equal(controller.view.state.doc.toString(), source);
      assert.equal(api.getText(), source);
      api.setEditing({ id: "fallback", enabled: true });
      assert.equal(api.getText(), source);
      assert.equal(api.undo(), false);
    }
    api.open({ id: "valid", text: '{"a":1}', language: "json", readOnly: true });
    assert.notEqual(controller.view.state.doc.toString(), api.getText());
    api.open({ id: "next", text: "新文件", language: "text", readOnly: true });
    assert.equal(api.getText(), "新文件");
    assert.equal(controller.view.state.doc.toString(), "新文件");
    assert.equal(messages.some(({ type }) => type === "change" || type === "error"), false);
  });
});

test("关闭后过期语言结果与命令不再操作预览，Esc 先关闭搜索", async () => {
  let rejectLanguage;
  await withWorkbench(async ({ controller, messages, document }) => {
    const { api } = controller;
    api.open({ id: "closing", text: "draft" });
    await Promise.resolve();
    assert.equal(api.search("closing"), true);
    assert.ok(document.querySelector(".cm-search"));
    assert.equal(api.consumeEscape("closing"), true);
    assert.equal(document.querySelector(".cm-search"), null);
    controller.view.dispatch({ selection: { anchor: 1, head: 4 } });
    assert.equal(api.consumeEscape("closing"), false, "没有搜索或补全时，Esc 应交回原生关闭流程");
    assert.equal(controller.view.state.selection.main.anchor, 1);
    assert.equal(controller.view.state.selection.main.head, 4, "原生确认前不得由 Escape 清除文本选区");
    assert.equal(api.dispose("closing"), true);
    rejectLanguage(new Error("late language error"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(api.getText("closing"), null);
    assert.equal(api.setEditing({ id: "closing", enabled: true }), false);
    assert.equal(messages.some((message) => message.type === "error"), false);
    assert.equal(controller.view, null);
  }, () => new Promise((resolve, reject) => { rejectLanguage = reject; }));
});

test("异步语言加载不能污染后来打开的会话", async () => {
  const pending = [];
  await withWorkbench(async ({ controller, messages }) => {
    controller.api.open({ id: "old", text: "old", language: "json" });
    await Promise.resolve();
    controller.api.open({ id: "new", text: "new", language: "yaml" });
    await Promise.resolve();
    pending[0].reject(new Error("old failure"));
    pending[1].resolve([]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(controller.api.getText(), "new");
    assert.equal(messages.some((message) => message.type === "error"), false);
  }, (language) => new Promise((resolve, reject) => pending.push({ language, resolve, reject })));
  assert.deepEqual(pending.map((item) => item.language), ["json", "yaml"]);
});

test("JSON 排版超限只发 formatLimit，不改变原文、dirty 或撤销历史", async () => {
  await withWorkbench(async ({ controller, messages, document }) => {
    const source = "[".repeat(MAX_JSON_FORMAT_DEPTH + 1) + "0" + "]".repeat(MAX_JSON_FORMAT_DEPTH + 1);
    controller.api.open({ id: "deep", text: source, language: "json" });
    assert.equal(controller.api.formatJSON("deep"), false);
    assert.equal(controller.api.getText("deep"), source);
    assert.equal(messages.at(-1).code, "formatLimit");
    assert.equal(messages.some((message) => message.type === "change"), false);
    assert.equal(document.querySelector("#status").textContent, "已保存");
    assert.equal(controller.api.undo("deep"), false);

    controller.view.dispatch({ changes: { from: 0, insert: " " } });
    const count = messages.length;
    assert.equal(controller.api.formatJSON("deep"), false);
    assert.equal(messages.length, count + 1);
    assert.equal(messages.at(-1).code, "formatLimit");
    assert.equal(controller.api.getText("deep"), ` ${source}`);
    assert.equal(document.querySelector("#status").textContent, "未保存");
    assert.equal(controller.api.undo("deep"), true);
    assert.equal(controller.api.getText("deep"), source);
  });
});

test("生产 HTML CSP 禁网络和内联脚本，仅引用本地 bundle", async () => {
  const html = await readFile(new URL("../src/index.html", import.meta.url), "utf8");
  const document = new JSDOM(html).window.document;
  const csp = document.querySelector('meta[http-equiv="Content-Security-Policy"]').content;
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /connect-src 'none'/);
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /style-src 'self' 'nonce-/);
  assert.match(csp, /img-src data:/);
  assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|https?:|\*/);
  assert.deepEqual(Array.from(document.scripts, (script) => script.getAttribute("src")), ["editor.js"]);
});
