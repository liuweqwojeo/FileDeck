#!/usr/bin/env python3
"""分阶段构建 ARM64 内核和原生应用，所有辅助文件与日志保存在项目 build/ 下。"""

import argparse
import os
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True
from common import BUILD, ROOT, SOURCE, LoggedCommands, capture, find_qt_prefix, require_sources
from doctor import inspect
from patches import apply_all
from native_sources import prepare_native_sources, verify_editor_bundle


def prepare_environment(qt_prefix, jobs=4):
    environment = os.environ.copy()
    local_bin = BUILD / "bin"
    local_bin.mkdir(parents=True, exist_ok=True)
    # 上游在子进程中使用 python 名称；只提供项目内别名，不修改 /usr/bin。
    for name in ["python", "python3"]:
        alias = local_bin / name
        if alias.is_symlink():
            if alias.resolve() != Path(sys.executable).resolve():
                alias.unlink()
        if not alias.exists():
            alias.symlink_to(Path(sys.executable).resolve())
    environment["PATH"] = os.pathsep.join([
        str(local_bin), str(BUILD / "host-tools" / "bin"),
        str(BUILD / "npm" / "node_modules" / ".bin"),
        environment.get("PATH", "")])
    environment["PYTHONUNBUFFERED"] = "1"
    environment["npm_config_cache"] = str(BUILD / "npm-cache")
    # 此网络环境的 GitHub HTTP/2 连接曾在子模块下载时中断；只在构建子进程使用 HTTP/1.1。
    git_config_count = int(environment.get("GIT_CONFIG_COUNT", "0"))
    environment["GIT_CONFIG_KEY_" + str(git_config_count)] = "http.version"
    environment["GIT_CONFIG_VALUE_" + str(git_config_count)] = "HTTP/1.1"
    environment["GIT_CONFIG_COUNT"] = str(git_config_count + 1)
    environment["FW_ONLYOFFICE_BUILD_JOBS"] = str(jobs)
    # 上游会在首次构建时重新初始化 Hunspell；补丁必须在该步骤完成后、编译前应用。
    environment["FW_ONLYOFFICE_HUNSPELL_PATCHER"] = str(ROOT / "scripts/onlyoffice/patches.py")

    # qt_setup 会修改 mkspecs/features/toolchain.prf；复制工具链避免写入 Homebrew。
    # base.qt_version() 从 QT_DEPLOY 的祖父目录读取版本，目录层级不能省略版本号。
    code, qt_version = capture([str(qt_prefix / "bin/qmake"), "-query", "QT_VERSION"])
    if code or not qt_version.startswith("5."):
        raise RuntimeError("无法读取受支持的 Qt 5 版本。")
    qt_root = BUILD / "qt" / qt_version
    destination = qt_root / "clang_64"
    stamp = qt_root / "source-prefix.txt"
    if destination.exists():
        if not stamp.exists() or stamp.read_text().strip() != str(qt_prefix):
            raise RuntimeError("项目内 Qt 已存在但来源不同，请检查 " + str(qt_root))
    else:
        qt_root.mkdir(parents=True, exist_ok=True)
        print("复制 Qt 工具链到项目缓存：" + str(destination), flush=True)
        shutil.copytree(qt_prefix, destination, symlinks=False)
        stamp.write_text(str(qt_prefix) + "\n", encoding="utf-8")
    (destination / "onlyoffice_qt.conf").write_text("[Paths]\nPrefix = " + str(destination) + "\n", encoding="utf-8")
    return environment, qt_root


