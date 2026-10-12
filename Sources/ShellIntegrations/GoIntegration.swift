import Foundation

/// Detects a Go module (`go.mod`) and exposes build / run / test / vet
/// smart actions. Active only when `go` is installed. This is a THIN
/// declaration: all marker/scan plumbing is delegated to
/// `ToolIntegrationBase` (the per-language REUSE RULE — no duplicated
/// boilerplate).
public final class GoIntegration: TerminalIntegration {
  public var id: String { base.id }
  public var displayName: String { base.displayName }
  public var requiredTool: String? { base.requiredTool }
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  private let base: ToolIntegrationBase

  public init(isAvailable: Bool) {
    base = ToolIntegrationBase(
      id: "go",
      displayName: "Go",
      requiredTool: "go",
      markerNames: ["go.mod"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { _, _ in
      [
        IntegrationAction(kind: .build, title: "Build", target: nil, command: "go build ./..."),
        IntegrationAction(kind: .run, title: "Run", target: nil, command: "go run ./..."),
        IntegrationAction(kind: .test, title: "Test", target: nil, command: "go test ./..."),
        IntegrationAction(kind: .lint, title: "Lint", target: nil, command: "go vet ./..."),
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
