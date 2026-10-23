"""把离线帮助存为可直接读取的 ZIP；保留原始字节、相对链接和全部语言。"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import stat
import tempfile
import zipfile

from optimize_resources import has_extended_attributes, sha256


APPS_ROOT = Path("Contents/Resources/editors/web-apps/apps")
HELP_ROOTS = tuple(APPS_ROOT / editor / "main/resources/help" for editor in (
    "common", "documenteditor", "spreadsheeteditor", "presentationeditor", "pdfeditor", "visioeditor"))
# 名称同时是原生读取器的能力标记；读取器只使用 version/links，entries 用于完整性复核。
MANIFEST_NAME = "FileDeckCompressedHelpV1.json"
MAX_ENTRY_BYTES = 128 * 1024 * 1024
MAX_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_LINK_DEPTH = 16
ZIP_DATE = (1980, 1, 1, 0, 0, 0)


def _valid_name(name):
    return (isinstance(name, str) and bool(name) and name != "." and "\\" not in name and "\0" not in name
            and not name.startswith("/") and name == str(PurePosixPath(name))
            and ".." not in PurePosixPath(name).parts)


def _digest(stream):
    digest, size = hashlib.sha256(), 0
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        size += len(chunk)
        if size > MAX_ENTRY_BYTES:
            raise ValueError("帮助资源超过原生读取器的单文件限制。")
        digest.update(chunk)
    return size, digest.hexdigest()


def _scan_help(root):
    """不跟随目录链接，记录磁盘原始内容；软链接的数据是原始相对目标。"""
    entries, links = [], {}
    for directory, directories, names in os.walk(root, followlinks=False):
        directories.sort()
        for name in directories + sorted(names):
            path = Path(directory) / name
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                continue
            relative = path.relative_to(root).as_posix()
            if not _valid_name(relative) or relative == MANIFEST_NAME:
                raise ValueError("帮助路径与归档格式冲突：" + str(path))
            if has_extended_attributes(path):
                raise ValueError("帮助资源带有无法归档的自定义扩展属性：" + str(path))
            if stat.S_ISLNK(metadata.st_mode):
                if name in directories:
                    raise ValueError("帮助目录不支持目录软链接：" + str(path))
                target = os.readlink(path)
                if not target or os.path.isabs(target) or "\\" in target or "\0" in target:
                    raise ValueError("帮助软链接必须为包内相对路径：" + str(path))
                payload = target.encode("utf-8")
                size, checksum = len(payload), hashlib.sha256(payload).hexdigest()
                links[relative] = target
                kind = "symlink"
            elif stat.S_ISREG(metadata.st_mode) and not metadata.st_mode & 0o111:
                with path.open("rb") as stream:
                    size, checksum = _digest(stream)
                kind = "file"
            else:
                raise ValueError("帮助目录含不支持的文件类型或可执行文件：" + str(path))
            if size > MAX_ENTRY_BYTES:
                raise ValueError("帮助资源超过原生读取器的单文件限制：" + str(path))
            entries.append({"path": relative, "kind": kind, "mode": stat.S_IMODE(metadata.st_mode),
                            "bytes": size, "sha256": checksum})
    return {"version": 1, "links": links, "entries": sorted(entries, key=lambda entry: entry["path"])}


def _zip_info(name, kind="file", mode=0o644):
    info = zipfile.ZipInfo(name, ZIP_DATE)
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = ((stat.S_IFLNK if kind == "symlink" else stat.S_IFREG) | mode) << 16
    return info


def _write_archive(root, destination, manifest):
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for entry in manifest["entries"]:
            info = _zip_info(entry["path"], entry["kind"], entry["mode"])
            if entry["kind"] == "symlink":
                archive.writestr(info, manifest["links"][entry["path"]].encode("utf-8"), compresslevel=9)
            else:
                # open(info) 不继承 ZipFile.compresslevel；显式指定固定压缩级别保持可复现。
                info._compresslevel = 9
                with (root / entry["path"]).open("rb") as source, archive.open(info, "w") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
        payload = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        if len(payload) > MAX_MANIFEST_BYTES:
            raise ValueError("帮助校验清单超过原生读取器限制。")
        archive.writestr(_zip_info(MANIFEST_NAME), payload, compresslevel=9)


def verify_help_archive(path, expected=None, verify_bytes=True):
    """复核格式、全部字节及链接元数据；重复打包也不能接受损坏或未知格式的归档。"""
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if (len(names) != len(set(names)) or MANIFEST_NAME not in names
                or any(not _valid_name(name) for name in names)
                or any(info.file_size > MAX_ENTRY_BYTES or info.flag_bits & 1
                       or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) for info in infos)):
            raise ValueError("帮助归档含不支持或不唯一的条目：" + str(path))
        if archive.getinfo(MANIFEST_NAME).file_size > MAX_MANIFEST_BYTES:
            raise ValueError("帮助归档校验清单超过原生读取器限制：" + str(path))
        manifest = json.loads(archive.read(MANIFEST_NAME).decode("utf-8"))
        if (not isinstance(manifest, dict) or manifest.get("version") != 1
                or not isinstance(manifest.get("links"), dict) or not isinstance(manifest.get("entries"), list)):
            raise ValueError("帮助归档校验清单格式不受支持：" + str(path))
        entries, links = manifest["entries"], manifest["links"]
        if expected is not None and manifest != expected:
            raise ValueError("帮助归档与原始校验清单不一致：" + str(path))
        if any(not isinstance(entry, dict) or not _valid_name(entry.get("path")) for entry in entries):
            raise ValueError("帮助归档校验清单含无效路径：" + str(path))
        entry_names = [entry["path"] for entry in entries]
        if (len(entry_names) != len(set(entry_names)) or set(entry_names) != set(names) - {MANIFEST_NAME}
                or set(links) != {entry["path"] for entry in entries if entry.get("kind") == "symlink"}):
            raise ValueError("帮助归档条目与校验清单不一致：" + str(path))
        for entry in entries:
            info = archive.getinfo(entry["path"])
            mode = info.external_attr >> 16
            expected_type = stat.S_IFLNK if entry.get("kind") == "symlink" else stat.S_IFREG
            if (entry.get("kind") not in ("file", "symlink") or stat.S_IFMT(mode) != expected_type
                    or stat.S_IMODE(mode) != entry.get("mode") or info.file_size != entry.get("bytes")):
                raise ValueError("帮助归档元数据不一致：" + entry["path"])
            if verify_bytes:
                with archive.open(info) as stream:
                    size, checksum = _digest(stream)
                if size != entry["bytes"] or checksum != entry.get("sha256"):
                    raise ValueError("帮助归档内容校验失败：" + entry["path"])
            if entry["kind"] == "symlink":
                target = links[entry["path"]]
                if (not isinstance(target, str) or not target or target.startswith("/")
                        or "\\" in target or "\0" in target or archive.read(info) != target.encode("utf-8")):
                    raise ValueError("帮助归档软链接不合法：" + entry["path"])
        return manifest


def verify_compressed_help(application, verify_bytes=True):
    """供 bundle 验收复用；轻量模式只核验目录结构、元数据及全部跨归档链接。"""
    application = Path(application).resolve()
    manifests = {}
    for relative in HELP_ROOTS:
        archive = application / relative.with_name("help.zip")
        if archive.exists() or archive.is_symlink():
            if (archive.is_symlink() or not archive.is_file() or (application / relative).exists()
                    or any((application / parent).is_symlink() for parent in relative.parents if parent != Path("."))):
                raise ValueError("已压缩帮助必须是独立的包内普通归档：" + str(archive))
            manifests[relative] = verify_help_archive(archive, verify_bytes=verify_bytes)
    _verify_link_graph(manifests)
    _reject_incoming_links(application, [application / relative for relative in manifests])
    return {"archives": len(manifests), "files": sum(len(item["entries"]) - len(item["links"]) for item in manifests.values()),
            "links": sum(len(item["links"]) for item in manifests.values()), "verifiedBytes": verify_bytes}


def _verify_link_graph(manifests):
    # 跨语言、跨编辑器的原有去重链接直接保留，不能先解引用再压缩导致重复资源回流。
    entries = {}
    for root, manifest in manifests.items():
        for entry in manifest["entries"]:
            entries[(root / entry["path"]).as_posix()] = (entry, manifest["links"].get(entry["path"]))
    for name, (entry, _target) in entries.items():
        if entry["kind"] != "symlink":
            continue
        current, visited = name, set()
        for _ in range(MAX_LINK_DEPTH + 1):
            if current not in entries or current in visited:
                raise ValueError("帮助软链接越界、损坏或存在循环：" + name)
            visited.add(current)
            target_entry, target = entries[current]
            if target_entry["kind"] == "file":
                break
            current = posixpath.normpath(posixpath.join(posixpath.dirname(current), target))
        else:
            raise ValueError("帮助软链接超过原生读取器的递归限制：" + name)


def _reject_incoming_links(application, roots):
    # 其他资源仍由普通文件 API 读取，不能让它们在移除 help 目录后变成悬空链接。
    for directory, directories, names in os.walk(application, followlinks=False):
        for name in directories + names:
            path = Path(directory) / name
            if not path.is_symlink() or any(path.is_relative_to(root) for root in roots):
                continue
            try:
                target = path.resolve()
            except RuntimeError:
                continue
            if any(target.is_relative_to(root) for root in roots):
                raise ValueError("帮助目录被其他运行资源引用，不能移除：" + str(path))


def compress_help(application):
    """仅用于打包暂存副本；所有新归档逐字节复核通过后，才移除原帮助目录。"""
    application = Path(application)
    if application.is_symlink() or not application.is_dir():
        raise ValueError("帮助压缩要求普通应用目录。")
    application = application.resolve()
    manifests, pending, temporary_paths = {}, {}, []
    report = {"schemaVersion": 1, "archives": [], "createdArchives": 0,
              "files": 0, "links": 0, "sourceBytes": 0, "archiveBytes": 0, "bytesSaved": 0}
    for relative in HELP_ROOTS:
        root, archive = application / relative, application / relative.with_name("help.zip")
        if any((application / parent).is_symlink() for parent in (relative,) + tuple(relative.parents)
               if parent != Path(".")) or archive.is_symlink():
            raise ValueError("帮助目录及归档必须为包内普通路径：" + str(root))
        if root.exists() and archive.exists():
            raise ValueError("帮助目录和归档同时存在，拒绝覆盖：" + str(root))
        if root.exists():
            if not root.is_dir():
                raise ValueError("帮助根路径必须为目录：" + str(root))
            manifests[relative] = _scan_help(root)
            pending[relative] = root
        elif archive.exists():
            if not archive.is_file():
                raise ValueError("帮助归档必须为普通文件：" + str(archive))
            manifests[relative] = verify_help_archive(archive)
    _verify_link_graph(manifests)
    _reject_incoming_links(application, [application / relative for relative in manifests])
    try:
        for relative, root in pending.items():
            with tempfile.NamedTemporaryFile(prefix=".help-", suffix=".zip", dir=root.parent, delete=False) as stream:
                temporary = Path(stream.name)
            temporary_paths.append(temporary)
            _write_archive(root, temporary, manifests[relative])
            verify_help_archive(temporary, manifests[relative])
            # 临时文件默认为 0600，发布资源须允许其他本机用户离线读取。
            temporary.chmod(0o644)
        # 再读原始目录防止压缩期间内容变化；任一失败均保留全部原帮助目录。
        for relative, root in pending.items():
            if _scan_help(root) != manifests[relative]:
                raise ValueError("帮助资源在打包期间发生变化：" + str(root))
        for relative, temporary in zip(pending, temporary_paths):
            temporary.replace(application / relative.with_name("help.zip"))
        for root in pending.values():
            shutil.rmtree(root)
        for relative, manifest in manifests.items():
            archive = application / relative.with_name("help.zip")
            entry = {"path": archive.relative_to(application).as_posix(), "sha256": sha256(archive),
                     "files": sum(item["kind"] == "file" for item in manifest["entries"]),
                     "links": len(manifest["links"]), "sourceBytes": sum(item["bytes"] for item in manifest["entries"]),
                     "archiveBytes": archive.stat().st_size, "created": relative in pending}
            entry["bytesSaved"] = entry["sourceBytes"] - entry["archiveBytes"]
            report["archives"].append(entry)
            for key in ("files", "links", "sourceBytes", "archiveBytes", "bytesSaved"):
                report[key] += entry[key]
        report["createdArchives"] = len(pending)
        return report
    finally:
        for temporary in temporary_paths:
            temporary.unlink(missing_ok=True)
