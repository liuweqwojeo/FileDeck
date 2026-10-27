import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import { EditorState } from "@codemirror/state";
import { createWorkbench } from "../src/workbench.mjs";
import { MAX_JSON_FORMAT_DEPTH } from "../src/json-format.mjs";
import { lineEndingField, restoreLineEndings } from "../src/line-endings.mjs";

async function withWorkbench(run, languageLoader = async () => []) {
  const dom = new JSDOM('<main><div id="editor"></div><div id="preview"></div></main><span id="status"></span>', { pretendToBeVisual: true });
  const { window } = dom;
  const previous = new Map();
  for (const name of ["window", "document", "Window", "MutationObserver", "HTMLElement", "Node", "DOMRect", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"]) {
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

test("版本差量以原始 UTF-16 往返混合换行、多选区、Unicode、撤销和保存期间输入", async () => {
  await withWorkbench(async ({ controller, messages }) => {
    const { api } = controller;
    let native = "a😀e\u{301}\r\n中文\r尾\n", version = 0, consumed = 1;
    api.open({ id: "patch", text: native, bridgeMode: "patch-v1" });
    const verify = () => {
      for (const message of messages.slice(consumed)) {
        if (message.type === "patch") {
          assert.equal(message.baseVersion, version);
          for (const edit of [...message.edits].reverse()) native = native.slice(0, edit.from) + edit.text + native.slice(edit.to);
        } else if (message.type === "change" || message.type === "state") native = message.text;
        else continue;
        version = message.version;
      }
      consumed = messages.length;
      assert.equal(api.getSnapshot().version, version);
      assert.equal(api.getSnapshot().text, native);
      assert.equal(native, api.getText());
    };
    controller.view.dispatch({ changes: [{ from: 1, to: 3, insert: "🌱" }, { from: 6, to: 8, insert: "新\n文" }] });
    verify();
    assert.equal(native, "a🌱e\u{301}\r\n新\r\n文\r尾\n");
    const saving = native;
    controller.view.dispatch({ changes: { from: 0, insert: "继续" } }); verify();
    api.markSaved({ id: "patch", text: saving }); verify();
    assert.equal(messages.at(-1).dirty, true);
    api.undo(); verify();
    api.redo(); verify();
    // 仅改变未编辑区行尾的恢复 effect 必须回退全文，不能漏掉 CRLF→CR 的字节变化。
    const field = controller.view.state.field(lineEndingField);
    controller.view.dispatch({ changes: { from: 0, insert: "!" }, effects: restoreLineEndings.of({ ...field, endings: field.endings.map(() => "\r") }) });
    assert.equal(messages.at(-1).type, "change"); verify();
    api.open({ id: "json-patch", text: '{"n":9223372036854775807,"a":[1,2]}', language: "json", bridgeMode: "patch-v1" });
    api.formatJSON();
    const formatted = api.getText();
    assert.equal(messages.at(-1).type, "patch");
    assert.ok(formatted.includes("9223372036854775807"));
    api.undo(); assert.equal(api.getText(), '{"n":9223372036854775807,"a":[1,2]}');
    assert.equal(api.getSnapshot("patch"), null);
  });
});

test("可见 Markdown 连续输入每帧只转换一次，确认与模式切换立即刷新且取消旧任务", async () => {
  await withWorkbench(async ({ controller, messages, document }) => {
    const { api } = controller, window = document.defaultView, preview = document.querySelector("#preview");
    const frames = new Map(); let frameID = 0, renders = 0;
    window.requestAnimationFrame = (callback) => { frames.set(++frameID, callback); return frameID; };
    window.cancelAnimationFrame = (id) => frames.delete(id);
    const html = Object.getOwnPropertyDescriptor(window.Element.prototype, "innerHTML");
    Object.defineProperty(preview, "innerHTML", { get() { return html.get.call(this); }, set(value) { renders++; html.set.call(this, value); } });
    const flush = () => { const pending = [...frames.values()]; frames.clear(); pending.forEach((callback) => callback()); };
    api.open({ id: "visible", text: "# 标题", language: "markdown", mode: "split", bridgeMode: "patch-v1" });
    for (const text of ["甲", "乙", "丙"]) controller.view.dispatch({ changes: { from: 2, to: controller.view.state.doc.length, insert: text } });
    assert.equal(messages.filter((message) => message.type === "patch").length, 3);
    assert.equal(renders, 1);
    flush(); assert.equal(renders, 2); assert.equal(preview.querySelector("h1").textContent, "丙");
    controller.view.dispatch({ changes: { from: 2, insert: "新" } });
    api.captureInteraction();
    assert.equal(renders, 3);
    preview.scrollTop = 127; api.setMode({ mode: "preview" });
    assert.equal(renders, 3); assert.equal(preview.scrollTop, 127);
    api.setMode({ mode: "split" }); controller.view.dispatch({ changes: { from: 2, insert: "待" } });
    const cancelled = [...frames.values()];
    api.setMode({ mode: "source" });
    flush(); assert.equal(renders, 3);
    api.setMode({ mode: "preview" }); assert.equal(renders, 4);
    api.open({ id: "next", text: "plain" });
    cancelled.forEach((callback) => callback());
    assert.equal(preview.childNodes.length, 0); assert.equal(renders, 4);
    api.dispose(); flush(); assert.equal(preview.childNodes.length, 0);
  });
});

test("大文档单字差量即时发送，桥接负载不再随全文长度增长", async (t) => {
  await withWorkbench(async ({ controller, messages }) => {
    const source = ("a".repeat(19) + "\r\n").repeat(100_000) + "尾部";
    controller.api.open({ id: "large-patch", text: source, bridgeMode: "patch-v1" });
    const endings = controller.view.state.field(lineEndingField).endings;
    for (let index = 0; index < 40; index++) controller.view.dispatch({ changes: { from: 1_000_000, to: 1_000_001, insert: index % 2 ? "x" : "y" } });
    const patches = messages.filter((message) => message.type === "patch");
    assert.equal(patches.length, 40);
    assert.equal(messages.filter((message) => message.type === "change").length, 0);
    const bytes = patches.reduce((size, message) => size + Buffer.byteLength(JSON.stringify(message)), 0);
    assert.ok(bytes < 12_000);
    assert.equal(controller.api.getSnapshot().version, 40);
    assert.equal(controller.view.state.field(lineEndingField).endings, endings);
    assert.equal(controller.api.getText().slice(-4), "\r\n尾部");
    t.diagnostic(`40 edits, ${Buffer.byteLength(source)} source bytes, ${bytes} total patch JSON bytes; legacy text alone >= ${Buffer.byteLength(source) * 40} bytes`);
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

test("只读文本可聚焦并用快捷键全选复制，仍禁止修改", async () => {
  await withWorkbench(async ({ controller, messages, document }) => {
    const { api } = controller;
    const text = "中文😀 e\u0301\n" + "可复制的正文\n".repeat(2_000);
    api.open({ id: "readonly-selection", text, language: "text", readOnly: true });
    const view = controller.view, content = view.contentDOM, window = document.defaultView;
    content.focus();
    assert.equal(document.activeElement, content);
    const mac = /Mac/.test(globalThis.navigator?.platform ?? "");
    const selectAll = new window.KeyboardEvent("keydown", { key: "a", code: "KeyA", metaKey: mac, ctrlKey: !mac, bubbles: true, cancelable: true });
    content.dispatchEvent(selectAll);
    assert.equal(selectAll.defaultPrevented, true);
    assert.equal(view.state.selection.main.from, 0);
    assert.equal(view.state.selection.main.to, text.length);
    let copied;
    const copy = new window.Event("copy", { bubbles: true, cancelable: true });
    Object.defineProperty(copy, "clipboardData", { value: { clearData() {}, setData(type, value) { if (type === "text/plain") copied = value; } } });
    content.dispatchEvent(copy);
    assert.equal(copied, text);
    view.dispatch({ selection: { anchor: 2 } });
    assert.equal(api.selectAll("stale-session"), false);
    assert.equal(view.state.selection.main.head, 2);
    api.suspend({ suspended: true });
    assert.equal(api.selectAll(), false);
    api.suspend({ suspended: false });
    assert.equal(api.selectAll(), true);
    assert.equal(view.state.selection.main.to, text.length);
    content.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Backspace", bubbles: true, cancelable: true }));
    assert.equal(api.getText(), text);
    assert.equal(content.getAttribute("contenteditable"), "false");
    assert.equal(messages.some(({ type }) => type === "change" || type === "patch"), false);
  });
});

test("只读禁止修改命令，JSON 语法失败不改文档，Markdown 可进入阅读模式", async () => {
  await withWorkbench(async ({ controller, messages, document }) => {
    const { api } = controller;
    api.open({ id: "readonly", text: '{"a":1}', readOnly: true });
    assert.equal(api.formatJSON(), false);
    assert.equal(api.undo(), false);
    assert.equal(document.querySelector(".cm-content").getAttribute("contenteditable"), "false");
    api.open({ id: "bad", text: '{"a":1,}', language: "json" });
    assert.equal(api.formatJSON(), false);
    assert.equal(api.getText(), '{"a":1,}');
    assert.equal(messages.at(-1).code, "invalidJSON");
    api.open({ id: "markdown", text: "# 标题\n\n![remote](https://bad.invalid/a.png)", language: "md", readOnly: true, mode: "preview" });
    assert.equal(document.querySelector("#preview").hidden, false);
    assert.equal(document.querySelector("#preview h1").textContent, "标题");
    assert.equal(document.querySelectorAll("#preview img").length, 0);
  });
});

test("正文 Tab 缩进可撤销，查找框与只读正文不接受缩进命令", async () => {
  await withWorkbench(async ({ controller, document }) => {
    const { api } = controller;
    api.open({ id: "indent", text: "value = 1\r\n", language: "python", bridgeMode: "patch-v1" });
    controller.view.focus();
    assert.equal(api.indentSelection(), true);
    assert.match(api.getText(), /^\s+value = 1\r\n$/);
    assert.equal(api.undo(), true);
    assert.equal(api.getText(), "value = 1\r\n");
    assert.equal(api.redo(), true);
    assert.match(api.getText(), /^\s+value/);
    assert.equal(api.indentSelection({ backward: true }), true);
    assert.equal(api.getText(), "value = 1\r\n");
    api.search();
    const input = document.querySelector('.cm-search input[name="search"]');
    input.focus();
    assert.equal(api.indentSelection(), false);
    assert.equal(input.placeholder, "查找");
    assert.ok(document.querySelector('.cm-search').textContent.includes("区分大小写"));
    api.open({ id: "readonly-indent", text: "value = 1\n", readOnly: true });
    controller.view.contentDOM.focus();
    assert.equal(api.indentSelection(), false);
  });
});

test("搜索行定位保留原始 JSON/Markdown、只读状态和撤销历史", async () => {
  await withWorkbench(async ({ controller }) => {
    const { api } = controller;
    for (const [language, source] of [["json", '{\r\n"a":1,"b":2\r\n}\r\n'], ["markdown", "# 标题\r\n\r\n命中内容\r\n"]]) {
      api.open({ id: language, language, text: source, readOnly: true, mode: "preview" });
      assert.equal(api.revealLine({ id: language, line: 3 }), true);
      assert.equal(controller.view.state.doc.lineAt(controller.view.state.selection.main.from).number, 3);
      assert.equal(api.getText(), source);
      assert.equal(api.undo(), false);
      assert.equal(controller.view.state.readOnly, true);
      api.setEditing({ id: language, enabled: true });
      assert.equal(api.getText(), source);
    }
    assert.equal(api.revealLine({ id: "stale", line: 2 }), false);
    assert.equal(api.revealLine({ line: 0 }), false);
  });
});

test("查找和替换各自撤销重做，正文历史保持独立", async () => {
  await withWorkbench(async ({ controller, document }) => {
    const { api } = controller;
    api.open({ id: "history-owner", text: "old body", language: "text" });
    controller.view.dispatch({ changes: { from: 0, to: 8, insert: "new body" } });
    api.search();
    const enter = (input, value) => {
      input.focus();
      input.dispatchEvent(new document.defaultView.InputEvent("beforeinput", { bubbles: true }));
      input.value = value;
      input.dispatchEvent(new document.defaultView.InputEvent("input", { bubbles: true }));
    };
    const search = document.querySelector('input[name="search"]');
    const replace = document.querySelector('input[name="replace"]');
    enter(search, "needle");
    enter(replace, "replacement");
    assert.equal(api.handleHistoryKey(), true);
    assert.equal(replace.value, "");
    assert.equal(search.value, "needle");
    assert.equal(api.getText(), "new body");
    assert.equal(api.handleHistoryKey({ redo: true }), true);
    assert.equal(replace.value, "replacement");
    search.focus();
    assert.equal(api.handleHistoryKey(), true);
    assert.equal(search.value, "");
    assert.equal(replace.value, "replacement");
    controller.view.focus();
    assert.equal(api.handleHistoryKey(), true);
    assert.equal(api.getText(), "old body");
    api.open({ id: "new-query-baseline", text: "alpha beta", language: "text" });
    api.search();
    enter(document.querySelector('input[name="search"]'), "old");
    controller.view.dispatch({ selection: { anchor: 6, head: 10 } });
    controller.view.focus();
    api.search();
    const newQuery = document.querySelector('input[name="search"]');
    assert.equal(newQuery.value, "beta");
    enter(newQuery, "replacement");
    api.handleHistoryKey();
    assert.equal(newQuery.value, "beta");
    assert.equal(api.getText(), "alpha beta");
  });
});

test("格式化 JSON 仅对 JSON 文件提供入口，其他语言调用不产生错误或修改", async () => {
  await withWorkbench(async ({ controller, messages, document }) => {
    const button = document.createElement("button");
    button.dataset.command = "formatJSON";
    document.body.append(button);
    controller.api.open({ id: "python", text: "x = 1\n", language: "example.py" });
    const count = messages.length;
    assert.equal(button.hidden, true);
    assert.equal(controller.api.formatJSON(), false);
    assert.equal(messages.length, count);
    assert.equal(controller.api.getText(), "x = 1\n");
    controller.api.open({ id: "json", text: '{"a":1}', language: "json" });
    assert.equal(button.hidden, false);
    controller.api.setEditing({ enabled: false });
    assert.equal(button.hidden, true);
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

test("隐藏 Markdown 不重建预览，显示时使用最新正文且保持即时草稿同步", async () => {
  await withWorkbench(async ({ controller, messages, document }) => {
    const preview = document.querySelector("#preview");
    const html = Object.getOwnPropertyDescriptor(document.defaultView.Element.prototype, "innerHTML");
    let renders = 0;
    Object.defineProperty(preview, "innerHTML", {
      get() { return html.get.call(this); },
      set(value) { renders++; html.set.call(this, value); },
    });
    const source = "# 原文\r\n" + "一行 Markdown 正文\r\n".repeat(4_000);
    controller.api.open({ id: "large-markdown", text: source, language: "markdown", mode: "source" });
    assert.equal(renders, 0);
    for (const value of ["甲", "乙", "丙"]) {
      controller.view.dispatch({ changes: { from: 2, to: 4, insert: value + "标题" } });
      assert.equal(messages.at(-1).type, "change");
      assert.equal(messages.at(-1).text, controller.api.getText());
      assert.equal(messages.at(-1).dirty, true);
    }
    assert.equal(renders, 0);
    controller.api.setMode({ mode: "split" });
    assert.equal(renders, 1);
    assert.equal(preview.querySelector("h1").textContent, controller.view.state.doc.line(1).text.slice(2));
    const heading = preview.querySelector("h1");
    preview.scrollTop = 127;
    controller.api.setMode({ mode: "preview" });
    controller.api.captureInteraction();
    controller.api.restoreInteraction();
    assert.equal(renders, 1);
    assert.equal(preview.querySelector("h1"), heading);
    assert.equal(preview.scrollTop, 127);
    controller.api.setMode({ mode: "source" });
    controller.api.undo();
    assert.equal(renders, 1);
    assert.equal(messages.at(-1).text, controller.api.getText());
    controller.api.setMode({ mode: "preview" });
    assert.equal(renders, 2);
    controller.api.open({ id: "next-document", text: "plain", language: "text" });
    assert.equal(preview.childNodes.length, 0);
    controller.api.open({ id: "next-markdown", text: "# 新会话", language: "md", readOnly: true, mode: "preview" });
    assert.equal(renders, 3);
    assert.equal(preview.querySelector("h1").textContent, "新会话");
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
