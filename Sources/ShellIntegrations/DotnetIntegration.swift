import Foundation

/// Detects a .NET / C# project (`*.csproj` / `*.sln` / `*.slnx`) and exposes
/// build / test / run smart actions. Active only when `dotnet` is installed.
///
/// Thin: identity, availability and command building are delegated to the
/// reusable `ToolIntegrationBase` (this file supplies only the identity, the
/// project picker, and the command builder), per the framework's per-language
/// REUSE RULE. The two complications the base cannot express are handled
/// here in a few lines:
///   - the marker is a *glob* (`*.csproj` / `*.sln` / `*.slnx`), not the
///     exact-names the base's `markerNames` matches, so relevance does a cheap
///     O(entries) suffix check over the shared `[DirectoryEntry]`; and
///   - the run target is the picked project, derived purely from the entry
///     names, so no manifest needs reading (tests never need a project on
///     disk — the directory entries are passed straight to `scan`).
public final class DotnetIntegration: TerminalIntegration {
  private let base: ToolIntegrationBase

  public var id: String { base.id }
  public var displayName: String { base.displayName }
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  /// - Parameter isAvailable: Initial availability (overwritten by the
  ///   coordinator).
  public init(isAvailable: Bool = false) {
    self.base = ToolIntegrationBase(
      id: "dotnet",
      displayName: ".NET",
      requiredTool: "dotnet",
      markerNames: [],
      isDirectory: false,
      isAvailable: isAvailable
    ) { _, files in
      DotnetIntegration.buildActions(files: files)
    }
  }

  /// File suffixes that mark a directory as a .NET project. A directory may
  /// contain any one of them; each must be a non-directory entry.
  static let markerExtensions = [".csproj", ".sln", ".slnx"]

  /// Whether `files` contains a non-directory entry ending in a .NET marker
  /// suffix. O(entries) over the shared list — never re-enumerates the dir.
  public func relevance(files: [DirectoryEntry]) -> Bool {
    files.contains { entry in
      guard !entry.isDirectory else { return false }
      return Self.markerExtensions.contains { entry.name.hasSuffix($0) }
    }
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    guard relevance(files: files) else { return [] }
    return base.builder(directory, files)
  }

  /// Builds the smart actions for a .NET directory: build (`dotnet build`),
  /// test (`dotnet test`) and run (`dotnet run`). `dotnet` auto-discovers the
  /// solution/project in the working directory, so the commands stay plain and
  /// the picked project name is carried as the target for toolbar grouping.
  static func buildActions(files: [DirectoryEntry]) -> [IntegrationAction] {
    let projectName = projectName(from: files)
    return [
      IntegrationAction(kind: .build, title: "Build", target: projectName, command: "dotnet build"),
      IntegrationAction(kind: .test, title: "Test", target: projectName, command: "dotnet test"),
      IntegrationAction(kind: .run, title: "Run", target: projectName, command: "dotnet run"),
    ]
  }

  /// Picks the project to group actions under, from the matching entry names:
  /// prefer a solution file (`.sln`, then `.slnx`) by its base name; otherwise
  /// the single `.csproj`'s base name. nil when no solution exists and there
  /// is more than one project file (ambiguous → whole directory).
  static func projectName(from files: [DirectoryEntry]) -> String? {
    for ext in [".sln", ".slnx"] {
      if let entry = files.first(where: { !$0.isDirectory && $0.name.hasSuffix(ext) }) {
        return String(entry.name.dropLast(ext.count))
      }
    }
    let projects = files.filter { !$0.isDirectory && $0.name.hasSuffix(".csproj") }
    if projects.count == 1, let only = projects.first {
      return String(only.name.dropLast(".csproj".count))
    }
    return nil
  }
}
