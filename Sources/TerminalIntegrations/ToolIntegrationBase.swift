import Foundation

/// A reusable, language-agnostic base for terminal project integrations.
///
/// A per-language integration needs to declare only its identity, the tool it
/// requires on PATH, the marker file(s) that make a directory "relevant", and
/// a command-builder closure that turns a directory + its shared entries into
/// smart actions. All the marker/scan plumbing lives here so per-language
/// cards stay thin and never duplicate the marker/scan boilerplate.
///
/// REUSE RULE: per-language cards must use this base (or its helpers), never
/// re-implement marker or scan logic.
public final class ToolIntegrationBase: TerminalIntegration {
  public let id: String
  public let displayName: String
  /// Toolchain binary the coordinator gates availability on via PATH.
  public var requiredTool: String?
  /// Set once at startup from `EnvironmentProbe`; false skips the integration.
  public var isAvailable: Bool

  /// Marker criteria: a directory is "relevant" when it contains an entry
  /// whose name is in `markerNames` AND whose directory-ness matches
  /// `markerIsDirectory`.
  public let markerNames: [String]
  public let markerIsDirectory: Bool

  /// Builds the smart actions for a directory. Called only when `isAvailable`
  /// and `relevance(...)` are both true.
  public let builder: (URL, [DirectoryEntry]) -> [IntegrationAction]

  /// - Parameters:
  ///   - id: Stable identifier, e.g. "rust", "node".
  ///   - displayName: Human-readable name, e.g. "Rust", "Node".
  ///   - requiredTool: Tool name gated on PATH availability; nil = no gate.
  ///   - markerNames: Marker file/directory names that identify a project.
  ///   - isDirectory: Whether each marker must be a directory (`true`) or not.
  ///   - isAvailable: Initial availability (overwritten by the coordinator).
  ///   - builder: Builds the actions for a relevant directory.
  public init(
    id: String,
    displayName: String,
    requiredTool: String? = nil,
    markerNames: [String],
    isDirectory: Bool = false,
    isAvailable: Bool = true,
    builder: @escaping (URL, [DirectoryEntry]) -> [IntegrationAction]
  ) {
    self.id = id
    self.displayName = displayName
    self.requiredTool = requiredTool
    self.markerNames = markerNames
    self.markerIsDirectory = isDirectory
    self.isAvailable = isAvailable
    self.builder = builder
  }

  /// Whether `files` contains an entry matching one of `markerNames` with the
  /// expected directory-ness.
  public func relevance(files: [DirectoryEntry]) -> Bool {
    files.contains { entry in
      guard markerNames.contains(entry.name) else { return false }
      return entry.isDirectory == markerIsDirectory
    }
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    guard relevance(files: files) else { return [] }
    return builder(directory, files)
  }
}
