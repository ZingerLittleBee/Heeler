// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HeelerSSH",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "HeelerSSH", targets: ["HeelerSSH"]),
    ],
    targets: [
        .binaryTarget(
            name: "COpenSSL",
            path: "Artifacts/COpenSSL.xcframework"
        ),
        .binaryTarget(
            name: "CLibSSH2",
            path: "Artifacts/CLibSSH2.xcframework"
        ),
        .target(
            name: "CHeelerSSHSupport",
            dependencies: ["CLibSSH2"]
        ),
        .target(
            name: "HeelerSSH",
            dependencies: ["CLibSSH2", "COpenSSL", "CHeelerSSHSupport"]
        ),
        .testTarget(
            name: "HeelerSSHTests",
            dependencies: ["HeelerSSH"]
        ),
    ]
)
