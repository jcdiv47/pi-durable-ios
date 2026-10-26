// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PiAppleTools",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PiAppleTools", targets: ["PiAppleTools"])],
    targets: [.target(name: "PiAppleTools")]
)
