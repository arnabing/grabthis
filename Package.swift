// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "grabthis",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "GrabThisApp", targets: ["GrabThisApp"]),
    ],
    targets: [
        .executableTarget(
            name: "GrabThisApp",
            path: "Sources/GrabThisApp"
        ),
    ]
)


