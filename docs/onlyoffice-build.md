# ONLYOFFICE macOS ARM64 源码构建

本目录提供源码获取、环境检查和两阶段构建入口。脚本存在或环境检查通过均不代表 Office 编辑能力已经验收；完成标准是生成原生应用，并在断网后完成 DOCX、XLSX、PPTX 的新建、修改、保存和重新打开。

## 固定版本与目录

- `scripts/onlyoffice/versions.lock.json` 固定 DesktopEditors `v10.0.0` 及其六个组件的 gitlink 提交。`web-apps-pro.git` 使用公开 `web-apps.git` 获取完全相同的提交 `9c0ca538c3b211052347df09d2a4d6781f023403`。
- `build_tools` 固定 `release/v9.4.0` 的 `cf4cac0846d03e2e00a6fec5d1ecd4e9463086d5`；其 `version` 是 `9.4.0`。上游未提供 `v10.0.0` 构建工具标签，保留真实版本，不强制重写 `PRODUCT_VERSION`。该组合仍须通过实际构建验证。
- 源码放在 `vendor/onlyoffice/`，辅助工具、日志和 Xcode 产物放在 `build/onlyoffice/`。附属仓库也固定 SHA，CEF 和其他第三方依赖由上游脚本继续下载；尚未实现所有二进制依赖的内容哈希锁定。
- CEF 5414 使用官方 `mac_arm64` 预构建框架，固定提交、归档大小和 SHA-256 见 `scripts/onlyoffice/binary-dependencies.lock.json`；下载后校验摘要及 7z 完整性。ARM64 文档渲染使用系统 JavaScriptCore，不需要自行编译 Chromium 或 V8。
- 上游 `defaults` 默认启用 `sdkjs-forms`；当前锁中包含该附属仓库，不能把未传 `--sdkjs-addon` 理解为禁用了表单。此组合已生成内核与 JS 资源，运行兼容性仍需真实文档验收。

## 环境准备

要求 macOS Apple Silicon、完整 Xcode、Python 3.9+、Node/npm、Qt 5 qmake、CMake、Make、Perl、curl 和 Git。当前机器是 macOS 14.7.2、Xcode 16.2；项目辅助工具使用已有 Python 3.12，Node 为 22.22.2。首次构建建议保留 100 GiB 空闲空间。

先执行只读检查（返回 `1` 表示存在缺失项）：

```sh
python3 scripts/onlyoffice/doctor.py --environment-only
python3 scripts/onlyoffice/doctor.py --json
```

环境准备分为系统构建工具、项目辅助工具和离线 qmake 三部分。下面的安装命令仅供缺少工具的机器显式执行；不要在构建进程运行时重建其 venv 或工具目录。`setup_tools.py`、`doctor.py` 和 `build.py` 都不会自动安装 Homebrew 组件。

### 系统和项目辅助工具

联网准备机器可按需执行：

```sh
brew install autoconf automake pkgconf nasm
python3.12 -m venv build/onlyoffice/host-tools
build/onlyoffice/host-tools/bin/python -m pip install --only-binary=:all: --no-deps cmake==3.31.6
npm install --prefix build/onlyoffice/npm --cache build/onlyoffice/npm-cache --no-audit --no-fund grunt-cli@1.5.0
```

若 Python 3.12 未在 PATH 中，可使用已有解释器的绝对路径，例如 `/opt/homebrew/opt/python@3.12/bin/python3.12`。CMake 固定 3.31.6 是为保留旧依赖的 CMake 兼容策略；CMake 4 移除了部分旧兼容支持，不能仅因为 `cmake` 命令存在就随意升级。构建脚本优先使用上述 venv 中的 CMake 和项目内的 grunt，不改变全局工具。grunt 的传递依赖锁文件由 npm 保留在 `build/onlyoffice/npm/package-lock.json`；离线复用需同时保存该目录或安装缓存，不能把顶层版本固定等同于所有依赖已完全锁定。

Autoconf/Automake 为旧 C/C++ 依赖生成构建脚本，pkgconf 提供 `pkg-config`，NASM 供汇编依赖使用。当前机器已安装这四项。不需要 Yarn；`mac_arm64` 路径不编译 V8，因此不需要 Ninja。不要用 GNU libtool 替换 `/usr/bin/libtool`，HEIF 静态库合并使用的是 Apple libtool。上游 ICU 脚本会先构建并执行 x86_64 工具，doctor 会检查 Rosetta；如果没有，必须先解决这一环境依赖，脚本不会静默安装它。

### 只准备 qmake，不安装整套 Qt

