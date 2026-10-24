// swift-tools-version: 6.0

// What the app decides over plain values, with no UIKit in it, so its tests run with
// `swift test` on the Mac instead of in the simulator (apps/ios/docs/IMPLEMENTATION.md §6).
import PackageDescription

let package = Package(
    name: "HoldMyTrackCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HoldMyTrackCore", targets: ["HoldMyTrackCore"]),
    ],
    // Yams reads the API contract for WireContractTests; the app never links it.
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "HoldMyTrackCore"),
        .testTarget(name: "HoldMyTrackCoreTests", dependencies: ["HoldMyTrackCore", "Yams"]),
    ]
)
