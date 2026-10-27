import test from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { defaultHighlightStyle, syntaxTree } from "@codemirror/language";
import { highlightTree } from "@lezer/highlight";
import { languageDescription, loadLanguage } from "../src/languages.mjs";

test("常见语言按后缀、完整文件名和大小写匹配准确语法", () => {
  const cases = {
    C: ["c", "h"], "C++": ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++"],
    "C#": ["cs"], Go: ["go"], Rust: ["rs"], Kotlin: ["kt", "kts"],
    "Objective-C": ["m"], "Objective-C++": ["mm"], Java: ["java"], Swift: ["swift"],
    JavaScript: ["js", "mjs", "cjs"], TypeScript: ["ts", "mts", "cts"], JSX: ["jsx"], TSX: ["tsx"],
    Vue: ["vue"], Svelte: ["svelte"], HTML: ["html", "htm"], CSS: ["css"], SCSS: ["scss"], LESS: ["less"], Sass: ["sass"],
    Python: ["py", "pyw", "pyi"], PHP: ["php", "phtml"], Ruby: ["rb"], Dart: ["dart"], Lua: ["lua"], R: ["r"],
    Perl: ["pl", "pm"], Scala: ["scala", "sbt"], Groovy: ["groovy", "gradle"], Julia: ["jl"],
    PowerShell: ["ps1", "psm1", "psd1"], "F#": ["fs", "fsx", "fsi"], "VB.NET": ["vb"],
    Clojure: ["clj", "cljc"], ClojureScript: ["cljs"], Erlang: ["erl", "hrl"],
    Shell: ["sh", "bash", "zsh"], SQL: ["sql"], JSON: ["json"], YAML: ["yaml", "yml"],
    Markdown: ["md", "markdown", "mdown"], TOML: ["toml"], "Properties files": ["ini", "properties", "conf", "config", "env", "editorconfig"],
    XML: ["xml", "xsd"], ProtoBuf: ["proto"],
  };
  for (const [expected, extensions] of Object.entries(cases)) {
    for (const ext of extensions) {
      for (const input of [ext, ext.toUpperCase(), `sample.${ext}`, `sample.${ext.toUpperCase()}`]) {
        assert.equal(languageDescription(input)?.name, expected, input);
      }
    }
  }
  for (const [filename, expected] of [["Dockerfile", "Dockerfile"], ["Jenkinsfile", "Groovy"],
    ["Gemfile", "Ruby"], ["Rakefile", "Ruby"], ["Podfile", "Ruby"], [".env.local", "Properties files"],
    ["nginx.conf", "Nginx"], ["CMakeLists.txt", "CMake"]]) {
    assert.equal(languageDescription(filename)?.name, expected, filename);
  }
  for (const input of ["", "text", "TXT", "plaintext", "unknown-language", "example.unknown", "my-rust-notes.txt"]) {
    assert.equal(languageDescription(input), null, input);
  }
});

test("新增语法模块可离线解析并产生高亮，不改动原文", async () => {
  const cases = [
    ["rs", 'fn main() { println!("中文"); }'], ["kt", 'fun main() { println("中文") }'],
    ["kts", 'val greeting = "中文"'], ["h", "#define VALUE 42"], ["hpp", "class Example {};"],
    ["m", '@interface Example\n@end'], ["mm", '@interface Example\n@end'],
    ["mjs", 'export const message = "中文";'], ["mts", 'export const value: number = 42;'],
    ["jsx", 'const view = <div title="中文" />;'], ["tsx", 'const view = <div title="中文" />;'],
    ["svelte", '<script>let name = "中文";</script>\n<h1>{name}</h1>'],
    ["vue", '<template><h1 title="中文">Hello</h1></template>'], ["scss", '$color: red; h1 { color: $color; }'],
    ["less", '@color: red; h1 { color: @color; }'], ["sass", '$color: red\nh1\n  color: $color'],
    ["go", 'package main\nfunc main() {}'], ["cs", 'public class Example {}'],
    ["php", '<?php echo "中文";'], ["rb", 'puts "中文"'], ["dart", 'void main() { print("中文"); }'],
    ["lua", 'local message = "中文"'], ["r", 'message <- "中文"'], ["pl", 'my $message = "中文";'],
    ["scala", 'val message = "中文"'], ["groovy", 'def message = "中文"'],
    ["jl", 'function greet()\n  return "中文"\nend'], ["ps1", '$message = "中文"'],
    ["fs", 'let message = "中文"'], ["vb", 'Dim message As String = "中文"'],
    ["clj", '(def message "中文")'], ["erl", '-module(example).'],
  ];
  for (const [extension, source] of cases) {
    const support = await loadLanguage(`sample.${extension}`);
    const state = EditorState.create({ doc: source, extensions: [support] });
    const tokens = [];
    highlightTree(syntaxTree(state), defaultHighlightStyle, (from, to, style) => tokens.push({ from, to, style }));
    assert.ok(tokens.length > 0, `${extension} 应实际产生高亮 token`);
    assert.equal(state.doc.toString(), source, extension);
  }
  assert.deepEqual(await loadLanguage("unknown-language"), []);
});
