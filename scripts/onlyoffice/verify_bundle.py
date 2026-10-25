#!/usr/bin/env python3
"""只读检查一个 ONLYOFFICE .app 的静态依赖、包内资源、ARM64 架构与签名；不启动应用。"""

import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import uuid
import zipfile
from xml.parsers.expat import ExpatError

sys.dont_write_bytecode = True
from common import BUILD, ROOT
from native_sources import verify_editor_bundle


# 32/64 位 Mach-O 以及两种宽度的 universal header，均包含大小端形式。
MACHO_MAGICS = {
    bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca")
}
CEF = "Contents/Frameworks/Chromium Embedded Framework.framework"
REQUIRED_BINARIES = {
    "converter": "Contents/Resources/converter/x2t",
    "cef": CEF + "/Chromium Embedded Framework",
    "core": "Contents/Frameworks/ascdocumentscore.framework/ascdocumentscore",
    "hunspell": "Contents/Frameworks/hunspell.framework/hunspell",
}
# 路径依据固定版 main.mm、deploy_desktop.py 和 Xcode copy 阶段；不是扫描本机安装软件。
REQUIRED_FILES = (
    "Contents/Resources/login/index.html",
    "Contents/Resources/converter/DoctRenderer.config",
    "Contents/Resources/editors/web-apps/apps/api/documents/index.html",
    *["Contents/Resources/editors/web-apps/apps/" + name + "/main/index.html"
      for name in ("documenteditor", "spreadsheeteditor", "presentationeditor")],
    *["Contents/Resources/editors/sdkjs/" + name + "/sdk-all.js"
      for name in ("word", "cell", "slide")],
    *["Contents/Resources/converter/empty/en-US/new." + extension
      for extension in ("docx", "xlsx", "pptx")],
)
REQUIRED_DIRECTORIES = (
    CEF + "/Resources", "Contents/Resources/editors/sdkjs-plugins",
    "Contents/Resources/converter/templates", "Contents/Resources/dictionaries",
    "Contents/Resources/login/fonts",
)
HELPERS = ("editors_helper", "editors_helper (GPU)", "editors_helper (Renderer)")
LIMITATIONS = [
    "静态检查不替代断网启动、DOCX/XLSX/PPTX 新建、修改、保存和重新打开验收。",
    "@rpath、@loader_path、@executable_path 和其他相对安装名仅记录；未模拟 dyld 搜索链。",
    "未验证 dlopen、外部进程调用、JavaScript 远程请求、任意 Office 资源语义或文档格式兼容性。",
    "本地编辑资源必须与当前检出源码一致；历史应用应使用其对应源码版本的校验器。",
    "检查脚本使用 Python/otool/lipo/codesign，不表示应用运行时依赖这些构建或检查工具。",
]


def run_command(arguments):
    return subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, errors="replace", timeout=60, check=False)


def add_error(report, code, path, detail):
    report["errors"].append({"code": code, "path": str(path), "detail": detail})


def invoke(report, arguments, runner):
    """保存工具原始输出；缺工具、非零退出与超时都不能降格成检查成功。"""
    entry = {"arguments": arguments, "returnCode": None, "stdout": "", "stderr": ""}
    try:
        result = runner(arguments)
        entry.update(returnCode=result.returncode, stdout=result.stdout or "", stderr=result.stderr or "")
    except (OSError, subprocess.SubprocessError) as error:
        entry["error"] = str(error)
        # TimeoutExpired 可能携带 bytes，即使调用方要求 text=True。
        for key, value in (("stdout", getattr(error, "stdout", None)),
                           ("stderr", getattr(error, "stderr", None))):
            if value:
                entry[key] = value.decode("utf-8", "replace") if isinstance(value, bytes) else value
    report["commands"].append(entry)
    if entry["returnCode"] != 0:
        add_error(report, "toolFailed", arguments[-1],
                  Path(arguments[0]).name + ": " + (entry.get("error") or entry["stderr"] or entry["stdout"]))
    return entry


def inside_file(root, relative):
    """先限制解析结果，避免通过 Info.plist、框架别名或资源链接读取包外文件。"""
    candidate = root / relative
    resolved = candidate.resolve(strict=True)
    if not resolved.is_relative_to(root):
        raise ValueError("路径解析到应用包外：" + str(candidate))
    return resolved


def scan_files(root, report):
    files = []
    unsafe_links = False

    def on_error(error):
        add_error(report, "scanFailed", error.filename or root, str(error))

    # 框架的 Versions/Current 属于正常链接，但不跟随任何目录链接递归，避免越界和重复扫描。
    for directory, directories, names in os.walk(root, followlinks=False, onerror=on_error):
        directories.sort()
        for name in sorted(directories + names):
            path = Path(directory) / name
            relative = str(path.relative_to(root))
            try:
                mode = path.lstat().st_mode
                if stat.S_ISLNK(mode):
                    entry = {"path": relative, "target": os.readlink(path)}
                    report["symlinks"].append(entry)
                    try:
                        entry["resolved"] = str(inside_file(root, relative).relative_to(root))
                    except (OSError, RuntimeError, ValueError) as error:
                        unsafe_links = True
                        add_error(report, "invalidSymlink", relative, str(error))
                elif stat.S_ISREG(mode):
                    files.append(path)
                elif not stat.S_ISDIR(mode):
                    add_error(report, "unsupportedFile", relative, "包内包含非常规文件，未读取。")
            except OSError as error:
                add_error(report, "scanFailed", relative, str(error))
    return files, unsafe_links


