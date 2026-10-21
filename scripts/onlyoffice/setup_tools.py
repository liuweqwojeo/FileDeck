#!/usr/bin/env python3
"""从已下载且校验固定的 Homebrew bottle 离线准备 qmake；不会安装系统软件。"""

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
from common import BUILD, capture

# 来自 Homebrew qt@5 5.15.19 bottle manifest 的 arm64_sonoma 项；已核对实际归档。
# 缓存文件名开头的哈希是 URL 缓存键，不能用它代替 bottle 内容的 SHA-256。
QT_VERSION = "5.15.19"
QT_BOTTLE_SHA256 = "06e23a0b11dae387d4267b7f497cf57d64373094a876fdfefe1672b935976c58"
QT_BOTTLE_SIZE = 54_796_944
QT_ARCHIVE_ROOT = "qt@5/" + QT_VERSION
DEFAULT_DESTINATION = BUILD / "toolchains" / "qt@5" / QT_VERSION
MAX_EXTRACTED_BYTES = 32 * 1024 * 1024


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def check_destination(destination):
    """不沿目标路径上的符号链接写入，避免缓存路径意外指向其他目录。"""
    destination = Path(os.path.abspath(destination))
    # macOS 的 /var、/tmp 是系统固定别名；临时目录会正常经过这些入口。
    system_aliases = {Path("/var"): Path("/private/var"), Path("/tmp"): Path("/private/tmp")}
    for path in [destination, *destination.parents]:
        if path.is_symlink():
            if sys.platform == "darwin" and system_aliases.get(path) == path.resolve():
                continue
            raise RuntimeError("工具链目标路径包含符号链接：" + str(path))
    return destination.resolve()


def selected_members(archive):
    selected = []
    seen = set()
    total = 0
    prefix = PurePosixPath(QT_ARCHIVE_ROOT)
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or "\\" in member.name:
            raise RuntimeError("归档包含不安全路径：" + member.name)
        try:
            relative = path.relative_to(prefix)
        except ValueError:
            continue
        name = relative.as_posix()
        # 不解压 Qt 框架和插件；它们不参与 AppKit 壳或静态内核的 qmake 构建。
        # 许可证随构建工具保留，避免只复制可执行文件后丢失其使用条款。
        wanted = name == "bin/qmake" or name == "mkspecs" or name.startswith("mkspecs/")
        wanted = wanted or (len(relative.parts) == 1 and name.startswith("LICENSE."))
        if not wanted:
            continue
        if not (member.isfile() or member.isdir()):
            raise RuntimeError("工具链归档不允许链接或特殊文件：" + member.name)
        if name in seen:
            raise RuntimeError("工具链归档包含重复路径：" + member.name)
        seen.add(name)
        total += member.size
        if member.size < 0 or total > MAX_EXTRACTED_BYTES:
            raise RuntimeError("工具链归档解压大小超过限制。")
        selected.append((member, relative))
    required = {"bin/qmake", "mkspecs/features/toolchain.prf", "mkspecs/macx-clang/qmake.conf"}
    regular = {path.as_posix() for member, path in selected if member.isfile()}
    if not required.issubset(regular):
        raise RuntimeError("归档缺少 qmake 或 macOS mkspecs：" + ", ".join(sorted(required - regular)))
    return selected


def tree_signature(root):
    result = {}
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise RuntimeError("已有工具链包含链接或特殊文件：" + str(path))
        relative = path.relative_to(root).as_posix()
        result[relative] = ("file", sha256(path), path.stat().st_mode & 0o7777) if path.is_file() else ("dir",)
    return result


def prepare_qmake(archive_path, destination, *, expected_sha256=QT_BOTTLE_SHA256,
                  expected_size=QT_BOTTLE_SIZE):
    """校验后在同级临时目录解压，完整成功才发布；已有目录只能完全匹配后复用。"""
    archive_path = Path(archive_path).expanduser()
    destination = check_destination(Path(destination).expanduser())
    if not archive_path.is_file():
        raise RuntimeError("找不到本地 Qt bottle：" + str(archive_path))
    if archive_path.stat().st_size != expected_size or sha256(archive_path) != expected_sha256:
        raise RuntimeError("Qt bottle 大小或 SHA-256 不匹配；未修改已有工具链。")
    destination.parent.mkdir(parents=True, exist_ok=True)
    # 排除本脚本的并发安装。异常退出后若锁文件遗留，应确认无进程再人工移除。
    lock = destination.with_name(destination.name + ".setup.lock")
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise RuntimeError("已有工具链准备锁，请确认没有另一个准备进程：" + str(lock)) from None
    os.close(descriptor)
    staging = None
    try:
        staging = Path(tempfile.mkdtemp(prefix=destination.name + ".staging-", dir=destination.parent))
        with tarfile.open(archive_path, mode="r:gz") as archive:
            members = selected_members(archive)
            # 手工白名单复制，不使用 extractall；不保留归档中的所有者或特权权限。
            for member, relative in members:
                target = staging / relative
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, target.open("xb") as output:
                        shutil.copyfileobj(source, output)
                    # mkspecs 内也包含构建辅助脚本；保留可执行性，但去除 setuid 等特权位。
                    target.chmod(0o755 if member.mode & 0o111 or relative.as_posix() == "bin/qmake" else 0o644)
        if destination.exists():
            if not destination.is_dir() or tree_signature(destination) != tree_signature(staging):
                raise RuntimeError("已有工具链与固定归档不一致；保留原目录，请使用新的 --destination。")
            return destination
        staging.rename(destination)
        staging = None
        return destination
    finally:
        if staging is not None:
            shutil.rmtree(staging)
        lock.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qt-archive", required=True, help="qt@5 5.15.19 arm64_sonoma bottle 本地归档")
    parser.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION,
                        help="准备后的 Qt 前缀；已有内容不一致时拒绝覆盖")
    args = parser.parse_args()
    destination = prepare_qmake(args.qt_archive, args.destination)
    code, version = capture([str(destination / "bin/qmake"), "-query", "QT_VERSION"])
    if code or version != QT_VERSION:
        raise RuntimeError("归档已校验并保留，但 qmake 无法运行或版本异常：" + version)
    print("Qt qmake 已准备并验证：" + str(destination))
    print("构建时传入 --qt-prefix " + str(destination))
    print("这里只准备构建工具；Office 编译和离线编辑验收仍需单独完成。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, tarfile.TarError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
