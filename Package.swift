// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SwiftAsar",
    platforms: [
        .macOS(.v11),
        .iOS(.v14),
        .tvOS(.v14),
        .watchOS(.v7)
    ],
    products: [
        .library(
            name: "SwiftAsar",
            targets: ["SwiftAsar"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftAsar"
        ),
        .testTarget(
            name: "SwiftAsarTests",
            dependencies: ["SwiftAsar"]
        ),
    ]
)
