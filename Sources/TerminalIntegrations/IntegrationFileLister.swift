import Foundation

/// Enumerates a directory's top-level entries ONCE, cheaply.
///
/// The coordinator calls this a single time per directory and passes the
/// resulting `[DirectoryEntry]` to every integration, so integrations never
/// re-scan the filesystem. Hidden entries (dotfiles / dot-directories such as
/// `.git`, `.build`, `.DS_Store`) are skipped: they are noise for project
/// detection and skipping them keeps the cache fingerprint stable.
public enum IntegrationFileLister {
  public static func list(directory: URL) -> [DirectoryEntry] {
    let keys: [URLResourceKey] = [.isDirectoryKey]
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: keys,
      options: []
    )) ?? []
    return urls.compactMap { url -> DirectoryEntry? in
      let name = url.lastPathComponent
      guard !name.hasPrefix(".") else { return nil }
      let isDirectory = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
      return DirectoryEntry(name: name, isDirectory: isDirectory)
    }
  }
}
