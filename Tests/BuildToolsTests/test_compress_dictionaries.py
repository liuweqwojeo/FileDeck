"""验证 .hz 字节往返、语言保留与真实 Hunspell 加载，防止仅缩小文件却丢失拼写能力。"""

import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/onlyoffice"))
import compress_dictionaries as compressor


class DictionaryCompressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = compressor.build_tools()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "中文 词典.app"
        self.dictionary = self.app / compressor.DICTIONARIES / "en_US"
        self.dictionary.mkdir(parents=True)
        self.affix = self.dictionary / "en_US.aff"
        self.affix_bytes = b"SET UTF-8\nTRY abcdefghijklmnopqrstuvwxyz\n" + b"# dictionary metadata\n" * 4000
        self.affix.write_bytes(self.affix_bytes)
        # 重复前缀模拟自然词表，同时保留可验证的普通词和 Unicode 词。
        self.words = ["hello", "world", "café"] + ["word" + str(i) for i in range(4000)]
        self.original = (str(len(self.words)) + "\n" + "\n".join(self.words) + "\n").encode()
        self.word_list = self.dictionary / "en_US.dic"
        self.word_list.write_bytes(self.original)

    def test_native_format_roundtrip_keeps_languages_and_nonspell_resources(self):
        untouched = {}
        for name in ("hyph_en_US.dic", "en_US_thes.dat", "en_US_thes.idx", "README.txt", "unused.dic"):
            path = self.dictionary / name
            path.write_bytes(self.original)
            untouched[path] = path.read_bytes()
        report = compressor.compress_dictionaries(self.app)
        self.assertEqual(report["languages"], ["en_US"])
        self.assertEqual(len(report["compressedFiles"]), 2)
        self.assertGreater(report["bytesSaved"], 0)
        self.assertFalse(self.word_list.exists())
        compressed = Path(str(self.word_list) + ".hz")
        self.assertEqual(compressor.subprocess.check_output([str(self.tools[1]), str(compressed)]), self.original)
        self.assertFalse(self.affix.exists())
        self.assertEqual(compressor.subprocess.check_output([str(self.tools[1]), str(self.affix) + ".hz"]), self.affix_bytes)
        for path, expected in untouched.items():
            self.assertEqual(path.read_bytes(), expected)
        self.assertEqual(compressor.compress_dictionaries(self.app)["compressedFiles"], [])

    def test_incomplete_pair_is_not_compressed_or_registered(self):
        self.affix.unlink()
        with patch.object(compressor, "build_tools") as build:
            report = compressor.compress_dictionaries(self.app)
        build.assert_not_called()
        self.assertEqual(report["languages"], [])
        self.assertEqual(self.word_list.read_bytes(), self.original)

    def test_decode_mismatch_preserves_original(self):
        actual_run = compressor.subprocess.run

        def corrupt_decoder(command, **kwargs):
            if command[0] == str(self.tools[1]):
                kwargs["stdout"].write(b"corrupt")
                return None
            return actual_run(command, **kwargs)

        with patch.object(compressor, "build_tools", return_value=self.tools), \
                patch.object(compressor.subprocess, "run", side_effect=corrupt_decoder):
            report = compressor.compress_dictionaries(self.app)
        self.assertTrue(all(item["reason"] == "roundtrip-mismatch" for item in report["skippedFiles"]))
        self.assertEqual(self.word_list.read_bytes(), self.original)
        self.assertFalse(Path(str(self.word_list) + ".hz").exists())

    def test_existing_compressed_target_is_not_overwritten(self):
        compressed = Path(str(self.word_list) + ".hz")
        compressed.write_bytes(b"existing")
        with self.assertRaisesRegex(RuntimeError, "拒绝覆盖"):
            compressor.compress_dictionaries(self.app)
        self.assertEqual(compressed.read_bytes(), b"existing")
        self.assertEqual(self.word_list.read_bytes(), self.original)

    def test_external_directory_alias_is_not_traversed(self):
        outside = self.root / "outside"
        self.dictionary.rename(outside)
        self.dictionary.symlink_to(outside, target_is_directory=True)
        self.assertEqual(compressor.compress_dictionaries(self.app)["compressedFiles"], [])
        self.assertEqual((outside / "en_US.dic").read_bytes(), self.original)

    def test_external_resource_root_is_rejected(self):
        resources = self.app / compressor.DICTIONARIES
        outside = self.root / "outside"
        resources.rename(outside)
        resources.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            compressor.compress_dictionaries(self.app)

    def test_custom_metadata_preserves_original(self):
        with patch.object(compressor, "has_extended_attributes", return_value=True):
            report = compressor.compress_dictionaries(self.app)
        self.assertEqual(report["compressedFiles"], [])
        self.assertEqual(self.word_list.read_bytes(), self.original)

    def test_repack_validates_existing_compressed_files_and_detects_damage(self):
        first = compressor.compress_dictionaries(self.app)
        repeat = compressor.compress_dictionaries(self.app)
        self.assertEqual(repeat["verifiedCompressedFiles"], len(first["compressedFiles"]))
        compressed = Path(str(self.word_list) + ".hz")
        data = bytearray(compressed.read_bytes())
        data[-1] ^= 0x40
        compressed.write_bytes(data)
        with self.assertRaisesRegex(RuntimeError, "文件校验失败"):
            compressor.compress_dictionaries(self.app)

    def test_missing_manifest_or_compressed_file_prevents_repack(self):
        compressor.compress_dictionaries(self.app)
        manifest = self.dictionary.parent / compressor.MANIFEST
        saved = manifest.read_bytes()
        manifest.unlink()
        with self.assertRaisesRegex(RuntimeError, "缺少完整性清单"):
            compressor.compress_dictionaries(self.app)
        manifest.write_bytes(saved)
        Path(str(self.word_list) + ".hz").unlink()
        with self.assertRaisesRegex(RuntimeError, "缺少配对"):
            compressor.compress_dictionaries(self.app)

    def test_lightweight_verification_needs_no_tools_and_checks_file_mode(self):
        compressor.compress_dictionaries(self.app)
        with patch.object(compressor, "build_tools") as build:
            report = compressor.verify_compressed_dictionaries(self.app)
        build.assert_not_called()
        self.assertEqual(report["compressedFiles"], 2)
        self.assertEqual(report["languageCount"], 1)
        self.assertFalse(report["decodedVerified"])
        Path(str(self.word_list) + ".hz").chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "文件校验失败"):
            compressor.verify_compressed_dictionaries(self.app)

    def test_full_verification_checks_decoded_hash_and_rejects_manifest_paths(self):
        compressor.compress_dictionaries(self.app)
        self.assertTrue(compressor.verify_compressed_dictionaries(self.app, verify_decoded=True)["decodedVerified"])
        manifest = self.dictionary.parent / compressor.MANIFEST
        original = json.loads(manifest.read_text())
        changed = json.loads(manifest.read_text())
        changed["files"][0]["sha256"] = "0" * 64
        manifest.write_text(json.dumps(changed))
        with self.assertRaisesRegex(RuntimeError, "解码校验失败"):
            compressor.verify_compressed_dictionaries(self.app, verify_decoded=True)
        original["files"][0]["target"] = "../outside.dic.hz"
        manifest.write_text(json.dumps(original))
        with self.assertRaisesRegex(RuntimeError, "无效路径"):
            compressor.verify_compressed_dictionaries(self.app)

    def test_bundle_verification_does_not_require_upstream_dictionary_registry(self):
        # 发布包静态验收应可独立运行；只有构建期选择词典才读取上游注册表。
        with patch.object(compressor, "dictionary_names", side_effect=FileNotFoundError("vendor is absent")):
            raw = compressor.verify_compressed_dictionaries(self.app)
        self.assertEqual(raw["compressedFiles"], 0)
        self.assertEqual(raw["languageCount"], 1)
        compressor.compress_dictionaries(self.app)
        with patch.object(compressor, "dictionary_names", side_effect=FileNotFoundError("vendor is absent")), \
                patch.object(compressor, "build_tools") as build:
            compressed = compressor.verify_compressed_dictionaries(self.app)
        build.assert_not_called()
        self.assertEqual(compressed["compressedFiles"], 2)
        self.assertEqual(compressed["languages"], ["en_US"])

    def test_orphan_hz_files_are_rejected_even_when_name_is_not_registered(self):
        orphan = self.dictionary / "unused.bin.hz"
        orphan.write_bytes(b"orphan")
        with self.assertRaisesRegex(RuntimeError, "缺少完整性清单"):
            compressor.verify_compressed_dictionaries(self.app)
        orphan.unlink()
        compressor.compress_dictionaries(self.app)
        orphan.write_bytes(b"orphan")
        with self.assertRaisesRegex(RuntimeError, "与完整性清单不一致"):
            compressor.verify_compressed_dictionaries(self.app)

    def test_unicode_crlf_and_no_final_newline_are_exact_or_preserved(self):
        for data in (b"3\r\nhello\r\nworld\r\ncaf\xc3\xa9\r\n", b"3\nhello\nworld\ncaf\xc3\xa9",
                     ("4000\n" + "词典内容\n" * 4000).encode()):
            with self.subTest(data=data[:30]):
                isolated = self.root / ("variant-" + str(len(data)) + ".app")
                dictionary = isolated / compressor.DICTIONARIES / "en_US"
                dictionary.mkdir(parents=True)
                (dictionary / "en_US.aff").write_bytes(self.affix_bytes)
                path = dictionary / "en_US.dic"
                path.write_bytes(data)
                compressor.compress_dictionaries(isolated)
                actual = path.read_bytes() if path.exists() else compressor.subprocess.check_output(
                    [str(self.tools[1]), str(path) + ".hz"])
                self.assertEqual(actual, data)

    def native_library(self):
        override = os.environ.get("FW_HUNSPELL_TEST_LIBRARY")
        path = Path(override or compressor.ROOT / "build/FileDeck.app/Contents/Frameworks/hunspell.framework/hunspell")
        if not path.is_file():
            if override:
                self.fail("指定的 Hunspell 测试库不存在：" + str(path))
            self.skipTest("需要已构建的真实 Hunspell framework")
        library = ctypes.CDLL(str(path))
        if not hasattr(library, "FWCompressedHunspellVersion"):
            if override:
                self.fail("指定的 Hunspell 库尚未修复压缩 EOF")
            self.skipTest("现有 Hunspell framework 未修复压缩 EOF；新包构建后需运行本测试")
        self.assertEqual(library.FWCompressedHunspellVersion(), 1)
        library.Hunspell_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        library.Hunspell_create.restype = ctypes.c_void_p
        library.Hunspell_destroy.argtypes = [ctypes.c_void_p]
        library.Hunspell_spell.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        library.Hunspell_add.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        library.Hunspell_remove.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        string_list = ctypes.POINTER(ctypes.c_char_p)
        library.Hunspell_suggest.argtypes = [ctypes.c_void_p, ctypes.POINTER(string_list), ctypes.c_char_p]
        library.Hunspell_free_list.argtypes = [ctypes.c_void_p, ctypes.POINTER(string_list), ctypes.c_int]
        return library

    def test_bundled_hunspell_spell_suggest_and_user_words_match_raw_dictionary(self):
        # 小型 .hz 会在构造时读到 EOF；真实库必须仍能读取所有缓冲行。
        library = self.native_library()
        self.affix.write_bytes(b"SET UTF-8\nTRY abcdefghijklmnopqrstuvwxyz\n" + b"# dictionary metadata\n" * 100)
        # 使用有效词数与重复词条制造可压缩的小词表，覆盖 <64 KiB 缓冲边界。
        self.word_list.write_bytes(("1200\n" + "hello\nworld\ncafé\n" * 400).encode())

        def results():
            handle = library.Hunspell_create(str(self.affix).encode(), str(self.word_list).encode())
            self.assertTrue(handle)
            try:
                spelling = [library.Hunspell_spell(handle, word.encode()) for word in ("hello", "world", "café", "heello")]
                suggestions = ctypes.POINTER(ctypes.c_char_p)()
                count = library.Hunspell_suggest(handle, ctypes.byref(suggestions), b"heello")
                suggested = [suggestions[i] for i in range(count)]
                library.Hunspell_free_list(handle, ctypes.byref(suggestions), count)
                library.Hunspell_add(handle, b"customuserword")
                added = library.Hunspell_spell(handle, b"customuserword")
                library.Hunspell_remove(handle, b"customuserword")
                removed = library.Hunspell_spell(handle, b"customuserword")
                return spelling, suggested, added, removed
            finally:
                library.Hunspell_destroy(handle)

        before = results()
        compressor.compress_dictionaries(self.app)
        self.assertEqual(results(), before)
        self.assertEqual(before[0], [1, 1, 1, 0])
        self.assertIn(b"hello", before[1])
        self.assertEqual(before[2:], (1, 0))

    def test_native_dictionary_last_entry_survives_large_buffer_eof(self):
        library = self.native_library()
        words = ["uniqueprefix" + hashlib.sha256(str(i).encode()).hexdigest()[:24] for i in range(20000)] + ["lastentryword"]
        self.word_list.write_bytes((str(len(words)) + "\n" + "\n".join(words) + "\n").encode())
        self.assertGreater(self.word_list.stat().st_size, 65536)

        def spelling():
            handle = library.Hunspell_create(str(self.affix).encode(), str(self.word_list).encode())
            self.assertTrue(handle)
            try:
                return [library.Hunspell_spell(handle, word.encode()) for word in (words[0], words[10000], words[-1], "absentword")]
            finally:
                library.Hunspell_destroy(handle)

        before = spelling()
        compressor.compress_dictionaries(self.app)
        self.assertEqual(spelling(), before)
        self.assertEqual(before, [1, 1, 1, 0])


if __name__ == "__main__":
    unittest.main()
