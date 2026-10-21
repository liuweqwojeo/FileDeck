"""用临时本地 Git 仓库验证下载恢复和文件保护，不访问网络或业务文件。"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
from fetch import fetch_repository


def git(*arguments):
    return subprocess.check_output(["git", *map(str, arguments)], stderr=subprocess.STDOUT,
                                   text=True).strip()


class LocalCommands:
    def run(self, arguments, **kwargs):
        subprocess.run(arguments, check=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, **kwargs)


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.upstream = self.root / "upstream"
        git("init", self.upstream)
        (self.upstream / "sample.txt").write_text("original", encoding="utf-8")
        git("-C", self.upstream, "add", "sample.txt")
        git("-C", self.upstream, "-c", "user.name=Build Test", "-c",
            "user.email=build-test@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "fixture")
        self.entry = {"path": "component", "url": self.upstream.as_uri(),
                      "commit": git("-C", self.upstream, "rev-parse", "HEAD")}
        self.source = self.root / "checkout"
        self.source.mkdir()
        self.target = self.source / "component"

    def tearDown(self):
        self.temporary.cleanup()

    def test_fresh_fetch_then_retry_preserves_local_edits(self):
        fetch_repository(self.entry, LocalCommands(), self.source)
        (self.target / "sample.txt").write_text("my edits", encoding="utf-8")
        fetch_repository(self.entry, LocalCommands(), self.source)
        self.assertEqual((self.target / "sample.txt").read_text(), "my edits")
        self.assertEqual(git("-C", self.target, "rev-parse", "HEAD"), self.entry["commit"])

    def test_recovers_interrupted_fetch_without_head(self):
        git("init", self.target)
        git("-C", self.target, "remote", "add", "origin", self.entry["url"])
        fetch_repository(self.entry, LocalCommands(), self.source)
        self.assertEqual((self.target / "sample.txt").read_text(), "original")

    def test_wrong_commit_never_resets_local_checkout(self):
        fetch_repository(self.entry, LocalCommands(), self.source)
        wrong = dict(self.entry, commit="0" * 40)
        with self.assertRaisesRegex(RuntimeError, "版本不匹配"):
            fetch_repository(wrong, LocalCommands(), self.source)
        self.assertEqual(git("-C", self.target, "rev-parse", "HEAD"), self.entry["commit"])

    def test_partial_checkout_with_user_files_is_preserved(self):
        git("init", self.target)
        git("-C", self.target, "remote", "add", "origin", self.entry["url"])
        file = self.target / "user.txt"
        file.write_text("keep", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "已有文件"):
            fetch_repository(self.entry, LocalCommands(), self.source)
        self.assertEqual(file.read_text(), "keep")

    def test_wrong_remote_is_not_replaced(self):
        git("init", self.target)
        git("-C", self.target, "remote", "add", "origin", "https://example.invalid/repo")
        with self.assertRaisesRegex(RuntimeError, "来源"):
            fetch_repository(self.entry, LocalCommands(), self.source)
        self.assertEqual(git("-C", self.target, "remote", "get-url", "origin"),
                         "https://example.invalid/repo")

    def test_path_traversal_and_symlink_are_rejected(self):
        for path in ["../outside", str(self.root / "absolute")]:
            with self.assertRaisesRegex(RuntimeError, "边界"):
                fetch_repository(dict(self.entry, path=path), LocalCommands(), self.source)
        self.target.symlink_to(self.upstream, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "边界"):
            fetch_repository(self.entry, LocalCommands(), self.source)


if __name__ == "__main__":
    unittest.main()
