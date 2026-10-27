#!/usr/bin/env python3
"""同一探针对比指定 Git 基线和当前源码；只读源码，产物保存在 build 下，不以墙钟阈值代替正确性测试。"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from test_native_content import CORE, NATIVE, ROOT
from benchmark_common import environment_info, resolve_commit, snapshot_sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", default="HEAD")
    options = parser.parse_args()
    base = resolve_commit(options.baseline_ref)
    parent = ROOT / "build/csv-performance"
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    paths = [Path("Sources/FileWorkbench") / (name + ".swift") for name in CORE]
    paths += [Path("NativeOffice/Workbench") / (name + ".swift") for name in NATIVE]
    probe = ROOT / "NativeOffice/Tests/CSVPerformance.swift"
    probe_data = probe.read_bytes()
    records, omitted = {}, {}
    for variant in ["baseline", "current"]:
        directory = output / variant
        directory.mkdir()
        sources = directory / "sources"
        hashes, omitted[variant] = snapshot_sources(paths, sources, probe, probe_data, base if variant == "baseline" else None)
        records[variant] = hashes
        binary = directory / "csv-performance"
        subprocess.run(["swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos14",
                        "-module-cache-path", str(output / "modules"), *map(str, sorted(sources.glob("*.swift"))),
                        "-o", str(binary)], cwd=ROOT, check=True)
        fixtures = directory / "fixtures"
        fixtures.mkdir()
        with (directory / "run.log").open("w") as log:
            subprocess.run([str(binary), str(fixtures), str(directory / "result.json")], cwd=ROOT,
                           check=True, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    report = {"baselineCommit": base, "sourceSHA256": records, "omittedBaselinePaths": omitted["baseline"],
              **environment_info(),
              "baseline": json.loads((output / "baseline/result.json").read_text()),
              "current": json.loads((output / "current/result.json").read_text())}
    (output / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output / "comparison.json")
    for before, after in zip(report["baseline"]["cases"], report["current"]["cases"]):
        print("rows=" + str(before["rows"]) + " medianMs " + str(round(before["editMedianMs"], 4)) + " -> "
              + str(round(after["editMedianMs"], 4)) + "; P95Ms " + str(round(before["editP95Ms"], 4)) + " -> " + str(round(after["editP95Ms"], 4)))


if __name__ == "__main__":
    main()