当前路线只用 qmake 和 mkspecs 生成内核 Makefile；应用壳是 AppKit。已验证下列 Homebrew bottle 中的 `bin/qmake` 在当前 macOS 上运行，且 `otool -L` 仅列出系统框架和系统动态库，因此不需要为 qmake 安装整个 Qt 运行时及其依赖链。

| 固定项 | 值 |
|---|---|
| 归档 | `qt@5--5.15.19.arm64_sonoma.bottle.tar.gz` |
| Qt 版本 | `5.15.19` |
| 大小 | `54,796,944` 字节 |
| SHA-256 | `06e23a0b11dae387d4267b7f497cf57d64373094a876fdfefe1672b935976c58` |
| 来源 | Homebrew `qt@5` 的 `5.15.19` bottle manifest，`arm64_sonoma` 条目 |

提供上述归档即可离线准备，不需要联网、Homebrew 命令或安装 Qt：

```sh
python3 scripts/onlyoffice/setup_tools.py --qt-archive /归档存放目录/qt@5--5.15.19.arm64_sonoma.bottle.tar.gz
python3 scripts/onlyoffice/doctor.py --environment-only --qt-prefix build/onlyoffice/toolchains/qt@5/5.15.19
```

脚本固定内容校验后，只提取 `bin/qmake`、`mkspecs/` 和许可证，拒绝路径穿越、重复路径、选中范围中的链接或特殊文件。先写同级临时目录，再发布完整目录；重复执行只在内容和文件权限完全一致时复用。已有目录包含改动、额外文件或手工提取时遗漏的许可证时会停止并保留原文件，可用 `--destination /新的工具链目录` 准备另一份。并发锁残留时，确认没有准备进程后再处理对应 `.setup.lock`。

联网机器可使用 `brew fetch --force-bottle --bottle-tag=arm64_sonoma qt@5` **仅下载** bottle，再将匹配版本的归档带到离线机器。Homebrew 公式可能更新；若拿到其他版本，上述脚本会拒绝，不会放宽哈希校验。Homebrew 缓存文件名中的前置哈希是下载地址的缓存键，不能当作文件 SHA-256。本机缓存中已保留并核验该固定归档；源码构建首次获取其他依赖仍需要联网。

若已有完整 Qt 安装，仍支持 `/opt/homebrew/opt/qt@5`，其他位置使用 `--qt-prefix /实际/Qt目录` 或 `ONLYOFFICE_QT_PREFIX`。构建前会把工具链复制到 `build/onlyoffice/qt/5.15.19/clang_64`，并通过 `onlyoffice_qt.conf` 指向复制后的前缀，因为上游会修改 `toolchain.prf`，不能直接改动来源工具链。项目内 `python` 别名跟随启动构建脚本的解释器，不改系统链接。

## 获取和构建

以下命令均在仓库根目录执行，首次运行需要联网，所有退出失败保留日志和现场：

```sh
python3 scripts/onlyoffice/fetch.py --dry-run
python3 scripts/onlyoffice/fetch.py
python3 scripts/onlyoffice/doctor.py --qt-prefix build/onlyoffice/toolchains/qt@5/5.15.19
python3 scripts/onlyoffice/build.py --phase core --qt-prefix build/onlyoffice/toolchains/qt@5/5.15.19
python3 scripts/onlyoffice/build.py --phase app
```

`fetch.py --only core-fonts document-templates` 可只获取指定附属仓库；已有仓库的提交与锁文件不符时停止，不会 `checkout -f` 或覆盖修改。脚本固定 `--update 0`，防止上游自动更新覆盖本地集成改动。

构建前按序应用 `scripts/onlyoffice/patches/build_tools-*.patch`。已应用的补丁自动跳过，相关源码存在不兼容修改时停止并保留现场。当前 Boost 补丁把子模块下载分离为可恢复步骤，并限制历史深度及并行任务数，避免首次下载中断后直接编译缺失的子模块。补丁测试覆盖重复应用与冲突时保留原文。

hyphen 作为嵌套仓库固定在版本锁中，由 `fetch.py` 预先取得，构建前核验 HEAD；上游不会重新获取已经存在的源码目录。插件 API 的三份入口改从固定的 `onlyoffice.github.io` 仓库复制，旧 `pluginBase.js` 仍按原方式拼接；缺少源文件立即失败。两套界面依赖使用 `npm ci`，Grunt 不再传 `--force`，安装或任务失败会停止构建，不能以输出目录存在代替成功。

第一阶段在 `build_tools` 内执行 `configure.py --module desktop --platform mac_arm64 --update 0 --clean 0 --qt-dir <项目Qt副本> --config 'release no_tests'`，再执行 `make.py`。**不能使用 `--platform native`**：上游配置把 ARM64 主机的 `native` 解析成 `mac_64`。

