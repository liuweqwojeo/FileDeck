"""构建期将 Hunspell 词典转换为原生 .hz 格式；运行期逐行读取，无需解压缓存。"""

import argparse
import filecmp
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

from common import ROOT
from optimize_resources import has_extended_attributes, sha256


DICTIONARIES = Path("Contents/Resources/dictionaries")
HUNSPELL = ROOT / "vendor/onlyoffice/core/Common/3dParty/hunspell"
MANIFEST = "filedeck-hunspell-compression.json"


def build_tools(source_root=HUNSPELL, output_root=None):
    """从锁定的上游源码编译离线构建工具，工具自身不进入应用包。"""
    source_root = Path(source_root)
    source = source_root / "hunspell/src"
    inputs = [source / relative for relative in (
        "tools/hzip.cxx", "tools/hunzip.cxx", "hunspell/hunzip.cxx", "hunspell/csutil.cxx",
        "hunspell/hunzip.hxx", "hunspell/csutil.hxx", "hunspell/utf_info.hxx")]
    digest = hashlib.sha256(b"filedeck-hzip-portable-v2-buffered-eof")
    for path in inputs:
        digest.update(path.read_bytes())
    output_root = Path(output_root or ROOT / "build/onlyoffice/compression-tools") / digest.hexdigest()[:16]
    hzip, hunzip = output_root / "hzip", output_root / "hunzip"
    if hzip.is_file() and hunzip.is_file():
        return hzip, hunzip
    output_root.mkdir(parents=True, exist_ok=True)
    text = inputs[0].read_text()
    # 上游 hzip 的 "rw" 不是标准 stdio 更新模式，在 macOS 上不可写；仅修正构建副本。
    needle = 'fdopen(tempfileno, "rw")'
    if text.count(needle) != 1:
        raise RuntimeError("上游 hzip 源码已变化，需复核临时文件模式修正。")
    portable = output_root / "hzip-portable.cxx"
    portable.write_text("// FileDeck build-only modification: use portable read/write stdio mode.\n" +
                        text.replace(needle, 'fdopen(tempfileno, "w+")'))
    compiler = shutil.which("clang++") or shutil.which("c++")
    if compiler is None:
        raise RuntimeError("构建 Hunspell 压缩工具需要 C++ 编译器。")
    subprocess.run([compiler, "-O2", "-std=c++11", str(portable), "-o", str(hzip)], check=True)
    # 解码器与运行库采用相同 EOF 修正：底层文件关闭后，最后一段解码缓冲仍然可读。
    # 使用构建副本，避免修改锁定的第三方源码；原生 framework 的补丁由构建流程管理。
    decoder = output_root / "decoder"
    shutil.copytree(source / "hunspell", decoder / "hunspell", dirs_exist_ok=True)
    (decoder / "tools").mkdir(exist_ok=True)
    shutil.copyfile(source / "tools/hunzip.cxx", decoder / "tools/hunzip.cxx")
    header = decoder / "hunspell/hunzip.hxx"
    content = header.read_text()
    old = "bool is_open() { return fin.is_open(); }"
    corrected = "bool is_open() { return bufsiz > 0; }"
    if old in content:
        header.write_text("// FileDeck build-only modification: preserve buffered data after EOF.\n" +
                          content.replace(old, corrected))
    elif corrected not in content:
        raise RuntimeError("Hunspell EOF 实现已变化，需复核解码缓冲状态。")
    subprocess.run([compiler, "-O2", "-std=c++11", str(decoder / "tools/hunzip.cxx"),
                    str(decoder / "hunspell/hunzip.cxx"), str(decoder / "hunspell/csutil.cxx"),
                    "-o", str(hunzip)], check=True)
    return hzip, hunzip


def dictionary_names(source_root=HUNSPELL):
    """只转换桌面拼写检查注册表实际加载的词典，连字符和同义词保持原格式。"""
    records = (Path(source_root) / "autogen/records.h").read_text()
    names = sorted(set(re.findall(r'\{\s*"([A-Za-z0-9_]+)"\s*,\s*\d+\s*\}', records)))
    if not names:
        raise RuntimeError("Hunspell 语言注册表为空或格式已变化。")
    return names


