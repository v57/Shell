import Foundation

/// Detects a Cargo (Rust) project (`Cargo.toml`) and exposes build / run /
/// test / lint smart actions. Active only when `cargo` is installed.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity, the manifest
/// reader, and the command builder), per the framework's per-language REUSE
/// RULE. The manifest reader is injectable so tests don't need a real project
/// on disk (mirrors `XcodeIntegration`'s injectable `buildList` runner).
public final class CargoIntegration: TerminalIntegration {
  /// Reads the `Cargo.toml` manifest text for a directory; nil when unreadable.
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
  ///   - readManifest: Reads `Cargo.toml`; injectable for headless tests.
  public init(
    isAvailable: Bool = false,
    readManifest: @escaping ManifestReader = CargoIntegration.liveReadManifest
  ) {
    self.base = ToolIntegrationBase(
      id: "cargo",
      displayName: "Rust",
      requiredTool: "cargo",
      markerNames: ["Cargo.toml"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { directory, _ in
      CargoIntegration.buildActions(directory: directory, readManifest: readManifest)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Reads the `Cargo.toml` from disk. The live default for tests to override.
  public static func liveReadManifest(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Builds the smart actions for a Cargo directory:
  /// build (`cargo build`), test (`cargo test`), lint (`cargo clippy`), and
  /// run per `[[bin]]` target (`cargo run --bin <name>`), falling back to a
  /// single `cargo run` (tagged with the `[package]` name) when no `[[bin]]`
  /// targets are declared.
  static func buildActions(directory: URL, readManifest: ManifestReader) -> [IntegrationAction] {
    let manifestURL = directory.appendingPathComponent("Cargo.toml")
    guard let source = readManifest(manifestURL) else { return [] }
    let parsed = parseManifest(source)

    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .build, title: "Build", target: nil, command: "cargo build"))
    actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: "cargo test"))
    actions.append(IntegrationAction(kind: .lint, title: "Lint", target: nil, command: "cargo clippy"))

    if parsed.binNames.isEmpty {
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run",
        target: parsed.packageName,
        command: "cargo run"
      ))
    } else {
      for name in parsed.binNames {
        actions.append(IntegrationAction(
          kind: .run,
          title: "Run · \(name)",
          target: name,
          command: "cargo run --bin \(name)"
        ))
      }
    }
    return actions
  }

  /// Extracts the `[package]` name and each `[[bin]]` name from Cargo.toml text.
  /// Only `name` keys inside `[package]` / `[[bin]]` sections are collected, so
  /// `[[example]]` / `[[test]]` / `[[bench]]` names never become run targets.
  static func parseManifest(_ source: String) -> (packageName: String?, binNames: [String]) {
    var packageName: String?
    var binNames: [String] = []
    var currentSection: String?

    for line in source.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      // "[section]" strips one bracket each side; "[[array-of-tables]]"
      // strips two (a single strip would leave "[bin]" and mis-key the section).
      if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
        currentSection = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        continue
      }
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        currentSection = trimmed.dropFirst(1).dropLast(1).trimmingCharacters(in: .whitespaces)
        continue
      }
      guard let eq = trimmed.firstIndex(of: "="),
            trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "name" else { continue }
      let rawValue = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      guard rawValue.count >= 2,
            rawValue.hasPrefix("\""),
            rawValue.hasSuffix("\"") else { continue }
      let value = String(rawValue.dropFirst().dropLast())
      switch currentSection {
      case "package":
        if packageName == nil { packageName = value }
      case "bin":
        if !binNames.contains(value) { binNames.append(value) }
      default:
        break
      }
    }
    return (packageName, binNames)
  }
}
