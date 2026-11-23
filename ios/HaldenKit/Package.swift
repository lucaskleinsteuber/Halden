// swift-tools-version: 6.2
// HaldenKit: everything of the Halden apps that isn't a screen or the camera. Talking to the
// server (pinned TLS), pairing, the local database, uploads that survive restarts, sync and
// thumbnails. It builds for iOS and macOS, so the tests run on the Mac with `swift test` and the
// Mac app can use it later.
import PackageDescription

let package = Package(
    name: "HaldenKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HaldenKit", targets: ["HaldenKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(
            name: "HaldenKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "HaldenKitTests",
            dependencies: ["HaldenKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