def manifest_entries(root):
    """包内清单独立描述压缩内容；验收发布包不能依赖构建机器的上游源码。"""
    manifest = root / MANIFEST
    if manifest.is_symlink():
        raise RuntimeError("词典完整性清单必须为普通文件。")
    if not manifest.exists():
        return None
    if not manifest.is_file():
        raise RuntimeError("词典完整性清单必须为普通文件。")
    data = json.loads(manifest.read_text())
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("files"), list):
        raise RuntimeError("词典完整性清单格式无效。")
    entries = data["files"]
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("target"), str):
            raise RuntimeError("词典完整性清单条目无效。")
        parts = entry["target"].split("/")
        if (len(parts) != 2 or not re.fullmatch(r"[A-Za-z0-9_]+", parts[0])
                or parts[1] not in (parts[0] + ".aff.hz", parts[0] + ".dic.hz")):
            raise RuntimeError("词典完整性清单含无效路径。")
        if (any(type(entry.get(key)) is not int or entry[key] <= 0 for key in ("originalBytes", "compressedBytes"))
                or type(entry.get("mode")) is not int or entry["mode"] < 0 or entry["mode"] > 0o777
                or entry["mode"] & 0o111
                or any(not isinstance(entry.get(key), str) or not re.fullmatch(r"[0-9a-f]{64}", entry[key])
                       for key in ("sha256", "compressedSha256"))):
            raise RuntimeError("词典完整性清单元数据无效。")
    return entries


def verify_existing(root, expected, hunzip=None, temporary=None):
    """重打包不信任扩展名；核对压缩文件和解码内容，损坏的 .hz 必须阻止发布。"""
    entries = manifest_entries(root)
    if entries is None:
        if expected:
            raise RuntimeError("已有压缩词典缺少完整性清单。")
        return []
    targets = [entry.get("target") for entry in entries]
    if len(targets) != len(set(targets)) or set(targets) != expected:
        raise RuntimeError("已有压缩词典与完整性清单不一致。")
    for entry in entries:
        target = root / entry["target"]
        if (target.is_symlink() or not target.is_file()
                or target.parent.is_symlink()
                or target.stat().st_size != entry.get("compressedBytes")
                or stat.S_IMODE(target.stat().st_mode) != entry.get("mode")
                or sha256(target) != entry.get("compressedSha256")):
            raise RuntimeError("已有压缩词典文件校验失败：" + str(target))
        if hunzip is not None:
            decoded = temporary / "existing-decoded"
            with decoded.open("wb") as stream:
                subprocess.run([str(hunzip), str(target)], stdout=stream, check=True)
            if (decoded.stat().st_size != entry.get("originalBytes") or sha256(decoded) != entry.get("sha256")):
                raise RuntimeError("已有压缩词典解码校验失败：" + str(target))
    return entries


def dictionary_root(application):
    application = Path(application)
    if application.is_symlink() or not application.is_dir():
        raise ValueError("词典压缩要求普通应用目录。")
    application = application.resolve()
    # 不允许目录别名把构建期写入引向包外；文件别名及自定义元数据也保持原状。
    if any((application / parent).is_symlink() for parent in (DICTIONARIES, *DICTIONARIES.parents)):
        raise ValueError("词典资源目录必须位于应用包内且不能为符号链接。")
    return application / DICTIONARIES


def dictionary_inventory(root, names):
    pairs, existing, languages = [], set(), []
    for name in names:
        directory = root / name
        if directory.is_symlink() or not directory.is_dir():
            continue
        pair = [directory / (name + suffix) for suffix in (".aff", ".dic")]
        for path in pair:
            target = Path(str(path) + ".hz")
            if target.exists() or target.is_symlink():
                if path.exists() or path.is_symlink():
                    raise RuntimeError("原词典和压缩词典同时存在，拒绝覆盖：" + str(target))
                existing.add(str(target.relative_to(root)))
        if all(path.is_file() or Path(str(path) + ".hz").is_file() for path in pair):
            languages.append(name)
            pairs.extend(pair)
        elif any(str(Path(str(path) + ".hz").relative_to(root)) in existing for path in pair):
            raise RuntimeError("已压缩词典缺少配对的 aff/dic 文件：" + name)
    return pairs, existing, languages


