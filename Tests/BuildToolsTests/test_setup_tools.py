"""离线构造归档验证工具链提取边界与重复执行保护，不改动实际构建目录。"""

import hashlib
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
from setup_tools import QT_ARCHIVE_ROOT, prepare_qmake


class SetupToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = self.root / "qt.tar.gz"
        self.destination = self.root / "toolchains" / "qt"

    def tearDown(self):
        self.temporary.cleanup()

    def fixture(self, extra=None, omit=None):
        entries = {"bin/qmake": b"qmake fixture", "mkspecs/features/toolchain.prf": b"feature",
                   "mkspecs/macx-clang/qmake.conf": b"configuration", "LICENSE.LGPLv3": b"license",
                   "lib/large-unused-library": b"ignored"}
        if omit:
            del entries[omit]
        with tarfile.open(self.archive, "w:gz") as archive:
            for name, data in entries.items():
                member = tarfile.TarInfo(QT_ARCHIVE_ROOT + "/" + name)
                member.size = len(data)
                member.mode = 0o4777
                archive.addfile(member, io.BytesIO(data))
            if extra:
                archive.addfile(extra, io.BytesIO(b"x") if extra.isfile() else None)
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def prepare(self, **kwargs):
        return prepare_qmake(self.archive, self.destination,
                             expected_sha256=kwargs.get("digest", self.digest),
                             expected_size=self.archive.stat().st_size)

    def test_whitelist_permissions_and_repeat_do_not_rewrite_files(self):
        self.fixture()
        self.prepare()
        qmake = self.destination / "bin/qmake"
        original = qmake.stat()
        self.prepare()
        self.assertEqual(qmake.stat().st_ino, original.st_ino)
        self.assertEqual(qmake.stat().st_mtime_ns, original.st_mtime_ns)
        self.assertEqual(qmake.stat().st_mode & 0o7777, 0o755)
        self.assertEqual((self.destination / "LICENSE.LGPLv3").read_bytes(), b"license")
        self.assertFalse((self.destination / "lib").exists())

    def test_checksum_mismatch_has_no_side_effects(self):
        self.fixture()
        with self.assertRaisesRegex(RuntimeError, "SHA-256"):
            self.prepare(digest="0" * 64)
        self.assertFalse(self.destination.parent.exists())

    def test_modified_toolchain_and_unowned_files_are_not_overwritten(self):
        self.fixture()
        self.prepare()
        qmake = self.destination / "bin/qmake"
        qmake.write_text("local edit")
        with self.assertRaisesRegex(RuntimeError, "保留原目录"):
            self.prepare()
        self.assertEqual(qmake.read_text(), "local edit")
        qmake.write_bytes(b"qmake fixture")
        (self.destination / "my-note").write_text("keep")
        with self.assertRaisesRegex(RuntimeError, "保留原目录"):
            self.prepare()
        self.assertEqual((self.destination / "my-note").read_text(), "keep")

    def test_rejects_path_traversal_links_and_duplicate_members(self):
        for name, kind, target in [("../outside", tarfile.REGTYPE, ""),
                                    ("/absolute", tarfile.REGTYPE, ""),
                                    (QT_ARCHIVE_ROOT + "/mkspecs/link", tarfile.SYMTYPE, "/tmp"),
                                    (QT_ARCHIVE_ROOT + "/mkspecs/hard", tarfile.LNKTYPE, "bin/qmake"),
                                    (QT_ARCHIVE_ROOT + "/bin/qmake", tarfile.REGTYPE, "")]:
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = target
                member.size = 1 if kind == tarfile.REGTYPE else 0
                self.fixture(extra=member)
                with self.assertRaises(RuntimeError):
                    self.prepare()
                self.assertFalse(self.destination.exists())
                self.assertFalse(self.destination.with_name("qt.setup.lock").exists())
                self.assertEqual(list(self.destination.parent.glob("*.staging-*")), [])

    def test_missing_required_members_leave_no_partial_install(self):
        self.fixture(omit="mkspecs/macx-clang/qmake.conf")
        with self.assertRaisesRegex(RuntimeError, "缺少"):
            self.prepare()
        self.assertFalse(self.destination.exists())

    def test_destination_symlink_is_not_followed(self):
        self.fixture()
        other = self.root / "other"
        other.mkdir()
        self.destination.parent.mkdir()
        self.destination.symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "符号链接"):
            self.prepare()
        self.assertEqual(list(other.iterdir()), [])

    def test_existing_setup_lock_is_respected(self):
        self.fixture()
        self.destination.parent.mkdir()
        lock = self.destination.with_name("qt.setup.lock")
        lock.write_text("another process")
        with self.assertRaisesRegex(RuntimeError, "准备锁"):
            self.prepare()
        self.assertEqual(lock.read_text(), "another process")
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
