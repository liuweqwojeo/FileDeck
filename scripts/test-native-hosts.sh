#!/bin/bash
# 全部真实原生 Swift 类参与编译；辅助应用/样本/日志均在项目 build 内，每次使用新目录。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/native-host-tests"
mkdir -p "$OUTPUT_DIR/module-cache"
RUN_DIR="$(mktemp -d "$OUTPUT_DIR/run.XXXXXX")"
APP_DIR="$RUN_DIR/NativeHostTests.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$RUN_DIR/fixtures" "$RUN_DIR/preferences-home"
export CLANG_MODULE_CACHE_PATH="$OUTPUT_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$OUTPUT_DIR/module-cache"
export FW_OFFICE_SMOKE_DIR="$RUN_DIR/fixtures"
export FW_OFFICE_SMOKE_TOKEN="$(uuidgen)"
# 浏览页使用 AppStorage；隔离 CoreFoundation 偏好目录，避免验收改变真实工作区的分栏和预览设置。
export CFFIXED_USER_HOME="$RUN_DIR/preferences-home"
/usr/bin/ditto "$PROJECT_DIR/Resources/Editors" "$APP_DIR/Contents/Resources/FileWorkbenchEditors"
python3 -B - "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleExecutable": "NativeHostTests", "CFBundleIdentifier": "local.fileworkbench.native-host-tests",
    "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "14.0"
}))
PY
SOURCES=()
for SOURCE in "$PROJECT_DIR"/Sources/FileWorkbench/*.swift; do
    case "$(basename "$SOURCE")" in
        FileWorkbenchApp.swift) ;;
        *) SOURCES+=("$SOURCE") ;;
    esac
done
SOURCES+=("$PROJECT_DIR"/NativeOffice/Workbench/*.swift "$PROJECT_DIR/scripts/test-native-hosts.swift")
# 并行开发可能在 swiftc 多阶段读取之间更新源码；每次验收编译自己的只读快照并记录摘要。
mkdir -p "$RUN_DIR/sources"
python3 -B - "$RUN_DIR" "${SOURCES[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
records = []
for source in map(Path, sys.argv[2:]):
    data = source.read_bytes()
    destination = root / "sources" / source.name
    with destination.open("xb") as stream:
        stream.write(data)
    records.append({"source": str(source), "sha256": hashlib.sha256(data).hexdigest()})
(root / "source-manifest.json").write_text(json.dumps(records, indent=2) + "\n")
PY
if ! swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
    -module-cache-path "$OUTPUT_DIR/module-cache" "$RUN_DIR"/sources/*.swift \
    -o "$APP_DIR/Contents/MacOS/NativeHostTests" > "$RUN_DIR/build.log" 2>&1; then
    cat "$RUN_DIR/build.log"
    exit 1
fi
# Finder/LaunchServices 无参数启动同一产物时应正常拒绝，不能触发 Swift 数组越界崩溃。
if "$APP_DIR/Contents/MacOS/NativeHostTests" > "$RUN_DIR/unguarded-launch.log" 2>&1; then
    echo "错误：无参数的测试入口未拒绝启动。" >&2
    exit 1
else
    STARTUP_STATUS=$?
    if [[ "$STARTUP_STATUS" != 64 ]]; then
        echo "错误：无参数启动返回 $STARTUP_STATUS，预期 64。" >&2
        exit 1
    fi
fi
"$APP_DIR/Contents/MacOS/NativeHostTests" "$RUN_DIR/fixtures" > "$RUN_DIR/run.log" 2>&1 &
TEST_PID=$!
echo "$TEST_PID" > "$RUN_DIR/process.pid"
if wait "$TEST_PID"; then
    cat "$RUN_DIR/run.log"
    echo "真实原生宿主报告：$RUN_DIR/fixtures/report.json"
else
    STATUS=$?
    cat "$RUN_DIR/run.log"
    echo "验收失败，保留日志：$RUN_DIR"
    exit "$STATUS"
fi
