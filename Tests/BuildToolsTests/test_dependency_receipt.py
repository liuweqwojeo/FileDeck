"""用临时仓库与归档验证依赖凭据，避免网络、实际 vendor 和大二进制扫描。"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
from dependency_receipt import THIRD_PARTY, snapshot, verify, write_receipt


def git(directory, *arguments):
    return subprocess.check_output(["git", "-C", str(directory), *arguments],
                                   stderr=subprocess.STDOUT, text=True).strip()


def commit(directory, text):
    git(directory, "add", ".")
    git(directory, "-c", "user.name=Receipt Test", "-c", "user.email=test@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-m", text)


class DependencyReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source"
        self.third_party = self.source / THIRD_PARTY
        self.repository = self.third_party / "sample" / "repository"
        self.repository.mkdir(parents=True)
        git(self.repository, "init")
        (self.repository / "source.txt").write_text("original")
        commit(self.repository, "initial")
        git(self.repository, "remote", "add", "origin", "https://user:secret@example.org/repo.git?token=secret")
        self.archive = self.third_party / "sample" / "source.tar.gz"
        self.archive.write_bytes(b"archive fixture")
        tools = self.source / "build_tools/tools/mac"
        tools.mkdir(parents=True)
        (tools / "7za").write_bytes(b"tool fixture")

    def tearDown(self):
        self.temporary.cleanup()

    def receipt(self, **kwargs):
        return snapshot(self.source, tools=[], **kwargs)

    def test_records_git_archives_support_files_and_redacts_credentials(self):
        receipt = self.receipt()
        self.assertEqual(len(receipt["repositories"]), 1)
        self.assertEqual(receipt["repositories"][0]["head"], git(self.repository, "rev-parse", "HEAD"))
        self.assertEqual(receipt["repositories"][0]["remotes"]["origin"], ["https://example.org/repo.git"])
        self.assertNotIn("secret", json.dumps(receipt))
        self.assertEqual(receipt["archives"][0]["sha256"], hashlib.sha256(b"archive fixture").hexdigest())
        self.assertEqual(receipt["archives"][0]["size"], len(b"archive fixture"))
        self.assertEqual([entry["path"] for entry in receipt["supportFiles"]], ["build_tools/tools/mac/7za"])
        self.assertEqual(verify(receipt, self.source, tools=[]), [])

    def test_excludes_outputs_caches_repository_fixtures_and_symlink_escape(self):
        for name in ["build", "out", "obj", ".cache", "node_modules", "bin.v2"]:
            path = self.third_party / "sample" / name
            path.mkdir()
            (path / "ignored.zip").write_bytes(b"ignored")
        (self.repository / "test-fixture.zip").write_bytes(b"source fixture is not a downloaded dependency")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret.7z").write_bytes(b"unrelated")
        (self.third_party / "linked-folder").symlink_to(outside, target_is_directory=True)
        (self.third_party / "linked.zip").symlink_to(outside / "secret.7z")
        receipt = self.receipt()
        self.assertEqual([item["path"] for item in receipt["archives"]], [self.archive.relative_to(self.source).as_posix()])
        self.assertNotIn("unrelated", json.dumps(receipt))

    def test_submodule_gitdir_is_recorded_without_walking_source_tree(self):
        child = self.repository / "nested"
        child.mkdir()
        git(child, "init")
        (child / "nested.txt").write_text("module")
        commit(child, "module")
        metadata = self.repository / ".git/modules/nested"
        metadata.parent.mkdir()
        shutil.move(child / ".git", metadata)
        (child / ".git").write_text("gitdir: ../.git/modules/nested\n")
        (self.repository / ".gitmodules").write_text('[submodule "nested"]\n\tpath = nested\n\turl = https://example.org/nested.git\n')
        receipt = self.receipt()
        self.assertEqual(len(receipt["repositories"]), 2)
        self.assertEqual(verify(receipt, self.source, tools=[]), [])
        (child / "nested.txt").write_text("next")
        commit(child, "next")
        self.assertTrue(any("Git HEAD" in failure for failure in verify(receipt, self.source, tools=[])))

    def test_archive_and_remote_changes_are_detected(self):
        receipt = self.receipt()
        self.archive.write_bytes(b"changed fixture")
        git(self.repository, "remote", "set-url", "origin", "https://example.org/other.git")
        failures = verify(receipt, self.source, tools=[])
        self.assertTrue(any("文件内容变化" in failure for failure in failures))
        self.assertTrue(any("Git HEAD 或 remote" in failure for failure in failures))
        self.archive.unlink()
        self.assertTrue(any("缺失" in failure for failure in verify(receipt, self.source, tools=[])))

    def test_unchanged_snapshot_reuses_hash_but_verify_rehashes(self):
        receipt = self.receipt()
        with patch("dependency_receipt.hashlib.sha256", side_effect=AssertionError("unexpected hash")):
            self.receipt(previous=receipt)
        with patch("dependency_receipt.hashlib.sha256", wraps=hashlib.sha256) as hasher:
            self.assertEqual(verify(receipt, self.source, tools=[]), [])
            self.assertEqual(hasher.call_count, 2)

    def test_receipt_paths_and_git_metadata_cannot_escape_scope(self):
        receipt = self.receipt()
        receipt["archives"][0]["path"] = "../../outside.zip"
        self.assertTrue(any("越界" in failure for failure in verify(receipt, self.source, tools=[])))
        receipt["archives"][0]["path"] = "build_tools/out/any.zip"
        self.assertTrue(any("不属于" in failure for failure in verify(receipt, self.source, tools=[])))
        outside = self.root / "outside-git"
        outside.mkdir()
        external = self.third_party / "external"
        external.mkdir()
        (external / ".git").write_text("gitdir: " + str(outside))
        result = self.receipt()
        self.assertEqual(len(result["repositories"]), 1)
        self.assertTrue(result["warnings"])

    def test_symlink_replacement_of_recorded_file_is_rejected(self):
        receipt = self.receipt()
        outside = self.root / "outside.zip"
        outside.write_bytes(self.archive.read_bytes())
        self.archive.unlink()
        self.archive.symlink_to(outside)
        self.assertTrue(any("符号链接" in failure for failure in verify(receipt, self.source, tools=[])))

    def test_tool_version_and_output_scope_are_verified(self):
        receipt = self.receipt()
        receipt["tools"] = [{"name": "cmake", "path": "/tool/cmake", "version": "3.31.6"}]
        self.assertTrue(any("工具版本" in failure for failure in verify(receipt, self.source, tools=[])))
        build = self.root / "build"
        output = build / "receipt.json"
        write_receipt(receipt, output, build)
        self.assertEqual(json.loads(output.read_text()), receipt)
        outside = self.root / "keep.json"
        outside.write_text("keep")
        with self.assertRaisesRegex(RuntimeError, "只能写入"):
            write_receipt(receipt, outside, build)
        self.assertEqual(outside.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
