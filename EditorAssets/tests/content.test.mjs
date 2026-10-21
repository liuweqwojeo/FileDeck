import test from "node:test";
import assert from "node:assert/strict";
import { EditorState, Transaction } from "@codemirror/state";
import { history, undo, redo } from "@codemirror/commands";
import { JSDOM } from "jsdom";
import { lineEndingExtensions, originalText, splitLineEndings, restoreLineEndings, lineEndingsForFormattedText } from "../src/line-endings.mjs";
import { formatJSONLosslessly, assertJSONFormatSize, JSONFormatLimitError, MAX_JSON_FORMAT_BYTES, MAX_JSON_FORMAT_DEPTH } from "../src/json-format.mjs";
import { renderMarkdown, safeRasterDataURI } from "../src/markdown.mjs";

function editor(text) {
  const target = { state: EditorState.create({ doc: splitLineEndings(text).normalized, extensions: [history(), ...lineEndingExtensions(text)] }) };
  target.dispatch = (transaction) => { target.state = transaction.state ?? target.state.update(transaction).state; };
  return target;
}

test("混合换行无改保存、编辑和分组撤销重做均无损", () => {
  const source = "第一行\r\n第二行\r第三行\n结尾";
  const target = editor(source);
  assert.equal(originalText(target.state), source);
  target.dispatch({ changes: { from: 4, to: 8, insert: "新增\n更多\n" }, annotations: Transaction.userEvent.of("input.type") });
  const modified = originalText(target.state);
  assert.equal(modified, "第一行\r\n新增\r\n更多\r\n第三行\n结尾");
  target.dispatch({ changes: { from: 10, insert: "!" }, annotations: Transaction.userEvent.of("input.type") });
  const second = originalText(target.state);
  assert.equal(undo(target), true);
  // 两次相邻输入可能合并为同一历史事件，继续撤销直到原文。
  while (originalText(target.state) !== source && undo(target)) { /* 检查最终恢复而不假定 UI 分组计时。 */ }
  assert.equal(originalText(target.state), source);
  while (redo(target)) { /* 重做全部。 */ }
  assert.equal(originalText(target.state), second);
});

test("多处编辑只影响被删除的换行，新增行使用首个 CR", () => {
  const target = editor("a\rb\r\nc\nd");
  target.dispatch({ changes: [{ from: 1, insert: "\nx" }, { from: 6, insert: "y" }] });
  assert.equal(originalText(target.state), "a\rx\rb\r\nc\nyd");
  undo(target);
  assert.equal(originalText(target.state), "a\rb\r\nc\nd");
});

test("超多行映射不使用展开参数，避免触发 JS 参数个数上限", () => {
  const source = "a\r\n".repeat(150_000);
  const target = editor(source);
  target.dispatch({ changes: { from: 0, insert: "x" } });
  assert.equal(originalText(target.state), `x${source}`);
});

test("JSON 词法排版保留大整数、指数、负零、小数零和字符串转义", () => {
  const source = '{"big":9223372036854775807,"huge":1E+9999,"negative":-0,"decimal":1.2300,"text":"\\u4e2d\\n","array":[true,null,{}]}';
  const result = formatJSONLosslessly(source);
  assert.match(result, /9223372036854775807/);
  assert.match(result, /1E\+9999/);
  assert.match(result, /"negative": -0/);
  assert.match(result, /1\.2300/);
  assert.match(result, /"\\u4e2d\\n"/);
  assert.deepEqual(JSON.parse(result), JSON.parse(source));
  assert.throws(() => formatJSONLosslessly('{"a": 1,}'), SyntaxError);
});

