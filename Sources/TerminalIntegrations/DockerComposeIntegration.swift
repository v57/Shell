import Foundation

/// Detects a Docker Compose project (`compose.yml` / `compose.yaml` /
/// `docker-compose.yml`) and exposes build / up / down / logs smart actions.
/// Active only when `docker` is installed.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity, the tool gate,
/// and the command builder), per the framework's per-language REUSE RULE.
/// Docker Compose exports no per-service manifest we parse here, so the
/// actions are emitted unconditionally and carry no project target.
public final class DockerComposeIntegration: TerminalIntegration {
  public var id: String { base.id }
  public var displayName: String { base.displayName }
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  private let base: ToolIntegrationBase

  public init(isAvailable: Bool = false) {
    base = ToolIntegrationBase(
      id: "docker",
      displayName: "Docker Compose",
      requiredTool: "docker",
      markerNames: ["compose.yml", "compose.yaml", "docker-compose.yml"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { _, _ in
      DockerComposeIntegration.buildActions()
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Builds the smart actions for a Docker Compose directory: build, up, down,
  /// and follow logs. There is no lifecycle action kind, so the lifecycle
  /// commands map onto the existing `.build` / `.run` kinds. No compose
  /// service is parsed, so no action carries a target name.
  static func buildActions() -> [IntegrationAction] {
    [
      IntegrationAction(kind: .build, title: "Build", target: nil, command: "docker compose build"),
      IntegrationAction(kind: .run, title: "Up", target: nil, command: "docker compose up -d"),
      IntegrationAction(kind: .run, title: "Down", target: nil, command: "docker compose down"),
      IntegrationAction(kind: .run, title: "Logs", target: nil, command: "docker compose logs -f"),
    ]
  }
}
