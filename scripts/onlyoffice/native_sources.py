"""同步本项目原生扩展到上游 Xcode 工程，不覆盖人工修改过的构建输入。"""

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tempfile

from common import ROOT, SOURCE, BUILD

# 浏览页和文档逻辑复用到统一原生应用；SwiftUI @main 入口不能再次编入。
SHARED_SWIFT_SOURCES = (
    "BrowserStore.swift", "CSVDocument.swift", "DocumentIO.swift", "DocumentSession.swift",
    "FileCapabilities.swift", "FileSystem.swift", "MediaOperations.swift", "SafeFileIO.swift",
    "TextDocumentSession.swift", "TextPreviewLoader.swift",
    "ContentView.swift", "FilePreviewView.swift", "FileMetadataView.swift",
    "WorkspaceDesign.swift", "WorkspaceStartupView.swift", "WorkspaceSplitView.swift",
    "WorkspaceEditorBridge.swift", "NewFileTemplate.swift",
)
WORKBENCH_SWIFT_SOURCES = (
    "FWNativeContent.swift", "FWDocumentHost.swift", "FWTextContent.swift", "FWBrowserHost.swift",
    "FWCSVContent.swift", "FWPDFContent.swift", "FWImageContent.swift", "FWQuickLookContent.swift",
    "FWBinaryState.swift", "FWPreviewModal.swift",
)
COORDINATOR_SOURCES = ("FWWorkbenchCoordinator.h", "FWWorkbenchCoordinator.mm")
SMOKE_SOURCES = ("FWOfficeSmoke.h", "FWOfficeSmoke.mm")
REQUIRED_EDITOR_RESOURCES = {
    "index.html", "editor.js", "editor.css", "editor.js.LEGAL.txt", "THIRD-PARTY-NOTICES.txt",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".fw-native-", delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def require_plain_path(path):
    if path.is_symlink() or path.resolve() != path.absolute():
        raise RuntimeError("原生输入路径不能经过符号链接：" + str(path))


def relative_name(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or ".." in path.parts or "\\" in name or path.as_posix() != name:
        raise RuntimeError("原生输入清单含越界路径：" + str(name))
    return name


def directory_files(directory):
    require_plain_path(directory)
    files = set()
    if directory.exists():
        for path in directory.rglob("*"):
            require_plain_path(path)
            if path.is_file():
                files.add(path.relative_to(directory).as_posix())
            elif not path.is_dir():
                raise RuntimeError("原生输入包含非普通文件：" + str(path))
    return files


def plan_sync(inputs, destination, manifest, expected=None):
    """先验证完整输入和全部目标，任何缺失或人工修改都在写入前失败。"""
    require_plain_path(destination)
    require_plain_path(manifest)
    previous = json.loads(manifest.read_text()) if manifest.exists() else {}
    if not isinstance(previous, dict) or any(not isinstance(name, str) or not isinstance(value, str)
                                             or not re.fullmatch(r"[0-9a-f]{64}", value)
                                             for name, value in previous.items()):
        raise RuntimeError("原生同步摘要清单损坏：" + str(manifest))
    for name in set(inputs) | set(previous):
        relative_name(name)
    missing = [str(path) for path in inputs.values() if not path.is_file()]
    if missing:
        raise RuntimeError("缺少原生构建输入：" + ", ".join(missing))
    unknown = directory_files(destination) - set(inputs) - set(previous)
    if unknown:
        raise RuntimeError("原生输入目标含未登记文件，已保留：" + ", ".join(sorted(unknown)))
    updated, changes, removals = {}, [], []
    for name, source in sorted(inputs.items()):
        require_plain_path(source)
        target = destination / name
        data = source.read_bytes()
        checksum = digest(data)
        if expected is not None and checksum != expected[name]:
            raise RuntimeError("编辑资源与 manifest 摘要不一致：" + str(source))
        require_plain_path(target)
        if target.exists():
            if not target.is_file():
                raise RuntimeError("原生输入目标不是普通文件：" + str(target))
            actual = digest(target.read_bytes())
            if actual != checksum and actual != previous.get(name):
                raise RuntimeError("原生输入含未同步的本地修改，已保留：" + str(target))
            if actual != checksum:
                changes.append((target, data))
        else:
            changes.append((target, data))
        updated[name] = checksum
    # 已从显式清单撤下的生成输入只能删除旧摘要仍一致的副本，不能误删人工修改。
    for name in sorted(set(previous) - set(inputs)):
        target = destination / name
        require_plain_path(target)
        if target.exists():
            if not target.is_file() or digest(target.read_bytes()) != previous[name]:
                raise RuntimeError("已撤下的原生输入含本地修改，已保留：" + str(target))
            removals.append(target)
    return changes, removals, manifest, updated


def publish_plans(plans):
    for changes, removals, _, _ in plans:
        for path, data in changes:
            write_atomic(path, data)
        for path in removals:
            path.unlink()
    for _, _, manifest, updated in plans:
        write_atomic(manifest, (json.dumps(updated, indent=2, ensure_ascii=False) + "\n").encode())


def sync_sources(origin, destination, manifest):
    """保留 Office 烟测同步入口，供独立验收和已有测试复用。"""
    inputs = {name: origin / name for name in SMOKE_SOURCES}
    publish_plans([plan_sync(inputs, destination, manifest)])


def workbench_inputs(root):
    inputs = {name: root / "Sources/FileWorkbench" / name for name in SHARED_SWIFT_SOURCES}
    inputs.update({name: root / "NativeOffice/Workbench" / name
                   for name in WORKBENCH_SWIFT_SOURCES + COORDINATOR_SOURCES})
    return inputs


def editor_inputs(origin):
    manifest = origin / "manifest.json"
    require_plain_path(manifest)
    if not manifest.is_file():
        raise RuntimeError("缺少编辑资源 manifest：" + str(manifest))
    data = manifest.read_bytes()
    metadata = json.loads(data)
    if not isinstance(metadata, dict):
        raise RuntimeError("编辑资源 manifest 必须是对象。")
    files = metadata.get("files")
    if metadata.get("schema") != 1 or not isinstance(files, dict) or not REQUIRED_EDITOR_RESOURCES.issubset(files):
        raise RuntimeError("编辑资源 manifest 不完整，必须包含编辑器、许可证和第三方声明。")
    for name, value in files.items():
        relative_name(name)
        if name == "manifest.json" or not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise RuntimeError("编辑资源 manifest 摘要无效：" + name)
    expected = {**files, "manifest.json": digest(data)}
    actual = directory_files(origin)
    if actual != set(expected):
        raise RuntimeError("编辑资源目录与显式清单不一致，缺失：%s；未登记：%s" %
                           (sorted(set(expected) - actual), sorted(actual - set(expected))))
    return {name: origin / name for name in expected}, expected


def verify_editor_bundle(bundle, origin=ROOT / "Resources/Editors"):
    """构建结束核对最终资源，避免把上游 editors 目录误当作本地编辑器。"""
    _, expected = editor_inputs(origin)
    if directory_files(bundle) != set(expected):
        raise RuntimeError("应用内 FileWorkbenchEditors 资源清单不完整或含未登记文件。")
    for name, checksum in expected.items():
        if digest((bundle / name).read_bytes()) != checksum:
            raise RuntimeError("应用内编辑资源摘要不一致：" + name)


def prepare_native_sources(root=ROOT, source=SOURCE, build=BUILD):
    destination = source / "desktop-apps/macos/ONLYOFFICE"
    resources, expected = editor_inputs(root / "Resources/Editors")
    plans = [
        plan_sync({name: root / "NativeOffice/Smoke" / name for name in SMOKE_SOURCES},
                  destination / "FileWorkbenchSmoke", build / "native-sources.json"),
        plan_sync(workbench_inputs(root), destination / "FileWorkbenchNative", build / "workbench-native-sources.json"),
        plan_sync(resources, destination / "FileWorkbenchEditors", build / "workbench-editor-resources.json", expected),
    ]
    publish_plans(plans)
