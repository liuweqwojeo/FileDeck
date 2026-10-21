"""在临时应用目录执行补丁后的真实签名脚本；不签名或改动实际构建产物。"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / "scripts/onlyoffice/patches"
PROJECT = "macos/ONLYOFFICE.xcodeproj/project.pbxproj"
COMMIT = "8f452c7f703b795dcc09012ba6517df4ca47f9bc"
ARM_PHASE = "FCB4C73226DD018B0012C20D"


def read_project(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


class CEFSigningTests(unittest.TestCase):
    def setUp(self):
        source = ROOT / "vendor/onlyoffice/desktop-apps"
        if not (source / ".git").exists():
            self.skipTest("获取固定上游源码后才运行 Xcode 签名阶段测试。")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "onlyoffice/desktop-apps"
        self.pbxproj = self.project / PROJECT
        self.pbxproj.parent.mkdir(parents=True)
        original = subprocess.check_output(["git", "-C", str(source), "show", COMMIT + ":" + PROJECT], text=True)
        self.pbxproj.write_text(original)
        self.original = read_project(self.pbxproj)
        # 与真实顺序一致，先应用烟测工程接线，再应用签名补丁；只触碰临时 pbxproj。
        for patch in ["desktop-apps-001-smoke-hooks.patch", "desktop-apps-002-cef-signing.patch"]:
            subprocess.run(["git", "-C", str(self.project), "apply", "--include=" + PROJECT,
                            str(PATCHES / patch)], check=True, capture_output=True)
        self.patched = read_project(self.pbxproj)
        self.core = self.root / "onlyoffice/build_tools/out/mac_arm64/onlyoffice/desktopeditors"
        self.frameworks = self.root / "构建 输出/ONLYOFFICE.app/Contents/Frameworks"
        self.contents = self.frameworks.parent
        self.converter = self.contents / "Resources/converter"
        self.frameworks.mkdir(parents=True)
        self.converter.mkdir(parents=True)
        for name in ["editors_helper.app", "editors_helper (GPU).app", "editors_helper (Renderer).app",
                     "ascdocumentscore.framework/Versions/Current", "hunspell.framework/Versions/Current"]:
            (self.core / name).mkdir(parents=True)
        self.libraries = self.core / "Chromium Embedded Framework.framework/Libraries"
        self.libraries.mkdir(parents=True)
        for name in ["libEGL.dylib", "libGLESv2.dylib", "libvk_swiftshader.dylib"]:
            (self.libraries / name).touch()
        (self.converter / "x2t").touch()
        (self.converter / "中文 converter.framework/Versions/Current").mkdir(parents=True)
        (self.contents / "MacOS").mkdir()
        (self.contents / "MacOS/ONLYOFFICE").touch()
        for name in ["Updater.app/Contents/MacOS/Updater", "Autoupdate",
                     "XPCServices/org.sparkle-project.Downloader.xpc/Contents/MacOS/org.sparkle-project.Downloader",
                     "XPCServices/org.sparkle-project.InstallerLauncher.xpc/Contents/MacOS/org.sparkle-project.InstallerLauncher"]:
            path = self.frameworks / "Sparkle.framework/Versions/B" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        # 只替代外部签名和 Mach-O 工具，不改写脚本的分支、返回码或文件复制逻辑。
        mock = """#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ['FW_COMMAND_LOG'], 'a') as output:
    output.write(json.dumps([pathlib.Path(sys.argv[0]).name] + sys.argv[1:]) + '\\n')
target = sys.argv[-1]
if not pathlib.Path(target).exists() or os.environ.get('FW_FAIL_TARGET') == target:
    sys.exit(73)
"""
        for name in ["codesign", "install_name_tool"]:
            path = self.bin / name
            path.write_text(mock)
            path.chmod(0o755)
        script = self.patched["objects"][ARM_PHASE]["shellScript"]
        self.script = self.root / "sign.sh"
        self.script.write_text(script.replace("/usr/bin/codesign ", "codesign "))
        self.environment = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                            "CONFIGURATION_BUILD_DIR": str(self.contents.parent.parent),
                            "CONTENTS_FOLDER_PATH": "ONLYOFFICE.app/Contents",
                            "BUILT_PRODUCTS_DIR": str(self.contents.parent.parent),
                            "FRAMEWORKS_FOLDER_PATH": "ONLYOFFICE.app/Contents/Frameworks",
                            "EXPANDED_CODE_SIGN_IDENTITY": "-", "EXPANDED_CODE_SIGN_IDENTITY_NAME": "Ad hoc",
                            "CODE_SIGNING_REQUIRED": "YES", "CODE_SIGNING_ALLOWED": "YES",
                            "CODE_SIGN_ENTITLEMENTS": str(self.root / "fixture.entitlements"),
                            "OTHER_CODE_SIGN_FLAGS": "", "FW_COMMAND_LOG": str(self.log)}

    def run_script(self, failure=None):
        environment = dict(self.environment)
        if failure:
            environment["FW_FAIL_TARGET"] = str(failure)
        result = subprocess.run(["/bin/sh", str(self.script)], cwd=self.project / "macos",
                                env=environment, capture_output=True, text=True)
        commands = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, commands

    def test_patch_changes_only_arm_script_and_reverse_check_is_valid(self):
        before = self.original["objects"]
        after = self.patched["objects"]
        changed = [key for key, value in before.items() if value.get("isa") == "PBXShellScriptBuildPhase"
                   and value != after[key]]
        self.assertEqual(changed, [ARM_PHASE])
        subprocess.run(["git", "-C", str(self.project), "apply", "--reverse", "--check",
                        str(PATCHES / "desktop-apps-002-cef-signing.patch")], check=True, capture_output=True)

    def test_current_cef_without_legacy_swiftshader_libraries_signs_successfully(self):
        result, commands = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        signed = [arguments[-1] for arguments in commands if arguments[0] == "codesign"]
        self.assertIn(str(self.converter / "中文 converter.framework/Versions/Current"), signed)
        self.assertFalse(any("libswiftshader_lib" in path for path in signed))
        self.assertEqual(signed[-1], str(self.contents / "MacOS/ONLYOFFICE"))

    def test_present_optional_libraries_are_signed_and_failures_stop_the_phase(self):
        for name in ["libswiftshader_libEGL.dylib", "libswiftshader_libGLESv2.dylib"]:
            (self.libraries / name).touch()
        failure = self.frameworks / "Chromium Embedded Framework.framework/Libraries/libswiftshader_libGLESv2.dylib"
        result, commands = self.run_script(failure)
        self.assertEqual(result.returncode, 73)
        self.assertEqual(commands[-1][-1], str(failure))
        self.assertTrue(any(arguments[-1].endswith("libswiftshader_libEGL.dylib") for arguments in commands))

    def test_required_library_signing_failure_is_not_hidden_by_later_success(self):
        failure = self.frameworks / "Chromium Embedded Framework.framework/Libraries/libEGL.dylib"
        result, commands = self.run_script(failure)
        self.assertEqual(result.returncode, 73)
        self.assertEqual(commands[-1][-1], str(failure))

    def test_framework_signing_failure_also_stops_inside_guarded_function(self):
        failure = self.frameworks / "ascdocumentscore.framework/Versions/Current"
        result, commands = self.run_script(failure)
        self.assertEqual(result.returncode, 73)
        self.assertEqual(commands[-1][-1], str(failure))

    def test_required_copy_failure_stops_before_any_signing(self):
        (self.core / "editors_helper (GPU).app").rmdir()
        result, commands = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])


if __name__ == "__main__":
    unittest.main()
