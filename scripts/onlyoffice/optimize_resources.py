"""移除明确的开发演示页，无损合并重复静态资源；保留全部运行能力。"""

from collections import defaultdict
import ctypes
import filecmp
import hashlib
import os
from pathlib import Path
import stat
import sys
import uuid


WEB_RESOURCES = Path("Contents/Resources/editors/web-apps")
EDITOR_RESOURCES = Path("Contents/Resources/editors")
RESOURCES = Path("Contents/Resources")
IMAGE_EXTENSIONS = {".png", ".gif", ".jpg", ".jpeg", ".svg", ".webp"}
STATIC_EXTENSIONS = IMAGE_EXTENSIONS | {".js", ".css", ".json", ".html", ".htm", ".woff", ".woff2", ".ttf", ".otf"}
# 精确列举独立的上游开发入口；不能按 test/example 名称批删，帮助文档包含统计检验及示例。
DEVELOPMENT_FILES = (
    EDITOR_RESOURCES / "web-apps/vendor/monaco/example.html",
    EDITOR_RESOURCES / "sdkjs-plugins/{9DC93CDB-B576-4F0C-B55E-FCC9C48DD007}/vendor/select2-4.0.6-rc.1/docs/examples.html",
)

# macOS 的系统 Python 没有 os.listxattr；只查询属性名称所需长度，不读取属性值。
if sys.platform == "darwin":
    _listxattr = ctypes.CDLL(None, use_errno=True).listxattr
    _listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    _listxattr.restype = ctypes.c_ssize_t


def has_extended_attributes(path):
    if hasattr(os, "listxattr"):
        names = os.listxattr(path, follow_symlinks=False)
    else:
        size = _listxattr(os.fsencode(path), None, 0, 1)  # Darwin XATTR_NOFOLLOW
        if size < 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(path))
        buffer = ctypes.create_string_buffer(size)
        result = _listxattr(os.fsencode(path), buffer, size, 1)
        if result < 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(path))
        names = [os.fsdecode(name) for name in buffer.raw[:result].split(b"\0") if name]
    # 系统自动附加的来源标记不属于图片内容；保留带资源叉或其他自定义属性的独立文件。
    return any(name != "com.apple.provenance" for name in names)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def optimize_resources(application):
    """只处理待签名副本中的静态资源；二进制、模板、字典和独立签名框架不参与。"""
    application = Path(application)
    if application.is_symlink() or not application.is_dir():
        raise ValueError("资源优化要求普通应用目录。")
    application = application.resolve()
    resources = application / RESOURCES
    report = {"schemaVersion": 2, "scope": str(RESOURCES),
              "linkedFiles": 0, "bytesSaved": 0, "links": [],
              "removedFiles": [], "removedBytes": 0}
    if not resources.exists():
        return report
    if resources.is_symlink() or not resources.resolve().is_relative_to(application):
        raise ValueError("资源目录必须位于应用包内。")
    for relative in (EDITOR_RESOURCES, WEB_RESOURCES):
        directory = application / relative
        if directory.is_symlink() or not directory.resolve().is_relative_to(application):
            raise ValueError("编辑器资源目录必须为应用包内的普通目录。")
    for relative in DEVELOPMENT_FILES:
        path = application / relative
        # 不沿任何目录别名删除文件，也不修改带自定义元数据的内容。
        if (path.is_symlink() or not path.is_file()
                or any((application / parent).is_symlink() for parent in relative.parents if parent != Path("."))
                or has_extended_attributes(path)):
            continue
        size = path.stat().st_size
        checksum = sha256(path)
        path.unlink()
        report["removedFiles"].append({"path": str(relative), "sha256": checksum, "bytes": size})
        report["removedBytes"] += size
    candidates = defaultdict(list)
    for directory, directories, names in os.walk(resources, followlinks=False):
        directories[:] = sorted(name for name in directories
                                if not (Path(directory) / name).is_symlink()
                                and not name.lower().endswith((".framework", ".app")))
        for name in sorted(names):
            path = Path(directory) / name
            metadata = path.lstat()
            relative = path.relative_to(application)
            is_editor_asset = relative.is_relative_to(EDITOR_RESOURCES) and path.suffix.lower() in STATIC_EXTENSIONS
            is_file_icon = path.parent == resources and path.suffix.lower() == ".icns"
            # 跳过链接、可执行文件和带扩展属性的文件，避免改变其独立元数据语义。
            if (not (is_editor_asset or is_file_icon) or not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_size < 1024 or metadata.st_mode & 0o111 or has_extended_attributes(path)):
                continue
            candidates[(metadata.st_size, stat.S_IMODE(metadata.st_mode))].append(path)

    for (size, _mode), paths in sorted(candidates.items()):
        if len(paths) < 2:
            continue
        originals = defaultdict(list)
        for path in sorted(paths):
            digest = sha256(path)
            # 哈希用于分组，完整字节比较才决定替换，不能仅凭同名、大小或摘要去重。
            canonical = next((p for p in originals[digest] if filecmp.cmp(p, path, shallow=False)), None)
            if canonical is None:
                originals[digest].append(path)
                continue
            target = os.path.relpath(canonical, path.parent)
            temporary = path.with_name("." + path.name + ".dedupe-" + uuid.uuid4().hex)
            try:
                temporary.symlink_to(target)
                # 原子替换后原路径仍可直接打开；相对链接允许整个 .app 随意移动。
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
            if not path.resolve(strict=True).is_relative_to(resources.resolve()) or sha256(path) != digest:
                raise RuntimeError("去重后的资源校验失败。")
            report["linkedFiles"] += 1
            report["bytesSaved"] += size
            report["links"].append({"path": str(path.relative_to(application)),
                                    "target": target, "sha256": digest, "bytes": size})
    return report