test("JSON 全文排版及其撤销保留原有混合换行", () => {
  const source = '{\r\n"a":1,\r"b":[2,3]\n}';
  const target = editor(source);
  const formatted = formatJSONLosslessly(target.state.doc.toString());
  target.dispatch({ changes: { from: 0, to: target.state.doc.length, insert: formatted }, effects: restoreLineEndings.of(lineEndingsForFormattedText(target.state, formatted)) });
  const endings = originalText(target.state).match(/\r\n|\r|\n/g);
  assert.deepEqual(endings.slice(0, 3), ["\r\n", "\r", "\n"]);
  assert.ok(endings.slice(3).every((value) => value === "\r\n"));
  undo(target);
  assert.equal(originalText(target.state), source);
});

test("合法的过深 JSON 被拒绝，深度上限内也不能无限膨胀排版输出", () => {
  const deep = "[".repeat(MAX_JSON_FORMAT_DEPTH + 1) + "0" + "]".repeat(MAX_JSON_FORMAT_DEPTH + 1);
  assert.doesNotThrow(() => JSON.parse(deep));
  assert.throws(() => formatJSONLosslessly(deep), JSONFormatLimitError);
  const allowed = "[".repeat(MAX_JSON_FORMAT_DEPTH) + "0" + "]".repeat(MAX_JSON_FORMAT_DEPTH);
  assert.doesNotThrow(() => formatJSONLosslessly(allowed));
  const expansion = "[".repeat(MAX_JSON_FORMAT_DEPTH) + "0,".repeat(30_000) + "0" + "]".repeat(MAX_JSON_FORMAT_DEPTH);
  assert.ok(Buffer.byteLength(expansion) < 100_000);
  assert.doesNotThrow(() => JSON.parse(expansion));
  assert.throws(() => formatJSONLosslessly(expansion), JSONFormatLimitError);
});

test("中文输出按 UTF-8 字节限制为 10 MiB，不按 JavaScript 字符数放宽", () => {
  const count = Math.floor((MAX_JSON_FORMAT_BYTES - 4) / 3);
  const source = `["${"中".repeat(count)}"]`;
  assert.equal(Buffer.byteLength(source), MAX_JSON_FORMAT_BYTES);
  assert.ok(source.length < MAX_JSON_FORMAT_BYTES / 2);
  assert.throws(() => formatJSONLosslessly(source), JSONFormatLimitError);
  const allowed = formatJSONLosslessly(`["${"中".repeat(count - 2)}"]`);
  assert.ok(Buffer.byteLength(allowed) <= MAX_JSON_FORMAT_BYTES);
});

test("恢复 CRLF 的额外字节计入排版结果限额", () => {
  const source = '"中"';
  assert.doesNotThrow(() => assertJSONFormatSize(source, MAX_JSON_FORMAT_BYTES - 5));
  assert.throws(() => assertJSONFormatSize(source, MAX_JSON_FORMAT_BYTES - 4), JSONFormatLimitError);
});

test("Markdown 禁 HTML、远程图片、SVG 和导航链接", () => {
  const source = '<img src="https://attacker.invalid/x" onerror="alert(1)"><script>alert(1)</script>\n\n![remote](https://attacker.invalid/x.png)\n![relative](../secret.png)\n![svg](data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=)\n[link](https://attacker.invalid)\n[javascript](javascript:alert%281%29)';
  const html = renderMarkdown(source);
  const document = new JSDOM(html).window.document;
  assert.equal(document.querySelectorAll("script,img,iframe,object,a,[onerror],[onclick],[href],[src]").length, 0);
  assert.match(document.body.textContent, /已阻止自动加载/);
  assert.match(document.body.textContent, /<script>alert\(1\)<\/script>/);
});

test("只允许有效栅格 data 图片，伪造 PNG 的 SVG 被拒绝", () => {
  const png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=";
  assert.equal(safeRasterDataURI(png), true);
  assert.equal(safeRasterDataURI("data:image/png;base64,PHN2Zz48L3N2Zz4="), false);
  assert.equal(safeRasterDataURI("data:image/svg+xml;base64,PHN2Zz48L3N2Zz4="), false);
  assert.equal(new JSDOM(renderMarkdown(`![safe](${png})`)).window.document.querySelectorAll("img").length, 1);
});
