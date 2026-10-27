// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenFeed",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OpenFeed", path: "Sources/OpenFeed")
    ]
)
