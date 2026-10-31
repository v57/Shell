#if os(macOS)
import ComponentKit
import Foundation
import ShellIntegrations
import SwiftUI
import UniformTypeIdentifiers

/// App-side launcher for the "Open With" control: resolves the real
/// application (by bundle id), its icon, and how to open a project directory
/// in it. The kit's `KitDesktop` looks apps up, draws their icons and opens
/// them; the pure kind-resolution stays in `TerminalIntegrations`
/// (`OpenWithResolver`).
enum ProjectOpener {
  /// The display name for a kind (also the menu-item title).
  static func displayName(for kind: OpenWithKind) -> String {
    switch kind {
    case .xcode: return "Xcode"
    case .code: return "Code"
    case .zed: return "Zed"
    case .vscode: return "Visual Studio Code"
    case .markdown: return "Markdown"
    case .git: return "Git"
    case .dev: return "Dev"
    case .finder: return "Finder"
    }
  }

  private static func bundleID(for kind: OpenWithKind) -> String {
    switch kind {
    case .xcode: return "com.apple.dt.Xcode"
    case .code: return "dev.v57.code"
    case .zed: return "dev.zed.Zed"
    case .vscode: return "com.microsoft.VSCode"
    case .markdown: return "dev.v57.md"
    case .git: return "dev.v57.git"
    case .dev: return "dev.v57.dev"
    case .finder: return "com.apple.finder"
    }
  }

  /// Whether the app for `kind` is installed (only installed apps are shown).
  @MainActor static func isInstalled(_ kind: OpenWithKind) -> Bool {
    KitDesktop.isAppInstalled(bundleID(for: kind))
  }

  /// The app's real icon, or a generic application symbol when it isn't installed.
  @MainActor static func icon(for kind: OpenWithKind) -> Image {
    KitDesktop.appIcon(bundleID(for: kind)) ?? Image(systemName: "app")
  }

  /// Opens `directory` (or its project file) in the app for `kind`.
  @MainActor static func open(_ kind: OpenWithKind, in directory: URL) {
    switch kind {
    case .finder:
      // Finder is the default handler for folders — plain `open`.
      KitDesktop.open(directory)
    case .xcode, .code, .zed, .vscode, .markdown, .git, .dev:
      KitDesktop.open([targetURL(for: kind, in: directory)], withApp: bundleID(for: kind))
    }
  }

  /// What to hand the app: for Xcode prefer the project bundle (`Package.swift`
  /// for a pure SwiftPM package); editors/Finder get the directory itself.
  private static func targetURL(for kind: OpenWithKind, in directory: URL) -> URL {
    guard kind == .xcode else { return directory }
    let entries = IntegrationFileLister.list(directory: directory)
    if let project = entries.first(where: {
      $0.name.hasSuffix(".xcodeproj") || $0.name.hasSuffix(".xcworkspace")
    }) {
      return directory.appendingPathComponent(project.name)
    }
    if entries.contains(where: { $0.name == "Package.swift" && !$0.isDirectory }) {
      return directory.appendingPathComponent("Package.swift")
    }
    return directory
  }
}
#endif // os(macOS)
