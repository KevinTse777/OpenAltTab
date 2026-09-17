// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenAltTab",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenAltTab",
            path: "Sources/OpenAltTab"
        )
    ]
)
