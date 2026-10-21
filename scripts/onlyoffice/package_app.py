#!/usr/bin/env python3
"""发布完整原生工作台 bundle；暂存并验签后替换入口，保留已有应用供回退。"""

import argparse
from datetime import datetime
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from common import ROOT


def package_app(source, destination):
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
    return previous


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    source = args.source or ROOT / "build/onlyoffice/DerivedData/Build/Products" / args.configuration / "ONLYOFFICE.app"
    destination = ROOT / "build/FileDeck.app"
    previous = package_app(source, destination)
    print("已生成 FileDeck：" + str(destination))
    if previous:
        print("上次应用已保留：" + str(previous))


if __name__ == "__main__":
    main()
