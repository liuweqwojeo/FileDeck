#!/bin/bash
# 独立编译新建服务，并使用真实完整应用的 Office 模板；每次保留隔离样本和验证报告。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$PROJECT_DIR/build/FileDeck.app}"
if [[ "$#" -gt 1 || ! -d "$APP_DIR/Contents/Resources/converter/empty" ]]; then
    echo "用法：bash scripts/test-file-creation.sh [完整 FileDeck.app 路径]" >&2
    exit 64
fi
APP_DIR="$(cd "$APP_DIR" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/file-creation-tests"
mkdir -p "$OUTPUT_DIR/module-cache"
RUN_DIR="$(mktemp -d "$OUTPUT_DIR/run.XXXXXX")"
mkdir -p "$RUN_DIR/fixtures" "$RUN_DIR/sources"
for name in NewFileTemplate FileSystem SafeFileIO DocumentIO MediaOperations; do
    cp "$PROJECT_DIR/Sources/FileWorkbench/$name.swift" "$RUN_DIR/sources/"
done
cp "$PROJECT_DIR/scripts/test-file-creation.swift" "$RUN_DIR/sources/"
if ! swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
    -module-cache-path "$OUTPUT_DIR/module-cache" "$RUN_DIR"/sources/*.swift \
    -o "$RUN_DIR/FileCreationAcceptance" > "$RUN_DIR/build.log" 2>&1; then
    cat "$RUN_DIR/build.log"
    exit 1
fi
if "$RUN_DIR/FileCreationAcceptance" "$APP_DIR" "$RUN_DIR/fixtures" > "$RUN_DIR/run.log" 2>&1; then
    cat "$RUN_DIR/run.log"
    echo "真实文件新建报告：$RUN_DIR/fixtures/report.json"
else
    STATUS=$?
    cat "$RUN_DIR/run.log"
    echo "验收失败，保留日志：$RUN_DIR" >&2
    exit "$STATUS"
fi
