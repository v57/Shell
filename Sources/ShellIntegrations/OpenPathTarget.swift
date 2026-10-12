import Foundation

/// How a path opened into Shell should be handled.
///
/// A single pure classification, distinct from the `OpenWithResolver` toolbar
/// control (which launches a project/directory in an external editor). This
/// decides what Shell itself does with the path: open a terminal session in a
/// folder, show a text file's content, or drop it.
public enum OpenPathTarget: Sendable, Equatable {
  /// A directory — open a new local terminal session running in it.
  case terminal(folder: URL)
  /// A recognized text file — show its content in an editor pane.
  case textFile(url: URL)
  /// Anything else (unknown/none extension, non-regular file) — drop silently.
  case ignored
}

/// Pure, testable classification of a path opened into Shell.
///
/// Free of AppKit/Process and nonisolated (Swift 5 language mode), so the
/// logic can be unit-tested on its own. Directory detection reads `URL`
/// resource values from the filesystem; text-file detection is a
/// case-insensitive extension match.
public enum OpenPathResolver {
  /// Extensions whose content Shell shows in the editor pane (case-insensitive).
  public static let textFileExtensions: Set<String> = ["txt", "conf", "md", "yml", "yaml"]

  /// Classifies `url` into an `OpenPathTarget`.
  ///
  /// - First, if the path is a directory, it opens a terminal session in it.
  /// - Then, if the path has a recognized text extension (case-insensitive)
  ///   and is a regular file, its content is shown.
  /// - Otherwise the path is ignored (unknown/absent extension, non-regular
  ///   file, or a non-existent path).
  public static func target(for url: URL) -> OpenPathTarget {
    // Directories take precedence, even if the name carries a text extension.
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
      return .terminal(folder: url)
    }

    let ext = url.pathExtension.lowercased()
    if textFileExtensions.contains(ext) {
      // Only regular files are eligible; sockets/devices/pipes and missing
      // paths fall through to `.ignored`.
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        return .textFile(url: url)
      }
    }

    return .ignored
  }
}
