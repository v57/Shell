import Foundation
import Observation
import SwiftUI
import ShellKit
import ShellIntegrations

/// Tracks the current working directory of a file browser for one terminal
/// session — locally (read live from the shell's cwd) or over SSH (via `pwd`).
///
/// The context is deliberately narrow: it owns the *path* (the absolute
/// directory `ls` should be run against), the *session* it belongs to, the
/// session's `ConnectionKind` (which decides the seeding strategy), and the
/// `FileCommandExecutor` used to run remote commands. It does not build the
/// view or the listing — a model owns those and reads `path`/`runner` off us.
///
/// Correctness against async `pwd`/`ls` results uses a coarse monotonic
/// `generation` counter, mirroring the generation-guard described in
/// `references/actor-isolation-and-off-main-work.md`: every path change and
/// every refresh bumps it, so an in-flight result that started against an
/// older path is discarded rather than clobbering newer state.
@MainActor
@Observable
final class DirectoryContext: Identifiable {
  let id = UUID()

  /// The terminal session this browser context belongs to.
  let session: TerminalSession
  /// The kind of the session — decides the seeding strategy and the runner.
  let kind: ConnectionKind
  /// The command executor selected by `kind`, used to run remote `pwd`/`ls`.
  let runner: any FileCommandExecutor

  /// Whether the session's directory lives on this host, so it can be listed
  /// with `FileManager`'s fast path instead of spawning a shell `ls`. This
  /// mirrors the runner selection in `runner(for:)`: local and screen sessions
  /// (and config-less action sessions) are local; SSH and remote-action sessions
  /// are remote.
  var isLocal: Bool {
    switch kind {
    case .local, .screen:
      return true
    case .action(let spec):
      return spec.config == nil
    case .ssh, .web, .database:
      return false
    }
  }

  /// The absolute current directory the browser is showing.
  private(set) var path: String

  /// Coarse monotonic generation counter. Bumped on every path change and
  /// refresh. A `pwd`/`ls`/`refresh` result that started under an earlier
  /// generation is discarded (see above). Readable so owners can detect that
  /// `path` moved underneath them.
  private(set) var generation = 0

  /// Whether the listing held by the owning model no longer matches `path`.
  /// Set true when the path changes (navigate / refresh); the owner clears it
  /// once it has re-listed against the new path.
  var listingIsStale = false

  /// The terminal session's live cwd as of the most recent `refresh()` poll.
  /// Lets `refresh()` tell a real shell `cd` (live changed) from a browser
  /// navigation (the browser path differs but the shell cwd didn't move), so a
  /// double-click drill-down is never yanked back to the shell's cwd.
  @ObservationIgnored private var lastLiveCWD: String?

  /// Creates a context, seeding `path` from the session's live cwd where that
  /// is possible synchronously (local). Remote kinds start with an empty
  /// sentinel and are populated by `refresh()`/`seed()`, since `pwd` is a
  /// command that can only be run asynchronously.
  init(session: TerminalSession, kind: ConnectionKind, runner: any FileCommandExecutor) {
    self.session = session
    self.kind = kind
    self.runner = runner
    self.path = Self.staticSeed(for: kind, session: session)
  }

  /// Convenience: builds the executor for `kind` and seeds via the primary init.
  convenience init(session: TerminalSession, kind: ConnectionKind) {
    self.init(session: session, kind: kind, runner: Self.runner(for: kind))
  }

  // MARK: - Runner selection

  /// The `FileCommandExecutor` appropriate for a connection kind. Local
  /// sessions run through `LocalProcessCommandRunner`; remote sessions run
  /// through `SSHCommandRunner` built from the kind's SSH config (action
  /// sessions carry their own `SSHConfig`, screen sessions run locally).
  static func runner(for kind: ConnectionKind) -> any FileCommandExecutor {
    switch kind {
    case .local, .screen:
      return LocalProcessCommandRunner()
    case .ssh(let config):
      return SSHCommandRunner(config: config)
    case .action(let spec):
      if let config = spec.config {
        return SSHCommandRunner(config: config)
      }
      return LocalProcessCommandRunner()
    case .web:
      // Web sessions have no file browser/executor; the Files panel is not
      // offered for them. Default keeps the switch exhaustive (unused).
      return LocalProcessCommandRunner()
    case .database:
      // Database sessions have no file system browser; the Files panel is
      // never offered for them. Default keeps the switch exhaustive (unused).
      return LocalProcessCommandRunner()
    }
  }

  // MARK: - Navigation

