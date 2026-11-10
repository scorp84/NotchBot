// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchBot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchBot",
            path: "NotchBot",
            exclude: ["Info.plist", "Resources"]
        )
    ]
)
