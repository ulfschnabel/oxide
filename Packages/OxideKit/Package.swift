// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OxideKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OxideKit", targets: ["OxideKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.41.0"),
    ],
    targets: [
        .target(
            name: "OxideKit",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "OxideKitTests",
            dependencies: ["OxideKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