内核与资源输出为 `vendor/onlyoffice/build_tools/out/mac_arm64/onlyoffice/desktopeditors/`。该目录不是完整 Mac 应用；`sln.json` 没有编译 macOS 壳的步骤。

第二阶段在 `desktop-apps/macos` 内运行 `xcodebuild -project ONLYOFFICE.xcodeproj -scheme ONLYOFFICE-arm`。默认 Debug，避免上游 Release 构建阶段递增源文件中的版本号；需要发布配置时显式传 `--configuration Release`。脚本使用本机 ad-hoc 签名 `-`，不创建证书、不进行公证、不要求 Apple 开发者账户。签名和 ARM64 架构验证成功后，应用位于：

```text
build/onlyoffice/DerivedData/Build/Products/Debug/ONLYOFFICE.app
```

原生源文件先通过 `native_sources.py` 同步，再应用 `desktop-apps-*.patch`。当前包含隔离验收钩子和 ARM 签名修复：CEF 5414 没有的两份旧 SwiftShader 库可以缺省，但其他必需复制、动态库路径修正和签名失败均立即停止；最终仍执行整个应用的严格签名验证。

qmake、OpenSSL 和 Xcode 默认最多 4 路编译，可通过 `--jobs` 调整。`--single-process` 将这三处限制为 1；上游 ICU/HEIF 自身的固定并行参数仍由对应脚本控制。只有明确需要清理内核产物时传 `--clean`。日志在 `build/onlyoffice/logs/`。网络沙箱失败时，应通过正常授权重试，不能把下载失败当成构建通过。

OpenSSL 的 macOS 安装采用“完成默认编译目标 → 安装 → 写完成标记”的顺序。原先同时传入 `build_libs install` 在并行 make 下会竞争生成文件；不使用全局 `MAKEFLAGS` 强加并行。安装目录存在不代表安装成功，缺少完成标记时会重新安装，保留已完成的源码获取和编译缓存。

## 打包资源精简

`package_app.py` 在待签名副本中执行静态资源去重：编辑器内的图片、脚本、样式、JSON、HTML、字体，以及顶层文件图标，只有大小、权限、SHA-256 和完整字节均一致时才合并为包内相对链接。原路径保持可读，ZIP 分发必须保留符号链接；不使用文件系统透明压缩，解压后的资源文件总量也会减少。

打包仅移除两个精确列举的第三方开发演示入口：Monaco 的 `example.html` 与 Select2 的 `docs/examples.html`。不按 `test`、`example` 等关键词批量删除；Excel 统计检验函数帮助、帮助示例图片、语言、字典、模板、插件、原生内核及独立签名框架均保留。`build/filedeck-resource-optimization.json` 记录新增链接、删除路径、字节数和摘要。

可用 `--source /path/to/FileDeck.app` 对已有完整应用重新打包，输入与输出应为不同路径；无需重编未改动的 Office 内核。打包完成仍严格验签，上一份应用保存在 `build/previous-apps/`。

### 离线帮助与拼写字典压缩

使用已经应用本项目 `desktop-sdk-001/002` 和 `hunspell-001` 补丁的内核，可进一步运行：

```sh
python3 scripts/onlyoffice/package_app.py --configuration Debug --version 0.1.0 --build-number 1 --compress-offline-resources
python3 scripts/onlyoffice/verify_bundle.py --app build/FileDeck.app
python3 scripts/onlyoffice/smoke.py --app build/FileDeck.app --workbench --compressed-resources --deadline-seconds 300
```

打包器先检查两个 framework 的三个能力符号；旧内核不能直接配合压缩资源。普通打包仍兼容明文资源；新增选项只有核验通过后才压缩。完整内核构建会在 Hunspell 上游初始化之后应用 EOF 补丁，避免首次构建的清理动作将补丁删除。

- 六组帮助目录分别保存为 `help.zip`，保留全部语言、HTML、搜索索引、图片、GIF 和跨编辑器相对链接。CEF 接管原来的本地 URL，每次仅把所需文件解压到内存；不创建完整帮助目录缓存。公式说明等原先打开外部浏览器的帮助链接改在应用现有帮助面板中打开，其他外部链接不变。
- 49 份注册拼写词典覆盖 65 个语言区域 ID；仅将能够逐字节往返且确实变小的 `.aff/.dic` 转成 Hunspell 原生 `.hz`。不适合压缩的文件保留原件，连字符、同义词、额外词典与许可证继续保留。Hunspell 按行读取，不依赖网络、Python、命令行解压器或落盘缓存。
- Hunspell 上游的 `is_open()` 忽略了已经读入的最后一段缓冲，导致压缩小词典及末尾词丢失；补丁改为以解码缓冲状态判断。构建期 `hzip/hunzip` 只留在 `build/onlyoffice/compression-tools/`，不会进入应用。
- 帮助 ZIP 内清单与字典目录内完整性清单保存摘要。首次压缩验证全部字节再移除原文件；重打包拒绝损坏、缺失或越界资源。归档本身属于签名资源，应用运行不修改它们。ZIP 分发解压后仍保留这种压缩存储，不依赖 APFS/HFS 文件系统压缩。

