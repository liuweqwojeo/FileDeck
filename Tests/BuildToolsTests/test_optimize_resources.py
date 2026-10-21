"""验证资源去重保持逐路径内容和包内链接边界，不裁剪语言或功能。"""

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
import optimize_resources as optimizer


class ResourceOptimizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "FileDeck.app"
        self.resources = self.app / optimizer.WEB_RESOURCES
        self.resources.mkdir(parents=True)

    def image(self, relative, data=b"image" * 1024):
        path = self.resources / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_all_original_paths_read_the_same_bytes_after_relocation(self):
        first = self.image("editor/help/en/图像.png")
        duplicate = self.image("another/help/zh/图像.png")
        distinct = self.image("editor/help/en/other.png", b"other" * 1024)
        before = {str(p.relative_to(self.app)): p.read_bytes() for p in (first, duplicate, distinct)}
        report = optimizer.optimize_resources(self.app)
        self.assertEqual(report["linkedFiles"], 1)
        self.assertEqual(report["bytesSaved"], len(first.read_bytes()))
        self.assertTrue(any(p.is_symlink() for p in (first, duplicate)))
        moved = self.root / "中文 移动目录/重命名.app"
        moved.parent.mkdir()
        self.app.rename(moved)
        for relative, expected in before.items():
            self.assertEqual((moved / relative).read_bytes(), expected)
        for path in moved.rglob("*"):
            if path.is_symlink():
                self.assertFalse(os.path.isabs(os.readlink(path)))
                self.assertTrue(path.resolve().is_relative_to(moved.resolve()))
        self.assertEqual(optimizer.optimize_resources(moved)["linkedFiles"], 0)

    def test_same_size_and_mocked_digest_do_not_merge_different_bytes(self):
        first = self.image("a.png", b"a" * 2048)
        second = self.image("b.png", b"b" * 2048)
        with patch.object(optimizer, "sha256", return_value="same"):
            report = optimizer.optimize_resources(self.app)
        self.assertEqual(report["linkedFiles"], 0)
        self.assertFalse(first.is_symlink() or second.is_symlink())

    def test_scripts_templates_dictionaries_small_and_executable_files_remain_independent(self):
        original = self.image("a.png")
        executable = self.image("executable.png")
        executable.chmod(0o755)
        other_mode = self.image("readonly.png")
        other_mode.chmod(0o444)
        script = self.image("script.js")
        tiny1 = self.image("tiny1.png", b"tiny")
        tiny2 = self.image("tiny2.png", b"tiny")
        external_scope = self.app / "Contents/Resources/converter/empty/en-US/new.docx"
        external_scope.parent.mkdir(parents=True)
        external_scope.write_bytes(original.read_bytes())
        report = optimizer.optimize_resources(self.app)
        self.assertEqual(report["linkedFiles"], 0)
        self.assertTrue(all(not p.is_symlink() for p in (original, executable, other_mode, script, tiny1, tiny2, external_scope)))

    def test_directory_links_are_not_followed_and_existing_file_links_are_preserved(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "a.png").write_bytes(b"a" * 2048)
        (outside / "b.png").write_bytes(b"a" * 2048)
        (self.resources / "outside").symlink_to(outside, target_is_directory=True)
        first = self.image("a.png")
        link = self.resources / "existing.png"
        link.symlink_to(first.name)
        optimizer.optimize_resources(self.app)
        self.assertFalse((outside / "b.png").is_symlink())
        self.assertEqual(os.readlink(link), first.name)

    def test_extended_attributes_are_preserved_by_skipping_the_file(self):
        first = self.image("a.png")
        duplicate = self.image("b.png")
        with patch.object(optimizer, "has_extended_attributes", side_effect=lambda p: p.name == duplicate.name):
            self.assertEqual(optimizer.optimize_resources(self.app)["linkedFiles"], 0)
        self.assertFalse(first.is_symlink() or duplicate.is_symlink())

    def test_external_resource_root_is_rejected(self):
        self.resources.rmdir()
        outside = self.root / "outside"
        outside.mkdir()
        self.resources.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            optimizer.optimize_resources(self.app)


if __name__ == "__main__":
    unittest.main()
