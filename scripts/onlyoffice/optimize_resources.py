"""无损合并 Office 网页中的重复图片；保留每个资源路径和读取内容。"""

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
IMAGE_EXTENSIONS = {".png", ".gif", ".jpg", ".jpeg", ".svg", ".webp"}

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
    """仅在待签名的暂存包内处理图片，不修改脚本、模板、字典或原生代码。"""
    application = Path(application)
    if application.is_symlink() or not application.is_dir():
        raise ValueError("资源优化要求普通应用目录。")
    application = application.resolve()
    resources = application / WEB_RESOURCES
    report = {"schemaVersion": 1, "scope": str(WEB_RESOURCES),
              "linkedFiles": 0, "bytesSaved": 0, "links": []}
    if not resources.exists():
        return report
    if resources.is_symlink() or not resources.resolve().is_relative_to(application):
        raise ValueError("网页资源目录必须位于应用包内。")
    candidates = defaultdict(list)
    for directory, directories, names in os.walk(resources, followlinks=False):
        directories[:] = sorted(name for name in directories if not (Path(directory) / name).is_symlink())
        for name in sorted(names):
            path = Path(directory) / name
            metadata = path.lstat()
            # 跳过链接、可执行文件和带扩展属性的文件，避免改变其独立元数据语义。
            if (path.suffix.lower() not in IMAGE_EXTENSIONS or not stat.S_ISREG(metadata.st_mode)
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
