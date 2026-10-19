// swift-tools-version:5.10
// This file tells Swift how to build the app. No Xcode project needed:
// `swift build` reads this, compiles everything in Sources/DropWheel, done.
import PackageDescription

let package = Package(
    name: "DropWheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DropWheel", path: "Sources/DropWheel")
    ]
)
