// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HeelerMosh",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        // The app imports both C modules directly: `libmoshios` for
        // mosh_main and `CMosh` for the winsize/locale helpers.
        .library(name: "HeelerMosh", targets: ["CMosh", "libmoshios"]),
    ],
    targets: [
        // libmoshios + protobuf 2.6.1 merged into one static archive per
        // slice by Scripts/build-native.sh — a single archive removes the
        // static-link ordering hazard between the two libraries.
        .binaryTarget(
            name: "libmoshios",
            path: "Artifacts/libmoshios.xcframework"
        ),
        .target(
            name: "CMosh",
            dependencies: ["libmoshios"],
            linkerSettings: [
                // libmoshios is C++; zlib backs the protobuf I/O paths.
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
            ]
        ),
    ]
)
