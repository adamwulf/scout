// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Scout",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ScoutKit", targets: ["ScoutKit"]), .executable(name: "scout", targets: ["scout"])],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")],
    targets: [
        .target(name: "ScoutKit"),
        .executableTarget(name: "scout", dependencies: ["ScoutKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "ScoutKitTests", dependencies: ["ScoutKit"]),
        .testTarget(name: "CLITests", dependencies: ["scout"])
    ]
)