def dependency_references(output):
    references = []
    for line in output.splitlines():
        if not line.strip() or (not line[0].isspace() and line.endswith(":")):
            continue  # 普通/Universal 输出均含每个文件或架构的标题。
        match = re.fullmatch(r"\s+(.+?)\s+\(compatibility version .+\)\s*", line)
        if not match:
            raise ValueError("无法识别 otool -L 输出行：" + line)
        if match[1] not in references:
            references.append(match[1])
    return references


def classify_reference(reference):
    if reference.startswith("/"):
        # 系统库可能只存在于 dyld shared cache；不要求在文件系统单独存在，也不扫描系统目录。
        normalized = os.path.normpath(reference)
        if normalized.startswith(("/System/Library/", "/usr/lib/")):
            return "system"
        return "externalAbsolute"
    return "unresolvedRelative"


def required_path(root, relative, report, directory=False):
    entry = {"path": relative, "kind": "directory" if directory else "file", "ok": False}
    report["resources"].append(entry)
    try:
        resolved = inside_file(root, relative)
        valid = (resolved.is_dir() and next(resolved.iterdir(), None) is not None) if directory else (
            resolved.is_file() and resolved.stat().st_size > 0)
        if not valid:
            raise ValueError("必须的资源不存在、类型不符或为空。")
        entry["ok"] = True
        return resolved
    except (OSError, RuntimeError, ValueError) as error:
        add_error(report, "missingResource", relative, str(error))
        return None


def bundle_executable(root, bundle_relative, report):
    prefix = (bundle_relative + "/") if bundle_relative else ""
    plist_path = required_path(root, prefix + "Contents/Info.plist", report)
    if plist_path is None:
        return None
    try:
        with plist_path.open("rb") as stream:
            info = plistlib.load(stream)
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or name in ("", ".", "..") or "/" in name or "\x00" in name:
            raise ValueError("CFBundleExecutable 必须是单个文件名。")
        return prefix + "Contents/MacOS/" + name
    except (OSError, ValueError, AttributeError, plistlib.InvalidFileException, ExpatError) as error:
        add_error(report, "invalidPlist", str(plist_path.relative_to(root)), str(error))
        return None


