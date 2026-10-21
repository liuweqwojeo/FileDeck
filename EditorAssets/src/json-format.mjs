export const MAX_JSON_FORMAT_BYTES = 10 * 1024 * 1024;
export const MAX_JSON_FORMAT_DEPTH = 256;
const utf8 = new TextEncoder();

export class JSONFormatLimitError extends Error {
  constructor(message) {
    super(message);
    this.name = "JSONFormatLimitError";
    this.code = "formatLimit";
  }
}

function checkByteCount(bytes) {
  if (bytes > MAX_JSON_FORMAT_BYTES) {
    throw new JSONFormatLimitError("JSON 排版结果超过 10 MiB 编辑上限，已保留原文。");
  }
}

// 原始 CRLF 比编辑器内的 LF 多一个字节；宿主提交事务前还要把映射带来的增量算入上限。
export function assertJSONFormatSize(text, extraBytes = 0) {
  checkByteCount(utf8.encode(text).length + extraBytes);
}

// 流式扫描而非 match() 收集全文 token，避免小 token 很多时额外建立数百万项数组。
// 此处仅识别边界；语法仍交给 JSON.parse 校验。
function* tokens(text) {
  let index = 0;
  while (index < text.length) {
    const character = text[index];
    if (/\s/.test(character)) { index++; continue; }
    const start = index++;
    if (character === '"') {
      while (index < text.length) {
        const current = text[index++];
        if (current === "\\") index++;
        else if (current === '"') break;
      }
    } else if (!"{}[],:".includes(character)) {
      while (index < text.length && !/\s/.test(text[index]) && !"{}[],:".includes(text[index])) index++;
    }
    yield text.slice(start, index);
  }
}

// JSON.parse 仅用于语法校验；输出由原始词法 token 生成，绝不序列化 JS Number。
// 深度在解析和分配缩进前限制，输出每次追加前按 UTF-8 字节计费，不允许短输入膨胀为巨量文本。
export function formatJSONLosslessly(text) {
  assertJSONFormatSize(text);
  let depth = 0;
  for (const token of tokens(text)) {
    if (token === "{" || token === "[") {
      if (++depth > MAX_JSON_FORMAT_DEPTH) {
        throw new JSONFormatLimitError(`JSON 嵌套超过 ${MAX_JSON_FORMAT_DEPTH} 层，无法安全排版，已保留原文。`);
      }
    } else if (token === "}" || token === "]") depth--;
  }
  JSON.parse(text);
  const iterator = tokens(text);
  let token = iterator.next().value;
  let next = iterator.next().value;
  let previous;
  let level = 0;
  let output = "";
  let outputBytes = 0;
  const append = (value, bytes = value.length) => {
    checkByteCount(outputBytes + bytes);
    output += value;
    outputBytes += bytes;
  };
  const newline = () => append(`\n${"  ".repeat(level)}`);
  while (token !== undefined) {
    if (token === "{" || token === "[") {
      append(token);
      level++;
      if (next !== (token === "{" ? "}" : "]")) newline();
    } else if (token === "}" || token === "]") {
      level--;
      if (previous !== (token === "}" ? "{" : "[")) newline();
      append(token);
    } else if (token === ",") {
      append(token);
      newline();
    } else if (token === ":") {
      append(": ");
    } else {
      append(token, token[0] === '"' ? utf8.encode(token).length : token.length);
    }
    previous = token;
    token = next;
    next = iterator.next().value;
  }
  return output;
}
