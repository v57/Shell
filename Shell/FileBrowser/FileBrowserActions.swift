import Foundation
import TerminalIntegrations

/// Runs folder/file operations (open, delete, move/copy) for a
/// `DirectoryBrowserModel` through the model's shared command runner, so they
/// behave identically over local and SSH sessions.
///
/// This is a small, stateless helper: it holds no long-lived mutable state and
/// is a value type. It is `@MainActor` (it reads the model's `context` and
/// mutates the busy/error state the view observes) but the actual shell command
/// is executed off the main thread via a detached task, because the
/// `FileCommandExecutor` is `Sendable`.
///
/// The three operations:
/// - `open(_:isDirectory:in:)` — a directory navigates the browser into it; a
///   file is opened with the host's default opener, chosen by checking the exit
///   code of `open` and falling back to `xdg-open` for a Linux host.
/// - `delete(path:isDirectory:confirmed:)` — destructive; refuses to run unless
///   the caller has already shown a confirmation dialog (`confirmed == true`).
/// - `moveCopy(source:destination:mode:isDirectory:)` — `rsync` (move appends an
///   `&& rm -rf <source>`), with a canonical-path check that blocks moving or
///   copying a directory into itself.
///
/// For every operation the model's busy flag is set around the work, the command
/// runs off the main thread, the listing refreshes on success, and a non-zero
/// exit code plus captured stderr lands in the model's `lastError`.
@MainActor struct FileBrowserActions {
  /// The model whose listing / busy / error state this helper drives.
  let model: DirectoryBrowserModel

  // MARK: - Open

  /// Opens `name` in `ctx`. Directories navigate the browser into them (a path
  /// change + re-list); every other entry is opened with the host's default
  /// opener. The opener is resolved against the host's capability: `open` on
  /// macOS, `xdg-open` on Linux, with a clear error if neither is available.
  func open(_ name: String, isDirectory: Bool, in ctx: DirectoryContext) async {
    if isDirectory {
      if ctx.navigate(into: name) { await model.refresh() }
      return
    }
    let path = Self.absolutePath(name, in: ctx)
    await openFile(path, in: ctx)
  }

  /// Opens a file, trying the macOS opener (`open`) first then the Linux opener
  /// (`xdg-open`). The exit code and the captured output ("command not found")
  /// tell us whether to fall back or surface a clear error.
  private func openFile(_ path: String, in ctx: DirectoryContext) async {
    let dir = ctx.path.isEmpty ? "/" : ctx.path
    model.setBusy(true)
    model.setLastError(nil)

    let mac = await Self.execute(
      FileCommandBuilder.open(path: path, isDirectory: false, remotePlatform: .macOS), in: dir,
      using: ctx.runner)
    if let mac, mac.exitCode == 0 {
      model.setBusy(false)
      return
    }

    let linux = await Self.execute(
      FileCommandBuilder.open(path: path, isDirectory: false, remotePlatform: .linux), in: dir,
      using: ctx.runner)
    if let linux, linux.exitCode == 0 {
      model.setBusy(false)
      return
    }

    let failed = mac ?? linux
    let detail: String
    if Self.isOpenerUnavailable(failed) {
      detail = "No default opener available for “\(path)” (open / xdg-open not found)."
    } else {
      detail = Self.errorText(command: "open", result: failed)
    }
    model.setLastError(detail)
    model.setBusy(false)
  }

  // MARK: - Delete

  /// Deletes `path` (`rm` for a file, `rm -rf` for a directory).
  ///
  /// `confirmed` MUST be true — the caller (the view) shows a confirmation
  /// dialog before invoking this, and that invariant is enforced here too so a
  /// destructive command can never be issued without the confirm step. A
  /// non-zero exit + captured stderr is surfaced through the model's error.
  func delete(path: String, isDirectory: Bool, confirmed: Bool) async {
    guard confirmed else {
      model.setLastError("Delete cancelled — confirmation is required before removing “\(path)”.")
      return
    }
    guard let ctx = model.context else { return }
    let command = FileCommandBuilder.delete(path: path, isDirectory: isDirectory)
    await run(command, in: ctx, refreshOnSuccess: true)
  }

  // MARK: - Move / Copy

