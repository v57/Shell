import Foundation

/// A lightweight, Sendable description of one entry in the active directory.
///
/// The active directory is enumerated ONCE into a shared `[DirectoryEntry]`
/// that is handed to every integration (see `SmartActionsCoordinator`).
/// Integrations must not re-enumerate the directory — they only read the one
/// or two files they actually need (e.g. `Package.swift`, `*.xcodeproj`).
public struct DirectoryEntry: Hashable, Sendable {
  public let name: String
  public let isDirectory: Bool

  public init(name: String, isDirectory: Bool) {
    self.name = name
    self.isDirectory = isDirectory
  }
}
