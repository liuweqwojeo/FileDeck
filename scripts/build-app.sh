#!/bin/bash
# 默认发布同时支持浏览、Office 与本地文档编辑的完整原生应用。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION=debug
BROWSER_ONLY=false
PACKAGE_ONLY=false
for argument in "$@"; do
    case "$argument" in
        debug|release) CONFIGURATION="$argument" ;;
        --browser-only) BROWSER_ONLY=true ;;
        --package-only) PACKAGE_ONLY=true ;;
        *) echo "用法: bash scripts/build-app.sh [debug|release] [--browser-only|--package-only]" >&2; exit 2 ;;
    esac
done
if [[ "$BROWSER_ONLY" == true && "$PACKAGE_ONLY" == true ]]; then
    echo "--browser-only 与 --package-only 不能同时使用。" >&2
    exit 2
fi
if [[ "$BROWSER_ONLY" == true ]]; then
    # 仅供浏览页快速验证；使用独立名称，绝不覆盖用户的完整工作台入口。
    export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
    swift build --disable-sandbox --configuration "$CONFIGURATION" --cache-path "$PROJECT_DIR/.build/cache"
    BIN_DIR="$(swift build --disable-sandbox --configuration "$CONFIGURATION" --cache-path "$PROJECT_DIR/.build/cache" --show-bin-path)"
    APP_DIR="$PROJECT_DIR/build/FileDeck浏览验证.app"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
    cp "$BIN_DIR/FileWorkbench" "$APP_DIR/Contents/MacOS/.FileWorkbench.new"
    mv -f "$APP_DIR/Contents/MacOS/.FileWorkbench.new" "$APP_DIR/Contents/MacOS/FileWorkbench"
    cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
    cp "$PROJECT_DIR/Resources/FileDeck.icns" "$APP_DIR/Contents/Resources/FileDeck.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName FileDeck浏览验证" "$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName FileDeck浏览验证" "$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.filedesk.FileWorkbench.browser-validation" "$APP_DIR/Contents/Info.plist"
    codesign --force --sign - "$APP_DIR"
    echo "已生成浏览验证应用: $APP_DIR"
else
    if [[ "$CONFIGURATION" == release ]]; then
        # 发布构建从锁文件安装工具并只读重建比较；不能自动覆盖资源以掩盖遗漏提交。
        npm --prefix EditorAssets ci --ignore-scripts --no-audit --no-fund
        npm --prefix EditorAssets run verify
    fi
    case "$CONFIGURATION" in
        debug) NATIVE_CONFIGURATION=Debug ;;
        release) NATIVE_CONFIGURATION=Release ;;
    esac
    if [[ "$PACKAGE_ONLY" != true ]]; then
        python3 scripts/onlyoffice/build.py --phase app --configuration "$NATIVE_CONFIGURATION"
    fi
    python3 scripts/onlyoffice/package_app.py --configuration "$NATIVE_CONFIGURATION"
fi
