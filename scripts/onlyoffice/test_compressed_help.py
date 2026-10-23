#!/usr/bin/env python3
"""编译并运行真实 CEF 压缩帮助读取回归；仅使用项目锁定源码、已构建对象和本地依赖。"""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

from common import BUILD, ROOT, SOURCE, lock


SDK = SOURCE / "desktop-sdk/ChromiumBasedEditors/lib"
CEF = SOURCE / "core/Common/3dParty/cef/mac_arm64"
MANIFEST = "FileDeckCompressedHelpV1.json"


def verify_dependencies():
    """版本不匹配时明确失败，避免悄悄使用系统 CEF 或临时 app 的动态库。"""
    expected = next(entry["commit"] for entry in lock()["repositories"] if entry["path"] == "desktop-sdk")
    actual = subprocess.check_output(["git", "-C", str(SOURCE / "desktop-sdk"), "rev-parse", "HEAD"],
                                     text=True).strip()
    if actual != expected:
        raise RuntimeError("desktop-sdk 与 versions.lock.json 不匹配，请先运行 fetch.py。")
    dependency = json.loads((Path(__file__).with_name("binary-dependencies.lock.json")).read_text())["dependencies"]["cef-5414-mac_arm64"]
    archive = CEF / "cef_binary.7z"
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if archive.stat().st_size != dependency["size"] or digest.hexdigest() != dependency["sha256"]:
        raise RuntimeError("本地 CEF 归档不符合 binary-dependencies.lock.json。")
    framework = CEF / "build/Chromium Embedded Framework.framework/Chromium Embedded Framework"
    header = SDK / "src/filedeck_compressed_help.h"
    objects = sorted((SDK / "core_build/mac_arm64/release/obj/src/cef/mac/libcef_dll").rglob("*.o"))
    if not framework.is_file() or not header.is_file() or not objects:
        raise RuntimeError("缺少 CEF framework、压缩帮助补丁或已构建 wrapper；请先运行 build.py。")
    return framework, objects


def write_fixture(base):
    """构造合法资源和故意损坏的归档；错误样本不能通过正式打包器生成。"""
    files = {
        "en/a.htm": "<html><body>offline original bytes</body></html>",
        "en/link.htm": "../../../../../common/main/resources/help/target.htm",
        "en/cyclea.htm": "cycleb.htm", "en/cycleb.htm": "cyclea.htm",
        "en/escape.htm": "../../../../../../../secret.htm", "en/mismatch.htm": "a.htm",
    }
    links = {name: value for name, value in files.items() if name != "en/a.htm"}
    links["en/mismatch.htm"] = "link.htm"
    for number in range(17):
        name = f"en/chain{number}.htm"
        target = f"chain{number + 1}.htm" if number < 16 else "a.htm"
        files[name] = links[name] = target
    for editor, entries, aliases in (("documenteditor", files, links),
                                    ("common", {"target.htm": "cross-root target bytes"}, {})):
        path = base / editor / "main/resources/help.zip"
        path.parent.mkdir(parents=True)
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, text in entries.items():
                archive.writestr(name, text)
            archive.writestr(MANIFEST, json.dumps({"version": 1, "links": aliases}))

    # 修改 STORED 条目的数据而保留中央目录 CRC，验证真实 CEF 解码器会拒绝损坏内容。
    path = base / "pdfeditor/main/resources/help.zip"
    path.parent.mkdir(parents=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("en/bad.htm", "original bytes CRC fail")
        archive.writestr(MANIFEST, json.dumps({"version": 1, "links": {}}))
    with zipfile.ZipFile(path) as archive:
        entry = archive.getinfo("en/bad.htm")
        offset = entry.header_offset + 30 + len(entry.filename.encode("utf-8")) + len(entry.extra)
    content = bytearray(path.read_bytes())
    content[offset] ^= 1
    path.write_bytes(content)
    path = base / "visioeditor/main/resources/help.zip"
    path.parent.mkdir(parents=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(MANIFEST, json.dumps({"version": 2, "links": {}}))


def main():
    framework, objects = verify_dependencies()
    output = BUILD / "compressed-help-tests"
    output.mkdir(parents=True, exist_ok=True)
    binary = output / "CompressedHelpReader"
    source = ROOT / "NativeOffice/Tests/CompressedHelpReader.cpp"
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-Wno-deprecated-builtins",
                    "-I", str(SDK / "src"), "-I", str(SDK / "src/cef/mac"), str(source),
                    *map(str, objects), "-o", str(binary)], cwd=ROOT, check=True)
    # 中文、空格和百分号同时覆盖 URL 解码；测试资源只写入 build，运行后自动清理。
    with tempfile.TemporaryDirectory(prefix="fixture-中文 空格%-", dir=output) as temporary:
        fixture = Path(temporary)
        write_fixture(fixture)
        result = subprocess.run([str(binary), str(fixture), str(framework)], cwd=ROOT,
                                check=True, timeout=60, capture_output=True, text=True)
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="")
        if "PASS: 25 compressed help reader checks" not in result.stdout:
            raise RuntimeError("压缩帮助测试未到达完整结束标记。")


if __name__ == "__main__":
    main()
