// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PBsync",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PBsyncCore", targets: ["PBsyncCore"]),
        .executable(name: "PBsyncApp", targets: ["PBsyncApp"]),
        .executable(name: "pbsync", targets: ["PBsyncCLI"])
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "PBsyncCore", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .executableTarget(name: "PBsyncApp", dependencies: ["PBsyncCore"]),
        .executableTarget(name: "PBsyncCLI", dependencies: ["PBsyncCore"]),
        .testTarget(name: "PBsyncCoreTests", dependencies: ["PBsyncCore"]),
        .testTarget(name: "PBsyncAppTests", dependencies: ["PBsyncApp", "PBsyncCore"])
    ]
)