`--compressed-resources` 验收通过真实 CEF 请求核对帮助样本摘要，并打开三种编辑器的帮助面板、检查五种语言的原生拼写结果，再执行文档编辑、保存、关闭和重开。全量帮助与词典字节核验和原生读取器边界测试另由构建工具测试覆盖。

本机 ARM64、0.1.0（构建 1）的这轮实测，以已经完成静态资源去重的应用为基线：

| 项目 | 压缩前 | 压缩后 | 减少 |
| --- | ---: | ---: | ---: |
| 应用普通文件总量 | 1,616,367,755 字节 | 1,366,303,999 字节 | 250,063,756 字节（15.47%） |
| 六组离线帮助 | 314,780,327 字节 | 228,590,332 字节 | 86,189,995 字节 |
| 全部字典目录（含清单） | 249,434,411 字节 | 91,753,028 字节 | 157,681,383 字节 |

帮助文件合并后签名资源清单还减少约 6.35 MB，内核读取支持增加少量代码；以上应用总量已计入这些变化。帮助目录统计包含原符号链接的目标字符串，应用普通文件总量不重复计算链接目标。原应用保留在 `build/previous-apps/`，后续构建应以重新测量为准。

本轮验收包含 138 项构建工具测试、25 项真实 CEF 读取器检查、49 份词典的 6,762 个原生拼写结果对照，以及禁止网络环境下 DOCX/XLSX/PPTX 的帮助目录、页面图片、语言回退、编辑保存重开和工作台混合文档回归。输入通过 SDK 完成，不代表系统输入法或所有 Office 排版兼容性均已覆盖。可复用命令见上文；本机详细结果位于 `build/offline-compression-analysis/`。

最终 ZIP 为 791,012,851 字节，解压到中文及空格路径后，普通文件字节、权限和全部符号链接与发布应用一致，仍为 1,366,303,999 字节。解压副本无文件系统透明压缩标志，并再次通过严格验签、压缩资源检查和断网运行验收。大小与 SHA-256 记录在 `final-size-and-distribution.json` / `SHA256SUMS.txt`；这份本地压缩产物尚未替换已有线上发布包。

## 验收与已知边界

环境准备已验证：固定 Qt bottle 的哈希、白名单提取、重复准备不重写文件、qmake 版本和系统动态库依赖；对应测试使用临时目录，不修改正在构建的工具链。安全归档测试可用 `python3 -B -m unittest discover -s Tests/BuildToolsTests -p test_setup_tools.py -v` 重跑。**这些结果不表示 Office 内核已编译，也不表示下列离线编辑验收已完成。**

1. 验证应用包内包含 CEF、编辑器静态资源、转换器、空白模板；关闭网络后启动应用。
2. 分别新建 DOCX、XLSX、PPTX，输入中文，保存到含空格及中文的路径，关闭后重新打开核对内容。
3. DOCX 检查表格、图片、页眉页脚及 PDF 导出；XLSX 检查公式、多工作表和合并单元格；PPTX 检查文字、图片、位置及 PDF 导出。
4. 检查未保存文档退出提示、中文输入法、多标签切换；确认不依赖系统安装的办公软件或 Node/Python 运行服务。

Xcode 16 与上游旧依赖的兼容补丁、源文件所需的精确工具版本、第三方下载可用性必须以实际构建结果为准。当前脚本保留并显示失败，不把缺少内核的 Swift 预览窗口称为 Office 编辑器。

官方依据：[构建工具](https://github.com/ONLYOFFICE/build_tools/tree/release/v9.4.0)、[平台解析](https://github.com/ONLYOFFICE/build_tools/blob/release/v9.4.0/scripts/config.py)、[CEF 获取](https://github.com/ONLYOFFICE/build_tools/blob/release/v9.4.0/scripts/core_common/modules/cef.py)、[macOS Xcode 工程](https://github.com/ONLYOFFICE/desktop-apps/tree/8f452c7f703b795dcc09012ba6517df4ca47f9bc/macos)、[公开 web-apps 固定提交](https://github.com/ONLYOFFICE/web-apps/commit/9c0ca538c3b211052347df09d2a4d6781f023403)。
