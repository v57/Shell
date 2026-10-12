// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Terminal",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Terminal", targets: ["Terminal"]), .library(name: "TerminalIntegrations", targets: ["TerminalIntegrations"]), .library(name: "Monitoring", targets: ["Monitoring"]), .library(name: "DatabaseEngines", targets: ["DatabaseEngines"])],
    dependencies: [
        // Local Database package (MongoDB / PostgreSQL / Redis / SQLite engine
        // libraries). All four engines are cross-platform — the C-driver
        // XCFrameworks ship iOS device + simulator slices, and
        // SQLite uses the SDK's system SQLite3 module that is present on both
        // macOS and iOS — so every engine links and runs on both platforms.
        .package(path: "../Database"),
    ],
    targets: [
        // Built by Binary/SSH-libssh2/build-ssh.sh. Its modulemap sits in
        // Headers/CLibssh2/ so it can share the build's include folder with the
        // Database package's driver XCFrameworks.
        .binaryTarget(name: "Libssh2", path: "Binary/SSH-libssh2/Libssh2.xcframework"),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Terminal",
            dependencies: [
                // libssh2 + mbedTLS, surfaced as the CLibssh2 module
                // (consumed by Libssh2Connection and Libssh2PortForward).
                "Libssh2",
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "TerminalIntegrations",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "Monitoring",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Aggregates the local ../Database engine libraries for shell/DB
        // sidebar integration. All four engines (MongoDB / PostgreSQL / Redis
        // / SQLite) are cross-platform now — the C-driver XCFrameworks add iOS
        // slices and SQLite rides the SDK's system SQLite3 module — so no
        // engine is conditionally excluded from iOS builds anymore.
        .target(
            name: "DatabaseEngines",
            dependencies: [
                .product(name: "PostgreSQL", package: "Database"),
                .product(name: "Redis", package: "Database"),
                .product(name: "MongoDB", package: "Database"),
                .product(name: "SQLite", package: "Database"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "TerminalIntegrationsTests",
            dependencies: ["TerminalIntegrations"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "TerminalTests",
            dependencies: ["Terminal"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "MonitoringTests",
            dependencies: ["Monitoring"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        )
    ]
)
