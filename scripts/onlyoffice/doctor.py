#!/usr/bin/env python3
"""只读检查 macOS ARM64 构建环境；不会安装软件、下载源码或写入报告文件。"""

import argparse
import json
import platform
import shutil
import sys

sys.dont_write_bytecode = True
from common import ROOT, BUILD, SOURCE, capture, find_qt_prefix, source_status, tool_path


def inspect(qt_prefix=None, include_sources=True):
    checks = []

    def add(name, ok, detail, required=True):
        checks.append({"name": name, "ok": bool(ok), "required": required, "detail": detail})

    add("macOS ARM64", platform.system() == "Darwin" and platform.machine() == "arm64",
        platform.platform())
    add("Python 3.9+", sys.version_info >= (3, 9), sys.version.split()[0] + " " + sys.executable)
    free = shutil.disk_usage(ROOT).free / (1024 ** 3)
    add("可用磁盘", free >= 100, "%.1f GiB（完整首次构建建议至少 100 GiB）" % free)
    for command in ["git", "xcodebuild", "clang", "make", "perl", "curl", "cmake", "node", "npm"]:
        path = tool_path(command)
        add(command, path is not None, path or "未找到")
    if shutil.which("xcodebuild"):
        code, value = capture(["xcodebuild", "-version"])
        add("Xcode 可用", code == 0, value)
    if platform.system() == "Darwin":
        code, output = capture(["/usr/bin/arch", "-x86_64", "/usr/bin/true"])
        add("Rosetta/x86_64 工具", code == 0, output or "可执行；ICU 上游脚本会先构建 x86_64 工具")
    qt = find_qt_prefix(qt_prefix)
    code, version = capture([str(qt / "bin/qmake"), "-query", "QT_VERSION"]) if qt else (1, "未找到 Qt 5")
    add("Qt 5 qmake", code == 0 and version.startswith("5."), str(qt or "") + " " + version)
    local_grunt = BUILD / "npm" / "node_modules" / ".bin" / "grunt"
    grunt = str(local_grunt) if local_grunt.is_file() else shutil.which("grunt")
    add("grunt-cli", grunt is not None, grunt or "请先安装项目内 grunt-cli，见构建说明")
    for command in ["autoconf", "automake", "pkg-config", "nasm"]:
        path = shutil.which(command)
        add(command, path is not None, path or "部分上游依赖可能需要", required=False)
    add("Apple libtool", (shutil.which("libtool") or "").startswith("/usr/bin/"),
        shutil.which("libtool") or "未找到", required=False)
    if include_sources:
        for entry in source_status():
            add("源码 " + entry["path"], entry["ok"], entry["actual"] or "尚未下载")
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--qt-prefix")
    parser.add_argument("--environment-only", action="store_true")
    args = parser.parse_args()
    checks = inspect(args.qt_prefix, not args.environment_only)
    ready = all(item["ok"] or not item["required"] for item in checks)
    if args.json:
        print(json.dumps({"ready": ready, "source": str(SOURCE), "checks": checks}, ensure_ascii=False, indent=2))
    else:
        for item in checks:
            label = "通过" if item["ok"] else ("缺失" if item["required"] else "提示")
            print("[%s] %s：%s" % (label, item["name"], item["detail"]))
        print("环境检查通过。" if ready else "尚未满足构建条件；本次检查未修改任何文件。")
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main())
