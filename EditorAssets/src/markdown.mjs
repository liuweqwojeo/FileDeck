import MarkdownIt from "markdown-it";

// 仅允许带正确文件头的栅格 data URI；SVG、远程地址、file:// 和相对路径均不自动加载。
export function safeRasterDataURI(source) {
  if (typeof source !== "string" || source.length > 7 * 1024 * 1024) return false;
  const match = /^data:image\/(png|jpeg|gif|webp);base64,([A-Za-z0-9+/]+={0,2})$/i.exec(source);
  if (!match) return false;
  let header;
  try { header = atob(match[2].slice(0, 48)); } catch { return false; }
  const bytes = Array.from(header, (character) => character.charCodeAt(0));
  switch (match[1].toLowerCase()) {
    case "png": return [137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => bytes[index] === byte);
    case "jpeg": return bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
    case "gif": return header.startsWith("GIF87a") || header.startsWith("GIF89a");
    case "webp": return header.startsWith("RIFF") && header.slice(8, 12) === "WEBP";
    default: return false;
  }
}

const markdown = new MarkdownIt({ html: false, linkify: false, typographer: false });
const escape = markdown.utils.escapeHtml;
markdown.renderer.rules.image = (tokens, index) => {
  const token = tokens[index];
  const source = token.attrGet("src") ?? "";
  const alt = token.content || "图片";
  if (!safeRasterDataURI(source)) return `<span class="blocked-image" role="img" aria-label="${escape(alt)}">[${escape(alt)}：已阻止自动加载]</span>`;
  return `<img src="${escape(source)}" alt="${escape(alt)}" loading="lazy" decoding="async">`;
};
// 不输出 href，防止键盘、右键或拖动等路径绕过普通 click 的阻止逻辑。
markdown.renderer.rules.link_open = (tokens, index) => `<span class="md-link" title="${escape(tokens[index].attrGet("href") ?? "")}">`;
markdown.renderer.rules.link_close = () => "</span>";

export function renderMarkdown(text) { return markdown.render(text); }
