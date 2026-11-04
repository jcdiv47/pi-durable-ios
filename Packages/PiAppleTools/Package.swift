// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PiAppleTools",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PiAppleTools", targets: ["PiAppleTools"])],
    // PiUI for the alarms' metadata type, which the widget extension's Live Activity shares.
    dependencies: [.package(path: "../PiUI")],
    targets: [
        .target(name: "PiAppleTools", dependencies: ["PiUI"]),
        .testTarget(name: "PiAppleToolsTests", dependencies: ["PiAppleTools"]),
    ]
)
