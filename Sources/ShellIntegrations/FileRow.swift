import Foundation

/// A lightweight, Sendable description of one entry parsed from raw `ls -la` output.
///
/// Produced purely by text parsing (`LSOutputParser`) with no filesystem access.
/// It carries the fields a directory viewer can render, and enough provenance
/// (permissions, modification date, symlink target) for that viewer to decide
/// how to present each row.
public struct FileRow: Sendable, Hashable, Identifiable {
  /// The file or directory name as it appears in the listing.
  public let name: String
  /// Whether the entry is a directory.
  public let isDirectory: Bool
  /// The entry size in bytes, when the listing reported one.
  public let size: Int64?
  /// When the entry was last modified, when the date could be parsed.
  public let modified: Date?
  /// The raw permission string (e.g. `drwxr-xr-x`), when present.
  public let permissions: String?
  /// The symlink target, when the entry is a symlink.
  public let symlinkTarget: String?

  /// Names are unique within a single directory listing, so the name is the identity.
  public var id: String { name }

  public init(
    name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil,
    permissions: String? = nil, symlinkTarget: String? = nil
  ) {
    self.name = name
    self.isDirectory = isDirectory
    self.size = size
    self.modified = modified
    self.permissions = permissions
    self.symlinkTarget = symlinkTarget
  }
}
