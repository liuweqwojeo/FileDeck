"""执行真实 base.cmd/cmd_in_dir，验证 npm/Grunt 子进程失败会终止界面构建。"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
import warnings
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "scripts/onlyoffice/patches/build_tools-006-locked-js-build.patch"
COMMIT = "cf4cac0846d03e2e00a6fec5d1ecd4e9463086d5"


class LockedJSBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        upstream = ROOT / "vendor/onlyoffice/build_tools"
        if not (upstream / ".git").exists():
            raise unittest.SkipTest("先获取固定上游源码；本测试不自动下载或实际安装 npm 包。")
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            (project / "scripts").mkdir()
            for name in ["base.py", "build_js.py"]:
                content = subprocess.check_output(["git", "-C", str(upstream), "show",
                                                   COMMIT + ":scripts/" + name], text=True)
                (project / "scripts" / name).write_text(content)
            subprocess.run(["git", "-C", str(project), "apply", "--check", str(PATCH)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(project), "apply", str(PATCH)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(project), "apply", "--reverse", "--check", str(PATCH)],
                           check=True, capture_output=True)
            cls.base_source = (project / "scripts/base.py").read_text()
            cls.js_source = (project / "scripts/build_js.py").read_text()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.interface = self.directory / "中文 界面/build"
        self.interface.mkdir(parents=True)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "commands.jsonl"
        # 只替代 npm/Grunt 可执行文件，真实 base.cmd 保留 shell、退出码和 SystemExit 语义。
        executable = """#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['FW_JS_COMMAND_LOG'], 'a') as output:
    output.write(json.dumps({'program': name, 'arguments': sys.argv[1:], 'cwd': os.getcwd()}) + '\\n')
failure = int(os.environ.get('FW_JS_FAIL_' + name.upper(), '0'))
# Grunt --force 的效果是遇到任务错误也继续；测试应能发现误加此参数。
if name == 'grunt' and '--force' in sys.argv:
    failure = 0
sys.exit(failure)
"""
        for name in ["npm", "grunt"]:
            path = self.bin / name
            path.write_text(executable)
            path.chmod(0o755)
        config = types.ModuleType("config")
        config.option = lambda name: "addon one, addon-two" if name == "web-apps-addons" else ""
        self.base = types.ModuleType("base")
        self.base.__file__ = str(self.directory / "build_tools/scripts/base.py")
        self.js = types.ModuleType("build_js")
        with patch.dict(sys.modules, {"config": config, "base": self.base}):
            # 上游 base.py 的旧正则包含无效转义警告，与本测试的命令失败传播无关。
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", DeprecationWarning)
                warnings.simplefilter("ignore", SyntaxWarning)
                exec(compile(self.base_source, "upstream base.py", "exec"), self.base.__dict__)
            exec(compile(self.js_source, str(PATCH), "exec"), self.js.__dict__)
        self.after = self.directory / "continued-after-interface"

    def run_interface(self, npm_failure=0, grunt_failure=0):
        previous = Path.cwd()
        environment = {"PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                       "FW_JS_COMMAND_LOG": str(self.log), "FW_JS_FAIL_NPM": str(npm_failure),
                       "FW_JS_FAIL_GRUNT": str(grunt_failure)}
        try:
            with patch.dict(os.environ, environment):
                self.js.build_interface(str(self.interface))
                self.after.touch()
        finally:
            # 上游在失败时直接退出进程，故测试在捕获 SystemExit 后自行恢复 cwd。
            os.chdir(previous)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_success_runs_ci_then_grunt_with_verbose_and_addons_in_correct_directory(self):
        self.run_interface()
        self.assertEqual(self.commands(), [
            {"program": "npm", "arguments": ["ci"], "cwd": str(self.interface)},
            {"program": "grunt", "arguments": ["--verbose", "--addon=addon one", "--addon=addon-two"],
             "cwd": str(self.interface)},
        ])
        self.assertTrue(self.after.is_file())

    def test_npm_failure_exits_without_grunt_retry_or_later_deployment(self):
        with self.assertRaisesRegex(SystemExit, r"Error \(npm\): 23"):
            self.run_interface(npm_failure=23)
        self.assertEqual([command["program"] for command in self.commands()], ["npm"])
        self.assertFalse(self.after.exists())

    def test_grunt_task_failure_exits_instead_of_continuing_with_incomplete_assets(self):
        with self.assertRaisesRegex(SystemExit, r"Error \(grunt\): 3"):
            self.run_interface(grunt_failure=3)
        self.assertEqual([command["program"] for command in self.commands()], ["npm", "grunt"])
        self.assertFalse(self.after.exists())


if __name__ == "__main__":
    unittest.main()
