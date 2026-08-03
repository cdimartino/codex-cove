// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexCove",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CoveCore",
            targets: ["CoveCore"]
        ),
        .executable(
            name: "CodexCove",
            targets: ["CodexCoveApp"]
        )
    ],
    targets: [
        .target(name: "CoveCore"),
        .executableTarget(
            name: "CodexCoveApp",
            dependencies: ["CoveCore"]
        ),
        .executableTarget(
            name: "CoveCoreSmokeTests",
            dependencies: ["CoveCore"],
            path: "Tests/CoveCoreTests"
        )
    ]
)
