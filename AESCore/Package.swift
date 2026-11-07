// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AESCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AESCore", targets: ["AESCore"]),
    ],
    targets: [
        .target(name: "AESCore"),
        .testTarget(name: "AESCoreTests", dependencies: ["AESCore"]),
    ]
)
