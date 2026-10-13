// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Stash", path: "Sources/Stash")
    ]
)
