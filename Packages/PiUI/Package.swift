// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PiUI",
    // macOS too, so `swift test` runs the validator and snapshot tests on the dev machine.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PiUI", targets: ["PiUI"])],
    targets: [
        .target(name: "PiUI"),
        // Fixtures and reference images are read (and recorded) in place, next to the tests.
        .testTarget(name: "PiUITests", dependencies: ["PiUI"], exclude: ["Fixtures", "Snapshots"]),
    ]
)
