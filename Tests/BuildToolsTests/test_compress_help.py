"""验证帮助压缩逐路径无损、跨编辑器链接和失败时保留原始目录。"""

import json
import hashlib
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
import compress_help as compressor


class CompressedHelpTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "FileDeck.app"
        self.app.mkdir()

    def help_file(self, relative="zh/目录/帮助.htm", data=b"offline-help" * 1024, editor="documenteditor"):
        path = self.app / compressor.APPS_ROOT / editor / "main/resources/help" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def archive(self, editor="documenteditor"):
        return self.app / compressor.APPS_ROOT / editor / "main/resources/help.zip"

    def rewrite_archive(self, archive, mutate):
        with zipfile.ZipFile(archive) as original:
            entries = [(info, original.read(info)) for info in original.infolist()]
        with zipfile.ZipFile(archive, "w") as changed:
            for info, payload in entries:
                changed.writestr(info, mutate(info.filename, payload))

    def test_archive_retains_exact_bytes_modes_cross_editor_links_and_is_idempotent(self):
        original = self.help_file()
        original.chmod(0o444)
        expected = original.read_bytes()
        link = self.help_file("en/images/example.png", b"", "spreadsheeteditor")
        link.unlink()
        target = os.path.relpath(original, link.parent)
        link.symlink_to(target)
        report = compressor.compress_help(self.app)
        self.assertEqual((report["createdArchives"], report["files"], report["links"]), (2, 1, 1))
        self.assertGreater(report["bytesSaved"], 0)
        self.assertFalse(original.exists())
        self.assertEqual(stat.S_IMODE(self.archive().stat().st_mode), 0o644)
        with zipfile.ZipFile(self.archive()) as archive:
            self.assertEqual(archive.read("zh/目录/帮助.htm"), expected)
            self.assertEqual(stat.S_IMODE(archive.getinfo("zh/目录/帮助.htm").external_attr >> 16), 0o444)
        with zipfile.ZipFile(self.archive("spreadsheeteditor")) as archive:
            self.assertEqual(archive.read("en/images/example.png"), target.encode())
            self.assertTrue(stat.S_ISLNK(archive.getinfo("en/images/example.png").external_attr >> 16))
            manifest = json.loads(archive.read(compressor.MANIFEST_NAME))
            self.assertEqual(manifest["links"], {"en/images/example.png": target})
        second = compressor.compress_help(self.app)
        self.assertEqual(second["createdArchives"], 0)
        self.assertEqual(second["bytesSaved"], report["bytesSaved"])
        self.assertEqual([entry["sha256"] for entry in report["archives"]],
                         [entry["sha256"] for entry in second["archives"]])
        self.assertEqual(compressor.verify_compressed_help(self.app)["links"], 1)
        moved = self.root / "中文 空格 新名称.app"
        self.app.rename(moved)
        self.assertEqual(compressor.verify_compressed_help(moved, verify_bytes=False)["files"], 1)

    def test_archive_is_deterministic_despite_different_file_times(self):
        path = self.help_file()
        root = path.parents[2]
        manifest = compressor._scan_help(root)
        first, second = self.root / "first.zip", self.root / "second.zip"
        compressor._write_archive(root, first, manifest)
        os.utime(path, (100000, 100000))
        compressor._write_archive(root, second, compressor._scan_help(root))
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_corrupted_archive_is_rejected_on_repeat(self):
        self.help_file("en/help.htm", b"help")
        compressor.compress_help(self.app)
        self.rewrite_archive(self.archive(), lambda name, data: b"oops" if name == "en/help.htm" else data)
        with self.assertRaisesRegex(ValueError, "内容校验失败"):
            compressor.compress_help(self.app)

    def test_changed_source_during_packaging_is_rejected_before_any_original_is_removed(self):
        first = self.help_file()
        second = self.help_file(editor="spreadsheeteditor")
        write = compressor._write_archive

        def mutate(root, destination, manifest):
            write(root, destination, manifest)
            if root == second.parents[2].resolve():
                first.write_bytes(b"changed")

        with patch.object(compressor, "_write_archive", side_effect=mutate), self.assertRaisesRegex(ValueError, "发生变化"):
            compressor.compress_help(self.app)
        self.assertEqual(first.read_bytes(), b"changed")
        self.assertTrue(second.is_file())
        self.assertFalse(self.archive().exists() or self.archive("spreadsheeteditor").exists())
        self.assertFalse(list(self.app.rglob(".help-*.zip")))

    def test_failed_archive_verification_keeps_all_originals(self):
        original = self.help_file()
        with patch.object(compressor, "verify_help_archive", side_effect=ValueError("invalid")), self.assertRaises(ValueError):
            compressor.compress_help(self.app)
        self.assertTrue(original.is_file())
        self.assertFalse(self.archive().exists())
        self.assertFalse(list(self.app.rglob(".help-*.zip")))

    def test_manifest_limit_matches_native_reader_before_write_or_read(self):
        original = self.help_file()
        with patch.object(compressor, "MAX_MANIFEST_BYTES", 1), self.assertRaisesRegex(ValueError, "清单超过"):
            compressor.compress_help(self.app)
        self.assertTrue(original.is_file())
        self.assertFalse(self.archive().exists())
        compressor.compress_help(self.app)
        with patch.object(compressor, "MAX_MANIFEST_BYTES", 1), self.assertRaisesRegex(ValueError, "清单超过"):
            compressor.verify_help_archive(self.archive(), verify_bytes=False)

    def test_incoming_link_outside_help_is_rejected_without_breaking_reference(self):
        original = self.help_file()
        incoming = self.app / "Contents/Resources/keep-help.htm"
        incoming.symlink_to(os.path.relpath(original, incoming.parent))
        with self.assertRaisesRegex(ValueError, "被其他运行资源引用"):
            compressor.compress_help(self.app)
        self.assertEqual(incoming.read_bytes(), original.read_bytes())

    def test_absolute_outside_missing_and_cyclic_links_are_rejected(self):
        for target in ("/tmp/outside", "../../../../../../outside", "missing.htm", "link.htm"):
            with self.subTest(target=target):
                link = self.help_file("en/link.htm")
                link.unlink()
                link.symlink_to(target)
                with self.assertRaises(ValueError):
                    compressor.compress_help(self.app)
                self.assertTrue(link.is_symlink())
                link.unlink()

    def test_directory_link_and_external_help_root_are_rejected(self):
        original = self.help_file()
        directory_link = original.parent / "directory"
        directory_link.symlink_to(".", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "目录软链接"):
            compressor.compress_help(self.app)
        directory_link.unlink()
        help_root = original.parents[2]
        external = self.root / "external"
        help_root.rename(external)
        help_root.symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "包内普通路径"):
            compressor.compress_help(self.app)
        self.assertEqual((external / "zh/目录/帮助.htm").read_bytes(), b"offline-help" * 1024)

    def test_oversized_executable_custom_metadata_and_reserved_name_are_rejected(self):
        original = self.help_file()
        with patch.object(compressor, "MAX_ENTRY_BYTES", 8), self.assertRaisesRegex(ValueError, "单文件限制"):
            compressor.compress_help(self.app)
        original.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "可执行文件"):
            compressor.compress_help(self.app)
        original.chmod(0o644)
        with patch.object(compressor, "has_extended_attributes", return_value=True), self.assertRaisesRegex(ValueError, "扩展属性"):
            compressor.compress_help(self.app)
        reserved = self.help_file(compressor.MANIFEST_NAME)
        with self.assertRaisesRegex(ValueError, "归档格式冲突"):
            compressor.compress_help(self.app)
        self.assertTrue(original.is_file() and reserved.is_file())

    def test_archive_manifest_cannot_escape_or_hide_extra_entries(self):
        self.help_file()
        compressor.compress_help(self.app)
        with zipfile.ZipFile(self.archive(), "a") as archive:
            archive.writestr("../outside.htm", b"invalid")
        with self.assertRaisesRegex(ValueError, "不支持或不唯一"):
            compressor.verify_compressed_help(self.app)

    def test_corrupt_manifest_link_graph_is_rejected_even_when_entry_hashes_match(self):
        original = self.help_file("en/original.htm")
        link = self.help_file("en/link.htm", b"")
        link.unlink()
        link.symlink_to(original.name)
        compressor.compress_help(self.app)

        def create_cycle(name, data):
            if name == "en/link.htm":
                return b"link.htm"
            if name == compressor.MANIFEST_NAME:
                manifest = json.loads(data)
                manifest["links"]["en/link.htm"] = "link.htm"
                for entry in manifest["entries"]:
                    if entry["path"] == "en/link.htm":
                        entry.update(bytes=len(b"link.htm"), sha256=hashlib.sha256(b"link.htm").hexdigest())
                return json.dumps(manifest).encode()
            return data

        self.rewrite_archive(self.archive(), create_cycle)
        with self.assertRaisesRegex(ValueError, "循环"):
            compressor.verify_compressed_help(self.app)

    def test_link_depth_matches_native_reader_limit(self):
        original = self.help_file("en/original.htm")
        previous = original
        for index in range(compressor.MAX_LINK_DEPTH):
            link = original.with_name("link-%d.htm" % index)
            link.symlink_to(previous.name)
            previous = link
        too_deep = original.with_name("too-deep.htm")
        too_deep.symlink_to(previous.name)
        with self.assertRaisesRegex(ValueError, "递归限制"):
            compressor.compress_help(self.app)
        self.assertTrue(original.is_file())
        too_deep.unlink()
        self.assertEqual(compressor.compress_help(self.app)["links"], compressor.MAX_LINK_DEPTH)

    def test_existing_archive_and_live_help_are_not_overwritten(self):
        original = self.help_file()
        self.archive().write_bytes(b"existing")
        with self.assertRaisesRegex(ValueError, "同时存在"):
            compressor.compress_help(self.app)
        self.assertTrue(original.is_file())
        self.assertEqual(self.archive().read_bytes(), b"existing")

    def test_no_help_is_noop_and_other_resources_are_unchanged(self):
        other = self.app / "Contents/Resources/dictionaries/en_US/en_US.dic"
        other.parent.mkdir(parents=True)
        other.write_bytes(b"dictionary")
        report = compressor.compress_help(self.app)
        self.assertEqual(report["createdArchives"], 0)
        self.assertEqual(other.read_bytes(), b"dictionary")


if __name__ == "__main__":
    unittest.main()
