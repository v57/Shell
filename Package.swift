// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Shell-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
    Context.environment["V57_LOCAL"] == nil
        ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}

// The libraries. The app is a package of its own (App/Package.swift) with the dependencies only it uses.
let package = Package(
    name: "Shell",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ShellKit", targets: ["ShellKit"]), .library(name: "ShellIntegrations", targets: ["ShellIntegrations"]), .library(name: "ShellMonitoring", targets: ["ShellMonitoring"]), .library(name: "ShellDatabaseEngines", targets: ["ShellDatabaseEngines"])],
    dependencies: [
        // Database's interface and pure-Swift engines, and its libssh2 +
        // mbedTLS build, which Shell links instead of its own (one copy per
        // app: two would clash). Binary/SSH-libssh2/build-ssh.sh
        // still builds the libssh2 that Database's Scripts/build-libssh2.sh
        // repackages.
        v57("Database"),
        // The vault: the store, keys and records the v57 apps share.
        v57("Vault"),
        // CodeActions: the smart actions (a project's schemes and their
        // build, run, test, lint and distribute commands) come from Code.
        v57("Code"),
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
            dependencies: [
                .product(name: "CodeActions", package: "Code"),
            ],
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
        // The sidebar's database connections: Database's interface
        // (DatabaseUI: the tree, browsers, query tabs, pipelines, inspector and
        // connection sheets) on its engine-neutral DatabaseKit (PostgreSQL,
        // MySQL, MariaDB, SQL Server, SQLite, DuckDB, MongoDB, Redis,
        // Cassandra, ScyllaDB), all pure Swift on macOS and iOS but DuckDB
        // (an optional download on the Mac).
        .target(
            name: "ShellDatabaseEngines",
            dependencies: [
                .product(name: "DatabaseKit", package: "Database"),
                .product(name: "DatabaseUI", package: "Database"),
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

#if os(Windows) || os(Linux)
// Off Apple platforms CryptoKit and os are v57/SwiftUI's stand-ins, Database's Libssh2 is libssh2 built from source
// (module CLibssh2, as on Apple platforms), and Foundation's extras come from SwiftUIPortability.
package.dependencies += [v57("SwiftUI")]
for target in package.targets where target.type == .regular || target.type == .test {
  target.dependencies += [
    .product(name: "CryptoKit", package: "SwiftUI"), .product(name: "os", package: "SwiftUI"),
    .product(name: "SwiftUIPortability", package: "SwiftUI"),
  ]
  if target.name == "ShellKit" { target.dependencies.append(.product(name: "SwiftUI", package: "SwiftUI")) }
  // URLSession lives in FoundationNetworking, @Observable in Observation and Apple's Foundation extras in
  // SwiftUIPortability: imported everywhere, as Foundation brings them on Apple platforms.
  target.swiftSettings = (target.swiftSettings ?? []) + [
    .unsafeFlags(
      ["FoundationNetworking", "Observation", "SwiftUIPortability"].flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] })
  ]
}
#if os(Linux)
// ShellMonitoring reads the CPU load through Platform's PlatformSystem.
package.dependencies += [v57("Platform")]
for target in package.targets where target.name == "ShellMonitoring" {
  target.dependencies.append(.product(name: "PlatformSystem", package: "Platform"))
}
#endif
#endif
