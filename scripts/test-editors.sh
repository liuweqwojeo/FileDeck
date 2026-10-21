#!/bin/bash
# 编译独立 WebKit 验收程序；所有二进制、缓存和日志留在项目 build/editor-tests。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/editor-tests"
mkdir -p "$OUTPUT_DIR/module-cache"
export CLANG_MODULE_CACHE_PATH="$OUTPUT_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$OUTPUT_DIR/module-cache"
if ! swiftc -parse-as-library -swift-version 5 -module-cache-path "$OUTPUT_DIR/module-cache" \
    -framework AppKit -framework WebKit "$PROJECT_DIR/scripts/test-editors.swift" \
    -o "$OUTPUT_DIR/editor-tests" > "$OUTPUT_DIR/build.log" 2>&1; then
    cat "$OUTPUT_DIR/build.log"
    exit 1
fi
if "$OUTPUT_DIR/editor-tests" "$PROJECT_DIR" "$OUTPUT_DIR" > "$OUTPUT_DIR/run.log" 2>&1; then
    cat "$OUTPUT_DIR/run.log"
else
    STATUS=$?
    cat "$OUTPUT_DIR/run.log"
    exit "$STATUS"
fi
