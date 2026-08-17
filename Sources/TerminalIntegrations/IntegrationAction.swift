import Foundation

/// A single runnable smart action produced by an integration for a directory.
///
/// The `command` is a shell snippet executed via
/// `zsh -lc "cd <dir> && <command>"`. `target` groups actions under a
/// project target/scheme for the toolbar's target picker (nil = whole project).
public struct IntegrationAction: Hashable, Sendable, Codable, Identifiable {
  public let id: UUID
  public let kind: IntegrationActionKind
  /// Short title, e.g. "Build" or "Run · server".
  public let title: String
  /// The project target/scheme this action applies to; nil = whole project.
  public let target: String?
  /// Shell snippet executed in the directory.
  public let command: String

  public init(
    id: UUID = UUID(),
    kind: IntegrationActionKind,
    title: String,
    target: String?,
    command: String
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.target = target
    self.command = command
  }
}
