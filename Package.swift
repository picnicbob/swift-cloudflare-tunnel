// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-cloudflare-tunnel",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "CloudflareTunnel", targets: ["CloudflareTunnel"]),
		.executable(name: "Quick Tunnel Test", targets: ["qtt"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CloudflareTunnel",
            dependencies: [],
            path: "Sources/CloudflareTunnel"
        ),
        .testTarget(
            name: "CloudflareTunnelTests",
            dependencies: ["CloudflareTunnel"],
            path: "Tests/CloudflareTunnelTests"
        ),
		.executableTarget(name: "qtt", dependencies: ["CloudflareTunnel"])
    ]
)
