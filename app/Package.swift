// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS("26.7.1")],
    products: [
        .library(name: "ExplorerCore", targets: ["ExplorerCore"]),
        .executable(name: "Explorer", targets: ["ExplorerApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(name: "ExplorerCore", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .executableTarget(name: "ExplorerApp", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerAppTests", dependencies: ["ExplorerApp", "ExplorerCore"])
    ]
)
