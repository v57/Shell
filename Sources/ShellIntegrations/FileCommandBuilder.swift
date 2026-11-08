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
  ///
  /// Public because the SSH runner builds its `cd '<dir>' && <command>`
  /// prefix from the same quote rule used by the static command builders.
  public static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// `path` as one word typed into a terminal: as-is when it has nothing the shell would read, else in single quotes;
  /// nil when it holds a control character (C0, DEL or C1). Quotes stop the shell, but the line editor reads those
  /// bytes as keys first: a dropped folder named `x<ESC>[201~<^U>touch PWNED<CR>` ends a bracketed paste, clears the
  /// line and runs the command (security audit H5).
  public static func terminalWord(_ path: String) -> String? {
    guard !path.unicodeScalars.contains(where: isControl) else { return nil }
    let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%")
    if !path.isEmpty, path.unicodeScalars.allSatisfy(plain.contains) { return path }
    return shellQuote(path)
  }

  /// A C0 or C1 control character, or DEL.
  static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
  }

  /// Lists the contents of `directory` in long format, without colours and with English month names.
  ///
  /// The listing runs on a pty, where BusyBox's ls (Alpine, routers, NAS) colours names by default and macOS's does
  /// with `CLICOLOR` set (S-003). `env` runs the real `ls` (no alias or function, in any login shell, fish too) with
  /// `LS_COLORS=none`, which turns BusyBox's colours off, and without `CLICOLOR`/`CLICOLOR_FORCE`; `--color=never`
  /// isn't in every ls. `LC_TIME=C` keeps the dates in the format the parser reads; names stay in the user's locale.
  public static func list(directory: String) -> String {
    "cd \(shellQuote(directory)) && \(listCommand)"
  }

  /// The `ls` part of `list(directory:)`.
  public static let listCommand = "env -u CLICOLOR -u CLICOLOR_FORCE LS_COLORS=none LC_TIME=C ls -la"

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
