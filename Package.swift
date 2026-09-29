// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swift-throttling",
    platforms: [
        .macOS(.v27),
        .iOS(.v27),
        .tvOS(.v27),
        .watchOS(.v27),
        .visionOS(.v27),
    ],
    products: [
        .library(name: "Throttling", targets: ["Throttling"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Throttling",
            dependencies: []
        ),
        .testTarget(
            name: "Throttling Tests",
            dependencies: [
                .target(name: "Throttling")
            ]
        )
    ]
)

