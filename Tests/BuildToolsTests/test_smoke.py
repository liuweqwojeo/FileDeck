"""仅验证验收器的产物校验逻辑；这些合成夹具不代表真正的 Office 引擎验收通过。"""

import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
from smoke import (CASES, REQUIRED_STAGES, RECOVERY_STAGES, RECOVERY_FILE, RECOVERY_DRAFT_SUFFIX,
                   WORKBENCH_TEST_SUITE_PREFIX, app_executable, create_run_directory, run,
                   verify_ooxml, verify_run, write_new_json)


class SmokeVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.parent = Path(self.temporary.name).resolve()
        self.directory, self.request = create_run_directory(self.parent, 120)
        self.marker = self.request["marker"]

    def tearDown(self):
        self.temporary.cleanup()

    def package(self, extension, parts):
        path = self.directory / CASES[extension]
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("[Content_Types].xml", "<Types/>")
            for name, value in parts.items():
                archive.writestr(name, value)
        return path

    def fixtures(self):
        word = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>{}</w:t></w:r><w:r><w:t>{}</w:t></w:r></w:p></w:body></w:document>'
        self.package("docx", {"word/document.xml": word.format(self.marker[:6], self.marker[6:])})
        strings = '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>{}</t></si></sst>'
        sheet = '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>'
        self.package("xlsx", {"xl/sharedStrings.xml": strings.format(self.marker), "xl/worksheets/sheet1.xml": sheet})
        slide = '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:p><a:r><a:t>{}</a:t></a:r></a:p></p:sld>'
        self.package("pptx", {"ppt/slides/slide1.xml": slide.format(self.marker)})

    def result(self, **overrides):
        cases = [{"format": extension, "file": name, "marker": self.marker,
                  **{stage: True for stage in REQUIRED_STAGES}} for extension, name in CASES.items()]
        return {"schemaVersion": 1, "token": self.request["token"], "status": "passed",
                "profileIsolated": True, "cases": cases, **overrides}

    def write_result(self, **overrides):
        write_new_json(self.directory / "native-result.json", self.result(**overrides))

    def test_new_private_directories_never_reuse_existing_run(self):
        other, request = create_run_directory(self.parent, 120)
        self.assertNotEqual(other, self.directory)
        self.assertNotEqual(request["token"], self.request["token"])
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        with self.assertRaises(FileExistsError):
            write_new_json(self.directory / "request.json", {"replace": True})
        self.assertEqual(json.loads((self.directory / "request.json").read_text())["token"], self.request["token"])

    def test_launch_replaces_inherited_workbench_suite_with_request_token(self):
        # 不启动应用；检查实际 Popen 的环境，避免只验证 manifest 而漏掉启动参数。
        with patch.dict(os.environ, {"FW_WORKBENCH_TEST_SUITE": "local.fileworkbench.desktop"}), \
                patch("smoke.app_executable", return_value=self.parent / "Fixture"), \
                patch("smoke.subprocess.Popen") as launch, \
                patch("smoke.verify_run", return_value={"status": "passed"}):
            launch.return_value.wait.return_value = 0
            report = run(self.parent / "Fixture.app", self.parent, 120)
        self.assertTrue(report["executionVerified"])
        arguments = launch.call_args.kwargs
        request = json.loads((arguments["cwd"] / "request.json").read_text())
        expected = WORKBENCH_TEST_SUITE_PREFIX + request["token"]
        self.assertEqual(request["workbenchTestSuite"], expected)
        self.assertEqual(arguments["env"]["FW_WORKBENCH_TEST_SUITE"], expected)
        self.assertEqual(arguments["env"]["FW_OFFICE_SMOKE_TOKEN"], request["token"])
        self.assertEqual(arguments["env"]["CFFIXED_USER_HOME"], str(arguments["cwd"] / "preferences-home"))

    def test_complete_native_stages_and_actual_body_text_are_required(self):
        self.fixtures()
        self.write_result()
        report = verify_run(self.directory)
        self.assertEqual(report["status"], "passed")
        self.assertEqual([case["format"] for case in report["cases"]], list(CASES))
        self.assertEqual(report["cases"][0]["markerParts"], ["word/document.xml"])

    def test_recorded_workbench_suite_must_match_request_token(self):
        self.fixtures()
        self.write_result()
        self.assertEqual(verify_run(self.directory)["workbenchTestSuite"], self.request["workbenchTestSuite"])
        self.request["workbenchTestSuite"] = "local.fileworkbench.desktop"
        (self.directory / "request.json").write_text(json.dumps(self.request))
        with self.assertRaisesRegex(RuntimeError, "偏好域"):
            verify_run(self.directory)

    def test_metadata_marker_does_not_count_as_document_content(self):
        path = self.package("docx", {
            "word/document.xml": '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:t>空文档</w:t></w:document>',
            "docProps/core.xml": "<metadata>" + self.marker + "</metadata>"})
        with self.assertRaisesRegex(RuntimeError, "正文"):
            verify_ooxml(path, "docx", self.marker)

    def test_compressed_resources_require_native_evidence_for_each_editor(self):
        self.fixtures()
        self.request["compressionSamples"] = []
        (self.directory / "request.json").write_text(json.dumps(self.request))
        result = self.result()
        path = self.directory / "native-result.json"
        path.write_text(json.dumps(result))
        with self.assertRaisesRegex(RuntimeError, "压缩资源"):
            verify_run(self.directory)
        for case in result["cases"]:
            case["compressedResourcesVerified"] = True
        path.write_text(json.dumps(result))
        self.assertTrue(verify_run(self.directory)["compressedResourcesVerified"])
        result["cases"][-1]["compressedResourcesVerified"] = False
        path.write_text(json.dumps(result))
        with self.assertRaisesRegex(RuntimeError, "压缩资源"):
            verify_run(self.directory)

    def test_workbench_requires_all_native_stages_and_exact_saved_text(self):
        self.fixtures()
        self.request["workbench"] = True
        (self.directory / "request.json").write_text(json.dumps(self.request))
        self.write_result()
        with self.assertRaisesRegex(RuntimeError, "混合文档"):
            verify_run(self.directory)
        stages = {name: True for name in ["passed", "textEditedInWebKit", "nativeSaveRoutedWhileSwitching",
                  "nativeCloseVerified", "pdfNativeTabVerified", "officeRetainedUnsavedChanges",
                  "browserEmbedded", "editorStillInBrowserWindow", "modalWindowCloseProtected", "modalQuitProtected", "modalDiscardClosed", "officeSaveAndReturnVerified", "nativeSaveAndReturnVerified"]}
        result = self.result(workbench=stages)
        (self.directory / "native-result.json").write_text(json.dumps(result))
        output = self.directory / "mixed.txt"
        output.write_bytes((self.marker + "\n").encode())
        with self.assertRaisesRegex(RuntimeError, "换行"):
            verify_run(self.directory)
        output.write_bytes((self.marker + "\r\n").encode())
        self.assertTrue(verify_run(self.directory)["workbench"]["passed"])
        # 单窗布局也是验收契约：不能用旧版混合标签报告证明浏览页面已经承载编辑器。
        for stage in ("nativeSaveRoutedWhileSwitching", "browserEmbedded", "editorStillInBrowserWindow", "modalWindowCloseProtected", "modalQuitProtected", "modalDiscardClosed", "officeSaveAndReturnVerified", "nativeSaveAndReturnVerified"):
            with self.subTest(stage=stage):
                incomplete = {**stages, stage: False}
                (self.directory / "native-result.json").write_text(json.dumps(self.result(workbench=incomplete)))
                with self.assertRaisesRegex(RuntimeError, "混合文档"):
                    verify_run(self.directory)

    def recovery_fixture(self):
        """明确标注的合成结果只测试校验器；真实面板由完整应用与外部 UI 操作验收。"""
        self.fixtures()
        self.request.update(workbench=True, recoveryPanel=True)
        (self.directory / "request.json").write_text(json.dumps(self.request))
        workbench = {name: True for name in ["passed", "textEditedInWebKit", "nativeSaveRoutedWhileSwitching",
                    "nativeCloseVerified", "pdfNativeTabVerified", "officeRetainedUnsavedChanges",
                    "browserEmbedded", "editorStillInBrowserWindow", "modalWindowCloseProtected",
                    "modalQuitProtected", "modalDiscardClosed", "officeSaveAndReturnVerified", "nativeSaveAndReturnVerified"]}
        recovery = {stage: True for stage in RECOVERY_STAGES}
        recovery.update(sourceFile="mixed.txt", destinationFile=RECOVERY_FILE,
                        lastSavedPath=str(self.directory / RECOVERY_FILE),
                        panelSelectedPath=str(self.directory / RECOVERY_FILE))
        (self.directory / "mixed.txt").write_bytes((self.marker + "\r\n").encode())
        (self.directory / RECOVERY_FILE).write_bytes((self.marker + RECOVERY_DRAFT_SUFFIX).encode())
        result = self.result(workbench=workbench, recoveryPanel=recovery)
        (self.directory / "native-result.json").write_text(json.dumps(result))
        checkpoint = {"schemaVersion": 1, "token": self.request["token"], "phase": "completed",
                      "directory": str(self.directory), "sourceFile": "mixed.txt", "expectedFileName": RECOVERY_FILE,
                      "expectedPath": str(self.directory / RECOVERY_FILE), "checks": recovery}
        (self.directory / "recovery-panel-checkpoint.json").write_text(json.dumps(checkpoint))
        return result, checkpoint

    def test_recovery_panel_request_always_enables_isolated_workbench(self):
        directory, request = create_run_directory(self.parent, 120, recovery_panel=True)
        self.assertTrue(request["recoveryPanel"])
        self.assertTrue(request["workbench"])
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertNotIn("recoveryPanel", self.request)

    def test_recovery_panel_requires_each_real_stage(self):
        result, _ = self.recovery_fixture()
        self.assertTrue(verify_run(self.directory)["recoveryPanel"]["passed"])
        for stage in RECOVERY_STAGES:
            with self.subTest(stage=stage):
                incomplete = {**result, "recoveryPanel": {**result["recoveryPanel"], stage: False}}
                (self.directory / "native-result.json").write_text(json.dumps(incomplete))
                with self.assertRaisesRegex(RuntimeError, "系统面板"):
                    verify_run(self.directory)

    def test_recovery_panel_requires_workbench_and_exact_system_selected_path(self):
        result, _ = self.recovery_fixture()
        for field in ("sourceFile", "destinationFile", "lastSavedPath", "panelSelectedPath"):
            with self.subTest(field=field):
                wrong = {**result, "recoveryPanel": {**result["recoveryPanel"], field: "../wrong"}}
                (self.directory / "native-result.json").write_text(json.dumps(wrong))
                with self.assertRaisesRegex(RuntimeError, "路径"):
                    verify_run(self.directory)
        (self.directory / "native-result.json").write_text(json.dumps(result))
        self.request["workbench"] = False
        (self.directory / "request.json").write_text(json.dumps(self.request))
        with self.assertRaisesRegex(RuntimeError, "系统面板"):
            verify_run(self.directory)

    def test_recovery_panel_checks_complete_source_and_draft_bytes(self):
        self.recovery_fixture()
        recovered = self.directory / RECOVERY_FILE
        recovered.write_text(self.marker)
        with self.assertRaisesRegex(RuntimeError, "完整内容"):
            verify_run(self.directory)
        recovered.write_bytes((self.marker + RECOVERY_DRAFT_SUFFIX).encode())
        (self.directory / "mixed.txt").write_text(self.marker + "\n")
        with self.assertRaisesRegex(RuntimeError, "换行"):
            verify_run(self.directory)
        (self.directory / "mixed.txt").write_bytes((self.marker + "\r\n").encode())
        outside = self.parent / "outside.txt"
        outside.write_bytes(recovered.read_bytes())
        recovered.unlink()
        recovered.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, "普通文件"):
            verify_run(self.directory)

    def test_recovery_checkpoint_must_belong_to_completed_run(self):
        _, checkpoint = self.recovery_fixture()
        for override in ({"token": "other"}, {"phase": "awaiting-save"}, {"directory": str(self.parent)},
                         {"expectedPath": "../outside"}, {"checks": {"passed": True}}):
            with self.subTest(override=override):
                (self.directory / "recovery-panel-checkpoint.json").write_text(json.dumps({**checkpoint, **override}))
                with self.assertRaisesRegex(RuntimeError, "进度"):
                    verify_run(self.directory)

    def test_xlsx_shared_string_must_be_referenced_by_cell(self):
        path = self.package("xlsx", {
            "xl/sharedStrings.xml": '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>' + self.marker + '</t></si></sst>',
            "xl/worksheets/sheet1.xml": '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>'})
        with self.assertRaisesRegex(RuntimeError, "正文"):
            verify_ooxml(path, "xlsx", self.marker)

    def test_xlsx_inline_strings_are_supported(self):
        path = self.package("xlsx", {
            "xl/worksheets/sheet1.xml": '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row><c t="inlineStr"><is><t>' + self.marker + '</t></is></c></row></sheetData></worksheet>'})
        self.assertEqual(verify_ooxml(path, "xlsx", self.marker)["markerParts"], ["xl/worksheets/sheet1.xml"])

    def test_failed_missing_incomplete_or_wrong_token_native_result_rejected(self):
        self.fixtures()
        with self.assertRaises(FileNotFoundError):
            verify_run(self.directory)
        for override in [{"status": "failed", "error": "deadline"}, {"token": "other"},
                         {"profileIsolated": False}, {"cases": []}]:
            with self.subTest(override=override):
                (self.directory / "native-result.json").write_text(json.dumps(self.result(**override)))
                with self.assertRaises(RuntimeError):
                    verify_run(self.directory)
        for stage in REQUIRED_STAGES:
            result = self.result()
            result["cases"][0][stage] = False
            (self.directory / "native-result.json").write_text(json.dumps(result))
            with self.assertRaisesRegex(RuntimeError, "未完成"):
                verify_run(self.directory)

    def test_untrusted_manifest_cannot_select_output_outside_run(self):
        self.fixtures()
        result = self.result()
        result["cases"][0]["file"] = "../outside.docx"
        write_new_json(self.directory / "native-result.json", result)
        with self.assertRaisesRegex(RuntimeError, "路径"):
            verify_run(self.directory)

    def test_output_symlink_and_archive_traversal_are_rejected(self):
        outside = self.parent / "keep.docx"
        outside.write_text("unchanged")
        target = self.directory / "word.docx"
        target.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, "普通文件"):
            verify_ooxml(target, "docx", self.marker)
        target.unlink()
        path = self.package("docx", {"../escape.xml": "text"})
        with self.assertRaisesRegex(RuntimeError, "路径"):
            verify_ooxml(path, "docx", self.marker)
        self.assertEqual(outside.read_text(), "unchanged")

    def test_archive_uncompressed_size_is_bounded(self):
        path = self.package("docx", {"word/document.xml": "a" * 200})
        with patch("smoke.MAX_ZIP_BYTES", 100), self.assertRaises(RuntimeError):
            verify_ooxml(path, "docx", self.marker)

    def test_app_bundle_executable_validation(self):
        app = self.parent / "Fixture.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        executable = app / "Contents" / "MacOS" / "Fixture"
        executable.write_bytes(b"test fixture, not an app")
        executable.chmod(0o700)
        with (app / "Contents" / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "Fixture"}, stream)
        self.assertEqual(app_executable(app), executable)
        with (app / "Contents" / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "../../outside"}, stream)
        with self.assertRaisesRegex(RuntimeError, "CFBundleExecutable"):
            app_executable(app)


if __name__ == "__main__":
    unittest.main()
