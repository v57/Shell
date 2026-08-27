import Foundation

/// Platform used to choose the default "open" command for a file.
public enum RemotePlatform: Sendable {
  case macOS
  case linux
}

/// Builds shell command strings for common file operations.
///
/// Paths and directory arguments are always passed through `shellQuote(_:)` so
/// that spaces and apostrophes are safe when the command is later executed by a
/// `FileCommandExecutor`.
public enum FileCommandBuilder {
  /// Mode for `moveCopy(source:destination:mode:)`.
  public enum MoveCopyMode {
    /// Copy the source to the destination, leaving the source in place.
    case copy
    /// Copy the source to the destination, then remove the source.
    case move
  }

  /// Wraps `value` in single quotes and escapes any embedded apostrophe as
  /// `'\\''`, so the value is safe to embed in a shell command.
  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Lists the contents of `directory` in long format.
  public static func list(directory: String) -> String {
    "cd \(shellQuote(directory)) && ls -la"
  }

  /// Opens a directory in the shell (`cd`) or a file with the platform's
  /// default opener.
  public static func open(path: String, isDirectory: Bool, remotePlatform: RemotePlatform) -> String {
    if isDirectory {
      return "cd \(shellQuote(path))"
    }
    switch remotePlatform {
    case .macOS:
      return "open \(shellQuote(path))"
    case .linux:
      return "xdg-open \(shellQuote(path))"
    }
  }

  /// Deletes a file (`rm`) or a directory (`rm -rf`).
  public static func delete(path: String, isDirectory: Bool) -> String {
    if isDirectory {
      return "rm -rf \(shellQuote(path))"
    }
    return "rm \(shellQuote(path))"
  }

  /// Copies or moves `source` to `destination`.
  ///
  /// Copy emits `rsync -a '<src>' '<dest>'`; move appends `&& rm -rf '<src>'`
  /// after the copy so the source is removed once the copy succeeds.
  public static func moveCopy(source: String, destination: String, mode: MoveCopyMode) -> String {
    let base = "rsync -a \(shellQuote(source)) \(shellQuote(destination))"
    switch mode {
    case .copy:
      return base
    case .move:
      return base + " && rm -rf \(shellQuote(source))"
    }
  }
}
