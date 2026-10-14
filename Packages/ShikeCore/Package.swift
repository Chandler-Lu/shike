// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShikeCore",
    platforms: [.iOS(.v17), .macOS(.v13), .watchOS(.v10)],
    products: [.library(name: "ShikeCore", targets: ["ShikeCore"])],
    targets: [
        .target(name: "ShikeCore"),
        .testTarget(name: "ShikeCoreTests", dependencies: ["ShikeCore"])
    ]
)
