#!/usr/bin/env python3
"""同一真实万文件目录与探针对比 Git 基线/当前 BrowserStore；生成源码摘要，不设机器相关阈值。"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from benchmark_common import browser_paths, environment_info, resolve_commit, snapshot_sources

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", default="HEAD")
    options = parser.parse_args()
    base = resolve_commit(options.baseline_ref)
    parent = ROOT / "build/browser-performance"
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    fixture = output / "fixtures"
    fixture.mkdir()
    for index in range(10_000):
        (fixture / f"{index:05}.txt").write_text("FileDeck directory fixture\n")
    probe = ROOT / "NativeOffice/Tests/BrowserPerformance.swift"
    probe_data = probe.read_bytes()
    records, omitted = {}, {}
    for variant in ["baseline", "current"]:
        directory = output / variant
        directory.mkdir()
        sources = directory / "sources"
        revision = base if variant == "baseline" else None
        hashes, omitted[variant] = snapshot_sources(browser_paths(revision), sources, probe, probe_data, revision)
        records[variant] = hashes
        binary = directory / "browser-performance"
        subprocess.run(["swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos14",
                        "-module-cache-path", str(output / "modules"), *map(str, sorted(sources.glob("*.swift"))),
                        "-o", str(binary)], cwd=ROOT, check=True)
        with (directory / "run.log").open("w") as log:
            subprocess.run([str(binary), str(fixture), str(directory / "result.json")], cwd=ROOT,
                           check=True, stdout=log, stderr=subprocess.STDOUT, timeout=300)
    report = {"baselineCommit": base, "sourceSHA256": records, "omittedBaselinePaths": omitted["baseline"],
              **environment_info(),
              "baseline": json.loads((output / "baseline/result.json").read_text()),
              "current": json.loads((output / "current/result.json").read_text())}
    (output / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output / "comparison.json")
    for before, after in zip(report["baseline"]["cases"], report["current"]["cases"]):
        print(f'{before["name"]}: {before["elapsedMs"]:.2f} -> {after["elapsedMs"]:.2f} ms')


if __name__ == "__main__":
    main()
