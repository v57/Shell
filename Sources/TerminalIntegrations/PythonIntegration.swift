import Foundation

/// Detects a Python project (`pyproject.toml` or `requirements.txt`) and
/// exposes test / run / lint smart actions. Active only when `python3` is
/// installed. The package driver (uv → poetry → plain pip3) is resolved once
/// at scan time and shapes the emitted commands.
///
/// This is a THIN declaration: all marker/relevance and scan plumbing is
/// delegated to the reusable `ToolIntegrationBase` (the per-language REUSE
/// RULE — no duplicated boilerplate). The driver resolver and the manifest
/// reader are injectable so tests don't need a real project or toolchain on
/// disk (mirrors `CargoIntegration`'s injectable manifest reader and
/// `XcodeIntegration`'s injectable build-list runner).
public final class PythonIntegration: TerminalIntegration {
  /// Resolves the package driver: "uv", "poetry", or "pip3". Injectable.
  public typealias DriverResolver = () -> String?
  /// Reads the `pyproject.toml` manifest text for a directory; nil when absent.
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
  ///   - resolveDriver: Detects uv / poetry / pip3; injectable for headless tests.
  ///   - readManifest: Reads `pyproject.toml`; injectable for headless tests.
  public init(
    isAvailable: Bool = false,
    resolveDriver: @escaping DriverResolver = PythonIntegration.liveDriverResolver,
    readManifest: @escaping ManifestReader = PythonIntegration.liveReadManifest
  ) {
    self.base = ToolIntegrationBase(
      id: "python",
      displayName: "Python",
      requiredTool: "python3",
      markerNames: ["pyproject.toml", "requirements.txt"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { directory, _ in
      PythonIntegration.buildActions(directory: directory, resolveDriver: resolveDriver, readManifest: readManifest)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Live detection: uv → poetry → plain pip3. `pip3` is the unconditional
  /// fallback; the coordinator already gates availability on `python3` (the
  /// base interpreter every pip3 invocation needs), so a plain driver is
  /// always a valid scan-time result.
  public static func liveDriverResolver() -> String? {
    let probe = EnvironmentProbe.probe()
    if probe.toolAvailable("uv") { return "uv" }
    if probe.toolAvailable("poetry") { return "poetry" }
    return "pip3"
  }

  public static func liveReadManifest(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Builds the test / run / lint actions for a Python directory:
  /// test and lint per the resolved driver, then one run action per
  /// console script (`[project.scripts]` / `[tool.poetry.scripts]`), falling
  /// back to the project/package name as a single run target when no console
  /// scripts are declared, and finally to a bare target-less run when no name
  /// can be derived (e.g. a requirements.txt-only project).
  static func buildActions(
    directory: URL,
    resolveDriver: DriverResolver,
    readManifest: ManifestReader
  ) -> [IntegrationAction] {
    guard let driver = resolveDriver() else { return [] }

    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: testCommand(driver: driver)))
    actions.append(IntegrationAction(kind: .lint, title: "Lint", target: nil, command: lintCommand(driver: driver)))

    let manifestURL = directory.appendingPathComponent("pyproject.toml")
    let parsed = parseManifest(readManifest(manifestURL) ?? "")

    let targets = parsed.scriptNames.isEmpty ? (parsed.projectName.map { [$0] } ?? []) : parsed.scriptNames
    if targets.isEmpty {
      actions.append(IntegrationAction(kind: .run, title: "Run", target: nil, command: runCommand(driver: driver, entry: nil)))
    } else {
      for name in targets {
        actions.append(IntegrationAction(
          kind: .run,
          title: "Run · \(name)",
          target: name,
          command: runCommand(driver: driver, entry: name)
        ))
      }
    }
    return actions
  }

  static func testCommand(driver: String) -> String {
    switch driver {
    case "uv": return "uv run pytest"
    case "poetry": return "poetry run pytest"
    default: return "pytest"
    }
  }

  static func lintCommand(driver: String) -> String {
    driver == "uv" ? "uv run ruff check" : "ruff check"
  }

  static func runCommand(driver: String, entry: String?) -> String {
    switch driver {
    case "uv":
      return entry.map { "uv run \($0)" } ?? "uv run"
    case "poetry":
      return entry.map { "poetry run \($0)" } ?? "poetry run"
    default: // pip3
      return entry.map { "python3 \($0)" } ?? "python3"
    }
  }

  /// Extracts the project/package name and the console-script names from a
  /// `pyproject.toml` document. Only `name` keys inside `[project]` /
  /// `[tool.poetry]` become the project name, and only keys under
  /// `[project.scripts]` / `[tool.poetry.scripts]` become run targets — so
  /// dependency/entry-point metadata never leaks into the run list.
  static func parseManifest(_ source: String) -> (projectName: String?, scriptNames: [String]) {
    var projectName: String?
    var scriptNames: [String] = []
    var currentSection: String?

    for line in source.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        currentSection = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        continue
      }
      guard let section = currentSection, let eq = trimmed.firstIndex(of: "=") else { continue }
      let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)

      switch section {
      case "project", "tool.poetry":
        if key == "name", projectName == nil {
          projectName = quotedValue(after: eq, in: trimmed)
        }
      case "project.scripts", "tool.poetry.scripts":
        if !key.isEmpty && !scriptNames.contains(key) {
          scriptNames.append(key)
        }
      default:
        break
      }
    }
    return (projectName, scriptNames)
  }

  private static func quotedValue(after eq: String.Index, in line: String) -> String? {
    let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return nil }
    return String(raw.dropFirst().dropLast())
  }
}
