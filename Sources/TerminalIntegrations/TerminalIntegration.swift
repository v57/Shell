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
  /// Toolchain binaries that gate availability. When non-empty, the coordinator
  /// sets `isAvailable` = true if ANY of these tools is on PATH (an OR rule).
  /// Defaults to `[requiredTool]` (a single-tool gate). An integration with an
  /// OR availability rule — e.g. JS/TS, bun-first with an npm fallback when bun
  /// is absent — overrides this to list every acceptable tool.
  var availabilityTools: [String] { get }
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
  /// Default: gate availability on the single `requiredTool`, if any.
  public var availabilityTools: [String] { requiredTool.map { [$0] } ?? [] }
}
