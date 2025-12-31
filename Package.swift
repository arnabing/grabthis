// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "grabthis",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "GrabThisApp", targets: ["GrabThisApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "GrabThisApp",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/GrabThisApp",
            resources: [
                .process("Assets.xcassets")
            ]
        ),
    ]
)


