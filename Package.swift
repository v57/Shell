// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Shell",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ShellKit", targets: ["ShellKit"]), .library(name: "ShellIntegrations", targets: ["ShellIntegrations"]), .library(name: "ShellMonitoring", targets: ["ShellMonitoring"]), .library(name: "ShellDatabaseEngines", targets: ["ShellDatabaseEngines"])],
    dependencies: [
        // Database's pure-Swift engines (every engine but DuckDB is offered)
        // and its libssh2 + mbedTLS build, which Shell links instead of its own
        // (one copy per app: two would clash). Binary/SSH-libssh2/build-ssh.sh
        // still builds the libssh2 that Database's Scripts/build-libssh2.sh
        // repackages.
        .package(path: "../Database"),
        // The vault: the store, keys and records the v57 apps share.
        .package(path: "../Vault"),
    ],
    targets: [
        .target(
            name: "ShellKit",
            dependencies: [
                // libssh2 + mbedTLS, surfaced as the CLibssh2 module
                // (consumed by Libssh2Connection and Libssh2PortForward).
                .product(name: "Libssh2", package: "Database"),
                // SSH channels as in-process byte streams for the database
                // browser (SSHChannelStreams, WireDialer): no local port.
                .product(name: "SSHTunnel", package: "Database"),
                .product(name: "WireKit", package: "Database"),
                // The device's SSH key, saved passwords and known hosts.
                .product(name: "VaultKit", package: "Vault"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "ShellIntegrations",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "ShellMonitoring",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // The database engines for the sidebar's connections: Database's
        // engine-neutral DatabaseKit (PostgreSQL, MySQL, MariaDB, SQL Server,
        // SQLite, MongoDB, Redis, Cassandra, ScyllaDB), all pure Swift on macOS
        // and iOS.
        .target(
            name: "ShellDatabaseEngines",
            dependencies: [
                .product(name: "DatabaseKit", package: "Database"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ShellIntegrationsTests",
            dependencies: ["ShellIntegrations"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ShellKitTests",
            dependencies: ["ShellKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ShellMonitoringTests",
            dependencies: ["ShellMonitoring"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        )
    ]
)
