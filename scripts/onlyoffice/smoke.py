#!/usr/bin/env python3
"""启动真实 CEF 编辑器离线验收；只检验本次新建目录，不伪造 Office 文件或替代应用运行。"""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
import zipfile

from common import BUILD

CASES = {"docx": "word.docx", "xlsx": "cell.xlsx", "pptx": "slide.pptx"}
REQUIRED_STAGES = ("created", "edited", "saved", "closed", "reopened", "verifiedInEditor", "closedAfterReopen")
RECOVERY_STAGES = ("editorSynchronized", "terminationInjected", "firstPanelPresented", "cancelPreservedDraft",
                   "secondPanelPresented", "saveCompleted", "sourceUnchanged", "recoveredTextVerified",
                   "dirtyCleared", "closedAndReleased", "passed")
RECOVERY_FILE = "mixed-恢复草稿.txt"
RECOVERY_DRAFT_SUFFIX = " recovery draft e\u0301 🌱"
NETWORK_POLICY = "sandbox-exec-deny-network"
WORKBENCH_TEST_SUITE_PREFIX = "local.fileworkbench.ui-test-"
MAX_ZIP_BYTES = 64 * 1024 * 1024
MAX_XML_BYTES = 16 * 1024 * 1024


def read_json(path, maximum=64 * 1024):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
        raise RuntimeError("结果必须是有大小上限的普通 JSON 文件：" + str(path))
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("JSON 顶层必须是对象：" + str(path))
    return value


