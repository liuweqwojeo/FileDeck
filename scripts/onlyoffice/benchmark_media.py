#!/usr/bin/env python3
"""同探针对比媒体 O3：独立进程测 12 MP 图片、20 页/120 行高亮；不以耗时阈值代替正确性断言。"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from test_native_content import CORE, NATIVE, ROOT
from benchmark_common import environment_info, resolve_commit, snapshot_sources, supports_batch_highlights


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", default="HEAD")
    args = parser.parse_args()
    baseline = resolve_commit(args.baseline_ref)
    parent = ROOT / "build/media-performance"
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    paths = [Path("Sources/FileWorkbench") / (name + ".swift") for name in CORE]
    paths += [Path("NativeOffice/Workbench") / (name + ".swift") for name in NATIVE]
    probe = ROOT / "NativeOffice/Tests/MediaPerformance.swift"
    probe_data = probe.read_bytes()
    report = {"baselineCommit": baseline, "variants": {}, **environment_info()}
    for variant in ["baseline", "current"]:
        directory = output / variant
        sources = directory / "sources"
        directory.mkdir()
        hashes, omitted = snapshot_sources(paths, sources, probe, probe_data, baseline if variant == "baseline" else None)
        command = ["swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos14", "-module-cache-path", str(output / "modules")]
        # 根据该变体的真实 API 选路径；HEAD 已含批量实现时，基线也应走批量，不能人为降级。
        batch = supports_batch_highlights((sources / "MediaOperations.swift").read_text())
        if batch:
            command += ["-D", "O3_BATCH"]
        command += [*map(str, sorted(sources.glob("*.swift"))), "-o", str(directory / "media-performance")]
        with (directory / "build.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, check=True, stdout=log, stderr=subprocess.STDOUT)
        cases = {}
        for scenario in ["image", "pdf"]:
            fixtures = directory / scenario
            fixtures.mkdir()
            with (fixtures / "run.log").open("w") as log:
                subprocess.run([str(directory / "media-performance"), str(fixtures), scenario, str(fixtures / "result.json")],
                               cwd=ROOT, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            cases[scenario] = json.loads((fixtures / "result.json").read_text())
        report["variants"][variant] = {"sourceSHA256": hashes, "omittedBaselinePaths": omitted,
                                      "pdfHighlightMode": "batch" if batch else "legacy-loop", "cases": cases}
    (output / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output / "comparison.json")
    for variant, values in report["variants"].items():
        print(variant, json.dumps({name: case["metrics"] for name, case in values["cases"].items()}))


if __name__ == "__main__":
    main()
