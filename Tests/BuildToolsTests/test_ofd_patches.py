"""用锁定的真实内核源文件验证 OFD 兼容补丁可应用、可重复检查并能还原。"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/onlyoffice"))
from patches import apply_patch


class OFDPatchTests(unittest.TestCase):
    def test_core_patches_apply_reentrantly_and_reverse_without_other_changes(self):
        upstream = ROOT / "vendor/onlyoffice/core"
        if not (upstream / ".git").exists():
            self.skipTest("先获取固定的内核源码；本测试不启动完整内核构建。")
        patches = sorted((ROOT / "scripts/onlyoffice/patches").glob("core-*.patch"))
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            originals = {}
            for patch in patches:
                for line in patch.read_text().splitlines():
                    if not line.startswith("--- a/"):
                        continue
                    name = line[len("--- a/"):]
                    data = subprocess.check_output(["git", "-C", str(upstream), "show", "HEAD:" + name])
                    target = directory / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    originals[name] = data
            for patch in patches:
                self.assertTrue(apply_patch(directory, patch))
                self.assertFalse(apply_patch(directory, patch))
            for patch in reversed(patches):
                subprocess.run(["git", "-C", str(directory), "apply", "--reverse", str(patch)],
                               check=True, capture_output=True)
            for name, data in originals.items():
                self.assertEqual((directory / name).read_bytes(), data)
