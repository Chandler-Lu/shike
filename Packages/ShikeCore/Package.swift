// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShikeCore",
    platforms: [.iOS(.v17), .macOS(.v13), .watchOS(.v10)],
    products: [.library(name: "ShikeCore", targets: ["ShikeCore"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.9.6")],
    targets: [
        .target(name: "ShikeCore", dependencies: ["SwiftSoup"]),
        .testTarget(name: "ShikeCoreTests", dependencies: ["ShikeCore"])
    ]
)
