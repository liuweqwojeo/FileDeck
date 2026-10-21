#!/usr/bin/env python3
"""离线记录已取得的 ONLYOFFICE 第三方依赖；凭据不是下载锁文件或构建成功证明。"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit, urlunsplit

sys.dont_write_bytecode = True
from common import BUILD, SOURCE, find_qt_prefix, tool_path

SCHEMA_VERSION = 1
THIRD_PARTY = "core/Common/3dParty"
SCAN_ROOTS = (THIRD_PARTY, "build_tools/tools/mac")
ARCHIVE_SUFFIXES = (".7z", ".zip", ".tar", ".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz")
EXCLUDED = {".git", ".cache", "cache", "caches", "node_modules", "__pycache__", "out", "output",
            "obj", "objects", ".objs", "bin.v2", "stage", "build", "release", "debug",
            "cmakefiles", "deriveddata", "dist"}
MAX_DISCOVERY_DEPTH = 4
AUDIT_FILES = (
    "build_tools/scripts/core_common/make_common.py", "build_tools/scripts/deploy_desktop.py",
    "build_tools/scripts/build_js.py",
    "build_tools/scripts/base.py",
    "build_tools/scripts/core_common/modules/boost.py", "build_tools/scripts/core_common/modules/cef.py",
    "build_tools/scripts/core_common/modules/pinned_binary.py",
    "build_tools/scripts/core_common/modules/icu.py", "build_tools/scripts/core_common/modules/openssl.py",
    "build_tools/scripts/core_common/modules/hyphen.py", "build_tools/scripts/core_common/modules/googletest.py",
    "build_tools/scripts/core_common/modules/heif.py", "core/Common/3dParty/apple/fetch.py",
    "core/Common/3dParty/html/fetch.py", "core/Common/3dParty/md/fetch.py",
    "core/Common/3dParty/hunspell/before.py", "core/Common/3dParty/hunspell/HEAD",
    "core/Common/3dParty/harfbuzz/make.py", "core/Common/3dParty/brotli/make.py",
    "build_tools/tools/mac/7za", "build_tools/tools/mac/toolchain.prf",
)

# 审计对象是当前锁定的 mac_arm64 desktop 路径；非本路线的 V8/Android 下载不纳入结论。
# 同时记录这些脚本的哈希，之后脚本变更时不能沿用这一静态审计结论。
SOURCE_RISKS = [
    {"dependency": "CEF 5414", "source": "https://github.com/ONLYOFFICE-data/build_tools_data/raw/refs/heads/master/cef/5414/mac_arm64/cef_binary.7z",
     "pin": "upstream-mutable-url; project-patch-003-available",
     "projectLock": "scripts/onlyoffice/binary-dependencies.lock.json",
     "projectPatch": "scripts/onlyoffice/patches/build_tools-003-cef-pinned-download.patch",
     "detail": "此项描述未打补丁的上游：master URL 可变，仅比较 Last-Modified。应用项目 003 补丁后，默认 mac_arm64 使用经官方 Git blob 核对的固定提交 URL、大小和 SHA-256，并在解包前执行 7za t；显式 CEF 107 和其他平台保留上游行为。凭据记录当前 cef.py 与固定下载模块的哈希，不能仅凭锁文件存在判断补丁已生效。"},
    {"dependency": "hyphen", "source": "https://github.com/hunspell/hyphen", "pin": "project-source-commit",
     "projectLock": "scripts/onlyoffice/versions.lock.json",
     "detail": "未准备源码时上游直接 clone 默认分支；项目已把嵌套仓库加入 versions.lock.json，fetch.py 预取固定提交，require_sources 在构建前核验 HEAD。必须使用项目构建入口，直接运行上游 make.py 会绕过此约束。"},
    {"dependency": "ICU 74.2", "source": "https://github.com/unicode-org/icu.git", "pin": "release-74-2",
     "detail": "克隆标签后仅复制 icu4c 并删除 Git 元数据；最终源码目录无法由现存 HEAD 反推，凭据不哈希整个源码树。"},
    {"dependency": "Boost 1.72.0", "source": "https://github.com/boostorg/boost.git", "pin": "boost-1.72.0",
     "detail": "父仓库按标签获取；凭据递归记录已初始化子模块实际 HEAD 和 remotes，不下载缺失子模块。"},
    {"dependency": "OpenSSL", "source": "https://github.com/openssl/openssl.git", "pin": "OpenSSL_1_1_1f",
     "detail": "标签未由下载器额外校验 SHA；记录取得后的实际 HEAD。"},
    {"dependency": "GoogleTest", "source": "https://github.com/google/googletest.git", "pin": "v1.13.0",
     "detail": "make_common 仍调用获取步骤；标签未额外校验 SHA。"},
    {"dependency": "HEIF 编解码器", "source": "build_tools/scripts/core_common/modules/heif.py",
     "pin": "x265 Release_4.1 / libde265 v1.0.16 / libheif v1.18.2",
     "detail": "按标签浅克隆；凭据记录实际提交，标签本身不是内容哈希。"},
    {"dependency": "HTML / Markdown / iWork / HarfBuzz / Brotli / Hunspell", "source": "core/Common/3dParty/*/fetch.py 或 make.py",
     "pin": "source-commit", "detail": "脚本中已有固定提交；仍需保存上游打补丁后的来源和修改，凭据只记录 Git 身份、不记录整个工作区。"},
    {"dependency": "编辑器插件入口", "source": "https://onlyoffice.github.io/sdkjs-plugins/v1/",
     "pin": "upstream-mutable-url; project-patch-005-available",
     "projectLock": "scripts/onlyoffice/versions.lock.json",
     "projectPatch": "scripts/onlyoffice/patches/build_tools-005-local-plugin-entries.patch",
     "detail": "未打补丁的 deploy_desktop 与 base 使用动态 URL。应用项目 005 补丁后，三个入口及旧版 pluginBase.js 均取自已固定的 onlyoffice.github.io 仓库；本凭据记录部署脚本哈希，不记录该仓库及输出内容，仓库 HEAD 由项目构建入口另行核验。"},
    {"dependency": "npm / Grunt 传递依赖", "source": "sdkjs / web-apps 构建步骤", "pin": "outside-scope",
     "detail": "node_modules、缓存和前端依赖树不在本凭据范围内；工具版本不等于传递依赖已锁定。"},
]


def relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "\\" in value:
        raise RuntimeError("凭据路径越界：" + str(value))
    return path


def source_path(source, relative):
    path = relative_path(relative)
    allowed = any(path == PurePosixPath(root) or PurePosixPath(root) in path.parents for root in SCAN_ROOTS)
    if not allowed and path.as_posix() not in AUDIT_FILES:
        raise RuntimeError("凭据路径不属于依赖审计范围：" + relative)
    target = source / path
    # 路径中任意目录链接均不跟随；Git 子模块 .git 文件另做边界验证。
    if target.resolve() != target:
        raise RuntimeError("依赖路径包含符号链接：" + relative)
    return target


def fingerprint(stat):
    return {"size": stat.st_size, "mtimeNs": stat.st_mtime_ns, "ctimeNs": stat.st_ctime_ns,
            "inode": stat.st_ino, "device": stat.st_dev}


def file_record(source, relative, cached=None, rehash=False):
    path = source_path(source, relative)
    if not path.is_file():
        raise RuntimeError("凭据文件缺失或不是普通文件：" + relative)
    before = fingerprint(path.stat())
    if (not rehash and cached and cached.get("stat") == before
            and re.fullmatch(r"[0-9a-f]{64}", cached.get("sha256", ""))):
        digest = cached["sha256"]
    else:
        hasher = hashlib.sha256()
        # 大归档流式读取；快照可复用未变 inode/时间/大小的哈希，verify 总是重新计算。
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(block)
        digest = hasher.hexdigest()
    if fingerprint(path.stat()) != before:
        raise RuntimeError("依赖文件仍在写入，请下载完成后重试：" + relative)
    return {"path": relative, "size": before["size"], "sha256": digest, "stat": before}


def run(arguments):
    environment = os.environ.copy()
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"):
        environment.pop(key, None)
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            errors="replace", env=environment, timeout=20, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.strip()[:1000] or "命令失败：" + arguments[0])
    return result.stdout.strip()


def redacted_remote(value):
    if "://" not in value:
        return value
    parsed = urlsplit(value)
    host = parsed.netloc.rsplit("@", 1)[-1]
    return urlunsplit((parsed.scheme, host, parsed.path, "", ""))


def git_command(source, relative):
    directory = source_path(source, relative)
    marker = directory / ".git"
    if marker.is_symlink():
        raise RuntimeError("Git 元数据为符号链接：" + relative)
    if marker.is_dir():
        gitdir = marker
    elif marker.is_file() and marker.stat().st_size <= 4096:
        text = marker.read_text(encoding="utf-8").strip()
        if not text.startswith("gitdir: "):
            raise RuntimeError("无效 Git 元数据：" + relative)
        raw = Path(os.path.abspath(directory / text[8:]))
        gitdir = source_path(source, raw.relative_to(source).as_posix())
    else:
        raise RuntimeError("没有独立 Git 元数据：" + relative)
    if (gitdir / "commondir").exists():
        raise RuntimeError("不读取指向共享 worktree 的 Git 元数据：" + relative)
    return ["git", "--git-dir=" + str(gitdir), "--work-tree=" + str(directory)]


def repository_record(source, relative):
    command = git_command(source, relative)
    head = run(command + ["rev-parse", "--verify", "HEAD"])
    remotes = {}
    for name in run(command + ["remote"]).splitlines():
        remotes[name] = [redacted_remote(url) for url in run(command + ["remote", "get-url", "--all", name]).splitlines()]
    return {"path": relative, "head": head, "remotes": remotes}


def discover(source):
    repositories, archives, warnings = set(), set(), []

    def visit_repository(relative):
        if relative in repositories:
            return
        try:
            command = git_command(source, relative)
            repositories.add(relative)
            modules = source_path(source, relative + "/.gitmodules")
            if not modules.is_file():
                return
            if modules.stat().st_size > 2 * 1024 * 1024:
                raise RuntimeError(".gitmodules 超过读取上限：" + relative)
            # 仅读取 gitlink 路径；不执行 submodule foreach 或源仓库提供的命令。
            output = run(command + ["config", "--no-includes", "--file", str(modules), "--null",
                                    "--get-regexp", r"^submodule\..*\.path$"])
            for item in output.split("\0"):
                if not item:
                    continue
                child = relative_path(item.split("\n", 1)[1]).as_posix()
                path = source_path(source, relative + "/" + child)
                if (path / ".git").exists():
                    visit_repository(path.relative_to(source).as_posix())
                else:
                    warnings.append("子模块尚未初始化：" + relative + "/" + child)
        except (RuntimeError, ValueError, IndexError) as error:
            warnings.append(str(error))

    for relative in SCAN_ROOTS:
        try:
            root = source_path(source, relative)
        except RuntimeError as error:
            warnings.append(str(error))
            continue
        if not root.is_dir():
            warnings.append("扫描目录尚不存在：" + relative)
            continue
        for directory, folders, files in os.walk(root, followlinks=False):
            path = Path(directory)
            rel = path.relative_to(source).as_posix()
            if (path / ".git").exists() or (path / ".git").is_symlink():
                visit_repository(rel)
                folders[:] = []
                continue
            folders[:] = [name for name in folders if name.lower() not in EXCLUDED and not (path / name).is_symlink()]
            if len(path.relative_to(root).parts) >= MAX_DISCOVERY_DEPTH:
                folders[:] = []
            for name in files:
                if name.lower().endswith(ARCHIVE_SUFFIXES) and not (path / name).is_symlink():
                    archives.add((path / name).relative_to(source).as_posix())
    return sorted(repositories), sorted(archives), warnings


def tool_versions(qt_prefix=None):
    versions = []
    commands = {"git": ["--version"], "xcodebuild": ["-version"], "clang": ["--version"],
                "cmake": ["--version"], "node": ["--version"], "npm": ["--version"],
                "autoconf": ["--version"], "automake": ["--version"], "pkg-config": ["--version"],
                "nasm": ["--version"], "grunt": ["--version"]}
    for name, arguments in commands.items():
        executable = tool_path(name)
        try:
            version = run([executable, *arguments])[:2000] if executable else None
            versions.append({"name": name, "path": executable, "version": version})
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            versions.append({"name": name, "path": executable, "version": None, "error": str(error)[:300]})
    versions.append({"name": "python", "path": sys.executable, "version": sys.version})
    qt = find_qt_prefix(qt_prefix or str(BUILD / "toolchains/qt@5/5.15.19"))
    versions.append({"name": "qmake", "path": str(qt / "bin/qmake") if qt else None,
                     "version": run([str(qt / "bin/qmake"), "-query", "QT_VERSION"]) if qt else None})
    return versions


def snapshot(source=SOURCE, previous=None, rehash=False, tools=None):
    source = Path(source).resolve()
    repositories, archives, warnings = discover(source)
    previous_files = {entry["path"]: entry for section in ("archives", "supportFiles")
                      for entry in (previous or {}).get(section, [])}
    receipt = {"schemaVersion": SCHEMA_VERSION, "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "scope": {"roots": list(SCAN_ROOTS), "discoveryDepth": MAX_DISCOVERY_DEPTH,
                         "excludedDirectories": sorted(EXCLUDED), "gitCheck": "HEAD and credential-redacted remotes only"},
               "repositories": [], "archives": [], "supportFiles": [], "tools": tools if tools is not None else tool_versions(),
               "sourceRisks": SOURCE_RISKS, "warnings": warnings,
               "limitations": ["不联网、不固定未来下载；不是逐字节可复现构建承诺。",
                               "不是跨仓库原子快照；最终凭据应在下载和源码更新结束后生成并验证。",
                               "不校验 Git 工作区修改、未跟踪文件、已丢弃 Git 元数据的源码树或构建产物。",
                               "发现 Git 仓库后不遍历其源文件；仅按 .gitmodules 递归检查已初始化子模块。",
                               "快照可复用统计属性未变文件的哈希；--verify 总是重算已记录文件哈希。"]}
    for relative in repositories:
        try:
            receipt["repositories"].append(repository_record(source, relative))
        except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            warnings.append("Git 状态未完成：" + relative + "：" + str(error))
    for section, paths in (("archives", archives), ("supportFiles", AUDIT_FILES)):
        for relative in paths:
            try:
                path = source_path(source, relative)
                if section == "supportFiles" and not path.exists():
                    continue
                receipt[section].append(file_record(source, relative, previous_files.get(relative), rehash))
            except (RuntimeError, OSError) as error:
                warnings.append(str(error))
    return receipt


def verify(receipt, source=SOURCE, tools=None):
    if receipt.get("schemaVersion") != SCHEMA_VERSION:
        raise RuntimeError("不支持的凭据版本。")
    source = Path(source).resolve()
    failures = []
    for section in ("archives", "supportFiles"):
        for recorded in receipt.get(section, []):
            try:
                actual = file_record(source, recorded["path"], rehash=True)
                if actual["size"] != recorded["size"] or actual["sha256"] != recorded["sha256"]:
                    failures.append("文件内容变化：" + recorded["path"])
            except (RuntimeError, OSError) as error:
                failures.append(str(error))
    for recorded in receipt.get("repositories", []):
        try:
            if repository_record(source, recorded["path"]) != recorded:
                failures.append("Git HEAD 或 remote 变化：" + recorded["path"])
        except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures.append(str(error))
    current_tools = {entry["name"]: entry for entry in (tools if tools is not None else tool_versions())}
    for recorded in receipt.get("tools", []):
        actual = current_tools.get(recorded["name"], {})
        if actual.get("version") != recorded.get("version") or actual.get("path") != recorded.get("path"):
            failures.append("工具版本或路径变化：" + recorded["name"])
    return failures


def write_receipt(receipt, output, build=BUILD):
    build = Path(build).resolve()
    output = Path(os.path.abspath(output))
    if output.is_symlink() or not output.resolve().is_relative_to(build):
        raise RuntimeError("凭据只能写入项目 build/onlyoffice 内的普通文件。")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".dependency-receipt-", dir=output.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(receipt, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=BUILD / "dependency-receipt.json")
    parser.add_argument("--verify", type=Path, metavar="RECEIPT", help="只检查已记录条目；不更新凭据")
    parser.add_argument("--list", action="store_true", help="仅显示审计范围和未完全固定的下载来源")
    parser.add_argument("--rehash", action="store_true", help="快照不复用已有文件哈希")
    parser.add_argument("--qt-prefix")
    args = parser.parse_args()
    if args.list:
        print(json.dumps({"scope": SCAN_ROOTS, "sourceRisks": SOURCE_RISKS}, ensure_ascii=False, indent=2))
        return 0
    if args.verify:
        receipt = json.loads(args.verify.read_text(encoding="utf-8"))
        failures = verify(receipt, tools=tool_versions(args.qt_prefix))
        print("\n".join(failures) if failures else "已记录的文件、Git HEAD/remote 和工具版本一致；未覆盖项仍以凭据限制为准。")
        return 1 if failures else 0
    previous = json.loads(args.output.read_text(encoding="utf-8")) if args.output.is_file() else None
    receipt = snapshot(previous=previous, rehash=args.rehash, tools=tool_versions(args.qt_prefix))
    write_receipt(receipt, args.output)
    print("依赖凭据已保存：" + str(args.output))
    print("%d 个 Git 仓库，%d 个归档，%d 条未完成/跳过提示；不代表 Office 构建验收。" %
          (len(receipt["repositories"]), len(receipt["archives"]), len(receipt["warnings"])))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
