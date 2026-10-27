#!/bin/bash
# 真实文档确认验收独立编译，不依赖共享浏览页改动；不接触用户正在编辑的应用窗口。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/modal-document-tests"
mkdir -p "$OUTPUT_DIR/module-cache"
RUN_DIR="$(mktemp -d "$OUTPUT_DIR/run.XXXXXX")"
APP_DIR="$RUN_DIR/ModalDocumentTests.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$RUN_DIR/fixtures" "$RUN_DIR/preferences-home" "$RUN_DIR/sources"
export CFFIXED_USER_HOME="$RUN_DIR/preferences-home"
export FW_MODAL_DOCUMENT_TEST_DIR="$RUN_DIR/fixtures"
export FW_MODAL_DOCUMENT_TEST_TOKEN="$(uuidgen)"
/usr/bin/ditto "$PROJECT_DIR/Resources/Editors" "$APP_DIR/Contents/Resources/FileWorkbenchEditors"
python3 -B - "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleExecutable": "ModalDocumentTests", "CFBundleIdentifier": "local.fileworkbench.modal-document-tests",
    "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "14.0"
}))
PY
for name in DraftRecoveryStore DocumentSession TextDocumentSession DocumentIO SafeFileIO FileCapabilities FileSystem CSVDocument MediaOperations TextPreviewLoader; do
    cp "$PROJECT_DIR/Sources/FileWorkbench/$name.swift" "$RUN_DIR/sources/"
done
for name in FWNativeContent FWDocumentHost FWTextContent FWCSVContent FWPDFContent FWImageContent FWQuickLookContent FWBinaryState; do
    cp "$PROJECT_DIR/NativeOffice/Workbench/$name.swift" "$RUN_DIR/sources/"
done
cp "$PROJECT_DIR/scripts/test-modal-documents.swift" "$RUN_DIR/sources/"
if ! swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
    -module-cache-path "$OUTPUT_DIR/module-cache" "$RUN_DIR"/sources/*.swift \
    -o "$APP_DIR/Contents/MacOS/ModalDocumentTests" > "$RUN_DIR/build.log" 2>&1; then
    cat "$RUN_DIR/build.log"
    exit 1
fi
swiftc -parse-as-library -target arm64-apple-macos14 -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$PROJECT_DIR/NativeOffice/Tests/SystemSavePanelDriver.swift" -o "$RUN_DIR/save-panel-driver"
# 无参数启动应安全退出；这里只验证入口门禁，不启动应用窗口。
set +e
"$APP_DIR/Contents/MacOS/ModalDocumentTests" > "$RUN_DIR/unguarded-launch.log" 2>&1
LAUNCH_STATUS=$?
set -e
if [[ "$LAUNCH_STATUS" -ne 64 ]]; then
    cat "$RUN_DIR/unguarded-launch.log"
    exit 1
fi
# 独立 watchdog 也能收敛 AppKit/WK 原生调用挂起；只终止本次测试的进程组。
if python3 -B - "$APP_DIR/Contents/MacOS/ModalDocumentTests" "$RUN_DIR/fixtures" "$RUN_DIR/save-panel-driver" > "$RUN_DIR/run.log" 2>&1 <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
binary, directory, driver = map(Path, sys.argv[1:])
process = subprocess.Popen([str(binary), str(directory)], start_new_session=True)
(directory.parent / "process.pid").write_text(str(process.pid) + "\n")
deadline = time.monotonic() + 100
pressed = False
try:
    while process.poll() is None:
        checkpoint = directory / 'save-panel-checkpoint.json'
        if checkpoint.exists() and not pressed:
            rejected = subprocess.run([str(driver), str(checkpoint), str(binary.parents[2]),
                                       os.environ['FW_MODAL_DOCUMENT_TEST_TOKEN'] + '-wrong'],
                                      capture_output=True, text=True, timeout=8)
            if rejected.returncode == 0:
                raise RuntimeError('Panel driver accepted an incorrect token')
            print('PASS external panel driver rejects an incorrect token', flush=True)
            result = subprocess.run([str(driver), str(checkpoint), str(binary.parents[2]),
                                     os.environ['FW_MODAL_DOCUMENT_TEST_TOKEN']], capture_output=True, text=True, timeout=8)
            print(result.stdout, end='', flush=True)
            print(result.stderr, end='', flush=True)
            result.check_returncode()
            (directory / 'save-panel-ax-result.json').write_text(result.stdout)
            pressed = True
        if time.monotonic() > deadline:
            raise subprocess.TimeoutExpired(str(binary), 100)
        time.sleep(0.05)
    sys.exit(process.returncode)
except subprocess.TimeoutExpired:
    print("FAIL 独立原生验收超时，停止本次测试进程组", flush=True)
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
    sys.exit(124)
except Exception as error:
    print('FAIL external panel driver: ' + str(error), flush=True)
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
    sys.exit(1)
PY
then
    cat "$RUN_DIR/run.log"
    echo "真实文档关闭报告：$RUN_DIR/fixtures/report.json"
else
    STATUS=$?
    cat "$RUN_DIR/run.log"
    echo "验收失败，保留日志：$RUN_DIR"
    exit "$STATUS"
fi
