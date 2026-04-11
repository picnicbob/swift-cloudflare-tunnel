// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickTunnelExample",
    platforms: [
        .macOS(.v12),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "QuickTunnelExample",
            dependencies: [
                .product(name: "CloudflareTunnel", package: "swift-cloudflare-tunnel"),
            ],
            path: "Sources"
        ),
    ]
)
