// swift-tools-version: 6.4
// The app, a package of its own beside the libraries (..), so the repositories it depends on can depend on this one's
// libraries without a cycle between packages.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Shell-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's libraries, the package at "..": SwiftPM names a path dependency after its folder, which is Shell in
/// the main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Shell")

let package = Package(
  name: "ShellApp", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "ShellApp", targets: ["ShellApp"])],
  dependencies: [
    .package(path: ".."),
    // Database's tunnels and byte streams, the vault, Markdown's notes, the shared design, in-app updates,
    // screenshot scenes and Code's action sheets (Platform's web view is added below, everywhere but Windows).
    v57("Database"), v57("Vault"), v57("Markdown"), v57("Component"), v57("UpdateKit"), v57("Dev"), v57("Code"),
  ],
  targets: [
    // The app, all of it but its entry point (Sources/Shell/ShellMain.swift): Shell.xcodeproj builds that file into
    // Shell.app with Resources (the icon, Info.plist, entitlements and privacy manifest); on Linux and Windows the
    // Shell target below does. Its tests (Tests/ShellTests) run inside Shell.app (the Keychain, the Secure Enclave,
    // the shared AppModel), so they stay the Xcode project's ShellTests target.
    .target(
      name: "ShellApp",
      dependencies: [
        .product(name: "ShellKit", package: kits), .product(name: "ShellIntegrations", package: kits),
        .product(name: "ShellMonitoring", package: kits), .product(name: "ShellDatabaseEngines", package: kits),
        .product(name: "SSHTunnel", package: "Database"), .product(name: "WireKit", package: "Database"),
        .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
        .product(name: "MarkdownKit", package: "Markdown"), .product(name: "ComponentKit", package: "Component"),
        .product(name: "DevScreenshots", package: "Dev"),
        // The Notarization sheet, shared with Code.
        .product(name: "CodeActionsUI", package: "Code"),
        // Updates from GitHub Releases outside the App Store (the iOS app updates through the App Store).
        .product(name: "UpdateKit", package: "UpdateKit", condition: .when(platforms: [.macOS, .linux, .windows])),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ])
  ])

#if !os(Windows)
// Web sessions: Platform's PlatformWeb (WKWebView on Apple platforms, WebKitGTK on Linux); Windows offers Open in
// Browser instead.
package.dependencies += [v57("Platform")]
for target in package.targets where target.name == "ShellApp" {
  target.dependencies.append(.product(name: "PlatformWeb", package: "Platform"))
}
#endif

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI and the frameworks the app imports (SwiftData, Charts, SQLite3, CryptoKit) are
// v57/SwiftUI's stand-ins. Only here: on Apple platforms the app uses Apple's, and v57/SwiftUI (with its swift-syntax)
// stays out of the package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
// On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), Observation (@Observable),
// URLSession and the file APIs SwiftUIPortability adds along: every file gets them here too.
let appSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .unsafeFlags(
    ["Combine", "Observation", "FoundationNetworking", "SwiftUIPortability"].flatMap {
      ["-Xfrontend", "-import-module", "-Xfrontend", $0]
    }),
]
for target in package.targets where target.name == "ShellApp" {
  target.dependencies += ["SwiftUI", "SwiftData", "Charts", "SQLite3", "CryptoKit", "SwiftUIPortability"].map {
    .product(name: $0, package: "SwiftUI")
  }
  target.swiftSettings = appSettings
}
// The entry point, Sources/Shell/ShellMain.swift, which Shell.xcodeproj builds on Apple platforms.
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this App folder>
// -Product ShellWinUI).
package.targets.append(
  .target(
    name: "Shell", dependencies: ["ShellApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.library(name: "ShellWinUI", type: .dynamic, targets: ["Shell"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product Shell; SwiftUI's Linux/scripts/build-app
// --package <this App folder> Shell stages it).
package.targets.append(
  .executableTarget(
    name: "Shell", dependencies: ["ShellApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.executable(name: "Shell", targets: ["Shell"]))
#endif
#endif
