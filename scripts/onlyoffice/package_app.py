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


def _require_offline_readers(application):
    """复制大型应用前只读核验能力；旧内核不能误用压缩资源。"""
    core = application / "Contents/Frameworks/ascdocumentscore.framework/ascdocumentscore"
    symbols = set(subprocess.check_output(["/usr/bin/nm", "-gUj", str(core)], text=True).splitlines())
    if not {"_FWCompressedHelpVersion", "_FWCompressedDictionariesVersion"}.issubset(symbols):
        raise RuntimeError("内核尚不支持离线压缩资源，请先应用 desktop-sdk 补丁并重编。")
    hunspell = application / "Contents/Frameworks/hunspell.framework/hunspell"
    symbols = set(subprocess.check_output(["/usr/bin/nm", "-gUj", str(hunspell)], text=True).splitlines())
    if "_FWCompressedHunspellVersion" not in symbols:
        raise RuntimeError("Hunspell 尚未修复压缩末尾读取，请先应用 hunspell 补丁并重编。")


def package_app(source, destination, version=None, build_number=None, compress_offline=False):
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
    # 也允许对已有的完整 FileDeck 重打包，资源优化不必重新编译未改动的 Office 内核。
    if executable not in {"ONLYOFFICE", "FileDeck"} or not (source / "Contents/MacOS" / executable).is_file():
        raise RuntimeError("来源不是完整的原生工作台应用。")
    if not (source / "Contents/Frameworks/Chromium Embedded Framework.framework").is_dir():
        raise RuntimeError("原生应用缺少 Chromium Embedded Framework。")
    if compress_offline:
        _require_offline_readers(source)
    icon = ROOT / "Resources/FileDeck.icns"
    if not icon.is_file():
        raise RuntimeError("缺少 FileDeck 应用图标：" + str(icon))
    destination.parent.mkdir(parents=True, exist_ok=True)
    # 仅清理本次暂存目录；压缩、签名或发布失败均不留下完整应用副本。
    with tempfile.TemporaryDirectory(prefix=".file-workbench-package-", dir=destination.parent) as staging:
        staged_app = Path(staging) / destination.name
        # ditto 保留 framework 内的版本链接和签名结构；先完成验证再触及用户入口。
        subprocess.run(["/usr/bin/ditto", str(source), str(staged_app)], check=True)
        # 本机构建不接管上游发行版更新；首次启动直接进入工作台，不出现联网检查询问。
        info.update(CFBundleName="FileDeck", CFBundleDisplayName="FileDeck", CFBundleExecutable="FileDeck",
                    CFBundleIconFile="FileDeck.icns",
                    SUEnableAutomaticChecks=False)
        # 拖动令牌需声明为 data 子类型，否则 SwiftUI 的系统桥接仅回传文件 URL。
        drag_type = {"UTTypeIdentifier": "local.filedeck.browser-drag",
                     "UTTypeConformsTo": ["public.data"], "UTTypeDescription": "FileDeck file drag"}
        info["UTExportedTypeDeclarations"] = [
            value for value in info.get("UTExportedTypeDeclarations", [])
            if value.get("UTTypeIdentifier") != drag_type["UTTypeIdentifier"]
        ] + [drag_type]
        if version is not None:
            info["CFBundleShortVersionString"] = version
        if build_number is not None:
            info["CFBundleVersion"] = build_number
        # asset catalog 名称的优先级可能高于 icns；移除旧名称，保证 Finder 与 Dock 使用新图标。
        info.pop("CFBundleIconName", None)
        shutil.copy2(icon, staged_app / "Contents/Resources/FileDeck.icns")
        if executable != "FileDeck":
            (staged_app / "Contents/MacOS" / executable).rename(staged_app / "Contents/MacOS/FileDeck")
        # macOS 和上游窗口标题优先读取本地化名称；只改主 plist 会在中文等环境显示旧名。
        # 保留 bundle ID 和版权字段，已有工作区、恢复数据与第三方声明继续有效。
        for localized in sorted((staged_app / "Contents/Resources").glob("*.lproj/InfoPlist.strings")):
            data = subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(localized)])
            metadata = plistlib.loads(data)
            metadata.update(CFBundleName="FileDeck", CFBundleDisplayName="FileDeck")
            localized.write_bytes(plistlib.dumps(metadata))
        (staged_app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        # 在签名前移除明确的开发入口、合并重复静态资源；全部运行资源路径及内容保持可读。
        optimization = optimize_resources(staged_app)
        if compress_offline:
            from compress_help import compress_help
            from compress_dictionaries import compress_dictionaries
            optimization["offlineCompression"] = {
                "help": compress_help(staged_app),
                "dictionaries": compress_dictionaries(staged_app),
            }
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
    return previous, optimization


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--version", help="FileDeck 发行版本，例如 0.1.0")
    parser.add_argument("--build-number", help="FileDeck 构建号，例如 1")
    parser.add_argument("--compress-offline-resources", action="store_true",
                        help="用支持压缩读取的内核无损压缩全部离线帮助和拼写字典")
    args = parser.parse_args()
    source = args.source or ROOT / "build/onlyoffice/DerivedData/Build/Products" / args.configuration / "ONLYOFFICE.app"
    destination = ROOT / "build/FileDeck.app"
    report = destination.parent / "filedeck-resource-optimization.json"
    # 在发布前拒绝报告链接；最终写入仍采用原子替换，避免后续链接变化触及应用或其他文件。
    if report.is_symlink() or (report.exists() and not report.is_file()):
        raise ValueError("资源核验报告目标必须为普通文件。")
    previous, optimization = package_app(source, destination, version=args.version, build_number=args.build_number,
                                         compress_offline=args.compress_offline_resources)
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
    print("无损静态资源去重：%d 个文件，节省 %.2f MiB" %
          (optimization["linkedFiles"], optimization["bytesSaved"] / 1024 ** 2))
    print("移除开发演示页：%d 个文件，节省 %d 字节" %
          (len(optimization.get("removedFiles", [])), optimization.get("removedBytes", 0)))
    if "offlineCompression" in optimization:
        offline = optimization["offlineCompression"]
        print("离线帮助压缩：%.2f MiB；拼写字典压缩：%.2f MiB" %
              (offline["help"]["bytesSaved"] / 1024 ** 2,
               offline["dictionaries"]["bytesSaved"] / 1024 ** 2))
    print("资源核验清单：" + str(report))
    if previous:
        print("上次应用已保留：" + str(previous))


if __name__ == "__main__":
    main()
