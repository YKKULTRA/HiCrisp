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
        .executableTarget(
            name: "HiCrisp",
            dependencies: ["CGVirtualDisplayAPI"],
            path: "Sources",
            exclude: ["CGVirtualDisplayAPI"],
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks"]),
            ]
        ),
    ]
)
