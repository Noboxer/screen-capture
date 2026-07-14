// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenCapture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenCapture",
            path: "Sources/ScreenCapture",
            exclude: ["Info.plist"]
        ),
    ]
)
