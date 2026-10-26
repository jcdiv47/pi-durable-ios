// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PiUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PiUI", targets: ["PiUI"])],
    targets: [.target(name: "PiUI")]
)