  /// Moves or copies `source` to `destination` via `rsync` (move appends an
  /// `&& rm -rf <source>` to remove the source once the copy succeeds). Blocks a
  /// directory being moved/copied into itself with a canonical-path check so
  /// `rsync` cannot recurse into its own output. The destination is anchored to
  /// the current directory when it is relative.
  func moveCopy(
    source: String, destination: String, mode: FileCommandBuilder.MoveCopyMode, isDirectory: Bool
  ) async {
    guard let ctx = model.context else { return }
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      model.setLastError("Destination path is empty.")
      return
    }
    let dest = Self.resolveDestination(trimmed, in: ctx)
    guard source != dest else {
      model.setLastError("Source and destination are the same path.")
      return
    }
    guard !Self.isDirectoryIntoItself(source: source, destination: dest, isDirectory: isDirectory)
    else {
      model.setLastError("Cannot \(mode == .move ? "move" : "copy") a directory into itself.")
      return
    }
    let command = FileCommandBuilder.moveCopy(source: source, destination: dest, mode: mode)
    await run(command, in: ctx, refreshOnSuccess: true)
  }

  // MARK: - Shared command execution

  /// Runs `command` through `ctx.runner` off the main thread, setting the busy
  /// flag, capturing any non-zero exit + stderr into `lastError`, and refreshing
  /// the listing on success.
  private func run(_ command: String, in ctx: DirectoryContext, refreshOnSuccess: Bool) async {
    let dir = ctx.path.isEmpty ? "/" : ctx.path
    model.setBusy(true)
    model.setLastError(nil)

    guard let result = await Self.execute(command, in: dir, using: ctx.runner) else {
      model.setLastError("Could not run “\(command)”.")
      model.setBusy(false)
      return
    }

    if result.exitCode != 0 {
      model.setLastError(Self.errorText(command: command, result: result))
      model.setBusy(false)
      return
    }

    if refreshOnSuccess { await model.refresh() } else { model.setBusy(false) }
  }

  /// Executes `command` off the main thread and returns the result, or nil if the
  /// runner threw (e.g. a connection failure). A nil return is distinct from a
  /// non-zero exit — the caller interprets it as "could not execute at all".
  private static func execute(
    _ command: String, in dir: String, using runner: any FileCommandExecutor
  ) async -> CommandResult? {
    do {
      return try await Task.detached(priority: .userInitiated) {
        try await runner.run(inDirectory: dir, command)
      }.value
    } catch { return nil }
  }

  // MARK: - Path helpers

  /// Joins an entry `name` onto the current directory to form an absolute path.
  private static func absolutePath(_ name: String, in ctx: DirectoryContext) -> String {
    let base = ctx.path
    if base.isEmpty { return name }
    if base == "/" { return "/" + name }
    return base + "/" + name
  }

  /// Anchors a user-typed destination: absolute paths are used as-is, relative
  /// paths are resolved against the current directory.
  private static func resolveDestination(_ destination: String, in ctx: DirectoryContext) -> String
  {
    if destination.hasPrefix("/") { return destination }
    let base = ctx.path
    if base.isEmpty || base == "/" { return "/" + destination }
    return base + "/" + destination
  }

  /// Canonical-path guard: after standardizing (resolving `.`/`..`), a directory
  /// may not be moved/copied to itself or into one of its own subdirectories,
  /// which `rsync` would otherwise recurse into indefinitely.
  private static func isDirectoryIntoItself(source: String, destination: String, isDirectory: Bool)
    -> Bool
  {
    guard isDirectory else { return false }
    let src = URL(fileURLWithPath: source).standardizedFileURL.path
    let dest = URL(fileURLWithPath: destination).standardizedFileURL.path
    if src == dest { return true }
    return dest.hasPrefix(src + "/")
  }

  // MARK: - Diagnostics

  /// True when the opener that ran isn't installed on the host: a shell "not
  /// found" exit code (127) or a message naming the missing command.
  private static func isOpenerUnavailable(_ result: CommandResult?) -> Bool {
    guard let result else { return false }
    if result.exitCode == 127 { return true }
    let out = result.output.lowercased()
    return out.contains("command not found") || out.contains("no such file or directory")
      || out.contains("not found")
  }

  /// Builds the message surfaced for a failed command: the exit code plus the
  /// captured output (the runners combine stdout and stderr).
  private static func errorText(command: String, result: CommandResult?) -> String {
    guard let result else { return "Could not run “\(command)”." }
    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = trimmed.isEmpty ? "" : ": \(trimmed)"
    return "Command failed (exit \(result.exitCode)) for “\(command)”\(detail)"
  }
}
