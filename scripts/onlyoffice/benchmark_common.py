"""性能探针共用的只读源码快照：旧版本只能使用该提交实际存在的文件。"""

import hashlib
from pathlib import Path
import platform
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def resolve_commit(reference):
    # 按提交解析并结束选项，拒绝工作树路径、树对象或被误当成 Git 参数的输入。
    return subprocess.check_output(
        ["git", "rev-parse", "--verify", "--end-of-options", reference + "^{commit}"],
        cwd=ROOT, text=True,
    ).strip()


def revision_paths(revision, directory):
    return [Path(name) for name in subprocess.check_output(
        ["git", "ls-tree", "-r", "--full-tree", "--name-only", revision, "--", str(directory)],
        cwd=ROOT, text=True,
    ).splitlines()]


def browser_paths(revision=None):
    directory = Path("Sources/FileWorkbench")
    paths = revision_paths(revision, directory) if revision else [p.relative_to(ROOT) for p in (ROOT / directory).glob("*.swift")]
    return sorted(p for p in paths if p.suffix == ".swift" and p.name != "FileWorkbenchApp.swift")


def snapshot_sources(paths, destination, probe, probe_data, revision=None):
    destination.mkdir()
    available = None
    if revision:
        available = set(revision_paths(revision, "Sources/FileWorkbench") + revision_paths(revision, "NativeOffice/Workbench"))
    hashes, omitted = {}, []
    for relative in paths:
        # DraftRecoveryStore 等是后续新增的依赖；不能从当前工作树混入旧基线。
        if available is not None and relative not in available:
            omitted.append(relative.as_posix())
            continue
        data = subprocess.check_output(["git", "show", revision + ":" + relative.as_posix()], cwd=ROOT) if revision else (ROOT / relative).read_bytes()
        target = destination / relative.name
        if target.exists():
            raise ValueError("源码快照文件名冲突：" + relative.as_posix())
        target.write_bytes(data)
        hashes[relative.as_posix()] = hashlib.sha256(data).hexdigest()
    if not hashes:
        raise ValueError("基线没有可编译的性能探针源码。")
    # 两个变体使用同一份探针字节，摘要必须对应实际复制并编译的内容。
    (destination / probe.name).write_bytes(probe_data)
    hashes[probe.relative_to(ROOT).as_posix()] = hashlib.sha256(probe_data).hexdigest()
    return hashes, omitted


def environment_info():
    return {"compiler": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
            "os": platform.platform(), "target": "arm64-apple-macos14", "optimization": "-O",
            "samplePolicy": "one nonexclusive sample per variant; baseline runs before current"}


def supports_batch_highlights(source):
    return bool(re.search(r"^\s*static\s+func\s+addHighlights\s*\(", source, re.MULTILINE))
