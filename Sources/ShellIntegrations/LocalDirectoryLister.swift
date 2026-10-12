import Foundation

/// A pure listing service that enumerates a LOCAL directory on this machine
/// with `FileManager` and turns each entry into `[FileRow]` values.
///
/// This is the fast path for local sessions: unlike `DirectoryLister` — which
/// runs `ls -la` through a `FileCommandExecutor` and therefore spawns a whole
/// `/bin/zsh -lic` process per listing (the dominant cost of opening a directory
/// in the Files panel) — this enumerates directly with the filesystem API. It
/// never spawns a process and performs no shell quoting.
///
/// It is used only for sessions whose path is on this host (see
/// `DirectoryContext.isLocal`); remote (SSH) sessions keep the shell-based
/// `DirectoryLister` path, whose public contract is unchanged.
public enum LocalDirectoryLister {
  /// The resource attributes pulled from the filesystem for each entry. These
  /// are exactly the fields a `FileRow` renders: whether it is a directory, a
  /// symlink, its size, and its modification date.
  private static let resourceKeys: [URLResourceKey] = [
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .fileSizeKey,
    .contentModificationDateKey,
  ]

  /// Enumerates `directory` on the local filesystem and returns one `FileRow`
  /// per entry, in a stable, Finder-like order (ascending by name).
  ///
  /// Hidden entries (dotfiles) are included, matching the `ls -la` behavior the
  /// shell path used. The `.` and `..` pseudo-entries never appear here because
  /// `contentsOfDirectory` returns only the directory's actual children.
  ///
  /// - Parameter directory: The absolute directory to list.
  /// - Throws: Whatever `FileManager` throws if the directory cannot be read
  ///   (e.g. a missing path or a permission error), which `DirectoryBrowserModel`
  ///   surfaces as its listing error — the same error behavior as the shell path.
  /// - Returns: The parsed file rows, ordered by name.
  public static func list(directory: String) throws -> [FileRow] {
    let url = URL(fileURLWithPath: directory)
    let children = try FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: resourceKeys, options: [])
    return try children
      .map { entry in try fileRow(for: entry) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Builds a `FileRow` from one directory entry.
  ///
  /// A symlink is reported as such (`isDirectory == false`, `isSymbolicLink
  /// == true`, `symlinkTarget` set to the link's stored target) rather than
  /// following the link, mirroring how `ls -la` renders a symlink (type `l`,
  /// not the target's type). The stored target string is read verbatim so a
  /// relative link (e.g. `../src`) is displayed exactly as `ls` would.
  private static func fileRow(for entry: URL) throws -> FileRow {
    let values = try entry.resourceValues(forKeys: Set(resourceKeys))
    let isLink = values.isSymbolicLink ?? false
    let isDirectory = isLink ? false : (values.isDirectory ?? false)
    return FileRow(
      name: entry.lastPathComponent,
      isDirectory: isDirectory,
      size: values.fileSize.map(Int64.init),
      modified: values.contentModificationDate,
      // The raw `ls -la` mode string (e.g. `-rw-r--r--`) is a shell-string
      // artifact the local fast path does not produce; `FileRow.permissions`
      // is not rendered by the viewer, and `isDirectory`/`symlinkTarget`
      // already capture the file-type behavior that matters here.
      permissions: nil,
      symlinkTarget: isLink ? (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) : nil)
  }
}
