import Foundation

/// Detects a JS/TS project (`package.json`) and exposes install / run / test
/// smart actions. bun-first with an npm fallback (user directive, 2026-09-06):
/// when `bun` is on PATH the integration drives bun; otherwise (npm/node
/// present) it drives npm. The chosen driver is surfaced in each action's
/// title and command.
///
/// Availability is `bun || npm || node` present. The framework's per-tool
/// `requiredTool` gate accepts only a single tool, which cannot express that
/// OR condition, so `requiredTool` is set to the PRIMARY driver "bun" (the
/// manager gates availability on it at startup — the bun-first path). The
/// npm fallback is fully implemented and tested in `scan` (reachable on
/// bun-less machines when `isAvailable` is enabled); `resolveTool` /
/// `readManifest` are injectable so tests don't need a real project or
/// toolchain on disk.
public final class JSIntegration: TerminalIntegration {
  public let id = "js"
  public let displayName = "JS/TS"
  public let requiredTool: String? = "bun"

  public var isAvailable: Bool

  /// Which driver is present: "bun", "npm", or nil (neither). Injectable.
  public typealias ToolResolver = () -> String?
  /// Reads the `package.json` manifest for a directory. Injectable.
  public typealias ManifestReader = (URL) -> String?

  private let resolveTool: ToolResolver
  private let readManifest: ManifestReader

  public init(
    isAvailable: Bool = false,
    resolveTool: @escaping ToolResolver = JSIntegration.liveToolResolver,
    readManifest: @escaping ManifestReader = JSIntegration.liveManifestReader
  ) {
    self.isAvailable = isAvailable
    self.resolveTool = resolveTool
    self.readManifest = readManifest
  }

  /// Marker: a directory is relevant when it contains a non-directory
  /// `package.json`. Cheap O(entries) check over the shared `[DirectoryEntry]`.
  public func relevance(files: [DirectoryEntry]) -> Bool {
    files.contains { $0.name == Self.markerName && !$0.isDirectory }
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    guard relevance(files: files) else { return [] }
    // No bun/npm/node present -> no JS toolchain; emit nothing.
    guard let driver = resolveTool() else { return [] }

    let manifestURL = directory.appendingPathComponent(Self.markerName)
    let manifest = readManifest(manifestURL) ?? ""
    let scripts = Self.scripts(from: manifest)

    var actions: [IntegrationAction] = []
    let usesBun = driver == "bun"
    actions.append(IntegrationAction(
      kind: .build,
      title: usesBun ? "Install · bun" : "Install · npm",
      target: nil,
      command: usesBun ? "bun install" : "npm ci"
    ))
    actions.append(IntegrationAction(
      kind: .test,
      title: usesBun ? "Test · bun" : "Test · npm",
      target: nil,
      command: usesBun ? "bun test" : "npm test"
    ))
    let runPrefix = usesBun ? "bun run" : "npm run"
    for name in scripts {
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run · \(name)",
        target: name,
        command: "\(runPrefix) \(name)"
      ))
    }
    return actions
  }

  private static let markerName = "package.json"

  /// Extracts top-level `scripts` keys from a package.json manifest, sorted.
  static func scripts(from manifest: String) -> [String] {
    struct Package: Decodable { let scripts: [String: String]? }
    guard let data = manifest.data(using: .utf8),
          let pkg = try? JSONDecoder().decode(Package.self, from: data)
    else { return [] }
    return (pkg.scripts?.keys.sorted()) ?? []
  }

  /// Live detection: prefers bun, then falls back to npm (node ships npm).
  public static func liveToolResolver() -> String? {
    let probe = EnvironmentProbe.probe()
    if probe.toolAvailable("bun") { return "bun" }
    if probe.toolAvailable("npm") || probe.toolAvailable("node") { return "npm" }
    return nil
  }

  public static func liveManifestReader(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }
}
