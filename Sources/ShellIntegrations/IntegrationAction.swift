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
  /// Setup the app checks before running the action; nil = none.
  public let requirement: IntegrationActionRequirement?

  public init(
    id: UUID = UUID(),
    kind: IntegrationActionKind,
    title: String,
    target: String?,
    command: String,
    requirement: IntegrationActionRequirement? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.target = target
    self.command = command
    self.requirement = requirement
  }
}

/// Setup an action needs before it can run, checked by the app.
public enum IntegrationActionRequirement: String, Hashable, Sendable, Codable {
  /// A Developer ID Application identity and a notarytool keychain profile;
  /// the app passes the chosen profile as `NOTARY_PROFILE` (see `Notarization`).
  case notarization
}
