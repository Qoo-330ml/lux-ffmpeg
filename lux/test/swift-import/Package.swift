// swift-tools-version:6.0
//
// lux/test/swift-import — F1 的最小 SwiftPM 自检包(独立于 lux-client)。
//
// 目的:证明 lux-ffmpeg 产出的动态 framework 能被 Swift 直接
// `import Libavformat / Libavcodec / Libavutil / Libswresample`,
// 不需要任何 C shim、头文件搜索路径或大小写不敏感的卷。
//
// 二进制来自 ../../.build/xcframeworks/(`lux/build/build-frameworks.sh all` 的产物),
// 该目录在 .gitignore 里,仓库不提交二进制。跑法见 `lux/test/swift-import/run.sh`。
//
import PackageDescription

let package = Package(
    name: "LuxFFmpegImport",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "lux-ffmpeg-probe", targets: ["LuxFFmpegProbeCLI"]),
    ],
    targets: [
        .target(
            name: "LuxFFmpegProbeKit",
            dependencies: [
                .target(name: "Libavformat"),
                .target(name: "Libavcodec"),
                .target(name: "Libavutil"),
                .target(name: "Libswresample"),
            ]
        ),
        .executableTarget(
            name: "LuxFFmpegProbeCLI",
            dependencies: ["LuxFFmpegProbeKit"]
        ),
        .testTarget(
            name: "LuxFFmpegProbeKitTests",
            dependencies: ["LuxFFmpegProbeKit"]
        ),
        // binaryTarget(path:) 指向包目录之外是允许的(SwiftPM 只要求路径存在);
        // 这样产物保持在 lux/.build/ 内,不用把二进制拷进源码目录。
        .binaryTarget(name: "Libavformat", path: "../../.build/xcframeworks/Libavformat.xcframework"),
        .binaryTarget(name: "Libavcodec", path: "../../.build/xcframeworks/Libavcodec.xcframework"),
        .binaryTarget(name: "Libavutil", path: "../../.build/xcframeworks/Libavutil.xcframework"),
        .binaryTarget(name: "Libswresample", path: "../../.build/xcframeworks/Libswresample.xcframework"),
    ]
)
