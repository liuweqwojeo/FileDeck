#!/usr/bin/env python3
"""编译并运行真实 CSV/PDF/图片原生会话回归，不依赖 Office 或修改 SwiftPM。"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ["DraftRecoveryStore", "DocumentSession", "DocumentIO", "SafeFileIO", "CSVDocument", "MediaOperations", "FileCapabilities", "FileSystem", "TextPreviewLoader"]
NATIVE = ["FWNativeContent", "FWBinaryState", "FWCSVContent", "FWPDFContent", "FWImageContent", "FWQuickLookContent"]


def main():
    with tempfile.TemporaryDirectory(prefix="fw-native-regression-") as directory:
        binary = pathlib.Path(directory) / "media-content-tests"
        sources = [ROOT / "Sources/FileWorkbench" / f"{name}.swift" for name in CORE]
        sources += [ROOT / "NativeOffice/Workbench" / f"{name}.swift" for name in NATIVE]
        sources.append(ROOT / "NativeOffice/Tests/MediaContentRegression.swift")
        subprocess.run(["/usr/bin/swiftc", "-parse-as-library", "-target", "arm64-apple-macos14.0",
                        "-module-cache-path", str(pathlib.Path(directory) / "modules"),
                        *map(str, sources), "-o", str(binary)], cwd=ROOT, check=True)
        result = subprocess.run([str(binary)], cwd=ROOT, check=False, timeout=60, capture_output=True, text=True)
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="")
        result.check_returncode()
        if "PASS: 15 native media/CSV session regressions" not in result.stdout:
            raise RuntimeError("Native regression process exited before its completion marker")


if __name__ == "__main__":
    main()
