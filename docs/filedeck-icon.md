# FileDeck 应用图标

当前图标依据用户提供的蓝色 FileDeck 标识制作：蓝色圆角方形，中间白色分栏图案，不包含名称和宣传语。使用内置 imagegen 编辑参考图，再通过 macOS 工具生成发布资源。

## 资源与构建

- `Resources/FileDeck.png`：1024 × 1024、RGBA、透明背景的图标源文件。
- `Resources/FileDeck.icns`：16–1024 像素与 Retina 资源，用于 Finder、Dock 和启动页。
- `scripts/build-app-icon.sh`：用系统 `sips` 和 `iconutil` 从 PNG 重新生成 ICNS。普通应用构建直接使用已生成的 ICNS，不依赖图像服务。
- `scripts/onlyoffice/package_app.py`：复制图标并设置 `CFBundleIconFile`；移除旧的 `CFBundleIconName`，避免旧 asset catalog 图标优先显示。
- `Sources/FileWorkbench/WorkspaceDesign.swift`：启动页读取包内同一 ICNS，不再绘制独立文件夹图案。
- `scripts/build-app.sh` 与 `Resources/Info.plist`：独立浏览验证包也使用 FileDeck 图标。

```sh
bash scripts/build-app-icon.sh
bash scripts/build-app.sh
```

部分受限执行环境中，`iconutil` 会对有效 PNG 报 `Invalid Iconset`；本次在允许系统图标转换服务的本机环境重新执行相同命令成功。无需修改源图或清除全局图标缓存。打包会刷新应用目录时间，避免 `ditto` 保留旧时间导致系统复用旧图标；本次还仅对最终包重新注册，已通过 `NSWorkspace.icon(forFile:)` 实际读取到蓝色图标。已运行的旧应用需正常退出后打开新包，才能加载新资源。

验证：`build/filedeck-icon-build.log` 记录完整构建与签名成功；`build/filedeck-icon-verification.json` 校验全部 ICNS 尺寸及最终包资源一致；系统读取的图标保存于 `build/icon-preview/system-FileDeck-refreshed.png`。此次 simplify Lite / refactor 检查了复用、质量与构建模式，已修复旧目录时间导致的缓存问题；未扩展编辑器功能范围。

## 图像生成提示词

方式：内置 imagegen；参考图为用户附件；透明背景开启。最终采用第二次生成结果，经 `sips` 规范为 1024 × 1024。原始参考附件保持不变。

```text
Extract the exact blue rounded-square app icon from the attached reference as a pristine flat digital logo asset on REAL TRANSPARENT background. No text. This is an exact brand extraction, NOT an illustration or redesign. Only a perfectly SQUARE flat solid #3867D6 tile with smoothly rounded corners (corner radius 22% of tile width), and the exact small centered white three-pane window symbol. White symbol width 29% and height 23% of blue tile; has rounded outer corners, a thin blue horizontal gap at top third and a thin blue vertical gap in the bottom two-thirds. Perfectly centered in the tile. Equal transparent margins 6.25% of canvas on ALL four sides, tile 87.5% of square canvas. Every interior blue pixel MUST use one identical solid blue color. No noise, no texture, no gradient, no shadow, no lighting, no fringe, no grain, no stray or detached pixels outside the clean silhouette, no extra marks. Razor-clean mathematical geometric contours with smooth antialiasing. Deliver a square production-quality app icon.
```
