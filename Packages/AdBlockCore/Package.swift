// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AdBlockCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AdBlockCore", targets: ["AdBlockCore"]),
    ],
    targets: [
        .target(name: "AdBlockCore"),
        .testTarget(name: "AdBlockCoreTests", dependencies: ["AdBlockCore"]),
    ]
)
