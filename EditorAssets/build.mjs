import { build } from "esbuild";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const output = resolve(root, "../Resources/Editors");
await mkdir(output, { recursive: true });
const lockText = await readFile(join(root, "package-lock.json"), "utf8");
// CodeMirror 通过本地 bundle 动态创建样式节点；只给这些节点 nonce，不开放 unsafe-inline。
const nonce = createHash("sha256").update(lockText).digest("base64").slice(0, 24);
const result = await build({
  absWorkingDir: root, entryPoints: ["src/index.mjs"], outfile: join(output, "editor.js"),
  bundle: true, format: "iife", platform: "browser", target: "safari17", minify: true,
  legalComments: "external", sourcemap: false, metafile: true,
});
if (Object.values(result.metafile.outputs).some((entry) => entry.imports.length)) {
  throw new Error("构建产物仍存在外部导入，不能作为离线资源交付。");
}
await writeFile(join(output, "index.html"), (await readFile(join(root, "src/index.html"), "utf8")).replaceAll("__STYLE_NONCE__", nonce));
await writeFile(join(output, "editor.css"), await readFile(join(root, "src/editor.css")));

// 随运行资源交付完整第三方许可；锁文件固定每个间接依赖的版本和下载摘要。
const lock = JSON.parse(lockText);
const notices = ["File Workbench 离线编辑器第三方声明\n构建时固定版本；运行时无需 npm、Node.js 或网络。\n"];
for (const [path, entry] of Object.entries(lock.packages).sort(([a], [b]) => a.localeCompare(b))) {
  if (!path || entry.dev || entry.optional) continue;
  const packageRoot = join(root, path);
  const info = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  const names = (await readdir(packageRoot)).filter((name) => /^(licen[cs]e|copying|notice)([-._].*)?$/i.test(name)).sort();
  if (!names.length) throw new Error(`缺少 ${info.name} 的许可文件，不能打包分发。`);
  notices.push(`\n${"=".repeat(72)}\n${info.name} ${info.version} — ${info.license ?? entry.license ?? "见下文"}\n`);
  for (const name of names) notices.push(`\n${name}\n${await readFile(join(packageRoot, name), "utf8")}\n`);
}
await writeFile(join(output, "THIRD-PARTY-NOTICES.txt"), notices.join(""));
const hashes = {};
for (const name of ["editor.js", "editor.js.LEGAL.txt", "editor.css", "index.html", "THIRD-PARTY-NOTICES.txt"]) {
  hashes[name] = createHash("sha256").update(await readFile(join(output, name))).digest("hex");
}
await writeFile(join(output, "manifest.json"), `${JSON.stringify({ schema: 1, target: "Safari 17 / macOS 14", dependenciesLockSHA256: createHash("sha256").update(lockText).digest("hex"), files: hashes }, null, 2)}\n`);
console.log(`离线编辑器已生成：${output}`);
