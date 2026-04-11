// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NamedTunnelExample",
    platforms: [
        .macOS(.v12),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "NamedTunnelExample",
            dependencies: [
                .product(name: "CloudflareTunnel", package: "swift-cloudflare-tunnel"),
            ],
            path: "Sources"
        ),
    ]
)
