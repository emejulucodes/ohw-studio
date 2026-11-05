// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OHWStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "OHWStudio", path: "Sources/OHWStudio")
    ]
)
