import Foundation

/// Enumerates a directory's top-level entries once, cheaply, for the "Open
/// With" apps. Hidden entries (dotfiles / dot-directories such as `.git`,
/// `.build`, `.DS_Store`) are skipped: they are noise for project detection.
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
