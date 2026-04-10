// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HiCrisp",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CGVirtualDisplayAPI",
            path: "Sources/CGVirtualDisplayAPI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "HiCrispSupport",
            path: "Sources/HiCrispSupport"
        ),
        .executableTarget(
            name: "HiCrisp",
            dependencies: ["CGVirtualDisplayAPI", "HiCrispSupport"],
            path: "Sources",
            exclude: ["CGVirtualDisplayAPI", "HiCrispSupport"],
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks"]),
            ]
        ),
        .testTarget(
            name: "HiCrispSupportTests",
            dependencies: ["HiCrispSupport"],
            path: "Tests/HiCrispSupportTests"
        ),
    ]
)
