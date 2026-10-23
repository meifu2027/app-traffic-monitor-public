// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AppTrafficMonitorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SharedContracts", targets: ["SharedContracts"]),
        .library(name: "StatsCore", targets: ["StatsCore"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "MihomoAdapter", targets: ["MihomoAdapter"]),
    ],
    targets: [
        .target(
            name: "SharedContracts",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "StatsCore",
            dependencies: ["SharedContracts"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "Storage",
            dependencies: ["SharedContracts", "StatsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MihomoAdapter",
            dependencies: ["SharedContracts"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
