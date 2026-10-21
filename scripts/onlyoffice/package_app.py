#!/usr/bin/env python3
"""发布完整原生工作台 bundle；暂存并验签后替换入口，保留已有应用供回退。"""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

from common import ROOT
from optimize_resources import optimize_resources


def package_app(source, destination, version=None, build_number=None):
    if version is not None and not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("版本号应为三段数字，例如 0.1.0。")
    if build_number is not None and not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build_number):
        raise ValueError("构建号应为一到三段数字。")
    source, destination = Path(source).absolute(), Path(destination).absolute()
    if source == destination or source.is_symlink() or destination.is_symlink():
        raise RuntimeError("应用来源和发布路径必须为不同的普通路径。")
    info_path = source / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    executable = info.get("CFBundleExecutable")
    # 必须发布包含 CEF 和文档内核的完整原生包，不能把旧浏览器二进制混入同名目录。
    if executable != "ONLYOFFICE" or not (source / "Contents/MacOS" / executable).is_file():
        raise RuntimeError("来源不是完整的原生工作台应用。")
    if not (source / "Contents/Frameworks/Chromium Embedded Framework.framework").is_dir():
        raise RuntimeError("原生应用缺少 Chromium Embedded Framework。")
    icon = ROOT / "Resources/FileDeck.icns"
    if not icon.is_file():
        raise RuntimeError("缺少 FileDeck 应用图标：" + str(icon))
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".file-workbench-package-", dir=destination.parent))
    staged_app = staging / destination.name
    # ditto 保留 framework 内的版本链接和签名结构；先完成验证再触及用户入口。
    subprocess.run(["/usr/bin/ditto", str(source), str(staged_app)], check=True)
    # 本机构建不接管上游发行版更新；首次启动直接进入工作台，不出现联网检查询问。
    info.update(CFBundleName="FileDeck", CFBundleDisplayName="FileDeck", CFBundleExecutable="FileDeck",
                CFBundleIconFile="FileDeck.icns",
                SUEnableAutomaticChecks=False)
    if version is not None:
        info["CFBundleShortVersionString"] = version
    if build_number is not None:
        info["CFBundleVersion"] = build_number
    # asset catalog 名称的优先级可能高于 icns；移除旧名称，保证 Finder 与 Dock 使用新图标。
    info.pop("CFBundleIconName", None)
    shutil.copy2(icon, staged_app / "Contents/Resources/FileDeck.icns")
    (staged_app / "Contents/MacOS" / executable).rename(staged_app / "Contents/MacOS/FileDeck")
    # macOS 和上游窗口标题优先读取本地化名称；只改主 plist 会在中文等环境显示旧名。
    # 保留 bundle ID 和版权字段，已有工作区、恢复数据与第三方声明继续有效。
    for localized in sorted((staged_app / "Contents/Resources").glob("*.lproj/InfoPlist.strings")):
        data = subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(localized)])
        metadata = plistlib.loads(data)
        metadata.update(CFBundleName="FileDeck", CFBundleDisplayName="FileDeck")
        localized.write_bytes(plistlib.dumps(metadata))
    (staged_app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    # 只改待签名副本，原生内核及所有图片内容保持不变；签名记录新的包内相对链接。
    optimization = optimize_resources(staged_app)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(staged_app)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged_app)], check=True)
    # ditto 保留源目录时间；刷新包根目录时间，让 macOS 识别同路径更新后的图标。
    os.utime(staged_app, None)
    previous = None
    if destination.exists():
        if not destination.is_dir():
            raise RuntimeError("发布路径已被非应用目录占用，已保留。")
        previous_root = destination.parent / "previous-apps"
        previous_root.mkdir(exist_ok=True)
        previous = previous_root / (destination.stem + "-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".app")
        destination.rename(previous)
    try:
        staged_app.rename(destination)
    except OSError:
        if previous is not None:
            previous.rename(destination)
        raise
    staging.rmdir()
    return previous, optimization


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--version", help="FileDeck 发行版本，例如 0.1.0")
    parser.add_argument("--build-number", help="FileDeck 构建号，例如 1")
    args = parser.parse_args()
    source = args.source or ROOT / "build/onlyoffice/DerivedData/Build/Products" / args.configuration / "ONLYOFFICE.app"
    destination = ROOT / "build/FileDeck.app"
    report = destination.parent / "filedeck-resource-optimization.json"
    # 在发布前拒绝报告链接；最终写入仍采用原子替换，避免后续链接变化触及应用或其他文件。
    if report.is_symlink() or (report.exists() and not report.is_file()):
        raise ValueError("资源核验报告目标必须为普通文件。")
    previous, optimization = package_app(source, destination, version=args.version, build_number=args.build_number)
    temporary_report = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".resource-report-",
                                         dir=destination.parent, delete=False) as stream:
            temporary_report = Path(stream.name)
            json.dump(optimization, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        temporary_report.replace(report)
    finally:
        if temporary_report is not None:
            temporary_report.unlink(missing_ok=True)
    print("已生成 FileDeck：" + str(destination))
    print("无损图片去重：%d 个文件，节省 %.2f MiB" %
          (optimization["linkedFiles"], optimization["bytesSaved"] / 1024 ** 2))
    print("资源核验清单：" + str(report))
    if previous:
        print("上次应用已保留：" + str(previous))


if __name__ == "__main__":
    main()
