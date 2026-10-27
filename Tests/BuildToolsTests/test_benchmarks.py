"""基线必须来自自己的 Git 树；新增依赖不能让文档中的旧基准失去可复现性。"""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("benchmark_common", ROOT / "scripts/onlyoffice/benchmark_common.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class BenchmarkSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            cls.baseline = benchmark.resolve_commit("59b5591")
        except subprocess.CalledProcessError:
            raise unittest.SkipTest("需要文档中使用的构建8历史基线。")

    def test_browser_uses_each_revisions_own_source_list(self):
        previous = benchmark.browser_paths(self.baseline)
        current = benchmark.browser_paths()
        draft = Path("Sources/FileWorkbench/DraftRecoveryStore.swift")
        search = Path("Sources/FileWorkbench/DirectorySearch.swift")
        self.assertNotIn(draft, previous)
        self.assertNotIn(search, previous)
        self.assertIn(draft, current)
        self.assertIn(search, current)
        self.assertTrue(all(p.name != "FileWorkbenchApp.swift" for p in previous + current))

    def test_legacy_snapshot_omits_new_dependencies_without_mixing_sources(self):
        paths = [Path("Sources/FileWorkbench/CSVDocument.swift"), Path("Sources/FileWorkbench/DraftRecoveryStore.swift")]
        probe = ROOT / "NativeOffice/Tests/CSVPerformance.swift"
        frozen_probe = probe.read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "sources"
            hashes, omitted = benchmark.snapshot_sources(paths, destination, probe, frozen_probe, self.baseline)
            self.assertEqual(omitted, [paths[1].as_posix()])
            expected = subprocess.check_output(["git", "show", self.baseline + ":" + paths[0].as_posix()], cwd=ROOT)
            self.assertEqual((destination / paths[0].name).read_bytes(), expected)
            self.assertEqual(hashes[paths[0].as_posix()], hashlib.sha256(expected).hexdigest())
            self.assertFalse((destination / paths[1].name).exists())
            self.assertEqual((destination / probe.name).read_bytes(), frozen_probe)

    def test_current_snapshot_keeps_required_new_dependency_and_actual_digests(self):
        paths = [Path("Sources/FileWorkbench/DraftRecoveryStore.swift")]
        probe = ROOT / "NativeOffice/Tests/CSVPerformance.swift"
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "sources"
            hashes, omitted = benchmark.snapshot_sources(paths, destination, probe, probe.read_bytes())
            self.assertFalse(omitted)
            actual = (ROOT / paths[0]).read_bytes()
            self.assertEqual((destination / paths[0].name).read_bytes(), actual)
            self.assertEqual(hashes[paths[0].as_posix()], hashlib.sha256(actual).hexdigest())

    def test_media_algorithm_follows_actual_revision_capability(self):
        path = "Sources/FileWorkbench/MediaOperations.swift"
        legacy = subprocess.check_output(["git", "show", self.baseline + ":" + path], cwd=ROOT, text=True)
        self.assertFalse(benchmark.supports_batch_highlights(legacy))
        self.assertTrue(benchmark.supports_batch_highlights((ROOT / path).read_text()))
        current_commit = benchmark.resolve_commit("HEAD")
        current = subprocess.check_output(["git", "show", current_commit + ":" + path], cwd=ROOT, text=True)
        self.assertTrue(benchmark.supports_batch_highlights(current), "HEAD 已优化时不能强制基线走旧算法")
