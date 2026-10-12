import Foundation

/// Detects an Elixir project (`mix.exs`) and exposes install / test / run
/// smart actions. Active only when `mix` (the Elixir build tool) is on PATH.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity and the command
/// builder), per the framework's per-language REUSE RULE — no duplicated
/// marker/scan boilerplate. No manifest parser is needed: `mix` reads
/// `mix.exs` itself, so every action below is emitted target-less whenever the
/// directory is relevant (mirrors `DartIntegration`, which likewise leans on
/// its tool to read the manifest).
public final class ElixirIntegration: TerminalIntegration {
  private let base: ToolIntegrationBase

  public var id: String { base.id }
  public var displayName: String { base.displayName }
  /// `mix` is the binary every command below shells through, so availability
  /// gates on it; the live PATH probe resolves `mix`.
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  /// - Parameter isAvailable: Initial availability (overwritten by the coordinator).
  public init(isAvailable: Bool = false) {
    self.base = ToolIntegrationBase(
      id: "elixir",
      displayName: "Elixir",
      requiredTool: "mix",
      markerNames: ["mix.exs"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { directory, _ in
      ElixirIntegration.buildActions(directory: directory)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Builds the smart actions for an Elixir directory: install
  /// (`mix deps.get`), test (`mix test`), and run (`mix run`). All three are
  /// emitted target-less whenever the directory is relevant — `mix` reads
  /// `mix.exs` itself, so there is no project name to resolve into a target.
  static func buildActions(directory: URL) -> [IntegrationAction] {
    [
      IntegrationAction(kind: .build, title: "Install", target: nil, command: "mix deps.get"),
      IntegrationAction(kind: .test, title: "Test", target: nil, command: "mix test"),
      IntegrationAction(kind: .run, title: "Run", target: nil, command: "mix run"),
    ]
  }
}
