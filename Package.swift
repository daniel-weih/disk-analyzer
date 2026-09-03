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
        .target(
            name: "DiskStatusCore",
            path: "Sources/DiskStatusCore",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "SwapAnalysisCore",
            path: "Sources/SwapAnalysisCore"
        ),
        .executableTarget(
            name: "DiskAnalyzer",
            dependencies: ["DiskStatusCore", "SwapAnalysisCore"],
            path: "Sources/DiskAnalyzer",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "DiskAnalyzerTests",
            dependencies: ["DiskAnalyzer", "DiskStatusCore", "SwapAnalysisCore"],
            path: "Tests/DiskAnalyzerTests"
        )
    ]
)