def verify_bundle(application, runner=run_command, editor_origin=ROOT / "Resources/Editors"):
    report = {"schemaVersion": 1, "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "application": str(Path(application).absolute()), "scope": "single-app-static-check",
              "status": "failed", "staticChecksPassed": False, "runtimeVerified": False,
              "offlineEditingVerified": False, "dynamicResolutionVerified": False,
              "limitations": LIMITATIONS.copy(), "errors": [], "symlinks": [], "resources": [],
              "machO": [], "requiredArchitectures": [], "commands": [], "signature": {"status": "notRun"}}
    root = Path(application).absolute()
    try:
        if root.suffix.lower() != ".app" or root.is_symlink() or not root.is_dir():
            raise ValueError("请提供一个实际存在的 .app 目录，不能是根符号链接。")
        root = root.resolve(strict=True)
        report["application"] = str(root)
    except (OSError, RuntimeError, ValueError) as error:
        add_error(report, "invalidApplication", root, str(error))
        return report

    files, unsafe_links = scan_files(root, report)
    report["regularFilesScanned"] = len(files)
    macho_paths = set()
    for path in files:
        try:
            with path.open("rb") as stream:
                magic = stream.read(4)
        except OSError as error:
            add_error(report, "readFailed", path.relative_to(root), str(error))
            continue
        if magic not in MACHO_MAGICS:
            continue
        macho_paths.add(path)
        entry = {"path": str(path.relative_to(root)), "magic": magic.hex(), "references": []}
        report["machO"].append(entry)
        # CEF 辅助程序以“(GPU)/(Renderer)”结尾；关闭 archive(member) 语法，避免被误当成归档成员。
        result = invoke(report, ["/usr/bin/otool", "-m", "-L", str(path)], runner)
        if result["returnCode"] == 0:
            try:
                # -L 对 dylib 还会列出自身 install name，亦纳入可搬移性检查并保留原值。
                for reference in dependency_references(result["stdout"]):
                    kind = classify_reference(reference)
                    entry["references"].append({"path": reference, "classification": kind})
                    if kind == "externalAbsolute":
                        add_error(report, "externalAbsoluteDependency", entry["path"], reference)
            except ValueError as error:
                add_error(report, "dependencyParseFailed", entry["path"], str(error))

    for relative in REQUIRED_FILES:
        required_path(root, relative, report)
    for relative in REQUIRED_DIRECTORIES:
        required_path(root, relative, report, directory=True)
    if not unsafe_links:
        try:
            verify_editor_bundle(root / "Contents/Resources/FileWorkbenchEditors", origin=editor_origin)
            report["editorResourcesVerified"] = True
        except (OSError, RuntimeError, ValueError) as error:
            report["editorResourcesVerified"] = False
            add_error(report, "editorResourcesInvalid", "Contents/Resources/FileWorkbenchEditors", str(error))
    try:
        with inside_file(root, "Contents/Info.plist").open("rb") as stream:
            identity = plistlib.load(stream)
        if identity.get("CFBundleIdentifier") != "local.fileworkbench.desktop" or any(
                not isinstance(identity.get(key), str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", identity[key])
                for key in ("CFBundleShortVersionString", "CFBundleVersion")):
            raise ValueError("必须为 FileDeck 工作台标识，并具有有效版本及构建号。")
        report["buildIdentity"] = {key: identity[key] for key in
                                   ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")}
    except (OSError, RuntimeError, ValueError, AttributeError, plistlib.InvalidFileException, ExpatError) as error:
        add_error(report, "invalidBuildIdentity", "Contents/Info.plist", str(error))
    binaries = dict(REQUIRED_BINARIES)
    main_binary = bundle_executable(root, "", report)
    if main_binary:
        binaries["main"] = main_binary
    for helper in HELPERS:
        relative = bundle_executable(root, "Contents/Frameworks/" + helper + ".app", report)
        if relative:
            binaries[helper] = relative
    for role, relative in binaries.items():
        path = required_path(root, relative, report)
        check = {"role": role, "path": relative, "required": "arm64", "architectures": [], "ok": False}
        report["requiredArchitectures"].append(check)
        if path is None:
            continue
        if path not in macho_paths:
            add_error(report, "notMachO", relative, "关键程序/框架未识别为 Mach-O。")
            continue
        if role in ("main", "converter", *HELPERS) and not os.access(path, os.X_OK):
            add_error(report, "notExecutable", relative, "关键程序没有执行权限。")
        result = invoke(report, ["/usr/bin/lipo", "-archs", str(path)], runner)
        if result["returnCode"] == 0:
            check["architectures"] = result["stdout"].split()
            check["ok"] = "arm64" in check["architectures"]
            if not check["ok"]:
                add_error(report, "missingARM64", relative, result["stdout"].strip())

    if not unsafe_links:
        # 签名只能确认文件未变；同时核对压缩清单，防止漏打归档或读不到的帮助链接。
        try:
            from compress_help import verify_compressed_help
            from compress_dictionaries import verify_compressed_dictionaries
            report["compressedResources"] = {
                "help": verify_compressed_help(root, verify_bytes=False),
                "dictionaries": verify_compressed_dictionaries(root),
            }
        except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
            add_error(report, "compressedResourceInvalid", "Contents/Resources", str(error))

    if unsafe_links:
        # 不把包外文件交给 codesign --deep；越界/坏链接已使静态检查失败。
        report["signature"] = {"status": "notRun", "reason": "包内含无效或越界符号链接。"}
    else:
        result = invoke(report, ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(root)], runner)
        report["signature"] = {"status": "passed" if result["returnCode"] == 0 else "failed",
                               "commandIndex": len(report["commands"]) - 1}
    report["staticChecksPassed"] = not report["errors"]
    report["status"] = "passed" if report["staticChecksPassed"] else "failed"
    return report


def write_report(report, output, build=BUILD):
    build = Path(build).resolve()
    output = Path(output).absolute()
    # 有效包的 application 已在检查开始时规范化；非法输入（如循环链接）仍应能留下失败报告。
    application = Path(report["application"])
    if (output.is_symlink() or not output.resolve().is_relative_to(build)
            or ("regularFilesScanned" in report and output.resolve().is_relative_to(application))):
        raise ValueError("报告只能写入项目 build/onlyoffice 内、被检查应用包之外。")
    output.parent.mkdir(parents=True, exist_ok=True)
    # 独占新建，不覆盖此前验收证据，也不改被检查的 .app。
    with output.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="只检查此 .app，不搜索其他安装目录")
    parser.add_argument("--output", type=Path, help="新建 JSON 报告，必须位于 build/onlyoffice 中")
    args = parser.parse_args(argv)
    report = verify_bundle(args.app)
    output = args.output or BUILD / ("bundle-verification-" + uuid.uuid4().hex + ".json")
    write_report(report, output)
    print("静态检查" + ("通过" if report["staticChecksPassed"] else "失败") + "；报告：" + str(output))
    print(LIMITATIONS[0])
    return 0 if report["staticChecksPassed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
