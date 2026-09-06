import Foundation

/// Detects a PHP/Composer project (`composer.json`) and exposes install / test /
/// run smart actions. Active only when `composer` is installed.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity, the composer.json
/// reader, and the command builder), per the framework's per-language REUSE RULE —
/// no duplicated marker/scan boilerplate. The manifest reader is injectable so
/// tests don't need a real project on disk (mirrors `DartIntegration`'s injectable
/// pubspec reader and `JSIntegration`'s injectable package.json reader).
public final class PHPIntegration: TerminalIntegration {
  /// Reads the `composer.json` manifest text for a directory; nil when unreadable.
  public typealias ManifestReader = (URL) -> String?

  private let base: ToolIntegrationBase

  public var id: String { base.id }
  public var displayName: String { base.displayName }
  /// Composer is the binary every command below shells through, so availability
  /// gates on it; the live PATH probe resolves `composer`.
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  /// - Parameters:
  ///   - isAvailable: Initial availability (overwritten by the coordinator).
  ///   - readManifest: Reads `composer.json`; injectable for headless tests.
  public init(
    isAvailable: Bool = false,
    readManifest: @escaping ManifestReader = PHPIntegration.liveReadManifest
  ) {
    self.base = ToolIntegrationBase(
      id: "php",
      displayName: "PHP",
      requiredTool: "composer",
      markerNames: ["composer.json"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { directory, _ in
      PHPIntegration.buildActions(directory: directory, readManifest: readManifest)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Reads the `composer.json` from disk. The live default for tests to override.
  public static func liveReadManifest(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Builds the smart actions for a PHP/Composer directory: install
  /// (`composer install`), test (`composer test` — only when a top-level
  /// `scripts.test` entry exists), and one run per named Composer script
  /// (`composer run-script <name>`). The `test` script is not emitted again as a
  /// run action: `composer test` is the shorthand for `composer run-script test`,
  /// so a second "Run · test" button would be a duplicate. The run action's
  /// `target` is the script name so the toolbar can group each script; install
  /// and test are project-wide and carry no target. Every action keys off the
  /// Composer toolchain.
  static func buildActions(directory: URL, readManifest: ManifestReader) -> [IntegrationAction] {
    let manifestURL = directory.appendingPathComponent("composer.json")
    let scripts = scriptNames(from: readManifest(manifestURL) ?? "")

    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .build, title: "Install", target: nil, command: "composer install"))
    if scripts.contains("test") {
      actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: "composer test"))
    }
    for name in scripts where name != "test" {
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run · \(name)",
        target: name,
        command: "composer run-script \(name)"
      ))
    }
    return actions
  }

  /// Extracts the top-level `scripts` keys from a composer.json document, sorted.
  /// `JSONSerialization` is used rather than a typed `[String: String]` decode so
  /// a script whose value is an array of commands — which Composer allows — still
  /// yields its key instead of failing the whole parse.
  static func scriptNames(from source: String) -> [String] {
    guard let data = source.data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let scripts = json["scripts"] as? [String: Any]
    else { return [] }
    return scripts.keys.sorted()
  }
}
