import Foundation

/// A per-directory project integration (Xcode, SwiftPM, future languages).
///
/// Conforming integrations must do as little scanning work as possible: they
/// receive a SHARED `[DirectoryEntry]` (enumerated once by the coordinator) and
/// should only read the one or two files they actually need (e.g.
/// `Package.swift`, `*.xcodeproj`) — never re-enumerate the directory.
public protocol TerminalIntegration: AnyObject {
  /// Stable identifier, e.g. "xcode", "swift".
  var id: String { get }
  /// Human-readable name, e.g. "Xcode", "Swift Package".
  var displayName: String { get }
  /// Toolchain binary that must be present on PATH for this integration to be
  /// available (e.g. "xcodebuild", "swift"). The coordinator reads it during
  /// `probeEnvironment()` to gate `isAvailable`. Default `nil` = not gated on a
  /// tool (always available when the app chooses to run it).
  var requiredTool: String? { get }
  /// Set once at startup from `EnvironmentProbe`; when false the integration
  /// is skipped entirely (no `relevance`/`scan` calls).
  var isAvailable: Bool { get set }

  /// Cheap gate (O(entries)) over the shared file list: whether this directory
  /// looks like something this integration handles (e.g. contains
  /// `Package.swift` or a `*.xcodeproj`). Returning false skips `scan`.
  func relevance(files: [DirectoryEntry]) -> Bool

  /// Produce the smart actions for a directory. Called only when `isAvailable`
  /// and `relevance(...)` are both true.
  func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction]
}

extension TerminalIntegration {
  /// Default: an integration is not gated on a specific toolchain binary.
  public var requiredTool: String? { nil }
}
