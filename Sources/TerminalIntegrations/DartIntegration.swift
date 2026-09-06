import Foundation

/// Detects a Dart project (`pubspec.yaml`) and exposes install / test / run
/// smart actions. Active only when `dart` is installed.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity, the pubspec
/// reader, and the command builder), per the framework's per-language REUSE
/// RULE. The pubspec reader is injectable so tests don't need a real project
/// on disk (mirrors `CargoIntegration`'s injectable manifest reader and
/// `XcodeIntegration`'s injectable build-list runner).
public final class DartIntegration: TerminalIntegration {
  /// Reads the `pubspec.yaml` manifest text for a directory; nil when unreadable.
  public typealias ManifestReader = (URL) -> String?

  private let base: ToolIntegrationBase

  public var id: String { base.id }
  public var displayName: String { base.displayName }
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  /// - Parameters:
  ///   - isAvailable: Initial availability (overwritten by the coordinator).
  ///   - readManifest: Reads `pubspec.yaml`; injectable for headless tests.
  public init(
    isAvailable: Bool = false,
    readManifest: @escaping ManifestReader = DartIntegration.liveReadManifest
  ) {
    self.base = ToolIntegrationBase(
      id: "dart",
      displayName: "Dart",
      requiredTool: "dart",
      markerNames: ["pubspec.yaml"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { directory, _ in
      DartIntegration.buildActions(directory: directory, readManifest: readManifest)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Reads the `pubspec.yaml` from disk. The live default for tests to override.
  public static func liveReadManifest(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Builds the smart actions for a Dart directory: install (`dart pub get`),
  /// test (`dart test`), and run (`dart run`). All three are emitted whenever
  /// the directory is relevant — `dart` reads `pubspec.yaml` itself, so the
  /// actions do not depend on us parsing the manifest. The run action carries
  /// the package name (from the top-level `name:` in `pubspec.yaml`) as its
  /// target where one can be parsed, so the toolbar can group it under the
  /// package; otherwise it is emitted target-less.
  static func buildActions(directory: URL, readManifest: ManifestReader) -> [IntegrationAction] {
    let manifestURL = directory.appendingPathComponent("pubspec.yaml")
    let packageName = parseName(from: readManifest(manifestURL) ?? "")

    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .build, title: "Build", target: nil, command: "dart pub get"))
    actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: "dart test"))
    actions.append(IntegrationAction(kind: .run, title: "Run", target: packageName, command: "dart run"))
    return actions
  }

  /// Extracts the top-level `name:` from a `pubspec.yaml` document. Only the
  /// unindented (column-0) `name` key is considered, so a nested `name:` under
  /// `dependencies:` / `dev_dependencies:` / `environment:` never becomes the
  /// package name. Surrounding quotes and a trailing comment are stripped.
  static func parseName(from source: String) -> String? {
    for line in source.split(separator: "\n") {
      guard let first = line.first else { continue }
      if first.isWhitespace { continue } // nested key, not the top-level name
      guard line.hasPrefix("name:") else { continue }

      var value = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
      if let hash = value.firstIndex(of: "#") {
        value = value[..<hash].trimmingCharacters(in: .whitespaces)
      }
      if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
        value = String(value.dropFirst().dropLast())
      } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
        value = String(value.dropFirst().dropLast())
      }
      if !value.isEmpty { return value }
    }
    return nil
  }
}