def build_core(runner, qt_prefix, clean=False, single_process=False, jobs=4):
    apply_all()
    # 资源压缩依赖内核按需读取；在内核编译前应用，不能只改发行包。
    apply_all("desktop-sdk")
    environment, qt_root = prepare_environment(qt_prefix, 1 if single_process else jobs)
    tools = SOURCE / "build_tools"
    # update=0 是必要边界：上游 update=1 会 checkout -f 各仓库并丢弃补丁。
    arguments = [sys.executable, "configure.py", "--module", "desktop",
                 "--platform", "mac_arm64", "--update", "0", "--clean", "1" if clean else "0",
                 "--qt-dir", str(qt_root), "--config", "release no_tests",
                 "--multiprocess", "0" if single_process else "1"]
    runner.run(arguments, cwd=tools, env=environment)
    runner.run([sys.executable, "make.py"], cwd=tools, env=environment)
    output = tools / "out" / "mac_arm64" / "onlyoffice" / "desktopeditors"
    expected = ["ascdocumentscore.framework/ascdocumentscore", "converter/x2t",
                "Chromium Embedded Framework.framework/Chromium Embedded Framework",
                "editors/web-apps/apps/documenteditor/main/index.html",
                "editors/sdkjs/word/sdk-all.js"]
    missing = [name for name in expected if not (output / name).exists()]
    if missing:
        raise RuntimeError("内核命令结束但产物不完整：" + ", ".join(missing))
    print("内核与资源已生成：" + str(output))


def build_app(runner, configuration, jobs=4):
    engine = SOURCE / "build_tools" / "out" / "mac_arm64" / "onlyoffice" / "desktopeditors"
    if not (engine / "ascdocumentscore.framework").is_dir():
        raise RuntimeError("缺少 ARM64 内核产物；先运行 --phase core。")
    prepare_native_sources()
    apply_all("desktop-apps")
    project = SOURCE / "desktop-apps" / "macos"
    # 使用本机 ad-hoc 签名以满足 Apple Silicon 加载要求；不访问或创建开发证书。
    runner.run(["xcodebuild", "-project", "ONLYOFFICE.xcodeproj", "-scheme", "ONLYOFFICE-arm",
                "-jobs", str(jobs),
                "-configuration", configuration, "-derivedDataPath", str(BUILD / "DerivedData"),
                "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "OO_BRANDING=onlyoffice",
                # Xcode 16 的调试 dylib 不在上游签名流程中，保持单一应用可执行文件。
                "ENABLE_DEBUG_DYLIB=NO",
                "CODE_SIGN_IDENTITY=-", "EXPANDED_CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
                "CODE_SIGN_STYLE=Manual", "ENABLE_USER_SCRIPT_SANDBOXING=NO", "build"], cwd=project)
    application = BUILD / "DerivedData" / "Build" / "Products" / configuration / "ONLYOFFICE.app"
    executable = application / "Contents" / "MacOS" / "ONLYOFFICE"
    if not executable.is_file():
        raise RuntimeError("未发现完整应用：" + str(application))
    # 蓝色 folder reference 必须完整保留编辑器目录、许可证与 manifest，不能误拷入上游 editors。
    verify_editor_bundle(application / "Contents/Resources/FileWorkbenchEditors")
    runner.run(["/usr/bin/lipo", str(executable), "-verify_arch", "arm64"])
    runner.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(application)])
    print("原生应用已生成；仍需执行离线编辑验收：" + str(application))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=["core", "app", "all"], default="core")
    parser.add_argument("--qt-prefix")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--clean", action="store_true", help="明确请求上游清理后重编内核")
    parser.add_argument("--single-process", action="store_true", help="内存紧张时禁用 qmake make 并行")
    parser.add_argument("--jobs", type=int, default=4, help="qmake/Xcode 并行数，16 GiB 主机默认 4")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs 必须至少为 1")
    require_sources()
    qt = find_qt_prefix(args.qt_prefix)
    if args.phase in ["core", "all"]:
        failures = [item for item in inspect(args.qt_prefix, include_sources=False)
                    if item["required"] and not item["ok"]]
        if failures:
            raise RuntimeError("构建前检查未通过：" + "；".join(item["name"] + " " + item["detail"] for item in failures))
    runner = LoggedCommands("build-" + args.phase)
    if args.phase in ["core", "all"]:
        build_core(runner, qt, args.clean, args.single_process, args.jobs)
    if args.phase in ["app", "all"]:
        build_app(runner, args.configuration, 1 if args.single_process else args.jobs)
    print("构建日志：" + str(runner.path))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
