// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PiSSH",
    // macOS too, so `swift test` runs the client against an in-process SSH server on the dev machine.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PiSSH", targets: ["PiSSH"])],
    // The app's only third-party dependency (docs/adr/0012-ssh-hosts.md): SSH over SwiftNIO, pinned to a minor version.
    dependencies: [.package(url: "https://github.com/orlandos-nl/Citadel.git", .upToNextMinor(from: "0.12.1"))],
    targets: [
        .target(name: "PiSSH", dependencies: [.product(name: "Citadel", package: "Citadel")]),
        .testTarget(name: "PiSSHTests", dependencies: ["PiSSH", .product(name: "Citadel", package: "Citadel")]),
    ]
)
