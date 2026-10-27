import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";

const resource = (name) => new URL(`../../Resources/Editors/${name}`, import.meta.url);

test("离线 bundle 支持 JSON 编辑撤销、配置预览与常见语言高亮", async () => {
  const html = await readFile(resource("index.html"), "utf8");
  const bundle = await readFile(resource("editor.js"), "utf8");
  const dom = new JSDOM(html, { runScripts: "outside-only", pretendToBeVisual: true, url: resource("index.html").href });
  const messages = [];
  dom.window.webkit = { messageHandlers: { workbench: { postMessage: (message) => messages.push(message) } } };
  dom.window.fetch = () => { throw new Error("离线资源不得联网"); };
  dom.window.XMLHttpRequest = class { constructor() { throw new Error("离线资源不得联网"); } };
  dom.window.Range.prototype.getClientRects = () => [];
  dom.window.Range.prototype.getBoundingClientRect = () => new dom.window.DOMRect();
  try {
    dom.window.eval(bundle);
    assert.equal(messages[0].type, "ready");
    const { workbench } = dom.window;
    const source = '{\r\n"id":9223372036854775807,\r"value":1.2300\n}';
    workbench.open({ id: "bundled", text: source, language: "json", readOnly: false });
    assert.equal(workbench.getText("bundled"), source);
    assert.equal(workbench.formatJSON("bundled"), true);
    assert.match(workbench.getText(), /9223372036854775807/);
    assert.match(workbench.getText(), /1\.2300/);
    assert.equal(workbench.undo("bundled"), true);
    assert.equal(workbench.getText(), source);
    await new Promise((resolve) => setTimeout(resolve, 15));
    assert.equal(messages.some((message) => message.type === "error"), false);
    workbench.open({ id: "colored-preview", text: '{"name":"中文","count":42,"enabled":true,"empty":null}', language: "json", readOnly: true });
    await new Promise((resolve) => setTimeout(resolve, 30));
    const content = dom.window.document.querySelector(".cm-content");
    for (const [kind, text] of [["key", '"name"'], ["string", '"中文"'], ["number", "42"], ["bool", "true"], ["null", "null"]]) {
      assert.ok(Array.from(content.querySelectorAll(`.fw-json-${kind}`)).some((span) => span.textContent === text), `${kind} 应获得对应的语义色彩`);
    }
    workbench.setEditing({ id: "colored-preview", enabled: true });
    assert.equal(content.querySelector(".fw-json-number").textContent, "42");
    const css = await readFile(resource("editor.css"), "utf8");
    const [light] = css.split("@media (prefers-color-scheme: dark)");
    for (const kind of ["key", "string", "number", "bool", "null"]) {
      assert.match(light, new RegExp(`\\.fw-json-${kind}[^{}]*\\{ color: #[0-9a-f]{6}; \\}`));
      assert.match(css.slice(css.indexOf("@media (prefers-color-scheme: dark)")), new RegExp(`\\.fw-json-${kind}[^{}]*\\{ color: #[0-9a-f]{6}; \\}`));
    }
    const yaml = ['# 配置说明', 'defaults: &defaults', '  title: "中文"', '  host: localhost', '  note: |', '    多行正文', '  code: !!str 42', 'service: *defaults'].join("\r\n");
    for (const language of ["yaml", "yml", "YAML", "YML"]) {
      const count = messages.length;
      workbench.open({ id: language, text: yaml, language, readOnly: true });
      await new Promise((resolve) => setTimeout(resolve, 30));
      const content = dom.window.document.querySelector(".cm-content");
      for (const [kind, text] of [["key", "title"], ["string", '"中文"'], ["string", "localhost"], ["string", "多行正文"], ["comment", "# 配置说明"], ["anchor", "&defaults"], ["anchor", "*defaults"], ["type", "!!str"], ["punctuation", ":"]]) {
        assert.ok(Array.from(content.querySelectorAll(`.fw-yaml-${kind}`)).some((span) => span.textContent.trim() === text), `${language} ${text} 应获得 ${kind} 配色`);
      }
      assert.equal(workbench.getText(), yaml);
      assert.equal(content.getAttribute("contenteditable"), "false");
      workbench.setEditing({ id: language, enabled: true });
      assert.ok(content.querySelector(".fw-yaml-key"));
      assert.equal(content.getAttribute("contenteditable"), "true");
      assert.equal(workbench.getText(), yaml);
      assert.equal(workbench.undo(), false);
      assert.deepEqual(messages.slice(count).map(({ type }) => type), ["opened"]);
    }
    for (const kind of ["key", "string", "comment", "anchor", "type", "punctuation"]) {
      for (const theme of [light, css.slice(css.indexOf("@media (prefers-color-scheme: dark)"))]) {
        assert.match(theme, new RegExp(`\\.fw-yaml-${kind}[^{}]*\\{ color: #[0-9a-f]{6}; \\}`));
      }
    }
    for (const [filename, source] of [
      ["main.rs", 'fn main() { println!("中文"); }\r\n'],
      ["main.kt", 'fun main() { println("中文") }\r\n'],
      ["build.gradle.kts", 'val message = "中文"\r\n'],
      ["sample.h", '#define VALUE 42\r\n'], ["sample.hpp", 'class Example {};\r\n'],
      ["module.mjs", 'export const message = "中文";\r\n'],
      ["sample.mm", '@interface Example\r\n@end\r\n'],
      ["App.svelte", '<script>let name = "中文";</script>\r\n<h1>{name}</h1>\r\n'],
      ["main.jl", 'function greet()\r\n  return "中文"\r\nend\r\n'],
    ]) {
      const count = messages.length;
      workbench.open({ id: filename, text: source, language: filename, readOnly: true });
      for (let attempt = 0; attempt < 100 && !content.querySelector('.cm-line span[class]'); attempt++) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      assert.ok(content.querySelector('.cm-line span[class]'), `${filename} 应从离线 bundle 显示实际高亮`);
      assert.equal(workbench.getText(), source, filename);
      workbench.setEditing({ id: filename, enabled: true });
      assert.ok(content.querySelector('.cm-line span[class]'), `${filename} 进入编辑后保留高亮`);
      assert.equal(workbench.getText(), source, filename);
      assert.equal(workbench.undo(), false, filename);
      assert.deepEqual(messages.slice(count).map(({ type }) => type), ['opened'], filename);
    }
    const nonce = dom.window.document.querySelector('meta[name="style-nonce"]').content;
    assert.ok(Array.from(dom.window.document.querySelectorAll("style")).some((style) => style.getAttribute("nonce") === nonce));
  } finally { dom.window.close(); }
});

test("交付资源与锁文件摘要一致并包含依赖许可", async () => {
  const manifest = JSON.parse(await readFile(resource("manifest.json"), "utf8"));
  for (const [name, hash] of Object.entries(manifest.files)) {
    assert.equal(createHash("sha256").update(await readFile(resource(name))).digest("hex"), hash);
  }
  const lock = await readFile(new URL("../package-lock.json", import.meta.url));
  assert.equal(createHash("sha256").update(lock).digest("hex"), manifest.dependenciesLockSHA256);
  const notices = await readFile(resource("THIRD-PARTY-NOTICES.txt"), "utf8");
  for (const dependency of ["@codemirror/state", "@codemirror/view", "markdown-it", "punycode.js"]) {
    assert.ok(notices.includes(dependency));
  }
});
