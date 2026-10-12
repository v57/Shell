#if os(macOS)
import AppKit
import Foundation
import ShellIntegrations
import UniformTypeIdentifiers

/// App-side launcher for the "Open With" control: resolves the real
/// application (by bundle id), its icon, and how to open a project directory
/// in it. Everything here needs AppKit, so it lives in the app target while
/// the pure kind-resolution stays in `TerminalIntegrations` (`OpenWithResolver`).
enum ProjectOpener {
  /// The display name for a kind (also the menu-item title).
  static func displayName(for kind: OpenWithKind) -> String {
    switch kind {
    case .xcode: return "Xcode"
    case .zed: return "Zed"
    case .vscode: return "Visual Studio Code"
    case .finder: return "Finder"
    }
  }

  private static func bundleID(for kind: OpenWithKind) -> String {
    switch kind {
    case .xcode: return "com.apple.dt.Xcode"
    case .zed: return "dev.zed.Zed"
    case .vscode: return "com.microsoft.VSCode"
    case .finder: return "com.apple.finder"
    }
  }

  static func appURL(for kind: OpenWithKind) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(for: kind))
  }

  /// Whether the app for `kind` is installed (only installed apps are shown).
  static func isInstalled(_ kind: OpenWithKind) -> Bool {
    appURL(for: kind) != nil
  }

  /// The app's real icon, or a generic application icon when it isn't installed.
  static func icon(for kind: OpenWithKind, fallback: NSImage = NSWorkspace.shared.icon(for: .application)) -> NSImage {
    guard let url = appURL(for: kind) else { return fallback }
    return NSWorkspace.shared.icon(forFile: url.path)
  }

  /// Opens `directory` (or its project file) in the app for `kind`.
  static func open(_ kind: OpenWithKind, in directory: URL) {
    switch kind {
    case .finder:
      // Finder is the default handler for folders — plain `open`.
      NSWorkspace.shared.open(directory)
    case .xcode, .zed, .vscode:
      guard let app = appURL(for: kind) else { return }
      let target = targetURL(for: kind, in: directory)
      try? NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
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
