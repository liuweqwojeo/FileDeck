"""应用可审查的上游兼容补丁；已应用时跳过，源码不匹配时停止而不是覆盖。"""

from pathlib import Path

from common import SOURCE, capture


def apply_patch(repository, patch):
    arguments = ["git", "-C", str(repository), "apply"]
    code, _ = capture(arguments + ["--reverse", "--check", str(patch)])
    if code == 0:
        return False
    code, detail = capture(arguments + ["--check", str(patch)])
    if code:
        raise RuntimeError("上游补丁与当前源码不匹配：" + patch.name + "\n" + detail)
    code, detail = capture(arguments + [str(patch)])
    if code:
        raise RuntimeError("应用上游补丁失败：" + patch.name + "\n" + detail)
    print("已应用上游补丁：" + patch.name, flush=True)
    return True


def apply_all(repository_name="build_tools"):
    repositories = {name: SOURCE / name for name in ("build_tools", "desktop-apps", "desktop-sdk")}
    repositories["hunspell"] = SOURCE / "core/Common/3dParty/hunspell/hunspell"
    if repository_name not in repositories:
        raise RuntimeError("没有配置此上游仓库的补丁：" + repository_name)
    if repository_name == "hunspell":
        repository = repositories[repository_name]
        code, revision = capture(["git", "-C", str(repository), "rev-parse", "HEAD"])
        if code or revision != (repository.parent / "HEAD").read_text().strip():
            raise RuntimeError("Hunspell 与固定内核版本不匹配，保留源码并停止。")
    directory = Path(__file__).with_name("patches")
    for patch in sorted(directory.glob(repository_name + "-*.patch")):
        apply_patch(repositories[repository_name], patch)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", choices=("build_tools", "desktop-apps", "desktop-sdk", "hunspell"))
    apply_all(parser.parse_args().repository)
