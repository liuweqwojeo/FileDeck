"""验证发布元数据与报告写入边界；原生签名另由真实应用验收覆盖。"""

import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
import package_app as packager
import compress_help as help_compressor
import compress_dictionaries as dictionary_compressor


class PackagingBoundaryTests(unittest.TestCase):
    def setUp(self):
        # 这些既有用例只隔离测试复制/压缩/发布事务；完整门禁由下方集成用例覆盖。
        gate = patch.object(packager, "verify_bundle", return_value={"staticChecksPassed": True, "buildIdentity": {}})
        gate.start()
        self.addCleanup(gate.stop)

    def fixture(self, root):
        source = root / "source.app"
        contents = source / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        (contents / "Resources/FileWorkbenchEditors").mkdir()
        (contents / "Resources/FileWorkbenchEditors/manifest.json").write_text("{}")
        (contents / "Frameworks/Chromium Embedded Framework.framework").mkdir(parents=True)
        for name in ("ascdocumentscore", "hunspell"):
            binary = contents / "Frameworks" / (name + ".framework") / name
            binary.parent.mkdir()
            binary.write_bytes(b"framework fixture")
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "FileDeck"}))
        (contents / "MacOS/FileDeck").write_bytes(b"native executable fixture")
        (root / "Resources").mkdir()
        (root / "Resources/FileDeck.icns").write_bytes(b"icon fixture")
        help_page = source / help_compressor.HELP_ROOTS[1] / "en/index.htm"
        help_page.parent.mkdir(parents=True)
        help_page.write_bytes(b"offline help " * 300)
        return source, help_page

    @staticmethod
    def fake_run(arguments, **kwargs):
        if arguments[0] == "/usr/bin/ditto":
            shutil.copytree(arguments[1], arguments[2], dirs_exist_ok=True, symlinks=True)
        return subprocess.CompletedProcess(arguments, 0)

    @staticmethod
    def supported_symbols(arguments, **kwargs):
        if arguments[-1].endswith("/hunspell"):
            return "_FWCompressedHunspellVersion\n"
        return "_FWCompressedHelpVersion\n_FWCompressedDictionariesVersion\n"

    def test_complete_upstream_and_branded_apps_can_be_repackaged_without_changing_source(self):
        for executable in ("ONLYOFFICE", "FileDeck"):
            with self.subTest(executable=executable), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, destination = root / "source.app", root / "output.app"
                contents = source / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                (contents / "Resources").mkdir()
                (contents / "Resources/FileWorkbenchEditors").mkdir()
                (contents / "Resources/FileWorkbenchEditors/manifest.json").write_text("{}")
                (contents / "Frameworks/Chromium Embedded Framework.framework").mkdir(parents=True)
                (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": executable}))
                (contents / "MacOS" / executable).write_bytes(b"native executable fixture")
                (root / "Resources").mkdir()
                (root / "Resources/FileDeck.icns").write_bytes(b"icon fixture")

                def run(arguments, **kwargs):
                    if arguments[0] == "/usr/bin/ditto":
                        shutil.copytree(arguments[1], arguments[2], dirs_exist_ok=True)
                    return subprocess.CompletedProcess(arguments, 0)

                with patch.object(packager, "ROOT", root), patch.object(packager.subprocess, "run", side_effect=run):
                    previous, _ = packager.package_app(source, destination)
                self.assertIsNone(previous)
                self.assertEqual((contents / "MacOS" / executable).read_bytes(), b"native executable fixture")
                self.assertEqual(plistlib.loads((contents / "Info.plist").read_bytes())["CFBundleExecutable"], executable)
                self.assertEqual((destination / "Contents/MacOS/FileDeck").read_bytes(), b"native executable fixture")

    def test_invalid_version_is_rejected_before_reading_or_replacing_app(self):
        for options in ({"version": "not-a-version"}, {"build_number": "../file"}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                packager.package_app("missing.app", "destination.app", **options)

    def test_compression_requires_all_reader_capabilities_before_removing_resources(self):
        for missing in ("_FWCompressedHelpVersion", "_FWCompressedDictionariesVersion", "_FWCompressedHunspellVersion"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, help_page = self.fixture(root)
                destination = root / "published.app"
                destination.mkdir()
                (destination / "existing").write_bytes(b"keep published application")

                def symbols(arguments, **kwargs):
                    return self.supported_symbols(arguments).replace(missing + "\n", "")

                with patch.object(packager, "ROOT", root), \
                        patch.object(packager.subprocess, "run", side_effect=self.fake_run) as run, \
                        patch.object(packager.subprocess, "check_output", side_effect=symbols), \
                        patch.object(help_compressor, "compress_help") as compress_help, \
                        patch.object(dictionary_compressor, "compress_dictionaries") as compress_dictionaries, \
                        self.assertRaises(RuntimeError):
                    packager.package_app(source, destination, compress_offline=True)
                compress_help.assert_not_called()
                compress_dictionaries.assert_not_called()
                run.assert_not_called()
                self.assertFalse(list(root.glob(".file-workbench-package-*")))
                self.assertTrue(help_page.is_file())
                self.assertEqual((destination / "existing").read_bytes(), b"keep published application")

    def test_supported_compression_is_signed_and_repackaged_without_modifying_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, help_page = self.fixture(root)
            destination, repacked = root / "published.app", root / "repacked.app"
            destination.mkdir()
            (destination / "existing").write_bytes(b"previous app")
            checks = []

            def run(arguments, **kwargs):
                if arguments[0] == "/usr/bin/codesign":
                    # 必须先完成归档校验和目录替换，签名才能覆盖最终发布内容。
                    app = Path(arguments[-1])
                    checks.append(help_compressor.verify_compressed_help(app))
                return self.fake_run(arguments, **kwargs)

            with patch.object(packager, "ROOT", root), \
                    patch.object(packager.subprocess, "run", side_effect=run), \
                    patch.object(packager.subprocess, "check_output", side_effect=self.supported_symbols), \
                    patch.object(dictionary_compressor, "compress_dictionaries", return_value={"bytesSaved": 0}):
                previous, first = packager.package_app(source, destination, compress_offline=True)
                _, second = packager.package_app(destination, repacked, compress_offline=True)
            self.assertEqual(help_page.read_bytes(), b"offline help " * 300)
            self.assertEqual((previous / "existing").read_bytes(), b"previous app")
            self.assertFalse(list(root.glob(".file-workbench-package-*")))
            self.assertEqual(first["offlineCompression"]["help"]["createdArchives"], 1)
            self.assertEqual(second["offlineCompression"]["help"]["createdArchives"], 0)
            self.assertEqual(len(checks), 4)
            self.assertTrue(all(check["archives"] == 1 and check["verifiedBytes"] for check in checks))
            self.assertEqual(first["offlineCompression"]["help"]["archives"][0]["sha256"],
                             second["offlineCompression"]["help"]["archives"][0]["sha256"])

    def test_uncompressed_packaging_keeps_existing_legacy_reader_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, help_page = self.fixture(root)
            destination = root / "published.app"
            with patch.object(packager, "ROOT", root), \
                    patch.object(packager.subprocess, "run", side_effect=self.fake_run), \
                    patch.object(packager.subprocess, "check_output") as symbols, \
                    patch.object(help_compressor, "compress_help") as compress_help, \
                    patch.object(dictionary_compressor, "compress_dictionaries") as compress_dictionaries:
                _, report = packager.package_app(source, destination)
            symbols.assert_not_called()
            compress_help.assert_not_called()
            compress_dictionaries.assert_not_called()
            self.assertNotIn("offlineCompression", report)
            self.assertEqual((destination / help_page.relative_to(source)).read_bytes(), help_page.read_bytes())

    def test_drag_type_is_declared_in_browser_and_preserved_when_repackaging(self):
        expected = {"UTTypeIdentifier": "local.filedeck.browser-drag",
                    "UTTypeConformsTo": ["public.data"], "UTTypeDescription": "FileDeck file drag"}
        browser = Path(__file__).resolve().parents[2] / "Resources/Info.plist"
        self.assertIn(expected, plistlib.loads(browser.read_bytes())["UTExportedTypeDeclarations"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, _ = self.fixture(root)
            source_info = source / "Contents/Info.plist"
            metadata = plistlib.loads(source_info.read_bytes())
            foreign = {"UTTypeIdentifier": "example.existing-document", "UTTypeConformsTo": ["public.data"]}
            metadata["UTExportedTypeDeclarations"] = [foreign]
            source_info.write_bytes(plistlib.dumps(metadata))
            published, repacked = root / "published.app", root / "repacked.app"
            with patch.object(packager, "ROOT", root), \
                    patch.object(packager.subprocess, "run", side_effect=self.fake_run):
                packager.package_app(source, published)
                packager.package_app(published, repacked)
            for application in (published, repacked):
                declarations = plistlib.loads((application / "Contents/Info.plist").read_bytes())["UTExportedTypeDeclarations"]
                self.assertIn(foreign, declarations)
                self.assertEqual([value for value in declarations if value["UTTypeIdentifier"] == expected["UTTypeIdentifier"]], [expected])

    def test_copy_compression_and_signature_failures_clean_only_current_staging(self):
        for failure in ("copy", "compression", "sign", "verify"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, help_page = self.fixture(root)
                destination = root / "published.app"
                destination.mkdir()
                (destination / "existing").write_bytes(b"keep existing")

                def run(arguments, **kwargs):
                    result = self.fake_run(arguments, **kwargs)
                    if (failure == "copy" and arguments[0] == "/usr/bin/ditto"
                            or failure == "sign" and "--force" in arguments
                            or failure == "verify" and "--verify" in arguments):
                        raise subprocess.CalledProcessError(1, arguments)
                    return result

                real_compress_help = help_compressor.compress_help

                def compress_help(app):
                    report = real_compress_help(app)
                    if failure == "compression":
                        raise RuntimeError("compression failed after modifying staged resources")
                    return report

                with patch.object(packager, "ROOT", root), \
                        patch.object(packager.subprocess, "run", side_effect=run), \
                        patch.object(packager.subprocess, "check_output", side_effect=self.supported_symbols), \
                        patch.object(help_compressor, "compress_help", side_effect=compress_help), \
                        patch.object(dictionary_compressor, "compress_dictionaries", return_value={}), \
                        self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                    packager.package_app(source, destination, compress_offline=True)
                self.assertEqual(help_page.read_bytes(), b"offline help " * 300)
                self.assertEqual((destination / "existing").read_bytes(), b"keep existing")
                self.assertFalse(list(root.glob(".file-workbench-package-*")))
                self.assertFalse((root / "previous-apps").exists())

    def test_failed_publish_restores_previous_app_and_cleans_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, help_page = self.fixture(root)
            destination = root / "published.app"
            destination.mkdir()
            (destination / "existing").write_bytes(b"keep existing")
            rename = Path.rename

            def fail_publish(path, target):
                if path.parent.name.startswith(".file-workbench-package-"):
                    raise OSError("publish failed")
                return rename(path, target)

            with patch.object(packager, "ROOT", root), \
                    patch.object(packager.subprocess, "run", side_effect=self.fake_run), \
                    patch.object(Path, "rename", autospec=True, side_effect=fail_publish), \
                    self.assertRaisesRegex(OSError, "publish failed"):
                packager.package_app(source, destination)
            self.assertEqual(help_page.read_bytes(), b"offline help " * 300)
            self.assertEqual((destination / "existing").read_bytes(), b"keep existing")
            self.assertFalse(list(root.glob(".file-workbench-package-*")))
            self.assertEqual(list((root / "previous-apps").iterdir()), [])

    def test_report_symlink_cannot_overwrite_an_application_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "build"
            build.mkdir()
            protected = build / "protected"
            protected.write_text("keep")
            (build / "filedeck-resource-optimization.json").symlink_to(protected)
            with patch.object(packager, "ROOT", root), patch.object(sys, "argv", ["package_app.py"]), \
                    patch.object(packager, "package_app") as publish:
                with self.assertRaises(ValueError):
                    packager.main()
                publish.assert_not_called()
            self.assertEqual(protected.read_text(), "keep")

    def test_report_is_published_after_packaging_without_leftover_temporary_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "build").mkdir()
            report = {"linkedFiles": 2, "bytesSaved": 100}
            with patch.object(packager, "ROOT", root), patch.object(sys, "argv", ["package_app.py"]), \
                    patch.object(packager, "package_app", return_value=(None, report)):
                packager.main()
            self.assertEqual(json.loads((root / "build/filedeck-resource-optimization.json").read_text()), report)
            self.assertFalse(list((root / "build").glob(".resource-report-*")))


class PackagingGateTests(unittest.TestCase):
    """只替代系统工具输出，实际调用统一校验器和打包事务，绝不 mock 门禁结果。"""
    def setUp(self):
        from editor_fixtures import make_bundle
        from test_verify_bundle import FixtureTools
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source, self.destination = self.root / 'source.app', self.root / 'published.app'
        make_bundle(self.root, self.source)
        (self.root / 'Resources/FileDeck.icns').write_bytes(b'fixture icon')
        self.destination.mkdir()
        (self.destination / 'original').write_bytes(b'keep existing app')
        self.tools = FixtureTools()

    def package(self, mutate=None):
        import verify_bundle as checker
        def commands(arguments, **kwargs):
            if arguments[0] == '/usr/bin/ditto':
                shutil.copytree(arguments[1], arguments[2], symlinks=True)
                if mutate: mutate(Path(arguments[2]))
            return subprocess.CompletedProcess(arguments, 0, '', '')
        with patch.object(packager, 'ROOT', self.root), \
             patch.object(packager.subprocess, 'run', side_effect=commands):
            # 默认参数已绑定原 runner，显式传入合成系统工具；检查实现保持真实。
            real = checker.verify_bundle
            with patch.object(packager, 'verify_bundle', side_effect=lambda app, **kw: real(app, runner=self.tools, **kw)):
                return packager.package_app(self.source, self.destination)

    def assert_preserved(self):
        self.assertEqual((self.destination / 'original').read_bytes(), b'keep existing app')
        self.assertFalse((self.root / 'previous-apps').exists())
        self.assertFalse(list(self.root.glob('.file-workbench-package-*')))

    def test_missing_editor_template_or_core_is_rejected_before_copy(self):
        paths = ['Contents/Resources/FileWorkbenchEditors/editor.js',
                 'Contents/Resources/converter/empty/en-US/new.docx',
                 'Contents/Frameworks/ascdocumentscore.framework/ascdocumentscore']
        for name in paths:
            with self.subTest(path=name):
                path = self.source / name
                data, mode = path.read_bytes(), path.stat().st_mode
                path.unlink()
                with self.assertRaisesRegex(RuntimeError, '打包校验失败'):
                    self.package()
                self.assert_preserved()
                path.write_bytes(data)
                path.chmod(mode)

    def test_staged_copy_damage_does_not_replace_original(self):
        for name in ['Contents/Resources/FileWorkbenchEditors/index.html',
                     'Contents/Resources/converter/empty/en-US/new.xlsx',
                     'Contents/Frameworks/ascdocumentscore.framework/ascdocumentscore']:
            with self.subTest(path=name), self.assertRaisesRegex(RuntimeError, '打包校验失败'):
                self.package(lambda app: (app / name).unlink())
            self.assert_preserved()

    def test_stale_inputs_wrong_identity_and_architecture_are_rejected(self):
        source = self.root / 'EditorAssets/src/index.mjs'
        original = source.read_bytes()
        source.write_bytes(original + b'changed')
        with self.assertRaisesRegex(RuntimeError, '构建输入已过期'):
            self.package()
        source.write_bytes(original)
        self.tools.architectures[str(self.source / 'Contents/MacOS/FileDeck')] = 'x86_64'
        with self.assertRaisesRegex(RuntimeError, 'missingARM64'):
            self.package()
        self.tools.architectures.clear()
        plist = self.source / 'Contents/Info.plist'
        metadata = plistlib.loads(plist.read_bytes())
        metadata['CFBundleIdentifier'] = 'org.onlyoffice.unmodified'
        plist.write_bytes(plistlib.dumps(metadata))
        with self.assertRaisesRegex(RuntimeError, 'invalidBuildIdentity'):
            self.package()
        self.assert_preserved()

    def test_resource_lost_during_optimization_is_rejected_after_signing(self):
        optimize = packager.optimize_resources

        def lose_template(app):
            report = optimize(app)
            (app / 'Contents/Resources/converter/empty/en-US/new.pptx').unlink()
            return report

        with patch.object(packager, 'optimize_resources', side_effect=lose_template), \
                self.assertRaisesRegex(RuntimeError, 'missingResource'):
            self.package()
        self.assert_preserved()

    def test_complete_package_validates_source_and_staging_then_publishes(self):
        previous, report = self.package()
        self.assertEqual((previous / 'original').read_bytes(), b'keep existing app')
        self.assertTrue(report['bundleValidation']['staticChecksPassed'])
        self.assertEqual(report['bundleValidation']['buildIdentity']['CFBundleVersion'], '6')
        self.assertTrue((self.destination / 'Contents/Resources/FileWorkbenchEditors/editor.js').is_file())
        signed = [call[-1] for call in self.tools.calls if call[0]=='/usr/bin/codesign']
        self.assertEqual(len(signed), 2)
        self.assertEqual(signed[0], str(self.source))
        self.assertIn('.file-workbench-package-', signed[1])
