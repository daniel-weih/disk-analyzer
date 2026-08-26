// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskAnalyzer",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DiskAnalyzer", targets: ["DiskAnalyzer"])
    ],
    targets: [
        .executableTarget(
            name: "DiskAnalyzer",
            path: "Sources/DiskAnalyzer",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DiskAnalyzerTests",
            dependencies: ["DiskAnalyzer"],
            path: "Tests/DiskAnalyzerTests"
        )
    ]
)
