"""ONLYOFFICE 构建工具共用路径、版本核验和带日志的命令执行；不修改系统环境。"""

import datetime
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "vendor" / "onlyoffice"
BUILD = ROOT / "build" / "onlyoffice"
LOCK_PATH = Path(__file__).with_name("versions.lock.json")


def lock():
    return json.loads(LOCK_PATH.read_text(encoding="utf-8"))


def capture(arguments, cwd=None):
    result = subprocess.run(arguments, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False)
    return result.returncode, result.stdout.strip()


def tool_path(command):
    """优先使用项目固定的构建工具，避免全局工具升级影响同一份源码。"""
    for directory in [BUILD / "host-tools" / "bin", BUILD / "npm" / "node_modules" / ".bin"]:
        candidate = directory / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which(command)


def source_status():
    statuses = []
    for entry in lock()["repositories"]:
        path = SOURCE / entry["path"]
        # 空的子模块目录可能向上发现父仓库，必须先确认它有自己的 .git。
        if not (path / ".git").exists():
            statuses.append({**entry, "actual": None, "ok": False})
            continue
        code, actual = capture(["git", "-C", str(path), "rev-parse", "HEAD"])
        statuses.append({**entry, "actual": actual if code == 0 else None,
                         "ok": code == 0 and actual == entry["commit"]})
    return statuses


def require_sources():
    failures = [entry for entry in source_status() if not entry["ok"]]
    if failures:
        details = ", ".join(entry["path"] for entry in failures)
        raise RuntimeError("源码缺失或提交不匹配：" + details + "。先运行 fetch.py。")


def find_qt_prefix(explicit=None):
    candidates = [explicit, os.environ.get("ONLYOFFICE_QT_PREFIX"),
                  "/opt/homebrew/opt/qt@5", "/usr/local/opt/qt@5"]
    qmake = shutil.which("qmake")
    if qmake:
        code, prefix = capture([qmake, "-query", "QT_INSTALL_PREFIX"])
        if code == 0:
            candidates.append(prefix)
    for value in candidates:
        if value and (Path(value).expanduser() / "bin" / "qmake").is_file():
            return Path(value).expanduser().resolve()
    return None


class LoggedCommands:
    """日志与子进程输出同步，失败时保留退出码，避免管道 tee 吞掉构建错误。"""

    def __init__(self, phase):
        directory = BUILD / "logs"
        directory.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.path = directory / (phase + "-" + stamp + ".log")

    def run(self, arguments, cwd=None, env=None):
        command = shlex.join([str(item) for item in arguments])
        print("$ " + command, flush=True)
        with self.path.open("a", encoding="utf-8") as log:
            log.write("\n$ " + command + "\n")
            log.flush()
            process = subprocess.Popen([str(item) for item in arguments], cwd=cwd, env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, errors="replace", bufsize=1, start_new_session=True)
            try:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                    log.flush()
                code = process.wait()
            except BaseException:
                # make.py 会再启动 git/make；中断必须结束整组，避免孤儿进程继续写同一构建目录。
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                process.wait()
                raise
            if code:
                raise RuntimeError("命令失败（退出码 %s），日志：%s" % (code, self.path))
