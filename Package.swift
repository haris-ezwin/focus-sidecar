// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FocusSidecar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FocusSidecar", targets: ["FocusSidecar"])
    ],
    targets: [
        .executableTarget(
            name: "FocusSidecar",
            path: "Sources/FocusSidecar"
        )
    ]
)
