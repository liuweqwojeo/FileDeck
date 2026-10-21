"""合成临时包和工具输出仅验证静态检查规则，不代表签名或真实 Office 运行通过。"""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
import verify_bundle as checker


class FixtureTools:
    def __init__(self):
        self.calls = []
        self.dependencies = {}
        self.architectures = {}
        self.failures = {}

    def __call__(self, arguments):
        self.calls.append(arguments)
        name, path = Path(arguments[0]).name, arguments[-1]
        if name in self.failures:
            failure = self.failures[name]
            if isinstance(failure, Exception):
                raise failure
            return subprocess.CompletedProcess(arguments, 1, "", failure)
        if name == "otool":
            dependencies = self.dependencies.get(path, ["/usr/lib/libSystem.B.dylib"])
            output = path + ":\n" + "".join(
                "\t" + item + " (compatibility version 1.0.0, current version 1.0.0)\n"
                for item in dependencies)
        elif name == "lipo":
            output = self.architectures.get(path, "arm64") + "\n"
        elif name == "codesign":
            output = ""
        else:
            raise AssertionError("不应启动其他工具或应用：" + str(arguments))
        return subprocess.CompletedProcess(arguments, 0, output, "")


class BundleVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()
        self.app = self.directory / "中文 空格.app"
        self.tools = FixtureTools()
        self.write_plist(self.app, "主程序")
        self.main = self.app / "Contents/MacOS/主程序"
        self.binary(self.main)
        for relative in checker.REQUIRED_FILES:
            self.file(self.app / relative)
        for relative in checker.REQUIRED_DIRECTORIES:
            self.file(self.app / relative / "fixture.txt")
        for relative in checker.REQUIRED_BINARIES.values():
            self.binary(self.app / relative)
        for helper in checker.HELPERS:
            bundle = self.app / "Contents/Frameworks" / (helper + ".app")
            self.write_plist(bundle, helper)
            self.binary(bundle / "Contents/MacOS" / helper)

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def file(path, data=b"fixture"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def binary(self, path, magic=b"\xcf\xfa\xed\xfe"):
        self.file(path, magic + b"synthetic fixture; not a real Mach-O")
        path.chmod(0o755)

    @staticmethod
    def write_plist(bundle, name):
        (bundle / "Contents").mkdir(parents=True, exist_ok=True)
        with (bundle / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": name}, stream)

    def verify(self):
        return checker.verify_bundle(self.app, runner=self.tools)

    @staticmethod
    def codes(report):
        return {item["code"] for item in report["errors"]}

    def test_complete_fixture_reports_static_only_and_does_not_change_bundle(self):
        before = {str(p.relative_to(self.app)): (p.read_bytes(), p.stat().st_mtime_ns)
                  for p in self.app.rglob("*") if p.is_file()}
        report = self.verify()
        self.assertEqual(report["status"], "passed", report["errors"])
        self.assertTrue(report["staticChecksPassed"])
        self.assertFalse(report["runtimeVerified"])
        self.assertFalse(report["offlineEditingVerified"])
        self.assertFalse(report["dynamicResolutionVerified"])
        self.assertEqual({item["role"] for item in report["requiredArchitectures"]},
                         {"main", "converter", "cef", "core", *checker.HELPERS})
        self.assertIn(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(self.app)],
                      self.tools.calls)
        after = {str(p.relative_to(self.app)): (p.read_bytes(), p.stat().st_mtime_ns)
                 for p in self.app.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_magic_detects_extensionless_libraries_without_scanning_adjacent_apps(self):
        for index, magic in enumerate(sorted(checker.MACHO_MAGICS)):
            self.binary(self.app / f"Contents/Resources/opaque-{index}", magic)
        script = self.app / "Contents/Resources/script.dylib"
        self.file(script, b"#!/usr/bin/env python3\n")
        script.chmod(0o755)
        outside = self.directory / "Other.app/Contents/MacOS/Other"
        self.binary(outside)
        report = self.verify()
        detected = {item["path"] for item in report["machO"]}
        self.assertTrue(all(f"Contents/Resources/opaque-{i}" in detected for i in range(8)))
        self.assertNotIn("Contents/Resources/script.dylib", detected)
        self.assertTrue(all(str(outside) not in command for command in self.tools.calls))

    def test_external_absolute_dependencies_are_rejected_and_raw_output_preserved(self):
        references = ["/opt/homebrew/lib/libssl.3.dylib", "/usr/local/lib/a.dylib",
                      "/Users/builder/work with spaces/libb.dylib", "/System/Library/../../outside.dylib"]
        self.tools.dependencies[str(self.main)] = references
        report = self.verify()
        self.assertFalse(report["staticChecksPassed"])
        self.assertEqual({item["detail"] for item in report["errors"]
                          if item["code"] == "externalAbsoluteDependency"}, set(references))
        command = next(item for item in report["commands"] if item["arguments"][-1] == str(self.main))
        self.assertIn(references[2], command["stdout"])

    def test_system_cache_paths_and_unresolved_dynamic_paths_are_distinguished(self):
        references = ["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
                      "/usr/lib/libobjc.A.dylib", "@rpath/Missing.framework/Missing",
                      "@loader_path/libLocal.dylib", "@executable_path/../Frameworks/other", "relative.dylib"]
        self.tools.dependencies[str(self.main)] = references
        report = self.verify()
        self.assertTrue(report["staticChecksPassed"], report["errors"])
        entry = next(item for item in report["machO"] if item["path"] == "Contents/MacOS/主程序")
        self.assertEqual([ref["classification"] for ref in entry["references"]],
                         ["system", "system"] + ["unresolvedRelative"] * 4)
        self.assertFalse(report["dynamicResolutionVerified"])

    def test_framework_internal_symlinks_are_allowed_and_scanned_once(self):
        original = self.app / checker.REQUIRED_BINARIES["cef"]
        actual = original.parent / "Versions/A/Chromium Embedded Framework"
        actual.parent.mkdir(parents=True)
        original.rename(actual)
        original.symlink_to("Versions/Current/Chromium Embedded Framework")
        (original.parent / "Versions/Current").symlink_to("A")
        report = self.verify()
        self.assertTrue(report["staticChecksPassed"], report["errors"])
        self.assertEqual(len(report["symlinks"]), 2)
        self.assertEqual(sum(command[0] == "/usr/bin/otool" and command[-1] == str(actual)
                             for command in self.tools.calls), 1)

    def test_external_and_broken_links_are_rejected_without_recursing_or_signing(self):
        outside = self.directory / "outside"
        self.binary(outside / "payload")
        (self.app / "Contents/escape").symlink_to(outside, target_is_directory=True)
        (self.app / "Contents/dangling").symlink_to("missing")
        report = self.verify()
        self.assertIn("invalidSymlink", self.codes(report))
        self.assertEqual(report["signature"]["status"], "notRun")
        self.assertFalse(any(command[0] == "/usr/bin/codesign" for command in self.tools.calls))
        self.assertFalse(any(str(outside) in command[-1] for command in self.tools.calls))

    def test_missing_empty_and_external_required_resources_fail(self):
        required = self.app / checker.REQUIRED_FILES[0]
        for mode in ("missing", "empty", "external"):
            with self.subTest(mode=mode):
                required.unlink(missing_ok=True)
                if mode == "empty":
                    required.touch()
                elif mode == "external":
                    outside = self.directory / "replacement"
                    outside.write_text("outside")
                    required.symlink_to(outside)
                report = self.verify()
                self.assertIn("missingResource", self.codes(report))

    def test_arm64_is_required_for_main_converter_cef_and_helpers(self):
        for relative in ["Contents/MacOS/主程序", checker.REQUIRED_BINARIES["converter"],
                         checker.REQUIRED_BINARIES["cef"],
                         "Contents/Frameworks/editors_helper.app/Contents/MacOS/editors_helper"]:
            with self.subTest(binary=relative):
                self.tools.architectures = {str(self.app / relative): "x86_64"}
                report = self.verify()
                self.assertIn("missingARM64", self.codes(report))
                failed = [item for item in report["requiredArchitectures"] if not item["ok"]]
                self.assertEqual([item["path"] for item in failed], [relative])
        self.tools.architectures = {str(self.main): "x86_64 arm64"}
        self.assertTrue(self.verify()["staticChecksPassed"])

    def test_invalid_main_binary_or_plist_cannot_pass(self):
        self.main.chmod(0o644)
        self.assertIn("notExecutable", self.codes(self.verify()))
        self.main.write_text("not Mach-O")
        self.assertIn("notMachO", self.codes(self.verify()))
        self.write_plist(self.app, "../../outside")
        self.assertIn("invalidPlist", self.codes(self.verify()))
        (self.app / "Contents/Info.plist").write_bytes(b"<plist><dict>")
        self.assertIn("invalidPlist", self.codes(self.verify()))

    def test_tool_failures_keep_stderr_and_never_become_success(self):
        for name, failure in [("codesign", "a sealed resource is missing or invalid"),
                              ("otool", "truncated or malformed object"),
                              ("lipo", FileNotFoundError("missing lipo")),
                              ("codesign", subprocess.TimeoutExpired("codesign", 60, output=b"partial output"))]:
            with self.subTest(tool=name):
                self.tools.failures = {name: failure}
                report = self.verify()
                self.assertFalse(report["staticChecksPassed"])
                self.assertIn("toolFailed", self.codes(report))
                matching = [item for item in report["commands"] if Path(item["arguments"][0]).name == name]
                self.assertTrue(all(str(failure) in (item.get("error", "") + item["stderr"]) for item in matching))

    def test_otool_universal_headers_spaces_and_unrecognized_output(self):
        output = ("/Some App/Foo (architecture arm64):\n"
                  "\t@rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework (compatibility version 0.0.0, current version 0.0.0)\n"
                  "/Some App/Foo (architecture x86_64):\n"
                  "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 2.0.0)\n")
        self.assertEqual(len(checker.dependency_references(output)), 2)
        with self.assertRaises(ValueError):
            checker.dependency_references("\tunknown output\n")
        with patch.object(checker, "dependency_references", side_effect=ValueError("unrecognized")):
            self.assertIn("dependencyParseFailed", self.codes(self.verify()))

    def test_report_is_exclusive_and_cannot_modify_the_bundle_or_escape_build(self):
        report = self.verify()
        build = self.directory / "build/onlyoffice"
        output = build / "report.json"
        checker.write_report(report, output, build=build)
        self.assertEqual(json.loads(output.read_text())["scope"], "single-app-static-check")
        with self.assertRaises(FileExistsError):
            checker.write_report(report, output, build=build)
        for output in (self.directory / "outside.json", self.app / "report.json"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                checker.write_report(report, output, build=build)
        # 即使 app 位于 build 内，也不允许把报告写进被检查的包。
        with self.assertRaises(ValueError):
            checker.write_report(report, self.app / "report.json", build=self.directory)
        escaped = build / "escape"
        escaped.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            checker.write_report(report, escaped / "out.json", build=build)

    def test_non_app_input_is_rejected_before_running_tools(self):
        report = checker.verify_bundle(self.directory, runner=self.tools)
        self.assertIn("invalidApplication", self.codes(report))
        self.assertEqual(self.tools.calls, [])
        alias = self.directory / "alias.app"
        alias.symlink_to(self.app, target_is_directory=True)
        report = checker.verify_bundle(alias, runner=self.tools)
        self.assertIn("invalidApplication", self.codes(report))
        alias.unlink()
        alias.symlink_to("alias.app")
        report = checker.verify_bundle(alias, runner=self.tools)
        build = self.directory / "build/onlyoffice"
        checker.write_report(report, build / "failure.json", build=build)
        self.assertEqual(json.loads((build / "failure.json").read_text())["status"], "failed")


if __name__ == "__main__":
    unittest.main()
