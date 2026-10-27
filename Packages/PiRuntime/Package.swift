// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PiRuntime",
    // macOS only so `swift test` can run the JSC suites on the dev machine; the app is iPhone-only.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PiRuntime", targets: ["PiRuntime"]),
    ],
    // Tests only: the UI tools run against PiUI's real SurfaceHost.
    dependencies: [.package(path: "../PiUI")],
    targets: [
        .target(
            name: "PiRuntime",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("JavaScriptCore")]
        ),
        .testTarget(
            name: "PiRuntimeTests",
            dependencies: ["PiRuntime", .product(name: "PiUI", package: "PiUI")],
            // Bundles produced by `js/build.ts` (git-ignored).
            resources: [.copy("JS")]
        ),
    ]
)