def write_new_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def app_executable(app):
    app = app.expanduser().resolve(strict=True)
    if not app.is_dir() or app.suffix != ".app":
        raise RuntimeError("--app 必须指向已构建的 macOS .app。")
    with (app / "Contents" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise RuntimeError("应用没有有效的 CFBundleExecutable。")
    executable = app / "Contents" / "MacOS" / name
    if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError("应用主程序不存在、不可执行或是符号链接。")
    try:
        executable.resolve().relative_to(app)
    except ValueError as error:
        raise RuntimeError("应用主程序不能位于包外。") from error
    if executable.resolve().parent != (app / "Contents" / "MacOS").resolve():
        raise RuntimeError("应用主程序不能位于包外。")
    return executable


def compressed_resource_samples(app):
    """抽取各帮助根的正文、索引、图片和跨目录链接，交给真实 CEF 核对响应摘要。"""
    from compress_help import HELP_ROOTS, verify_help_archive
    entries, manifests = {}, {}
    for relative in HELP_ROOTS:
        archive = app / relative.with_suffix(".zip")
        manifest = verify_help_archive(archive)
        manifests[relative] = manifest
        for entry in manifest["entries"]:
            entries[(app / relative / entry["path"]).as_posix()] = (relative, entry)
    samples = []
    for relative, manifest in manifests.items():
        selected = set()
        for extension in (".htm", ".html", ".js", ".css", ".json", ".png", ".gif"):
            match = next((item for item in manifest["entries"] if item["kind"] == "file"
                          and Path(item["path"]).suffix == extension), None)
            if match:
                selected.add(match["path"])
        # 每种已打包语言的目录索引都走一次压缩读取，避免只验证英文帮助。
        selected.update(item["path"] for item in manifest["entries"] if item["path"].endswith("/Contents.json"))
        selected.update(list(manifest["links"])[:2])
        for name in sorted(selected):
            path = app / relative / name
            target = path
            for _ in range(17):
                owner, entry = entries[target.as_posix()]
                if entry["kind"] != "symlink":
                    break
                target = Path(os.path.normpath(target.parent / manifests[owner]["links"][entry["path"]]))
            else:
                raise RuntimeError("帮助测试样本链接循环。")
            samples.append({"url": path.as_uri(), "bytes": entry["bytes"], "sha256": entry["sha256"]})
    return samples


def create_run_directory(parent, deadline_seconds, workbench=False, compression_samples=None, recovery_panel=False):
    if not 30 <= deadline_seconds <= 1800:
        raise RuntimeError("截止时长必须为 30 到 1800 秒。")
    parent = parent.expanduser().resolve()
    parent.mkdir(parents=True, exist_ok=True)
    # 保存与重新打开必须经过中文及空格路径，覆盖原生路径与 CEF 字符串转换边界。
    directory = Path(tempfile.mkdtemp(prefix="fw-office-smoke-中文 路径-", dir=parent)).resolve()
    directory.chmod(0o700)
    token = str(uuid.uuid4())
    request = {"schemaVersion": 1, "token": token, "marker": "文件工作台离线验收-" + token,
               "deadlineUnix": time.time() + deadline_seconds, "networkPolicy": NETWORK_POLICY,
               "workbenchTestSuite": WORKBENCH_TEST_SUITE_PREFIX + token}
    if workbench or recovery_panel:
        request["workbench"] = True
    if recovery_panel:
        request["recoveryPanel"] = True
    if compression_samples is not None:
        request["compressionSamples"] = compression_samples
    write_new_json(directory / "request.json", request)
    return directory, request


def verify_ooxml(path, extension, marker):
    """按正文节点读取标记；元数据中的同名字符串不能冒充真正写入的内容。"""
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_ZIP_BYTES:
        raise RuntimeError("Office 输出不是大小合理的普通文件：" + path.name)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(entries) > 4096 or len(set(names)) != len(names):
            raise RuntimeError("OOXML 条目过多或包含重名条目。")
        if sum(entry.file_size for entry in entries) > MAX_ZIP_BYTES:
            raise RuntimeError("OOXML 解压后超过验收大小上限。")
        for entry in entries:
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or ".." in name.parts or "\\" in entry.filename or entry.flag_bits & 1:
                raise RuntimeError("OOXML 包含不安全的路径或加密条目。")
        if "[Content_Types].xml" not in names:
            raise RuntimeError("输出不是完整 OOXML 包。")

        def xml(name):
            try:
                entry = archive.getinfo(name)
            except KeyError as error:
                raise RuntimeError("OOXML 缺少必要正文部件：" + name) from error
            if entry.file_size > MAX_XML_BYTES:
                raise RuntimeError("OOXML XML 超过验收大小上限。")
            return ET.fromstring(archive.read(name))

        found_in = []
        if extension == "docx":
            namespace = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
            root = xml("word/document.xml")
            if marker in "".join(node.text or "" for node in root.iter(namespace + "t")):
                found_in.append("word/document.xml")
        elif extension == "xlsx":
            namespace = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
            strings = []
            if "xl/sharedStrings.xml" in names:
                strings = ["".join(node.text or "" for node in item.iter(namespace + "t"))
                           for item in xml("xl/sharedStrings.xml").findall(namespace + "si")]
            for name in names:
                if not name.startswith("xl/worksheets/sheet") or not name.endswith(".xml"):
                    continue
                for cell in xml(name).iter(namespace + "c"):
                    value_node = cell.find(namespace + "v")
                    value = value_node.text if value_node is not None and value_node.text else ""
                    if cell.get("t") == "s":
                        index = int(value)
                        if not 0 <= index < len(strings):
                            raise RuntimeError("XLSX 单元格引用了不存在的共享字符串。")
                        value = strings[index]
                    elif cell.get("t") == "inlineStr":
                        value = "".join(node.text or "" for node in cell.iter(namespace + "t"))
                    if marker in value:
                        found_in.append(name)
                        break
        elif extension == "pptx":
            namespace = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
            for name in names:
                if name.startswith("ppt/slides/slide") and name.endswith(".xml"):
                    if marker in "".join(node.text or "" for node in xml(name).iter(namespace + "t")):
                        found_in.append(name)
        else:
            raise RuntimeError("不支持的验收格式：" + extension)
        if not found_in:
            raise RuntimeError(path.name + " 的正文中没有本次唯一中文标记。")
        return {"format": extension, "file": path.name, "bytes": info.st_size, "markerParts": found_in}


def verify_run(directory):
    directory = Path(directory).expanduser().absolute()
    if directory.is_symlink() or directory.resolve() != directory:
        raise RuntimeError("验收目录不能经过符号链接。")
    request = read_json(directory / "request.json", 65536)
    native = read_json(directory / "native-result.json")
    token = request.get("token")
    try:
        uuid.UUID(token)
    except (ValueError, TypeError, AttributeError) as error:
        raise RuntimeError("请求令牌无效。") from error
    marker = request.get("marker")
    if request.get("schemaVersion") != 1 or marker != "文件工作台离线验收-" + token:
        raise RuntimeError("请求版本或中文标记无效。")
    if request.get("networkPolicy") != NETWORK_POLICY:
        raise RuntimeError("此运行没有声明所需的进程网络隔离。")
    if "workbenchTestSuite" in request and request["workbenchTestSuite"] != WORKBENCH_TEST_SUITE_PREFIX + token:
        raise RuntimeError("工作台测试偏好域与本次令牌不一致。")
    if native.get("schemaVersion") != 1 or native.get("token") != token:
        raise RuntimeError("原生结果不属于本次测试。")
    if native.get("status") != "passed":
        raise RuntimeError("原生验收未通过：" + str(native.get("error", native.get("phase", "unknown"))))
    if native.get("profileIsolated") is not True:
        raise RuntimeError("原生应用数据目录未隔离。")
    cases = native.get("cases")
    if not isinstance(cases, list) or len(cases) != len(CASES):
        raise RuntimeError("原生结果缺少三种格式的完整记录。")
    verified = []
    seen = set()
    for case in cases:
        if not isinstance(case, dict):
            raise RuntimeError("原生用例必须为对象。")
        extension = case.get("format")
        if extension not in CASES or extension in seen or case.get("file") != CASES[extension] or case.get("marker") != marker:
            raise RuntimeError("原生用例格式、路径或标记不匹配。")
        if not all(case.get(stage) is True for stage in REQUIRED_STAGES):
            raise RuntimeError(extension + " 未完成真实编辑、保存、关闭和重开验证。")
        seen.add(extension)
        verified.append(verify_ooxml(directory / CASES[extension], extension, marker))
    workbench = None
    if request.get("workbench") is True:
        workbench = native.get("workbench")
        stages = ("passed", "textEditedInWebKit", "nativeSaveRoutedWhileSwitching", "nativeCloseVerified",
                  "pdfNativeTabVerified", "officeRetainedUnsavedChanges", "browserEmbedded",
                  "editorStillInBrowserWindow", "modalWindowCloseProtected", "modalQuitProtected", "modalDiscardClosed")
        if not isinstance(workbench, dict) or not all(workbench.get(stage) is True for stage in stages):
            raise RuntimeError("未完成混合文档、保存路由、模态窗口关闭/退出保护与状态保留验证。")
        path = directory / "mixed.txt"
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 16384:
            raise RuntimeError("混合文本输出不是受限普通文件。")
        if path.read_bytes() != (marker + "\r\n").encode("utf-8"):
            raise RuntimeError("混合文本正文或原始换行未正确保存。")
    recovery = None
    if request.get("recoveryPanel") is True:
        recovery = native.get("recoveryPanel")
        if request.get("workbench") is not True or not isinstance(recovery, dict) or not all(
                recovery.get(stage) is True for stage in RECOVERY_STAGES):
            raise RuntimeError("未完成恢复草稿的真实系统面板取消、保存与关闭释放验收。")
        expected_path = str(directory / RECOVERY_FILE)
        if (recovery.get("sourceFile") != "mixed.txt" or recovery.get("destinationFile") != RECOVERY_FILE
                or recovery.get("lastSavedPath") != expected_path or recovery.get("panelSelectedPath") != expected_path):
            raise RuntimeError("恢复草稿的实际系统面板选择或保存路径不匹配。")
        # 独立重读真实文件；只有状态布尔值或标记包含关系不能证明完整草稿已抢救。
        path = directory / RECOVERY_FILE
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 16384:
            raise RuntimeError("恢复草稿输出不是受限普通文件。")
        if path.read_bytes() != (marker + RECOVERY_DRAFT_SUFFIX).encode("utf-8"):
            raise RuntimeError("恢复草稿正文与已同步的完整内容不一致。")
        checkpoint = read_json(directory / "recovery-panel-checkpoint.json")
        if (checkpoint.get("schemaVersion") != 1 or checkpoint.get("token") != token
                or checkpoint.get("phase") != "completed" or checkpoint.get("directory") != str(directory)
                or checkpoint.get("sourceFile") != "mixed.txt" or checkpoint.get("expectedFileName") != RECOVERY_FILE
                or checkpoint.get("expectedPath") != expected_path or checkpoint.get("checks") != recovery):
            raise RuntimeError("恢复面板进度与本次运行的最终结果不一致。")
    if "compressionSamples" in request:
        if not all(case.get("compressedResourcesVerified") is True for case in cases):
            raise RuntimeError("压缩资源未通过真实 CEF 帮助面板与原生拼写检查验收。")
    return {"schemaVersion": 1, "status": "passed", "directory": str(directory), "cases": verified,
            "workbench": workbench,
            "workbenchTestSuite": request.get("workbenchTestSuite"),
            "recoveryPanel": recovery,
            "compressedResourcesVerified": "compressionSamples" in request,
            "networkPolicy": NETWORK_POLICY, "inputMethod": native.get("inputMethod"),
            "limitations": ["通过 SDK 输入上下文写入中文；系统输入法组合输入和排版兼容性仍需单独验收。"]}


def stop_process(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    except ProcessLookupError:
        process.wait(timeout=5)


def run(app, output_parent, deadline_seconds, workbench=False, compressed_resources=False, recovery_panel=False):
    executable = app_executable(app)
    sandbox = Path("/usr/bin/sandbox-exec")
    if not sandbox.is_file():
        raise RuntimeError("本机没有 sandbox-exec，不能宣称已完成离线验收。")
    samples = compressed_resource_samples(app.resolve()) if compressed_resources else None
    directory, request = create_run_directory(output_parent, deadline_seconds, workbench=workbench,
                                               compression_samples=samples, recovery_panel=recovery_panel)
    if recovery_panel:
        # 外部操作者只观察 checkpoint 并操作实际系统面板，不向进程回传保存 URL 或伪造成功。
        print("恢复面板进度：" + str(directory / "recovery-panel-checkpoint.json"), file=sys.stderr, flush=True)
    environment = os.environ.copy()
    environment["FW_OFFICE_SMOKE_DIR"] = str(directory)
    environment["FW_OFFICE_SMOKE_TOKEN"] = request["token"]
    # 工作台偏好显式隔离；CFFIXED_USER_HOME 仅辅助路径重定向，不保证隔离 CFPreferences。
    environment["FW_WORKBENCH_TEST_SUITE"] = request["workbenchTestSuite"]
    # Office 数据隔离仍由 ASCHelper 钩子与真实 app_data_path 检查保证。
    preferences = directory / "preferences-home"
    preferences.mkdir(mode=0o700)
    environment["CFFIXED_USER_HOME"] = str(preferences)
    command = [str(sandbox), "-p", "(version 1)(allow default)(deny network*)", str(executable),
               "-ApplePersistenceIgnoreState", "YES", "-moveToApplicationsFolderAlertSuppress", "YES",
               # 离线验收不检查更新，避免首次启动的 Sparkle 选择窗占据菜单目标。
               "-SUEnableAutomaticChecks", "NO"]
    process = None
    report = {"schemaVersion": 1, "status": "failed", "directory": str(directory)}
    try:
        with (directory / "runtime.log").open("x", encoding="utf-8") as output:
            process = subprocess.Popen(command, env=environment, cwd=directory, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            # 原生也持有同一次截止时间；无钩子、模态框阻塞或子进程崩溃均不能永久等待。
            remaining = max(0, request["deadlineUnix"] - time.time())
            try:
                code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError("应用未在截止时间内正常退出；检查 runtime.log 与原生结果。") from error
        if code != 0:
            raise RuntimeError("应用未正常退出，退出码：" + str(code))
        report = verify_run(directory)
        report["applicationExitCode"] = code
        report["executionVerified"] = True
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, ET.ParseError) as error:
        report["error"] = str(error)
    finally:
        if process is not None:
            stop_process(process)
        write_new_json(directory / "verification.json", report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app", type=Path, help="已构建且集成 FWOfficeSmoke 的 .app")
    source.add_argument("--verify", type=Path, help="仅复核已有验收产物，不启动应用")
    parser.add_argument("--output-parent", type=Path, default=BUILD / "smoke")
    parser.add_argument("--deadline-seconds", type=int, default=360)
    parser.add_argument("--workbench", action="store_true", help="同时验证 Office/文本/PDF 混合标签和菜单保存路由")
    parser.add_argument("--recovery-panel", action="store_true", help="包含 workbench；等待外部真实取消一次、保存一次恢复草稿系统面板")
    parser.add_argument("--compressed-resources", action="store_true", help="同时验证压缩帮助响应、帮助面板和原生拼写检查")
    arguments = parser.parse_args()
    try:
        if arguments.verify:
            result = verify_run(arguments.verify)
            result["executionVerified"] = False
            result["mode"] = "artifact-verification-only"
        else:
            result = run(arguments.app, arguments.output_parent, arguments.deadline_seconds,
                         workbench=arguments.workbench, compressed_resources=arguments.compressed_resources,
                         recovery_panel=arguments.recovery_panel)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, ET.ParseError) as error:
        result = {"schemaVersion": 1, "status": "failed", "error": str(error)}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
