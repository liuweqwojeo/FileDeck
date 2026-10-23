import { basicSetup } from "codemirror";
import { Compartment, EditorSelection, EditorState, Transaction } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { indentWithTab, redo, redoDepth, undo, undoDepth } from "@codemirror/commands";
import { closeCompletion } from "@codemirror/autocomplete";
import { openSearchPanel, closeSearchPanel } from "@codemirror/search";
import { HighlightStyle, LanguageDescription, syntaxHighlighting } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { tags } from "@lezer/highlight";
import { lineEndingExtensions, originalText, splitLineEndings, restoreLineEndings, lineEndingsForFormattedText } from "./line-endings.mjs";
import { formatJSONLosslessly, assertJSONFormatSize, JSONFormatLimitError } from "./json-format.mjs";
import { renderMarkdown } from "./markdown.mjs";

const aliases = { md: "markdown", yml: "yaml", js: "javascript", ts: "typescript", py: "python", rb: "ruby", sh: "shell", cs: "c#", cpp: "c++" };
// 使用固定 token 类，颜色由本地 CSS 根据系统外观切换，预览和编辑共用同一套语义。
const jsonHighlightStyle = HighlightStyle.define([
  { tag: tags.propertyName, class: "fw-json-key" },
  { tag: tags.string, class: "fw-json-string" },
  { tag: tags.number, class: "fw-json-number" },
  { tag: tags.bool, class: "fw-json-bool" },
  { tag: tags.null, class: "fw-json-null" },
  { tag: [tags.bracket, tags.separator], class: "fw-json-punctuation" },
]);
// YAML 将未加引号的值和块文本标记为 content，也必须显式配色才能覆盖常见配置文件。
const yamlHighlightStyle = HighlightStyle.define([
  { tag: tags.propertyName, class: "fw-yaml-key" },
  { tag: [tags.string, tags.content, tags.attributeValue], class: "fw-yaml-string" },
  { tag: tags.comment, class: "fw-yaml-comment" },
  { tag: tags.labelName, class: "fw-yaml-anchor" },
  { tag: [tags.typeName, tags.keyword], class: "fw-yaml-type" },
  { tag: [tags.meta, tags.punctuation], class: "fw-yaml-punctuation" },
]);
async function loadLanguage(language) {
  const name = aliases[language.toLowerCase()] ?? language;
  const description = LanguageDescription.matchLanguageName(languages, name, true);
  return description ? description.load() : [];
}

