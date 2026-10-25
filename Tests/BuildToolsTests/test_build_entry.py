"""通过实际 shell 入口和隔离工具探针，验证 release/package-only 不绕过锁定重建门禁。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BuildEntryTests(unittest.TestCase):
    def test_release_package_only_runs_locked_rebuild_check_before_packaging(self):
        script = Path(__file__).resolve().parents[2] / 'scripts/build-app.sh'
        for fail in (False, True):
            with self.subTest(verificationFails=fail), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                log = root / 'calls'
                for tool in ['npm', 'python3']:
                    path = root / tool
                    path.write_text('#!/bin/bash\nprintf "%s %s\\n" "${0##*/}" "$*" >> "$FW_ENTRY_LOG"\n'
                                    'if [[ "$FW_ENTRY_FAIL" == 1 && "$*" == *"run verify" ]]; then exit 9; fi\n')
                    path.chmod(0o755)
                env = dict(os.environ, PATH=str(root)+':'+os.environ['PATH'],
                           FW_ENTRY_LOG=str(log), FW_ENTRY_FAIL='1' if fail else '0')
                result = subprocess.run(['/bin/bash', str(script), 'release', '--package-only'], env=env,
                                        capture_output=True, text=True, timeout=10)
                lines = log.read_text().splitlines()
                self.assertIn('ci --ignore-scripts --no-audit --no-fund', lines[0])
                self.assertTrue(lines[1].endswith('run verify'))
                if fail:
                    self.assertEqual(result.returncode, 9)
                    self.assertEqual(len(lines), 2)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(lines[2], 'python3 scripts/onlyoffice/package_app.py --configuration Release')
