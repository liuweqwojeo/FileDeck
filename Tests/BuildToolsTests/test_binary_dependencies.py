"""直接执行补丁中的固定下载逻辑；网络由测试替身替代，真实 vendor 保持只读。"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "scripts/onlyoffice/patches/build_tools-003-cef-pinned-download.patch"
LOCK = ROOT / "scripts/onlyoffice/binary-dependencies.lock.json"
CEF_PATH = "scripts/core_common/modules/cef.py"
HELPER_PATH = "scripts/core_common/modules/pinned_binary.py"


def load_download_helper():
    """新增文件在补丁内有完整源码，测试它本身，避免另写一份实现让测试空转。"""
    section = PATCH.read_text().split("diff --git a/" + HELPER_PATH + " b/" + HELPER_PATH + "\n", 1)[1]
    lines = [line[1:] for line in section.splitlines(True) if line.startswith("+") and not line.startswith("+++")]
    module = types.ModuleType("pinned_binary")
    exec(compile("".join(lines), str(PATCH), "exec"), module.__dict__)
    return module


class BinaryDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()
        self.archive = self.directory / "cef_binary.7z"
        self.payload = b"valid fixture"
        self.dependency = {"url": "https://example.invalid/immutable/archive.7z", "size": len(self.payload),
                           "sha256": hashlib.sha256(self.payload).hexdigest()}
        self.helper = load_download_helper()

    def tearDown(self):
        self.temporary.cleanup()

    def test_patch_constants_match_anchored_lock(self):
        locked = json.loads(LOCK.read_text())["dependencies"]["cef-5414-mac_arm64"]
        self.assertEqual(self.helper.CEF_MAC_ARM64_5414, {key: locked[key] for key in ["url", "size", "sha256"]})
        self.assertIn(locked["source"]["commit"], locked["url"])
        self.assertEqual(locked["source"]["gitBlobSha1"], "bb6d397bdfd6a35dd0437b4974282a8e793d961b")
        self.assertFalse(locked["source"]["gitLfs"])

    def test_download_validates_then_atomically_replaces_then_tests_archive(self):
        self.archive.write_bytes(b"old cache")
        events = []
        real_replace = os.replace

        def command(arguments):
            events.append(arguments[0])
            if arguments[0] == "curl":
                self.assertIn("--fail", arguments)
                self.assertEqual(arguments[arguments.index("--retry") + 1], "3")
                self.assertEqual(arguments[arguments.index("--connect-timeout") + 1], "30")
                temporary = Path(arguments[arguments.index("--output") + 1])
                self.assertEqual(temporary.parent, self.archive.parent)
                self.assertNotEqual(temporary, self.archive)
                self.assertEqual(self.archive.read_bytes(), b"old cache")
                temporary.write_bytes(self.payload)
            else:
                self.assertEqual(arguments, ["7za", "t", str(self.archive)])
                self.assertEqual(self.archive.read_bytes(), self.payload)

        def replace(source, target):
            events.append("replace")
            self.assertTrue(self.helper.matches_dependency(source, self.dependency))
            real_replace(source, target)

        with patch.object(self.helper.subprocess, "check_call", side_effect=command), patch.object(self.helper.os, "replace", side_effect=replace):
            self.helper.prepare_pinned_archive(self.archive, self.dependency)
        self.assertEqual(events, ["curl", "replace", "7za"])
        self.assertEqual(list(self.directory.glob("*.part")), [])

    def test_invalid_download_preserves_existing_cache_and_cleans_temporary(self):
        self.archive.write_bytes(b"keep old cache")

        def command(arguments):
            self.assertEqual(arguments[0], "curl")
            Path(arguments[arguments.index("--output") + 1]).write_bytes(b"wrong fixture")

        with patch.object(self.helper.subprocess, "check_call", side_effect=command):
            with self.assertRaisesRegex(RuntimeError, "SHA-256"):
                self.helper.prepare_pinned_archive(self.archive, self.dependency)
        self.assertEqual(self.archive.read_bytes(), b"keep old cache")
        self.assertEqual(list(self.directory.iterdir()), [self.archive])

    def test_http_failure_never_replaces_original_cache(self):
        self.archive.write_bytes(b"keep")
        with patch.object(self.helper.subprocess, "check_call", side_effect=subprocess.CalledProcessError(22, "curl")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.helper.prepare_pinned_archive(self.archive, self.dependency)
        self.assertEqual(self.archive.read_bytes(), b"keep")
        self.assertEqual(list(self.directory.iterdir()), [self.archive])

    def test_valid_cache_skips_network_but_failed_7za_stops_processing(self):
        self.archive.write_bytes(self.payload)
        before = self.archive.stat().st_mtime_ns
        with patch.object(self.helper.subprocess, "check_call") as command:
            self.helper.prepare_pinned_archive(self.archive, self.dependency)
            command.assert_called_once_with(["7za", "t", str(self.archive)])
        self.assertEqual(self.archive.stat().st_mtime_ns, before)
        with patch.object(self.helper.subprocess, "check_call", side_effect=subprocess.CalledProcessError(2, "7za")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.helper.prepare_pinned_archive(self.archive, self.dependency)

    def test_symlink_cache_cannot_overwrite_other_file(self):
        other = self.directory / "other"
        other.write_bytes(b"keep")
        self.archive.symlink_to(other)
        with patch.object(self.helper.subprocess, "check_call") as command:
            with self.assertRaisesRegex(RuntimeError, "符号链接"):
                self.helper.prepare_pinned_archive(self.archive, self.dependency)
            command.assert_not_called()
        self.assertEqual(other.read_bytes(), b"keep")


class CEFWiringTests(unittest.TestCase):
    def test_patch_applies_and_keeps_other_platform_and_explicit_107_behavior(self):
        upstream = ROOT / "vendor/onlyoffice/build_tools"
        if not (upstream / ".git").exists():
            self.skipTest("获取固定上游源码后才运行补丁接线测试；下载校验单测不依赖 vendor。")
        original = subprocess.check_output(["git", "-C", str(upstream), "show",
                                           "cf4cac0846d03e2e00a6fec5d1ecd4e9463086d5:" + CEF_PATH], text=True)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            project = directory / "build_tools"
            cef = project / CEF_PATH
            cef.parent.mkdir(parents=True)
            cef.write_text(original)
            subprocess.run(["git", "-C", str(project), "apply", "--check", str(PATCH)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(project), "apply", str(PATCH)], check=True, capture_output=True)
            for platform, use_107 in [("mac_arm64", False), ("mac_64", False), ("mac_arm64", True)]:
                with self.subTest(platform=platform, cef_107=use_107):
                    self.check_wiring(directory, cef, platform, use_107)

    def check_wiring(self, directory, cef, platform, use_107):
        events = []
        config = types.ModuleType("config")
        config.check_option = lambda name, value: (name == "platform" and value == platform) or (name == "config" and value == "cef_version_107" and use_107)
        base = types.ModuleType("base")
        base.get_script_dir = lambda: str(directory / "build_tools/scripts")
        base.check_module_version = lambda *_: None
        base.is_dir = os.path.isdir
        base.is_file = os.path.isfile
        base.create_dir = lambda path: Path(path).mkdir(parents=True, exist_ok=True)
        base.readFile = lambda path: Path(path).read_text() if Path(path).exists() else ""
        base.writeFile = lambda path, content: Path(path).write_text(content)
        base.delete_file = lambda path: Path(path).unlink(missing_ok=True)
        base.delete_dir = lambda path: shutil.rmtree(path) if Path(path).is_dir() else None
        base.cmd = lambda name, args: shutil.move(args[0], args[1]) if name == "mv" else None

        def header(url):
            events.append("last-modified")
            return "upstream timestamp"

        def download(url, path):
            events.append("upstream-download")
            Path(path).write_bytes(b"legacy")

        def extract(path, destination):
            events.append("extract")
            self.assertTrue(Path(path).is_file())
            if platform == "mac_arm64" and not use_107:
                self.assertEqual(Path(path).read_bytes(), b"verified fixture")
            Path("Chromium Embedded Framework.framework").mkdir()

        helper = load_download_helper()

        def pinned(path, dependency):
            events.append("pinned-hash-and-7za")
            Path(path).write_bytes(b"verified fixture")

        helper.prepare_pinned_archive = pinned
        base.get_file_last_modified_url, base.download, base.extract = header, download, extract
        scope = directory / "core/Common/3dParty/cef"
        if scope.exists():
            shutil.rmtree(scope)
        scope.mkdir(parents=True)
        # 旧 Last-Modified 缓存首次切换到固定哈希时需要重新解包，但不能删掉已验证归档。
        (scope / platform / "build").mkdir(parents=True)
        (scope / platform / "cef_binary.7z").write_bytes(b"old cache")
        (scope / platform / "cef_binary.7z.data").write_text("legacy timestamp")
        module = types.ModuleType("cef")
        previous_cwd = Path.cwd()
        previous_path = list(sys.path)
        try:
            with patch.dict(sys.modules, {"base": base, "config": config, "pinned_binary": helper}):
                exec(compile(cef.read_text(), str(cef), "exec"), module.__dict__)
                module.make()
        finally:
            os.chdir(previous_cwd)
            sys.path[:] = previous_path
        if platform == "mac_arm64" and not use_107:
            self.assertEqual(events, ["pinned-hash-and-7za", "extract"])
            self.assertEqual((scope / platform / "cef_binary.7z.data").read_text(), "sha256:" + helper.CEF_MAC_ARM64_5414["sha256"])
        else:
            self.assertEqual(events, ["last-modified", "upstream-download", "extract"])


if __name__ == "__main__":
    unittest.main()
