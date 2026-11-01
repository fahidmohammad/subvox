// swift-tools-version: 5.9
import PackageDescription

// Run the logic tests without launching the app or requesting sensor access.
let package = Package(
    name: "Subvox",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "Subvox",
            path: "Subvox",
            exclude: ["App/SubvoxApp.swift", "Info.plist", "Subvox.entitlements"]),
        .testTarget(name: "SubvoxTests", dependencies: ["Subvox"], path: "SubvoxTests"),
    ])
