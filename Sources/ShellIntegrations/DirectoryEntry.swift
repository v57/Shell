import Foundation

/// A lightweight, Sendable description of one entry in the active directory,
/// for the "Open With" apps (`OpenWithResolver`).
public struct DirectoryEntry: Hashable, Sendable {
  public let name: String
  public let isDirectory: Bool

  public init(name: String, isDirectory: Bool) {
    self.name = name
    self.isDirectory = isDirectory
  }
}
