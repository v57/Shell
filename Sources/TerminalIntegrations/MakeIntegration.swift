import Foundation

/// Detects a GNU Make project (`Makefile`) and exposes build / test / run
/// smart actions. Active only when `make` is installed. This is a THIN
/// declaration: all marker/scan plumbing is delegated to
/// `ToolIntegrationBase` (the per-language REUSE RULE — no duplicated
/// boilerplate). Make exports no machine-readable manifest, so the commands
/// are emitted unconditionally (the default target plus the conventional
/// build / test / run targets).
public final class MakeIntegration: TerminalIntegration {
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
      id: "make",
      displayName: "Make",
      requiredTool: "make",
      markerNames: ["Makefile"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { _, _ in
      [
        IntegrationAction(kind: .build, title: "Build", target: nil, command: "make"),
        IntegrationAction(kind: .test, title: "Test", target: nil, command: "make test"),
        IntegrationAction(kind: .build, title: "Build", target: nil, command: "make build"),
        IntegrationAction(kind: .run, title: "Run", target: nil, command: "make run"),
      ]
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }
}
