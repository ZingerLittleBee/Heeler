// swift-tools-version: 6.2

import PackageDescription

// The native libraries (CTailscale, CZeroTier, CEasyTier) are built and
// published by https://github.com/Ylarod/heeler-overlay-natives (ADR 0021).
//
// Upgrade with `scripts/use-overlay-natives-release.sh <version>` (repository
// root). Always depend on an exact release; never on a branch or a range.
let nativesDependency: Package.Dependency =
    .package(url: "https://github.com/Ylarod/heeler-overlay-natives.git", exact: "1.0.2")

let package = Package(
    name: "HeelerOverlay",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "HeelerOverlay", targets: ["HeelerOverlay"]),
    ],
    dependencies: [
        nativesDependency,
    ],
    targets: [
        .target(
            name: "CHeelerOverlaySupport",
            dependencies: [
                .product(name: "CZeroTier", package: "heeler-overlay-natives"),
            ]
        ),
        .target(
            name: "HeelerOverlay",
            dependencies: [
                .product(name: "CTailscale", package: "heeler-overlay-natives"),
                .product(name: "CZeroTier", package: "heeler-overlay-natives"),
                .product(name: "CEasyTier", package: "heeler-overlay-natives"),
                "CHeelerOverlaySupport",
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("resolv"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "HeelerOverlayTests",
            dependencies: [
                "HeelerOverlay",
                "CHeelerOverlaySupport",
                .product(name: "CZeroTier", package: "heeler-overlay-natives"),
            ]
        ),
    ]
)
