// swift-tools-version: 5.9
import PackageDescription

// 仅依赖 macOS 系统框架，避免首次构建需要下载第三方预览组件。
let package = Package(
    name: "FileWorkbench",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FileWorkbench", targets: ["FileWorkbench"])],
    targets: [
        .executableTarget(name: "FileWorkbench"),
        .testTarget(name: "FileWorkbenchTests", dependencies: ["FileWorkbench"])
    ]
)
