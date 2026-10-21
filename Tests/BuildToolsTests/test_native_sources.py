"""本地原生扩展同步不得覆盖用户对 vendor 的手工修改。"""

from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
from native_sources import sync_sources
import native_sources as native


class NativeSourcesTests(unittest.TestCase):
    def test_repeat_update_and_conflict_preserve_user_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            origin = root / "origin"
            origin.mkdir()
            destination = root / "vendor-input"
            manifest = root / "manifest.json"
            for name in ("FWOfficeSmoke.h", "FWOfficeSmoke.mm"):
                (origin / name).write_text("initial\n")
            sync_sources(origin, destination, manifest)
            timestamp = (destination / "FWOfficeSmoke.mm").stat().st_mtime_ns
            sync_sources(origin, destination, manifest)
            self.assertEqual((destination / "FWOfficeSmoke.mm").stat().st_mtime_ns, timestamp)
            (origin / "FWOfficeSmoke.mm").write_text("updated\n")
            sync_sources(origin, destination, manifest)
            self.assertEqual((destination / "FWOfficeSmoke.mm").read_text(), "updated\n")
            (destination / "FWOfficeSmoke.mm").write_text("user edit\n")
            (origin / "FWOfficeSmoke.h").write_text("pending update\n")
            with self.assertRaises(RuntimeError):
                sync_sources(origin, destination, manifest)
            self.assertEqual((destination / "FWOfficeSmoke.mm").read_text(), "user edit\n")
            self.assertEqual((destination / "FWOfficeSmoke.h").read_text(), "initial\n")

    def test_destination_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            actual = root / "actual"
            actual.mkdir()
            link = root / "link"
            link.symlink_to(actual, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                sync_sources(root, link, root / "manifest.json")
            self.assertEqual(list(actual.iterdir()), [])


class WorkbenchNativeSourcesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "vendor/onlyoffice"
        self.build = self.root / "build"
        self.destination = self.source / "desktop-apps/macos/ONLYOFFICE"
        for path in native.workbench_inputs(self.root).values():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// fixture " + path.name + "\n")
        smoke = self.root / "NativeOffice/Smoke"
        smoke.mkdir(parents=True)
        for name in native.SMOKE_SOURCES:
            (smoke / name).write_text("smoke fixture\n")
        self.editors = self.root / "Resources/Editors"
        self.editors.mkdir(parents=True)
        for name in native.REQUIRED_EDITOR_RESOURCES:
            (self.editors / name).write_text("fixture " + name + "\n")
        self.update_resource_manifest()

    def update_resource_manifest(self):
        files = {name: native.digest((self.editors / name).read_bytes())
                 for name in native.REQUIRED_EDITOR_RESOURCES}
        (self.editors / "manifest.json").write_text(json.dumps({"schema": 1, "files": files}))

    def prepare(self):
        native.prepare_native_sources(self.root, self.source, self.build)

    def test_complete_shared_native_resources_and_smoke_are_synced_without_old_entry_point(self):
        (self.root / "Sources/FileWorkbench/FileWorkbenchApp.swift").write_text("@main // excluded")
        self.prepare()
        target = self.destination / "FileWorkbenchNative"
        self.assertEqual({path.name for path in target.iterdir()}, set(native.workbench_inputs(self.root)))
        self.assertIn("ContentView.swift", native.workbench_inputs(self.root))
        self.assertNotIn("FileWorkbenchApp.swift", native.workbench_inputs(self.root))
        self.assertTrue((self.destination / "FileWorkbenchSmoke/FWOfficeSmoke.mm").is_file())
        resources = self.destination / "FileWorkbenchEditors"
        native.verify_editor_bundle(resources, self.editors)
        stamp = (target / "DocumentIO.swift").stat().st_mtime_ns
        self.prepare()
        self.assertEqual((target / "DocumentIO.swift").stat().st_mtime_ns, stamp)
        (resources / "editor.js").write_text("tampered bundle")
        with self.assertRaisesRegex(RuntimeError, "摘要不一致"):
            native.verify_editor_bundle(resources, self.editors)

    def test_missing_coordinator_fails_before_publishing_smoke_or_resources(self):
        (self.root / "NativeOffice/Workbench/FWWorkbenchCoordinator.mm").unlink()
        with self.assertRaisesRegex(RuntimeError, "缺少原生构建输入.*FWWorkbenchCoordinator.mm"):
            self.prepare()
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.build.exists())

    def test_resource_hash_failure_and_unregistered_file_prevent_any_publication(self):
        (self.editors / "editor.js").write_text("changed without manifest")
        with self.assertRaisesRegex(RuntimeError, "摘要不一致"):
            self.prepare()
        self.assertFalse(self.destination.exists())
        self.update_resource_manifest()
        (self.editors / "untracked.js").write_text("not in explicit resource manifest")
        with self.assertRaisesRegex(RuntimeError, "未登记"):
            self.prepare()
        self.assertFalse(self.destination.exists())

    def test_resource_conflict_preserves_all_source_sets_and_existing_manifest(self):
        self.prepare()
        target = self.destination / "FileWorkbenchEditors/editor.js"
        target.write_text("user resource edit")
        smoke = self.destination / "FileWorkbenchSmoke/FWOfficeSmoke.h"
        previous = smoke.read_bytes()
        (self.root / "NativeOffice/Smoke/FWOfficeSmoke.h").write_text("pending smoke update")
        with self.assertRaisesRegex(RuntimeError, "本地修改"):
            self.prepare()
        self.assertEqual(smoke.read_bytes(), previous)
        self.assertEqual(target.read_text(), "user resource edit")

    def test_retired_inputs_are_removed_only_when_previous_digest_still_matches(self):
        origin = self.root / "retired.swift"
        origin.write_text("old source")
        target = self.root / "generated"
        manifest = self.root / "generated.json"
        native.publish_plans([native.plan_sync({"retired.swift": origin}, target, manifest)])
        (target / "retired.swift").write_text("user edit")
        with self.assertRaisesRegex(RuntimeError, "已撤下.*本地修改"):
            native.plan_sync({}, target, manifest)
        (target / "retired.swift").write_bytes(origin.read_bytes())
        native.publish_plans([native.plan_sync({}, target, manifest)])
        self.assertFalse((target / "retired.swift").exists())

    def test_nested_target_link_cannot_escape_destination(self):
        origin = self.root / "fixture.swift"
        origin.write_text("source")
        target = self.root / "generated"
        target.mkdir()
        other = self.root / "other"
        other.mkdir()
        (target / "nested").symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "符号链接"):
            native.plan_sync({"nested/file.swift": origin}, target, self.root / "generated.json")
        self.assertEqual(list(other.iterdir()), [])
