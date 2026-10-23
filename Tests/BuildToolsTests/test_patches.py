"""上游补丁必须可重入，并拒绝覆盖不匹配的用户修改。"""

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
from patches import apply_patch


class PatchTests(unittest.TestCase):
    def test_fresh_hunspell_initialization_cannot_delete_compression_fix(self):
        # 模拟上游首次版本检查确实删除旧目录，再让 before.py 生成源码。
        # 直接执行应用补丁后的模块，验证 hook 的调用顺序和重复构建语义。
        source = '''import base
import os

def clean():
  if base.is_dir("hunspell"):
    base.delete_dir_with_access_error("hunspell")

def make(build_js=True):
  old_cur_dir = os.getcwd()
  core_common_dir = base.get_script_dir() + "/../../core/Common"
  os.chdir(core_common_dir + "/3dParty/hunspell")

  base.common_check_version("hunspell", "1", clean)
  base.cmd("python", ["./before.py"])

  if (build_js):
    os.chdir(core_common_dir + "/js")
    base.cmd("python", ["./make.py", core_common_dir + "/3dParty/hunspell/hunspell.json"])

  os.chdir(old_cur_dir)
'''
        patch_file = Path(__file__).resolve().parents[2] / "scripts/onlyoffice/patches/build_tools-007-hunspell-compressed-eof.patch"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "build_tools"
            module = repository / "scripts/core_common/modules/hunspell.py"
            module.parent.mkdir(parents=True)
            module.write_text(source)
            subprocess.run(["git", "init", "-q", str(repository)], check=True)
            self.assertTrue(apply_patch(repository, patch_file))
            self.assertFalse(apply_patch(repository, patch_file))
            dependency = root / "core/Common/3dParty/hunspell"
            checkout = dependency / "hunspell"
            checkout.mkdir(parents=True)
            state = checkout / "state"
            state.write_text("previous checkout")
            events = []
            initialized = False

            def version(name, required, clean):
                nonlocal initialized
                events.append("version")
                self.assertEqual((name, required), ("hunspell", "1"))
                if not initialized:
                    clean()
                    initialized = True

            def clean(path):
                events.append("clean")
                shutil.rmtree(path)

            def command(executable, arguments):
                self.assertEqual(executable, "python")
                if arguments == ["./before.py"]:
                    events.append("before")
                    if not checkout.exists():
                        checkout.mkdir()
                        state.write_text("fresh source")
                else:
                    events.append("patch")
                    self.assertEqual(arguments, ["/project/scripts/onlyoffice/patches.py", "hunspell"])
                    self.assertIn(state.read_text(), ("fresh source", "patched"))
                    state.write_text("patched")

            base = SimpleNamespace(get_script_dir=lambda: str(repository / "scripts"), is_dir=os.path.isdir,
                                   delete_dir_with_access_error=clean, common_check_version=version, cmd=command,
                                   get_env=lambda key: "/project/scripts/onlyoffice/patches.py"
                                   if key == "FW_ONLYOFFICE_HUNSPELL_PATCHER" else "")
            namespace = {"__name__": "test_hunspell_initialization"}
            previous_cwd = Path.cwd()
            try:
                with patch.dict(sys.modules, {"base": base}):
                    exec(compile(module.read_text(), str(module), "exec"), namespace)
                    namespace["make"](False)
                    self.assertEqual(events, ["version", "clean", "before", "patch"])
                    self.assertEqual(state.read_text(), "patched")
                    events.clear()
                    namespace["make"](False)
                    self.assertEqual(events, ["version", "before", "patch"])
                    self.assertEqual(state.read_text(), "patched")
            finally:
                os.chdir(previous_cwd)

    def test_applies_once_and_keeps_unrelated_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            source = root / "sample.txt"
            source.write_text("original\n")
            unrelated = root / "personal.txt"
            unrelated.write_text("keep me\n")
            patch = root / "change.patch"
            patch.write_text("--- a/sample.txt\n+++ b/sample.txt\n@@ -1 +1 @@\n-original\n+patched\n")
            self.assertTrue(apply_patch(root, patch))
            self.assertFalse(apply_patch(root, patch))
            self.assertEqual(source.read_text(), "patched\n")
            self.assertEqual(unrelated.read_text(), "keep me\n")
            source.write_text("user changed this\n")
            with self.assertRaises(RuntimeError):
                apply_patch(root, patch)
            self.assertEqual(source.read_text(), "user changed this\n")


if __name__ == "__main__":
    unittest.main()
