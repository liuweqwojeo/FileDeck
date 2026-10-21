"""验证发布元数据与报告写入边界；原生签名另由真实应用验收覆盖。"""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "onlyoffice"))
import package_app as packager


class PackagingBoundaryTests(unittest.TestCase):
    def test_invalid_version_is_rejected_before_reading_or_replacing_app(self):
        for options in ({"version": "not-a-version"}, {"build_number": "../file"}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                packager.package_app("missing.app", "destination.app", **options)

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
