// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DroidShim",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DroidShimCore",
            type: .dynamic,
            targets: ["DroidShimCore"]
        ),
        .executable(
            name: "DroidShimApp",
            targets: ["DroidShimApp"]
        )
    ],
    targets: [
        .target(
            name: "DroidShimCore",
            dependencies: ["DroidShimNative"],
            path: "Sources/DroidShimCore",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .target(
            name: "DroidShimNative",
            dependencies: [],
            path: "Sources/DroidShimNative",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("Binary"),
                .define("__APPLE__"),
                .define("_GNU_SOURCE")
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedFramework("Metal", .when(platforms: [.iOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.iOS]))
            ]
        ),
        .executableTarget(
            name: "DroidShimApp",
            dependencies: ["DroidShimCore"],
            path: "Sources/DroidShimApp",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("UIKit", .when(platforms: [.iOS]))
            ]
        ),
        .testTarget(
            name: "DroidShimTests",
            dependencies: ["DroidShimCore", "DroidShimNative"],
            path: "Tests",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
