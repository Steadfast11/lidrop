// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lidrop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "lidrop", path: "Sources/lidrop")
    ]
)
