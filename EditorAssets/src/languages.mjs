// 原生宿主传入文件名，兼容旧调用传入语言名或后缀；大部分映射复用 CodeMirror 的语言数据库。
import { LanguageDescription, LanguageSupport, StreamLanguage } from "@codemirror/language";
import { languages } from "@codemirror/language-data";

const descriptions = [...languages,
  LanguageDescription.of({
    name: "Svelte", extensions: ["svelte"],
    load: () => import("@replit/codemirror-lang-svelte").then(({ svelte }) => svelte()),
  }),
  LanguageDescription.of({
    name: "Julia", extensions: ["jl"],
    load: () => import("@codemirror/legacy-modes/mode/julia").then(({ julia }) => new LanguageSupport(StreamLanguage.define(julia))),
  }),
];

// .m 在上游同时属于 Mathematica、Objective-C 和 Octave；本工作台的源代码入口默认使用 Objective-C。
// 其余项目补充数据库尚未收录的常见变体，不复制已有的 Rust/Kotlin/C++ 等后缀表。
const extensionAliases = {
  m: "objective-c", hrl: "erlang", sbt: "scala", pyi: "python", fsx: "f#", fsi: "f#",
  zsh: "shell", env: "properties", conf: "properties", config: "properties", editorconfig: "properties",
  mdown: "markdown",
};

export function languageDescription(input) {
  const value = typeof input === "string" ? input.trim() : "";
  if (!value || ["text", "txt", "plaintext"].includes(value.toLowerCase())) return null;
  const filename = value.split(/[\\/]/).at(-1);
  const extension = filename.split(".").at(-1).toLowerCase();
  const alias = /^\.env(?:\.|$)/i.test(filename) ? "properties"
    : /^Podfile$/i.test(filename) ? "ruby" : extensionAliases[extension];
  // 先匹配文件名规则（如 nginx.conf、Dockerfile），再应用通用后缀兜底。
  const named = LanguageDescription.matchLanguageName(descriptions, value, false);
  const byFilename = LanguageDescription.matchFilename(descriptions, filename);
  if (alias && !(byFilename?.filename?.test(filename))) {
    return LanguageDescription.matchLanguageName(descriptions, alias, false);
  }
  return named ?? byFilename
    ?? LanguageDescription.matchFilename(descriptions, `file.${extension}`);
}

export async function loadLanguage(input) {
  const description = languageDescription(input);
  return description ? description.load() : [];
}
