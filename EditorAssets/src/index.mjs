import { createWorkbench } from "./workbench.mjs";

const controller = createWorkbench({
  editorRoot: document.querySelector("#editor"), previewRoot: document.querySelector("#preview"),
  statusRoot: document.querySelector("#status"), nonce: document.querySelector('meta[name="style-nonce"]').content,
  postMessage: (message) => window.webkit?.messageHandlers?.workbench?.postMessage(message),
});
window.workbench = controller.api;
for (const button of document.querySelectorAll("button[data-command]")) {
  button.addEventListener("click", () => controller.api[button.dataset.command]());
}
for (const button of document.querySelectorAll("button[data-mode]")) {
  button.addEventListener("click", () => controller.api.setMode({ mode: button.dataset.mode }));
}
// 防御性拦截：渲染器本身不创建链接，此处还覆盖未来组件引入的锚点与中键点击。
for (const type of ["click", "auxclick"]) document.addEventListener(type, (event) => {
  if (event.target.closest?.("a")) event.preventDefault();
}, true);
window.addEventListener("dragover", (event) => event.preventDefault());
window.addEventListener("drop", (event) => event.preventDefault());
window.webkit?.messageHandlers?.workbench?.postMessage({ type: "ready" });
