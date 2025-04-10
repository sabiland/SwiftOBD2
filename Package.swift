// swift-tools-version: 5.7.1
import PackageDescription

let package = Package(
    name: "SwiftOBD2",
    platforms: [
        .iOS(.v14),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "SwiftOBD2",
            targets: ["SwiftOBD2"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", from: "7.6.5")
    ],
    targets: [
        .target(
            name: "SwiftOBD2",
            dependencies: [
                .product(name: "CocoaAsyncSocket", package: "CocoaAsyncSocket")
            ]
        ),
        .testTarget(
            name: "SwiftOBD2Tests",
            dependencies: ["SwiftOBD2"]
        )
    ]
)