"""按真实补丁顺序解析临时 Xcode 工程，校验 Swift/ObjC++、框架及资源只接入 ARM。"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/onlyoffice"))
import native_sources
from patches import apply_patch

PROJECT = "macos/ONLYOFFICE.xcodeproj/project.pbxproj"
ARM = "FCB4C6BA26DD018B0012C20D"


def read_project(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))["objects"]


class SwiftWorkbenchProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        upstream = ROOT / "vendor/onlyoffice/desktop-apps"
        if not (upstream / ".git").exists():
            raise unittest.SkipTest("先获取固定的桌面源码；本测试不启动 Xcode 构建。")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / PROJECT
            path.parent.mkdir(parents=True)
            path.write_bytes(subprocess.check_output(["git", "-C", str(upstream), "show",
                                                      "8f452c7f703b795dcc09012ba6517df4ca47f9bc:" + PROJECT]))
            for name in ["desktop-apps-001-smoke-hooks.patch", "desktop-apps-002-cef-signing.patch",
                         "desktop-apps-003-swift-workbench.patch", "desktop-apps-007-embedded-browser.patch",
                         "desktop-apps-009-preview-modal.patch", "desktop-apps-010-new-file-templates.patch",
                         "desktop-apps-011-draft-recovery.patch", "desktop-apps-012-directory-search.patch"]:
                if name.startswith("desktop-apps-003"):
                    cls.before = read_project(path)
                subprocess.run(["git", "-C", str(directory), "apply", "--include=" + PROJECT,
                                str(ROOT / "scripts/onlyoffice/patches" / name)], check=True, capture_output=True)
            cls.after = read_project(path)
            subprocess.run(["git", "-C", str(directory), "apply", "--reverse", "--check",
                            str(ROOT / "scripts/onlyoffice/patches/desktop-apps-003-swift-workbench.patch")],
                           check=True, capture_output=True)

    def phase_files(self, objects, target, kind):
        phase = next(objects[key] for key in objects[target]["buildPhases"] if objects[key]["isa"] == kind)
        return [objects[objects[key]["fileRef"]] for key in phase["files"]]

    def test_sources_match_explicit_sync_manifest_and_smoke_remains_compiled(self):
        old = {item["path"] for item in self.phase_files(self.before, ARM, "PBXSourcesBuildPhase")}
        new = {item["path"] for item in self.phase_files(self.after, ARM, "PBXSourcesBuildPhase")}
        expected = set(native_sources.SHARED_SWIFT_SOURCES + native_sources.WORKBENCH_SWIFT_SOURCES)
        expected.add("FWWorkbenchCoordinator.mm")
        self.assertEqual(new - old, expected)
        self.assertTrue(old.issubset(new))
        self.assertIn("FileWorkbenchSmoke/FWOfficeSmoke.mm", new)
        self.assertNotIn("FileWorkbenchApp.swift", new)
        self.assertIn("ContentView.swift", new)
        self.assertIn("WorkspaceEditorBridge.swift", new)
        self.assertIn("NewFileTemplate.swift", new)
        groups = [obj for obj in self.after.values() if obj.get("isa") == "PBXGroup"
                  and obj.get("path") in {"FileWorkbenchNative", "../FileWorkbenchNative"}]
        self.assertEqual({self.after[key]["path"] for group in groups for key in group["children"]},
                         expected | {"FWWorkbenchCoordinator.h"})

    def test_only_arm_target_receives_swift_settings_sources_and_resources(self):
        for key, target in self.before.items():
            if target.get("isa") != "PBXNativeTarget" or key == ARM:
                continue
            self.assertEqual(target, self.after[key])
            for phase in target["buildPhases"]:
                self.assertEqual(self.before[phase], self.after[phase])
            for config in self.before[target["buildConfigurationList"]]["buildConfigurations"]:
                self.assertEqual(self.before[config], self.after[config])
        for key in self.after[self.after[ARM]["buildConfigurationList"]]["buildConfigurations"]:
            settings = self.after[key]["buildSettings"]
            self.assertEqual(settings["PRODUCT_MODULE_NAME"], "FileWorkbenchNative")
            self.assertEqual(settings["SWIFT_OBJC_INTERFACE_HEADER_NAME"], "FileWorkbenchNative-Swift.h")
            self.assertEqual(settings["SWIFT_VERSION"], "5.0")
            self.assertEqual(settings["MACOSX_DEPLOYMENT_TARGET"], "14.0")
            self.assertIn("FW_WORKBENCH_ENABLED=1", settings["GCC_PREPROCESSOR_DEFINITIONS"])
            self.assertEqual(settings["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"], "YES")
            self.assertEqual(settings["ENABLE_DEBUG_DYLIB"], "NO")
            self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "local.fileworkbench.desktop")
            self.assertEqual(settings["PRODUCT_NAME"], "ONLYOFFICE")

    def test_system_frameworks_and_editor_folder_are_linked_without_resource_flattening(self):
        frameworks = self.phase_files(self.after, ARM, "PBXFrameworksBuildPhase")
        actual = {item.get("name") for item in frameworks}
        for name in ["SwiftUI", "WebKit", "PDFKit", "ImageIO", "QuickLookUI", "CryptoKit", "UniformTypeIdentifiers"]:
            self.assertIn(name + ".framework", actual)
        resources = self.phase_files(self.after, ARM, "PBXResourcesBuildPhase")
        folder = next(item for item in resources if item.get("path") == "FileWorkbenchEditors")
        self.assertEqual(folder["lastKnownFileType"], "folder")
        self.assertEqual(folder["sourceTree"], "<group>")
        # 不单独登记 index.html，否则 Copy Bundle Resources 会把目录打平。
        self.assertFalse(any(item.get("path") == "FileWorkbenchEditors/index.html" for item in resources))

    def test_complete_desktop_patch_chain_remains_reentrant_after_later_shell_changes(self):
        upstream = ROOT / "vendor/onlyoffice/desktop-apps"
        patches = sorted((ROOT / "scripts/onlyoffice/patches").glob("desktop-apps-*.patch"))
        paths = {line[len("--- a/"):].split("\t", 1)[0]
                 for patch in patches for line in patch.read_text().splitlines() if line.startswith("--- a/")}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            for name in paths:
                target = directory / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(subprocess.check_output(["git", "-C", str(upstream), "show",
                                                            "8f452c7f703b795dcc09012ba6517df4ca47f9bc:" + name]))
            for patch in patches:
                self.assertTrue(apply_patch(directory, patch))
            # 后续补丁可能修改前一补丁的上下文；逐个反向检查必须仍能确认已应用。
            for patch in patches:
                self.assertFalse(apply_patch(directory, patch))
