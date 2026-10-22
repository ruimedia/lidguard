// swift-tools-version:5.9
import PackageDescription

// LidGuard —— 仅驻菜单栏的 macOS 合盖保活守卫
//
// 注意：本机只安装了 Command Line Tools，没有完整 Xcode。
// SwiftUI 的 @State / @StateObject 依赖 SwiftUIMacros 插件（随 Xcode 分发），
// 因此界面用 AppKit 实现。SwiftUI 版本保留在 swiftui-draft/ 目录，
// 装了 Xcode 后可迁回。
let package = Package(
    name: "LidGuard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LidGuard",
            path: "Sources/LidGuard"
        )
    ]
)