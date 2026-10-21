"""验证插件入口只取固定仓库，并保留旧插件拼接格式；所有写入限于临时目录。"""

import ast
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "scripts/onlyoffice/patches/build_tools-005-local-plugin-entries.patch"
COMMIT = "cf4cac0846d03e2e00a6fec5d1ecd4e9463086d5"
NAMES = ("plugins.js", "plugins-ui.js", "plugins.css")


class LocalPluginEntryTests(unittest.TestCase):
    def setUp(self):
        upstream = ROOT / "vendor/onlyoffice/build_tools"
        if not (upstream / ".git").exists():
            self.skipTest("先获取固定的 build_tools 源码；测试不自动联网。")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.project = self.directory / "build_tools"
        self.script = self.project / "scripts/base.py"
        self.script.parent.mkdir(parents=True)
        for name in ["scripts/base.py", "scripts/deploy_desktop.py"]:
            content = subprocess.check_output(["git", "-C", str(upstream), "show", COMMIT + ":" + name], text=True)
            (self.project / name).write_text(content)
        subprocess.run(["git", "-C", str(self.project), "apply", "--check", str(PATCH)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.project), "apply", str(PATCH)], check=True, capture_output=True)
        self.base = types.ModuleType("base")
        self.base.__file__ = str(self.script)
        with patch.dict(sys.modules, {"config": types.ModuleType("config")}):
            exec(compile(self.script.read_text(), str(self.script), "exec"), self.base.__dict__)
        self.source = self.directory / "onlyoffice.github.io/sdkjs-plugins/v1"
        self.source.mkdir(parents=True)
        self.contents = {name: ("// 固定版本 " + name + "\n").encode() for name in NAMES}
        for name, content in self.contents.items():
            (self.source / name).write_bytes(content)
        self.output = self.directory / "输出 插件"

    def test_desktop_entry_wiring_uses_local_files_and_legacy_format_stays_exact(self):
        tree = ast.parse((self.project / "scripts/deploy_desktop.py").read_text())
        expressions = [node for node in ast.walk(tree) if isinstance(node, ast.Expr)
                       and isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute)
                       and node.value.func.attr in ("copy_pinned_plugin_entries", "support_old_versions_plugins")]
        self.assertEqual(len(expressions), 2)
        # 执行实际部署文件中的两个入口调用，接真实 base 函数；网络调用必须完全消失。
        with patch.object(self.base, "download", side_effect=AssertionError("禁止动态下载")):
            for expression in sorted(expressions, key=lambda node: node.lineno):
                exec(compile(ast.Module(body=[expression], type_ignores=[]), "deployment entry", "exec"),
                     {"base": self.base, "root_dir": str(self.output)})
        plugins = self.output / "editors/sdkjs-plugins"
        for name, content in self.contents.items():
            self.assertEqual((plugins / "v1" / name).read_bytes(), content)
        expected = self.contents["plugins.js"] + b"\n\n" + self.contents["plugins-ui.js"]
        self.assertEqual((plugins / "pluginBase.js").read_bytes(), expected)
        self.assertEqual((plugins / "plugins.css").read_bytes(), self.contents["plugins.css"])
        self.assertFalse((plugins / "plugins.js").exists())
        self.assertFalse((plugins / "plugins-ui.js").exists())

    def test_missing_source_fails_before_overwriting_any_output(self):
        self.output.mkdir()
        (self.output / "plugins.js").write_text("keep previous")
        (self.source / "plugins.css").unlink()
        with self.assertRaisesRegex(RuntimeError, "固定的插件入口文件缺失.*plugins.css"):
            self.base.copy_pinned_plugin_entries(str(self.output))
        self.assertEqual((self.output / "plugins.js").read_text(), "keep previous")
        self.assertEqual(len(list(self.output.iterdir())), 1)

    def test_copy_failure_propagates_instead_of_reporting_success(self):
        with patch.object(self.base.shutil, "copy2", side_effect=PermissionError("read-only destination")):
            with self.assertRaises(PermissionError):
                self.base.copy_pinned_plugin_entries(str(self.output))

    def test_repeat_copy_is_stable_and_legacy_cache_is_preserved(self):
        self.base.copy_pinned_plugin_entries(str(self.output))
        self.base.copy_pinned_plugin_entries(str(self.output))
        self.base.support_old_versions_plugins(str(self.output))
        before = (self.output / "pluginBase.js").read_bytes()
        with patch.object(self.base, "copy_pinned_plugin_entries", side_effect=AssertionError("已有兼容入口无需重复拼接")):
            self.base.support_old_versions_plugins(str(self.output))
        self.assertEqual((self.output / "pluginBase.js").read_bytes(), before)

    def test_patch_reverse_check_proves_it_is_reentrant(self):
        subprocess.run(["git", "-C", str(self.project), "apply", "--reverse", "--check", str(PATCH)],
                       check=True, capture_output=True)


class HyphenPinTests(unittest.TestCase):
    def test_nested_locked_fetch_prevents_upstream_default_branch_clone(self):
        upstream = ROOT / "vendor/onlyoffice/build_tools"
        if not (upstream / ".git").exists():
            self.skipTest("先获取固定的 build_tools 源码；测试不自动联网。")
        sys.path.insert(0, str(ROOT / "scripts/onlyoffice"))
        self.addCleanup(sys.path.remove, str(ROOT / "scripts/onlyoffice"))
        import common
        import fetch
        entry = next(item for item in common.lock()["repositories"] if item["path"] == "core/Common/3dParty/hyphen/hyphen")
        original = subprocess.check_output(["git", "-C", str(upstream), "show",
                                            COMMIT + ":scripts/core_common/modules/hyphen.py"], text=True)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            local = root / "local-origin"
            source.mkdir()
            local.mkdir()
            subprocess.run(["git", "init", "-q", str(local)], check=True)
            (local / "hyphen.c").write_text("fixture source")
            subprocess.run(["git", "-C", str(local), "add", "hyphen.c"], check=True)
            subprocess.run(["git", "-C", str(local), "-c", "user.name=Build Test", "-c", "user.email=build-test@example.invalid",
                            "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"], check=True)
            commit = subprocess.check_output(["git", "-C", str(local), "rev-parse", "HEAD"], text=True).strip()
            fixture = dict(entry, url=local.as_uri(), commit=commit)
            runner = types.SimpleNamespace(run=lambda arguments: subprocess.run(arguments, check=True, capture_output=True))
            fetch.fetch_repository(fixture, runner, source)
            fetch.fetch_repository(fixture, runner, source)
            with patch.object(common, "SOURCE", source), patch.object(common, "lock", return_value={"repositories": [fixture]}):
                common.require_sources()
                with patch.object(common, "lock", return_value={"repositories": [dict(fixture, commit="0" * 40)]}):
                    with self.assertRaisesRegex(RuntimeError, "提交不匹配"):
                        common.require_sources()
            script_directory = source / "build_tools/scripts"
            script_directory.mkdir(parents=True)
            base = types.ModuleType("base")
            base.get_script_dir = lambda: str(script_directory)
            base.is_dir = os.path.isdir
            base.cmd = lambda *_: self.fail("固定的嵌套源码已存在，上游不能再次 clone 默认分支")
            module = types.ModuleType("hyphen")
            previous = Path.cwd()
            previous_path = list(sys.path)
            try:
                with patch.dict(sys.modules, {"config": types.ModuleType("config"), "base": base}):
                    exec(compile(original, "upstream hyphen.py", "exec"), module.__dict__)
                    module.make()
            finally:
                os.chdir(previous)
                sys.path[:] = previous_path


if __name__ == "__main__":
    unittest.main()
