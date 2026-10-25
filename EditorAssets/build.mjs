import { build } from "esbuild";
import { createHash } from "node:crypto";
import { lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const check = process.argv.slice(2).includes("--check");
if (process.argv.slice(2).some((arg) => arg !== "--check")) throw new Error("仅支持 --check 参数。");
const committed = resolve(root, "../Resources/Editors");
// 校验模式在临时目录重建，不能以重新生成 manifest 掩盖已提交资源过期。
const temporary = check ? await mkdtemp(join(tmpdir(), "filedeck-editors-")) : null;
const output = temporary ?? committed;
try {
  async function sourceInputs() {
    const inputs = {};
    async function addInput(name) {
      const path = join(root, name);
      const info = await lstat(path);
      if (info.isSymbolicLink()) throw new Error(`编辑输入不能为符号链接：${name}`);
      if (info.isDirectory()) {
        for (const child of (await readdir(path)).sort()) await addInput(`${name}/${child}`);
      } else if (info.isFile()) {
        inputs[`EditorAssets/${name}`] = createHash("sha256").update(await readFile(path)).digest("hex");
      } else throw new Error(`编辑输入不是普通文件：${name}`);
    }
    for (const name of ["build.mjs", "package.json", "package-lock.json", "src"]) await addInput(name);
    return inputs;
  }
  const inputs = await sourceInputs();
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
  if (JSON.stringify(await sourceInputs()) !== JSON.stringify(inputs)) throw new Error("构建期间输入发生变化，请重新构建编辑资源。");
  await writeFile(join(output, "manifest.json"), `${JSON.stringify({ schema: 2, target: "Safari 17 / macOS 14", dependenciesLockSHA256: createHash("sha256").update(lockText).digest("hex"), inputs, files: hashes }, null, 2)}\n`);
  if (check) {
    const names = [...Object.keys(hashes), "manifest.json"].sort();
    if (JSON.stringify((await readdir(committed)).sort()) !== JSON.stringify(names)) throw new Error("编辑资源清单已过期，请执行 npm run build。");
    for (const name of names) {
      if (!(await readFile(join(committed, name))).equals(await readFile(join(output, name)))) throw new Error(`编辑资源与重建结果不一致：${name}；请执行 npm run build。`);
    }
  }
  console.log(check ? "离线编辑器与已提交资源一致。" : `离线编辑器已生成：${output}`);
} finally {
  if (temporary) await rm(temporary, { recursive: true, force: true });
}