export function createWorkbench({ editorRoot, previewRoot, statusRoot, nonce, postMessage, languageLoader = loadLanguage }) {
  let view = null;
  let session = null;
  let jsonSourceState = null;
  let generation = 0;
  const language = new Compartment();
  const editing = new Compartment();
  let interaction = null;
  const matches = (id) => session !== null && (id === undefined || id === session.id);
  const send = (message) => { try { postMessage?.(message); } catch { /* 原生桥接离线时仍保留当前编辑内容。 */ } };
  const sourceState = () => jsonSourceState ?? view.state;
  const historyState = () => ({ canUndo: undoDepth(sourceState()) > 0, canRedo: redoDepth(sourceState()) > 0 });
  const updateJSONPreview = () => {
    if (jsonSourceState) {
      view.setState(jsonSourceState);
      jsonSourceState = null;
    }
    if (!session.readOnly || session.language.toLowerCase() !== "json") return;
    try {
      const formatted = formatJSONLosslessly(view.state.doc.toString());
      if (formatted === view.state.doc.toString()) return;
      // 美化仅用于展示；保留源码 state，切回编辑时连同原始换行、选区和撤销历史一起恢复。
      // setState 不发送 change，避免预览产生草稿或把显示用缩进写回原生会话。
      const preview = view.state.update({
        changes: { from: 0, to: view.state.doc.length, insert: formatted },
        annotations: Transaction.addToHistory.of(false),
      }).state;
      jsonSourceState = view.state;
      view.setState(preview);
    } catch {
      // 无效或超限 JSON 仍可阅读原文，不能因自动排版阻止进入编辑修复。
    }
  };
  const renderPreview = () => {
    const markdown = ["markdown", "md"].includes(session.language.toLowerCase());
    const mode = markdown ? session.mode : "source";
    previewRoot.hidden = mode === "source";
    editorRoot.hidden = mode === "preview";
    editorRoot.parentElement.classList.toggle("markdown-layout", mode === "split");
    editorRoot.parentElement.classList.toggle("reading-layout", mode === "preview");
    editorRoot.ownerDocument.body.classList.toggle("read-only", session.readOnly);
    for (const button of editorRoot.ownerDocument.querySelectorAll("[data-mode]")) {
      button.hidden = !markdown || session.readOnly;
      button.setAttribute("aria-pressed", String(button.dataset.mode === mode));
    }
    previewRoot.innerHTML = markdown ? renderMarkdown(view.state.doc.toString()) : "";
  };
  const changed = (update) => {
    if (!update.docChanged || !session) return;
    const text = originalText(update.state);
    const dirty = text !== session.savedText;
    statusRoot.textContent = session.readOnly ? "只读" : dirty ? "未保存" : "已保存";
    renderPreview();
    send({ type: "change", id: session.id, text, dirty, ...historyState() });
  };

  const api = {
    open(document) {
      if (!document || typeof document.id !== "string" || !document.id || typeof document.text !== "string") {
        throw new TypeError("open 需要非空会话 id 和完整文本。");
      }
      const token = ++generation;
      jsonSourceState = null;
      session = { id: document.id, savedText: document.text, language: typeof document.language === "string" ? document.language : "text", readOnly: document.readOnly === true,
        mode: ["source", "preview", "split"].includes(document.mode) ? document.mode : "source", suspended: false };
      interaction = null;
      const state = EditorState.create({
        doc: splitLineEndings(document.text).normalized,
        extensions: [basicSetup, keymap.of([indentWithTab]), ...lineEndingExtensions(document.text), language.of([]),
          ...(session.language.toLowerCase() === "json" ? [syntaxHighlighting(jsonHighlightStyle)] : []),
          ...(["yaml", "yml"].includes(session.language.toLowerCase()) ? [syntaxHighlighting(yamlHighlightStyle)] : []),
          EditorView.cspNonce.of(nonce), editing.of([EditorState.readOnly.of(session.readOnly), EditorView.editable.of(!session.readOnly)]),
          EditorView.contentAttributes.of({ "aria-label": "文件编辑器", spellcheck: "false" }), EditorView.updateListener.of(changed)],
      });
      if (view) view.setState(state);
      else view = new EditorView({ state, parent: editorRoot });
      updateJSONPreview();
      statusRoot.textContent = session.readOnly ? "只读" : "已保存";
      renderPreview();
      // 初次加载不发送 change/dirty；异步语言模块只能配置仍处于活动状态的同一会话。
      send({ type: "opened", id: session.id, readOnly: session.readOnly, ...historyState() });
      const requestedLanguage = session.language;
      Promise.resolve().then(() => languageLoader(requestedLanguage)).then((extension) => {
        if (token === generation && matches(document.id)) {
          // 高亮异步到达时也更新保留的源码，保证从美化预览进入编辑后仍有语法高亮。
          if (jsonSourceState) jsonSourceState = jsonSourceState.update({ effects: language.reconfigure(extension) }).state;
          view.dispatch({ effects: language.reconfigure(extension) });
        }
      }).catch(() => {
        if (token === generation && matches(document.id)) send({ type: "error", id: session.id, code: "languageUnavailable", message: "语法高亮不可用，仍可编辑和保存文本。" });
      });
      return true;
    },
    getText(id) { return matches(id) ? originalText(sourceState()) : null; },
    setEditing({ id, enabled }) {
      if (!matches(id)) return false;
      session.readOnly = enabled !== true;
      session.mode = session.readOnly && ["markdown", "md"].includes(session.language.toLowerCase()) ? "preview" : "source";
      updateJSONPreview();
      view.dispatch({ effects: editing.reconfigure([EditorState.readOnly.of(session.readOnly || session.suspended), EditorView.editable.of(!session.readOnly && !session.suspended)]) });
      statusRoot.textContent = session.readOnly ? "只读" : originalText(sourceState()) !== session.savedText ? "未保存" : "已保存";
      renderPreview();
      return true;
    },
    setMode({ id, mode }) {
      if (!matches(id) || !["source", "preview", "split"].includes(mode)) return false;
      session.mode = mode;
      renderPreview();
      return true;
    },
    captureInteraction(id) {
      if (!matches(id)) return false;
      // 原生确认只暂停同一个 EditorView；不重建 state，撤销历史及 DOM 焦点保持可恢复。
      interaction = { selection: view.state.selection.toJSON(), editorTop: view.scrollDOM.scrollTop,
        editorLeft: view.scrollDOM.scrollLeft, previewTop: previewRoot.scrollTop, previewLeft: previewRoot.scrollLeft,
        focused: editorRoot.ownerDocument.activeElement, mode: session.mode };
      return true;
    },
    getInteractionState(id) {
      if (!matches(id)) return null;
      return { selection: view.state.selection.toJSON(), editorTop: view.scrollDOM.scrollTop,
        editorLeft: view.scrollDOM.scrollLeft, previewTop: previewRoot.scrollTop, previewLeft: previewRoot.scrollLeft,
        mode: session.mode, focusedEditor: view.hasFocus, ...historyState() };
    },
    suspend({ id, suspended }) {
      if (!matches(id)) return false;
      session.suspended = suspended === true;
      view.dispatch({ effects: editing.reconfigure([EditorState.readOnly.of(session.readOnly || session.suspended), EditorView.editable.of(!session.readOnly && !session.suspended)]) });
      return true;
    },
    restoreInteraction(id) {
      if (!matches(id) || !interaction) return false;
      session.mode = interaction.mode;
      view.dispatch({ selection: EditorSelection.fromJSON(interaction.selection) });
      renderPreview();
      if (interaction.focused?.isConnected) interaction.focused.focus({ preventScroll: true });
      view.scrollDOM.scrollTop = interaction.editorTop;
      view.scrollDOM.scrollLeft = interaction.editorLeft;
      previewRoot.scrollTop = interaction.previewTop;
      previewRoot.scrollLeft = interaction.previewLeft;
      interaction = null;
      return true;
    },
    consumeEscape(id) {
      // 只让编辑器临时面板优先关闭；不能调用默认 Escape 的 simplifySelection，否则会丢失确认前选区。
      return matches(id) && (closeCompletion(view) || closeSearchPanel(view));
    },
    dispose(id) {
      if (!matches(id)) return false;
      generation++;
      view.destroy(); view = null; session = null; interaction = null; jsonSourceState = null;
      previewRoot.replaceChildren();
      return true;
    },
    undo(id) { return matches(id) && !session.readOnly && !session.suspended ? undo(view) : false; },
    redo(id) { return matches(id) && !session.readOnly && !session.suspended ? redo(view) : false; },
    search(id) { return matches(id) && !session.suspended ? openSearchPanel(view) : false; },
    formatJSON(id) {
      if (!matches(id) || session.readOnly || session.suspended) return false;
      try {
        const formatted = formatJSONLosslessly(view.state.doc.toString());
        const endings = lineEndingsForFormattedText(view.state, formatted);
        assertJSONFormatSize(formatted, endings.endings.reduce((bytes, ending) => bytes + ending.length - 1, 0));
        if (formatted !== view.state.doc.toString()) view.dispatch({
          changes: { from: 0, to: view.state.doc.length, insert: formatted },
          effects: restoreLineEndings.of(endings),
          annotations: Transaction.userEvent.of("input.format"),
        });
        return true;
      } catch (error) {
        send({ type: "error", id: session.id, code: error instanceof JSONFormatLimitError ? "formatLimit" : "invalidJSON", message: String(error.message) });
        return false;
      }
    },
    markSaved({ id, text }) {
      // 保存期间继续输入时不能把较新的修改误标为已保存；宿主须传实际成功写入的完整文本。
      if (!matches(id) || typeof text !== "string") return false;
      session.savedText = text;
      const current = originalText(sourceState());
      const dirty = current !== text;
      statusRoot.textContent = session.readOnly ? "只读" : dirty ? "未保存" : "已保存";
      send({ type: "state", id: session.id, text: current, dirty, ...historyState() });
      return true;
    },
  };
  return { api: Object.freeze(api), get view() { return view; }, destroy() { generation++; view?.destroy(); view = null; session = null; jsonSourceState = null; } };
}
