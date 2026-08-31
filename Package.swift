// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Terminal",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Terminal", targets: ["Terminal"]), .library(name: "TerminalIntegrations", targets: ["TerminalIntegrations"]), .library(name: "Monitoring", targets: ["Monitoring"]), .library(name: "DatabaseEngines", targets: ["DatabaseEngines"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto", from: "4.0.0"),
        // Local Database package (MongoDB / PostgreSQL / Redis / SQLite engine
        // libraries). All four engines are cross-platform — the C-driver
        // XCFramework (Cdrivers) ships iOS device + simulator slices, and
        // SQLite uses the SDK's system SQLite3 module that is present on both
        // macOS and iOS — so every engine links and runs on both platforms.
        .package(path: "../Database"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Terminal",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                // The libssh2 + mbedTLS static library is merged into the
                // Database package's Cdrivers XCFramework, surfaced as the
                // CLibssh2 module (consumed by Libssh2Connection). Depending
                // on the Cdrivers product links libssh2 into the Terminal
                // target without a second C-module binaryTarget (which would
                // collide under Xcode's ProcessXCFramework).
                .product(name: "Cdrivers", package: "Database"),
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
        // / SQLite) are cross-platform now — the C-driver XCFramework adds iOS
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
            name: "MonitoringTests",
            dependencies: ["Monitoring"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        )
    ]
)
