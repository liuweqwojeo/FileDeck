import { basicSetup } from "codemirror";
import { Compartment, EditorSelection, EditorState, Text, Transaction } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { history, indentWithTab, redo, redoDepth, selectAll, undo, undoDepth } from "@codemirror/commands";
import { closeCompletion } from "@codemirror/autocomplete";
import { openSearchPanel, closeSearchPanel } from "@codemirror/search";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { lineEndingExtensions, lineEndingField, originalText, splitLineEndings, restoreLineEndings, lineEndingsForFormattedText } from "./line-endings.mjs";
import { createTextEditEncoder } from "./text-bridge.mjs";
import { formatJSONLosslessly, assertJSONFormatSize, JSONFormatLimitError } from "./json-format.mjs";
import { renderMarkdown } from "./markdown.mjs";
import { loadLanguage } from "./languages.mjs";

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
export function createWorkbench({ editorRoot, previewRoot, statusRoot, nonce, postMessage, languageLoader = loadLanguage }) {
  let view = null;
  let session = null;
  let jsonSourceState = null;
  let previewDocument = null;
  let previewFrame = null;
  const frameWindow = editorRoot.ownerDocument.defaultView;
  let encodeEdits = createTextEditEncoder();
  let generation = 0;
  const language = new Compartment();
  const editing = new Compartment();
  let interaction = null;
  // WebKit 的 document.execCommand('undo') 可能跨 input 与 contenteditable 撤销。
  // 查找/替换字段复用 CodeMirror 历史，但各自持有独立 state，不接触正文历史或草稿。
  const inputHistories = new WeakMap();
  const searchInput = (node) => node?.matches?.('.cm-search input[name="search"],.cm-search input[name="replace"]');
  const captureInputStart = ({ target }) => {
    if (searchInput(target) && inputHistories.get(target)?.state.doc.toString() !== target.value) {
      // 再次查找会按正文选区更新 query，程序性赋值不触发 input，下一次输入须使用新基线。
      inputHistories.set(target, { state: EditorState.create({ doc: target.value, extensions: [history()] }) });
    }
  };
  const captureInputChange = (event) => {
    const { target } = event;
    const record = inputHistories.get(target);
    if (!record) { captureInputStart(event); return; }
    if (record && record.state.doc.toString() !== target.value) {
      record.state = record.state.update({ changes: { from: 0, to: record.state.doc.length, insert: target.value },
        selection: EditorSelection.range(target.selectionStart ?? 0, target.selectionEnd ?? 0),
        annotations: Transaction.userEvent.of("input.type") }).state;
    }
  };
  editorRoot.addEventListener("focusin", captureInputStart);
  editorRoot.addEventListener("beforeinput", captureInputStart);
  editorRoot.addEventListener("input", captureInputChange);
  const matches = (id) => session !== null && (id === undefined || id === session.id);
  const send = (message) => { try { postMessage?.(message); } catch { /* 原生桥接离线时仍保留当前编辑内容。 */ } };
  const sourceState = () => jsonSourceState ?? view.state;
  const historyState = () => ({ canUndo: undoDepth(sourceState()) > 0, canRedo: redoDepth(sourceState()) > 0 });
  const isDirty = () => {
    const state = sourceState(), endings = state.field(lineEndingField).endings;
    return !state.doc.eq(session.savedDocument) || endings.length !== session.savedEndings.length
      || endings.some((ending, index) => ending !== session.savedEndings[index]);
  };
  const cancelPreview = () => {
    if (previewFrame !== null) frameWindow.cancelAnimationFrame(previewFrame);
    previewFrame = null;
  };
  const paintPreview = () => {
    cancelPreview();
    if (!session || !["markdown", "md"].includes(session.language.toLowerCase())
        || session.mode === "source" || previewDocument === view.state.doc) return;
    previewRoot.innerHTML = renderMarkdown(view.state.doc.toString());
    previewDocument = view.state.doc;
  };
  const queuePreview = () => {
    if (!["markdown", "md"].includes(session.language.toLowerCase()) || session.mode === "source") return;
    if (previewDocument === view.state.doc) { cancelPreview(); return; }
    if (previewFrame !== null) return;
    const token = generation;
    previewFrame = frameWindow.requestAnimationFrame(() => {
      if (token === generation) paintPreview();
    });
  };
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
    for (const button of editorRoot.ownerDocument.querySelectorAll('[data-command="formatJSON"]')) {
      button.hidden = session.readOnly || session.language.toLowerCase() !== "json";
    }
    for (const button of editorRoot.ownerDocument.querySelectorAll("[data-mode]")) {
      button.hidden = !markdown || session.readOnly;
      button.setAttribute("aria-pressed", String(button.dataset.mode === mode));
    }
    // 显式切换模式立即呈现最新正文；连续输入的转换则由帧任务合并。
    paintPreview();
  };
  const changed = (update) => {
    if (!update.docChanged || !session) return;
    const dirty = isDirty();
    statusRoot.textContent = session.readOnly ? "只读" : dirty ? "未保存" : "已保存";
    queuePreview();
    const baseVersion = session.version++;
    const edits = session.bridgeMode === "patch-v1" ? encodeEdits(update) : null;
    // 草稿差量仍在同一编辑事务里即时发送，预览调度不会延迟故障恢复所需的正文。
    if (edits) send({ type: "patch", id: session.id, baseVersion, version: session.version, edits, ...historyState() });
    else send({ type: "change", id: session.id, text: originalText(update.state), dirty,
      ...(session.bridgeMode === "patch-v1" ? { version: session.version } : {}), ...historyState() });
  };

  const api = {
    open(document) {
      if (!document || typeof document.id !== "string" || !document.id || typeof document.text !== "string") {
        throw new TypeError("open 需要非空会话 id 和完整文本。");
      }
      const token = ++generation;
      cancelPreview();
      encodeEdits = createTextEditEncoder();
      jsonSourceState = null;
      previewDocument = null;
      if (previewRoot.firstChild) previewRoot.replaceChildren();
      session = { id: document.id, language: typeof document.language === "string" ? document.language : "text", readOnly: document.readOnly === true,
        bridgeMode: document.bridgeMode === "patch-v1" ? "patch-v1" : "full", version: 0,
        mode: ["source", "preview", "split"].includes(document.mode) ? document.mode : "source", suspended: false };
      interaction = null;
      const state = EditorState.create({
        doc: splitLineEndings(document.text).normalized,
        extensions: [basicSetup, keymap.of([indentWithTab]), EditorState.phrases.of({
          "Find": "查找", "Replace": "替换", "next": "下一个", "previous": "上一个", "all": "全选匹配",
          "match case": "区分大小写", "regexp": "正则", "by word": "全词", "replace": "替换", "replace all": "全部替换",
          "close": "关闭", "No matches": "没有匹配结果", "Search": "查找",
        }), ...lineEndingExtensions(document.text), language.of([]),
          ...(session.language.toLowerCase() === "json" ? [syntaxHighlighting(jsonHighlightStyle)] : []),
          ...(["yaml", "yml"].includes(session.language.toLowerCase()) ? [syntaxHighlighting(yamlHighlightStyle)] : []),
          EditorView.cspNonce.of(nonce), editing.of([EditorState.readOnly.of(session.readOnly), EditorView.editable.of(!session.readOnly)]),
          // contenteditable=false 在 WebKit 中不能直接聚焦；只读预览仍需接收全选、复制等键盘命令。
          EditorView.contentAttributes.of({ "aria-label": "文件编辑器", "aria-description": "Tab 缩进，Shift+Tab 减少缩进，Ctrl+Tab 切换焦点", spellcheck: "false", tabindex: "0" }), EditorView.updateListener.of(changed)],
      });
      if (view) view.setState(state);
      else view = new EditorView({ state, parent: editorRoot });
      session.savedDocument = state.doc;
      session.savedEndings = state.field(lineEndingField).endings;
      updateJSONPreview();
      statusRoot.textContent = session.readOnly ? "只读" : "已保存";
      renderPreview();
      // 初次加载不发送 change/dirty；异步语言模块只能配置仍处于活动状态的同一会话。
      send({ type: "opened", id: session.id, readOnly: session.readOnly,
        ...(session.bridgeMode === "patch-v1" ? { bridgeMode: "patch-v1", version: 0 } : {}), ...historyState() });
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
    getSnapshot(id) { return matches(id) ? { version: session.version, text: originalText(sourceState()), ...historyState() } : null; },
    setEditing({ id, enabled }) {
      if (!matches(id)) return false;
      session.readOnly = enabled !== true;
      session.mode = session.readOnly && ["markdown", "md"].includes(session.language.toLowerCase()) ? "preview" : "source";
      updateJSONPreview();
      view.dispatch({ effects: editing.reconfigure([EditorState.readOnly.of(session.readOnly || session.suspended), EditorView.editable.of(!session.readOnly && !session.suspended)]) });
      statusRoot.textContent = session.readOnly ? "只读" : isDirty() ? "未保存" : "已保存";
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
      paintPreview();
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
      if (session.suspended) paintPreview();
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
      cancelPreview();
      view.destroy(); view = null; session = null; interaction = null; jsonSourceState = null; previewDocument = null;
      encodeEdits = null;
      previewRoot.replaceChildren();
      return true;
    },
    undo(id) { return matches(id) && !session.readOnly && !session.suspended ? undo(view) : false; },
    redo(id) { return matches(id) && !session.readOnly && !session.suspended ? redo(view) : false; },
    search(id) { return matches(id) && !session.suspended ? openSearchPanel(view) : false; },
    selectAll(id) {
      if (!matches(id) || session.suspended || session.mode === "preview") return false;
      view.focus();
      return selectAll(view);
    },
    handleHistoryKey({ id, redo: forward = false } = {}) {
      if (!matches(id) || session.suspended) return false;
      const focused = editorRoot.ownerDocument.activeElement;
      if (focused?.matches('input:not([type="checkbox"]),textarea')) {
        const record = inputHistories.get(focused);
        if (record) {
          const target = { state: record.state, dispatch: (transaction) => { record.state = transaction.state; } };
          if ((forward ? redo : undo)(target)) {
            focused.value = record.state.doc.toString();
            focused.setSelectionRange(record.state.selection.main.from, record.state.selection.main.to);
            focused.dispatchEvent(new frameWindow.Event("change", { bubbles: true }));
          }
        }
        // 无历史时也消费命令，不能退回到正文历史。
        return true;
      }
      return forward ? api.redo(id) : api.undo(id);
    },
    indentSelection({ id, backward = false } = {}) {
      if (!matches(id) || session.readOnly || session.suspended || editorRoot.ownerDocument.activeElement !== view.contentDOM) return false;
      return backward ? indentWithTab.shift(view) : indentWithTab.run(view);
    },
    revealLine({ id, line } = {}) {
      if (!matches(id) || !Number.isSafeInteger(line) || line < 1) return false;
      // 搜索行号来自原始文件；JSON 自动排版和 Markdown 阅读视图不能改变定位坐标。
      if (jsonSourceState) { view.setState(jsonSourceState); jsonSourceState = null; }
      session.mode = "source";
      renderPreview();
      const target = view.state.doc.line(Math.min(line, view.state.doc.lines));
      view.dispatch({ selection: { anchor: target.from, head: target.to },
        effects: EditorView.scrollIntoView(target.from, { y: "center" }), annotations: Transaction.addToHistory.of(false) });
      view.focus();
      return true;
    },
    formatJSON(id) {
      if (!matches(id) || session.readOnly || session.suspended || session.language.toLowerCase() !== "json") return false;
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
      const current = originalText(sourceState());
      const saved = splitLineEndings(text);
      session.savedDocument = current === text ? sourceState().doc : Text.of(saved.normalized.split("\n"));
      session.savedEndings = saved.endings;
      const dirty = isDirty();
      statusRoot.textContent = session.readOnly ? "只读" : dirty ? "未保存" : "已保存";
      send({ type: "state", id: session.id, text: current, dirty,
        ...(session.bridgeMode === "patch-v1" ? { version: session.version } : {}), ...historyState() });
      return true;
    },
  };
  return { api: Object.freeze(api), get view() { return view; }, destroy() {
    editorRoot.removeEventListener("focusin", captureInputStart);
    editorRoot.removeEventListener("beforeinput", captureInputStart);
    editorRoot.removeEventListener("input", captureInputChange);
    generation++; cancelPreview(); view?.destroy(); view = null; session = null; interaction = null; jsonSourceState = null; previewDocument = null; encodeEdits = null;
  } };
}