def verify_compressed_dictionaries(application, verify_decoded=False):
    """默认只读核对清单、路径、权限及压缩哈希；完整核验额外逐文件解码比较。"""
    root = dictionary_root(application)
    if not root.exists():
        return {"compressedFiles": 0, "languageCount": 0, "languages": [], "decodedVerified": False}
    # 直接枚举包内 .hz 与清单比对，未知名称的孤儿文件也不能悄悄漏过。
    # 普通未压缩包无需清单或 vendor；注册表仅用于构建期决定哪些文件可转换。
    existing = {path.relative_to(root).as_posix() for path in root.rglob("*.hz")}
    if verify_decoded and existing:
        _hzip, hunzip = build_tools()
        with tempfile.TemporaryDirectory(prefix="dictionary-verification-") as temporary:
            entries = verify_existing(root, existing, hunzip, Path(temporary))
    else:
        entries = verify_existing(root, existing)
    names = sorted(path.name for path in root.iterdir()
                   if path.is_dir() and not path.is_symlink() and re.fullmatch(r"[A-Za-z0-9_]+", path.name))
    _pairs, _existing, languages = dictionary_inventory(root, names)
    return {"compressedFiles": len(entries), "languageCount": len(languages), "languages": languages,
            "decodedVerified": bool(verify_decoded and existing),
            "originalBytes": sum(item["originalBytes"] for item in entries),
            "compressedBytes": sum(item["compressedBytes"] for item in entries)}


def compress_dictionaries(application, source_root=HUNSPELL, tool_directory=None):
    """压缩待签名副本；调用方必须先保证桌面内核允许 .aff.hz/.dic.hz 语言枚举。"""
    root = dictionary_root(application)
    application = Path(application).resolve()
    report = {"format": "hunspell-hz", "compressedFiles": [], "skippedFiles": [],
              "originalBytes": 0, "compressedBytes": 0, "bytesSaved": 0, "languages": [],
              "verifiedCompressedFiles": 0}
    if not root.exists():
        return report
    candidates = []
    pairs, existing, report["languages"] = dictionary_inventory(root, dictionary_names(source_root))
    for path in pairs:
        if not path.exists():
            continue
        metadata = path.lstat()
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o111
                or metadata.st_size == 0 or has_extended_attributes(path)):
            report["skippedFiles"].append({"path": str(path.relative_to(application)), "reason": "metadata"})
            continue
        target = Path(str(path) + ".hz")
        candidates.append((path, target))
    if not candidates and not existing and not (root / MANIFEST).exists() and not (root / MANIFEST).is_symlink():
        return report
    hzip, hunzip = build_tools(source_root, tool_directory)
    with tempfile.TemporaryDirectory(prefix=".dictionary-compression-", dir=application.parent) as temporary:
        work = Path(temporary)
        entries = verify_existing(root, existing, hunzip, work)
        report["verifiedCompressedFiles"] = len(entries)
        for path, target in candidates:
            raw, compressed, decoded = work / "input", work / "input.hz", work / "decoded"
            shutil.copyfile(path, raw)
            subprocess.run([str(hzip), str(raw)], check=True)
            with decoded.open("wb") as stream:
                subprocess.run([str(hunzip), str(compressed)], stdout=stream, check=True)
            # .hz 对某些极端行格式有限制；任何不完全一致的文件都不得替换原件。
            if not filecmp.cmp(path, decoded, shallow=False):
                report["skippedFiles"].append({"path": str(path.relative_to(application)), "reason": "roundtrip-mismatch"})
                continue
            before, after = path.stat().st_size, compressed.stat().st_size
            if after >= before:
                report["skippedFiles"].append({"path": str(path.relative_to(application)), "reason": "not-smaller"})
                continue
            checksum = sha256(path)
            compressed_checksum = sha256(compressed)
            compressed.chmod(stat.S_IMODE(path.stat().st_mode))
            os.replace(compressed, target)
            path.unlink()
            report["compressedFiles"].append({"path": str(path.relative_to(application)),
                                               "target": str(target.relative_to(application)),
                                               "originalBytes": before, "compressedBytes": after,
                                               "sha256": checksum})
            report["originalBytes"] += before
            report["compressedBytes"] += after
            report["bytesSaved"] += before - after
            entries.append({"target": str(target.relative_to(root)), "originalBytes": before,
                            "compressedBytes": after, "sha256": checksum,
                            "compressedSha256": compressed_checksum,
                            "mode": stat.S_IMODE(target.stat().st_mode)})
        if report["compressedFiles"]:
            manifest = root / MANIFEST
            previous_size = manifest.stat().st_size if manifest.exists() else 0
            temporary_manifest = work / MANIFEST
            temporary_manifest.write_text(json.dumps({"version": 1, "files": entries},
                                                     ensure_ascii=False, indent=2) + "\n")
            report["manifestBytes"] = temporary_manifest.stat().st_size
            report["bytesSaved"] -= report["manifestBytes"] - previous_size
            os.replace(temporary_manifest, manifest)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="已支持 .hz 枚举的待签名应用副本")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = compress_dictionaries(args.app)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
