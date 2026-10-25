#!/bin/bash
# 编译项目真实视图；测试偏好域、目录、截图与报告均与用户工作区隔离。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$PROJECT_DIR/build/welcome-acceptance"
mkdir -p "$OUTPUT/module-cache"
RUN_DIR="$(mktemp -d "$OUTPUT/run.XXXXXX")"
APP="$RUN_DIR/WelcomeAcceptance.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT_DIR/Resources/FileDeck.icns" "$APP/Contents/Resources/"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'WelcomeAcceptance', 'CFBundleIdentifier': 'local.filedeck.welcome-acceptance',
    'CFBundleName': 'FileDeck欢迎页验收', 'CFBundlePackageType': 'APPL',
    'NSPrincipalClass': 'NSApplication', 'CFBundleIconFile': 'FileDeck.icns', 'LSMinimumSystemVersion': '14.0'
}))
PY
SOURCES=()
for SOURCE in "$PROJECT_DIR"/Sources/FileWorkbench/*.swift; do
    case "$(basename "$SOURCE")" in
        FileWorkbenchApp.swift) ;;
        *) SOURCES+=("$SOURCE") ;;
    esac
done
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
    -module-cache-path "$OUTPUT/module-cache" "${SOURCES[@]}" "$PROJECT_DIR/scripts/test-welcome.swift" \
    -o "$APP/Contents/MacOS/WelcomeAcceptance" > "$RUN_DIR/build.log" 2>&1 || { cat "$RUN_DIR/build.log"; exit 1; }
printf '%s\n' "$RUN_DIR" > "$OUTPUT/latest-run.txt"
"$APP/Contents/MacOS/WelcomeAcceptance" "$RUN_DIR" > "$RUN_DIR/run.log" 2>&1 || { cat "$RUN_DIR/run.log"; exit 1; }
cat "$RUN_DIR/run.log"
printf '欢迎页原生运行报告：%s/report.json\n' "$RUN_DIR"