  /// Appends a child directory `name` to `path`. Callers pass only real
  /// directories (the view gates on `FileRow.isDirectory`); this keeps the
  /// append, normalizing stray separators and refusing empty/`.` targets that
  /// would otherwise be silent no-ops.
  ///
  /// - Returns: `true` if `path` changed.
  @discardableResult
  func navigate(into name: String) -> Bool {
    let component = name.trimmingCharacters(in: .init(charactersIn: "/"))
    guard !component.isEmpty, component != "." else { return false }
    generation += 1
    path = Self.appending(component, to: path)
    listingIsStale = true
    return true
  }

  /// Strips the last path component, stopping at `/`. Returns whether the path
  /// changed (i.e. we weren't already at the root).
  @discardableResult
  func navigateUp() -> Bool {
    guard path != "/" else { return false }
    generation += 1
    let parent = (path as NSString).deletingLastPathComponent
    path = parent.isEmpty ? "/" : parent
    listingIsStale = true
    return true
  }

  // MARK: - Refresh

  /// Re-reads the live cwd: local reads `session.currentDirectory` (sync),
  /// remote runs `pwd` through the runner and takes the first output line.
  /// Updates `path` and marks the listing stale when it moved.
  ///
  /// The generation guard discards a result that went stale mid-flight (a
  /// navigate or newer refresh bumped the counter) so an old path's `pwd`
  /// cannot overwrite newer state.
  ///
  /// The browser only re-anchors to `live` when the shell's cwd actually
  /// CHANGED since the last poll (a real `cd`). When the live cwd is unchanged
  /// but the browser path differs, that difference is a navigation the user
  /// initiated (a double-click drill-down), which must not be reverted.
  ///
  /// - Returns: `true` if the path changed and the listing must be refreshed.
  @discardableResult
  func refresh() async -> Bool {
    generation += 1
    let gen = generation
    guard let live = await liveCWD() else { return false }
    guard generation == gen else { return false }  // superseded while awaiting
    defer { lastLiveCWD = live }
    // A real shell `cd` moves the live cwd; only then re-anchor the browser.
    guard lastLiveCWD == nil || live != lastLiveCWD else { return false }
    guard live != path else { return false }
    path = live
    listingIsStale = true
    return true
  }

  /// Explicitly seeds a remote path (SSH/screen/action) by running `pwd`
  /// before any listing. Local paths are already seeded in `init`; calling
  /// this for a local context re-reads the live cwd (no-op if unchanged).
  /// Convenience wrapper the owning model calls on session selection change.
  func seed() async {
    _ = await refresh()
  }

  // MARK: - Internals

  /// Seeded synchronously. Local sessions expose the cwd directly; remote
  /// kinds prefer the live cwd already published by the session's transport
  /// (`remoteCurrentDirectory`), and otherwise start as the empty sentinel to
  /// be populated by `refresh()`/`seed()` (which runs a login-dir `pwd`).
  private static func staticSeed(for kind: ConnectionKind, session: TerminalSession) -> String {
    switch kind {
    case .local:
      return session.currentDirectory?.path ?? NSHomeDirectory()
    default:
      return session.remoteCurrentDirectory?.path ?? ""
    }
  }

  /// The current absolute cwd: local from the session, remote from the
  /// session's live transport cwd (so the browser follows the terminal's `cd`
  /// on the host), falling back to a login-dir `pwd` until the first poll.
  private func liveCWD() async -> String? {
    switch kind {
    case .local:
      return session.currentDirectory?.path
    default:
      // Prefer the live cwd already published by the session's transport
      // (follows the terminal's `cd` on the host); otherwise ask the remote
      // login directory via `pwd` (a fresh SSH exec channel starts in home).
      if let remote = session.remoteCurrentDirectory?.path { return remote }
      return (try? await runPWD()) ?? nil
    }
  }

  /// Runs `pwd` through the runner and returns the first non-empty output
  /// line. Falls back to the current path (or `/`) if `pwd` fails or is empty.
  /// During the initial seed the path is unknown, so `pwd` runs in `.` (the
  /// remote SSH exec channel's login directory = the user's home) rather than
  /// drilling into `/` — the history of the file browser always opening at
  /// root for a fresh remote session.
  private func runPWD() async throws -> String {
    let target = path.isEmpty ? "." : path
    let result = try await runner.run(inDirectory: target, "pwd")
    guard result.exitCode == 0 else { return path.isEmpty ? "/" : path }
    let line = result.output
      .split(whereSeparator: { $0.isNewline })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first(where: { !$0.isEmpty })
      .map { String($0) }
    return line ?? (path.isEmpty ? "/" : path)
  }

  /// Joins a normalized `component` onto `path`, handling the `/` root.
  private static func appending(_ component: String, to path: String) -> String {
    if path == "/" { return "/" + component }
    return path + "/" + component
  }
}
