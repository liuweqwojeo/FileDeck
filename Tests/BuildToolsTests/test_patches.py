"""上游补丁必须可重入，并拒绝覆盖不匹配的用户修改。"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
from patches import apply_patch


class PatchTests(unittest.TestCase):
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
