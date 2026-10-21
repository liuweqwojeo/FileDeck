#!/usr/bin/env python3
"""按锁定 SHA 获取 ONLYOFFICE 源码；不切换已存在的错误版本，不覆盖本地修改。"""

import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from common import SOURCE, LoggedCommands, capture, lock


def fetch_repository(entry, runner, source=SOURCE):
    target = source / entry["path"]
    # 清单中的路径也要受项目边界约束，避免损坏的清单或符号链接把下载写到外部。
    if target.is_symlink() or not target.resolve().is_relative_to(source.resolve()):
        raise RuntimeError("源码路径超出项目边界：" + str(target))
    if (target / ".git").exists():
        code, actual = capture(["git", "-C", str(target), "rev-parse", "--verify", "HEAD"])
        if code == 0:
            if actual != entry["commit"]:
                raise RuntimeError("已有仓库版本不匹配，保留现场并停止：" + str(target))
            print("已固定：" + entry["path"])
            return
        # fetch 中断后会留下尚无 HEAD 的仓库。只在工作目录仍为空、远端一致时重试，
        # 不要求用户删除已下载对象，也不把已有用户文件当作可覆盖的临时目录。
        if any(path.name != ".git" for path in target.iterdir()):
            raise RuntimeError("未完成的仓库内已有文件，保留现场并停止：" + str(target))
        code, remote = capture(["git", "-C", str(target), "remote", "get-url", "origin"])
        if code or remote != entry["url"]:
            raise RuntimeError("未完成仓库的来源与锁文件不一致：" + str(target))
    else:
        if target.exists() and any(target.iterdir()):
            raise RuntimeError("目录非空且没有独立 Git 元数据，停止以防覆盖：" + str(target))
        target.parent.mkdir(parents=True, exist_ok=True)
        runner.run(["git", "init", str(target)])
        runner.run(["git", "-C", str(target), "remote", "add", "origin", entry["url"]])
    runner.run(["git", "-C", str(target), "fetch", "--depth=1", "origin", entry["commit"]])
    runner.run(["git", "-C", str(target), "checkout", "--detach", entry["commit"]])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", nargs="+", help="只获取指定 path，例如 build_tools core-fonts")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    entries = lock()["repositories"]
    if args.only:
        unknown = set(args.only) - {entry["path"] for entry in entries}
        if unknown:
            parser.error("未知仓库：" + ", ".join(sorted(unknown)))
        entries = [entry for entry in entries if entry["path"] in args.only]
    if args.dry_run:
        for entry in entries:
            print(entry["path"], entry["commit"], entry["url"])
        return 0
    runner = LoggedCommands("fetch")
    for entry in entries:
        fetch_repository(entry, runner)
    print("源码获取完成，日志：" + str(runner.path))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
