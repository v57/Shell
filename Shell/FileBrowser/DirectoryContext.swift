import Foundation
import Observation
import SwiftUI
import Terminal
import TerminalIntegrations

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
  /// kinds need a `pwd` command, so they start as the empty sentinel and are
  /// populated by `refresh()`/`seed()`.
  private static func staticSeed(for kind: ConnectionKind, session: TerminalSession) -> String {
    switch kind {
    case .local:
      return session.currentDirectory?.path ?? NSHomeDirectory()
    default:
      return ""
    }
  }

  /// The current absolute cwd: local from the session, remote via `pwd`.
  private func liveCWD() async -> String? {
    switch kind {
    case .local:
      return session.currentDirectory?.path
    default:
      return (try? await runPWD()) ?? nil
    }
  }

  /// Runs `pwd` through the runner and returns the first non-empty output
  /// line. Falls back to the current path (or `/`) if `pwd` fails or is empty.
  private func runPWD() async throws -> String {
    let target = path.isEmpty ? "/" : path
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
