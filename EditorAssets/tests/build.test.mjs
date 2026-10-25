// 在隔离副本中修改构建输入和产物，验证 --check 失败且不重写已提交资源。
import test from "node:test";
import assert from "node:assert/strict";
import { cp, mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const original = fileURLToPath(new URL("..", import.meta.url));
test("只读重建比较拒绝旧输入和错误产物，并保留原文件", async () => {
  const root = await mkdtemp(join(tmpdir(), "filedeck-editor-regression-"));
  try {
    const assets = join(root, "EditorAssets");
    await mkdir(assets);
    for (const name of ["src", "build.mjs", "package.json", "package-lock.json"]) {
      await cp(join(original, name), join(assets, name), { recursive: true });
    }
    await symlink(join(original, "node_modules"), join(assets, "node_modules"), "dir");
    const resources = join(root, "Resources/Editors");
    await cp(resolve(original, "../Resources/Editors"), resources, { recursive: true });
    const run = () => spawnSync(process.execPath, [join(assets, "build.mjs"), "--check"], { encoding: "utf8" });
    assert.equal(run().status, 0);
    for (const name of ["src/index.mjs", "package-lock.json", "build.mjs", "package.json"]) {
      const path = join(assets, name), bytes = await readFile(path);
      const manifest = await readFile(join(resources, "manifest.json"));
      await writeFile(path, Buffer.concat([bytes, Buffer.from("\n ")]));
      const result = run();
      assert.notEqual(result.status, 0, name);
      assert.match(result.stderr, /不一致/);
      assert.deepEqual(await readFile(join(resources, "manifest.json")), manifest);
      await writeFile(path, bytes);
    }
    const script = join(resources, "editor.js"), bytes = await readFile(script);
    const altered = Buffer.concat([bytes, Buffer.from("\n// stale output")]);
    await writeFile(script, altered);
    assert.notEqual(run().status, 0);
    assert.deepEqual(await readFile(script), altered);
    await writeFile(script, bytes);
    await rm(join(resources, "editor.css"));
    assert.notEqual(run().status, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
