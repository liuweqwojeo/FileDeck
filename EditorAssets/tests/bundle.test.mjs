import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";

const resource = (name) => new URL(`../../Resources/Editors/${name}`, import.meta.url);

test("生成的单文件 bundle 在无网络 DOM 中启动并完成 JSON 编辑及撤销", async () => {
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
