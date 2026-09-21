// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WeChatClean",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(
            name: "WeChatClean",
            targets: ["WeChatClean"]
        )
    ],
    targets: [
        .executableTarget(
            name: "WeChatClean",
            path: "Sources/WeChatClean"
        ),
        .testTarget(
            name: "WeChatCleanTests",
            dependencies: ["WeChatClean"],
            path: "Tests/WeChatCleanTests"
        )
    ]
)
