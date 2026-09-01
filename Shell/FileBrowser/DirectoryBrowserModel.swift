import Foundation
import Observation
import SwiftUI
import Terminal
import TerminalIntegrations

/// The stateful owner of the Files panel: it holds the `DirectoryContext` for
/// the currently-browsed session, the parsed `[FileRow]` listing, the column
/// sort order, the row selection, the in-flight/busy flag, any listing error,
/// and the visible flag (whether the Files panel or the terminal is shown).
///
/// The model is deliberately thin on rendering — `DirectoryBrowserView` reads
/// all of this off it. It owns the work: re-selecting a session rebuilds the
/// context (which picks the correct runner by connection kind), and `refresh()`
/// lists the directory off the main thread using a generation guard so a stale
/// result (the path moved, or the selection changed mid-flight) is discarded
/// instead of clobbering newer state.
@MainActor @Observable final class DirectoryBrowserModel {
  /// Whether the Files panel (vs the terminal) is shown in the detail area.
  /// The framework/segmented control binds to this.
  var visible = false

  /// The directory context for the currently-browsed session. Rebuilt whenever
  /// the session selection changes (`setSession`).
  private(set) var context: DirectoryContext?

  /// The currently-browsed session, kept so the model can tear down cleanly
  /// when the selection moves to a different session or away from all sessions.
  private(set) var session: TerminalSession?

  /// The parsed rows for `context.path`, in listing order.
  private(set) var rows: [FileRow] = []

  /// The active column sort order, driven by the sortable `Table` columns.
  var sortOrder: [KeyPathComparator<FileRow>] = []

  /// Selected row names (the `.id` of a `FileRow` is its name).
  var selection: Set<String> = []

  /// Whether a refresh is currently in flight, shown as a `ProgressView` only
  /// while the initial listing is still pending (rows empty).
  private(set) var busy = false

  /// The last listing error, shown by the view and cleared on retry.
  private(set) var lastError: String?

  /// How often a remote (SSH/action) path is re-typed via `pwd` while the
  /// panel is visible. Remote connections must not be polled on the 1s tick —
  /// that would keep a network connection open in the background.
  private let sshTickInterval: TimeInterval = 5

  /// Model-level monotonic generation. Bumped on every refresh and on every
  /// session re-selection; a `refresh()` result that started under an older
  /// generation is discarded. This is deliberately INDEPENDENT of
  /// `DirectoryContext.generation`, which is bumped by the context on every
  /// `refresh()` call even when the path did not change — so it is not a
  /// reliable signal that the path moved underneath a listing.
  private var generation = 0

  /// The last time the remote `pwd` sync ran, so `syncTick()` throttles it.
  @ObservationIgnored private var lastSSHTick = Date.distantPast

  // MARK: - Selection

  /// Tracks the selected terminal session. A `nil` session clears the browser
  /// (no session → no Files panel). A non-`nil` session rebuilds a context
  /// (which picks the runner by `kind`), seeds the remote path via `pwd`, and
  /// triggers an initial listing.
  func setSession(_ session: TerminalSession?, kind: ConnectionKind) {
    generation += 1
    self.session = session
    guard let session else {
      context = nil
      rows = []
      selection = []
      lastError = nil
      busy = false
      return
    }
    // DirectoryContext's convenience init selects the runner by kind
    // (local/screen -> LocalProcessCommandRunner, ssh/remote-action ->
    // SSHCommandRunner(config:)).
    let ctx = DirectoryContext(session: session, kind: kind)
    context = ctx
    rows = []
    selection = []
    lastError = nil
    // Seed the remote path (`pwd`) and list the directory once. Local contexts
    // are already seeded synchronously in init, so `seed()` is a cheap no-op
    // re-read there.
    Task { await seedAndList(ctx) }
  }

  /// Clears the browser. Convenience for "no session selected".
  func clear() { setSession(nil, kind: .local) }

  // MARK: - Listing

  /// Re-lists the current directory. Runs the listing off the main thread and
  /// publishes the rows back. A generation guard discards a result for a path
  /// or session that moved while the listing was in flight.
  func refresh() async {
    generation += 1
    let gen = generation
    guard let ctx = context else { return }
    let path = ctx.path
    let runner = ctx.runner
    let isLocal = ctx.isLocal
    busy = true
    lastError = nil
    do {
      // List off the main thread so an `ls` (or a remote `ls`) never blocks the
      // UI. The executor is Sendable; for a local session it is an `actor`, for
      // a remote one a @MainActor class whose `run` we simply await (it hops).
      // A local session takes the `FileManager` fast path (no `/bin/zsh` spawn
      // per listing); a remote session keeps the shell-based `DirectoryLister`.
      let result = try await Task.detached(priority: .userInitiated) {
        if isLocal {
          return try LocalDirectoryLister.list(directory: path)
        }
        return try await DirectoryLister.list(directory: path, executor: runner)
      }.value
      guard gen == generation, context === ctx else { return }  // superseded
      rows = result
      ctx.listingIsStale = false
      busy = false
    } catch {
      guard gen == generation, context === ctx else { return }  // superseded
      lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      busy = false
    }
  }

  // MARK: - Navigation

  /// Navigates into a directory `row`. Emits `navigate(into:)` from the view.
  func navigate(into row: FileRow) {
    guard let ctx = context else { return }
    if ctx.navigate(into: row.name) { Task { await refresh() } }
  }

  /// Strips the last path component, stopping at `/`. The view's "up" button
  /// and the ⌘⇧U shortcut both call this.
  func navigateUp() {
    guard let ctx = context else { return }
    if ctx.navigateUp() { Task { await refresh() } }
  }

  /// Double-clicking a file/directory. Directories navigate into; files open
  /// through `FileBrowserActions` (the host's default opener, local or SSH).
  func open(_ row: FileRow) {
    guard let ctx = context else { return }
    Task {
      await FileBrowserActions(model: self).open(row.name, isDirectory: row.isDirectory, in: ctx)
    }
  }

  /// Deletes the selected entries. The view shows a confirmation dialog before
  /// calling this; the destructive command only runs after that confirm step
  /// (`confirmed: true` inside `FileBrowserActions.delete`).
  func delete(_ names: Set<String>) {
    guard let ctx = context, !names.isEmpty else { return }
    let ordered = names.sorted()
    let actions = FileBrowserActions(model: self)
    Task {
      for name in ordered {
        guard let row = rows.first(where: { $0.name == name }) else { continue }
        await actions.delete(
          path: Self.absolutePath(name, in: ctx), isDirectory: row.isDirectory, confirmed: true)
      }
    }
  }

  /// Moves or copies the selected entries to `destination`. A relative
  /// destination is anchored to the current directory inside `FileBrowserActions`.
  func moveCopy(_ names: Set<String>, to destination: String, mode: FileCommandBuilder.MoveCopyMode)
  {
    guard let ctx = context, !names.isEmpty else { return }
    let ordered = names.sorted()
    let actions = FileBrowserActions(model: self)
    Task {
      for name in ordered {
        guard let row = rows.first(where: { $0.name == name }) else { continue }
        await actions.moveCopy(
          source: Self.absolutePath(name, in: ctx), destination: destination, mode: mode,
          isDirectory: row.isDirectory)
      }
    }
  }

  /// Renames a single entry `from` to `to` within the current directory. A
  /// rename is a move of one entry to a new name in the same directory, so it
  /// reuses the move/copy path: it moves `from` to a relative destination of
  /// just the new name, which `FileBrowserActions` anchors to the current
  /// directory. The listing refreshes on success (via the shared move path).
  func rename(from: String, to: String) {
    guard let ctx = context, !from.isEmpty, !to.isEmpty, from != to else { return }
    let actions = FileBrowserActions(model: self)
    Task {
      guard let row = rows.first(where: { $0.name == from }) else { return }
      await actions.moveCopy(
        source: Self.absolutePath(from, in: ctx), destination: to, mode: .move,
        isDirectory: row.isDirectory)
    }
  }

  /// Copies files dropped onto the browser (from Finder) into the current
  /// directory, via the shared rsync move/copy path. This is the drop side of
  /// the browser's drag-and-drop: `DirectoryBrowserView` calls it with the
  /// external file URLs the user drops onto the table. Each source path is used
  /// as-is (an absolute local path); only the destination is the current dir.
  func copyIn(urls: [URL]) {
    guard let ctx = context, !urls.isEmpty else { return }
    let destination = path.isEmpty ? "/" : path
    let actions = FileBrowserActions(model: self)
    Task {
      for url in urls {
        await actions.moveCopy(
          source: url.path, destination: destination, mode: .copy,
          isDirectory: Self.isDirectoryFile(url))
      }
    }
  }

  // MARK: - Displayed state

  /// The absolute directory being shown, for the breadcrumb path bar.
  var path: String { context?.path ?? "" }

  /// Whether the "up" action is possible: a path has been established and it
  /// is not the root.
  var canNavigateUp: Bool {
    guard let ctx = context else { return false }
    return !ctx.path.isEmpty && ctx.path != "/"
  }

  // MARK: - Session sync

  /// Called on the window's 1s tick. Local sessions re-read the live cwd and
  /// re-list when it moves (picked up within ~1s). Remote (SSH/action) sessions
  /// re-type the path via `pwd` on a slower cadence, and only while the panel is
  /// visible, so a background SSH connection is not kept open spamming `pwd`.
  func syncTick() {
    guard let ctx = context else { return }
    switch ctx.kind {
    case .local:
      // The shell changed directories: adopt the new cwd and re-list.
      Task { if await ctx.refresh() { await refresh() } }
    case .screen, .ssh, .action:
      // Remote paths are known only by asking (`pwd`). Throttle to the slower
      // cadence and skip entirely while the panel is hidden.
      guard visible, Date().timeIntervalSince(lastSSHTick) >= sshTickInterval else { return }
      lastSSHTick = Date()
      Task { if await ctx.refresh() { await refresh() } }
    case .web:
      // Web sessions have no directory to browse; the Files panel is never
      // shown for them, so there is nothing to tick.
      break
    case .database:
      // Database sessions have no terminal directory to browse; nothing to tick.
      break
    }
  }
}

// MARK: - Helpers

extension DirectoryBrowserModel {
  /// Seeds the remote path (`pwd` for SSH/action; a no-op re-read for local)
  /// then lists once. Used by `setSession`.
  fileprivate func seedAndList(_ ctx: DirectoryContext) async {
    await ctx.seed()
    await refresh()
  }

  // MARK: - File-operation state hooks

  /// Internal setter so `FileBrowserActions` (same module) can drive the busy
  /// flag the view observes around a file operation. Kept internal — the raw
  /// setter is not part of the model's surface.
  func setBusy(_ value: Bool) { busy = value }

  /// Internal setter so `FileBrowserActions` can surface a command failure
  /// (non-zero exit + stderr) through the same `lastError` the listing uses.
  func setLastError(_ message: String?) { lastError = message }

  /// Joins a child entry `name` onto the context's current directory, forming
  /// the absolute path a file operation runs against.
  fileprivate static func absolutePath(_ name: String, in ctx: DirectoryContext) -> String {
    let base = ctx.path
    if base.isEmpty { return name }
    if base == "/" { return "/" + name }
    return base + "/" + name
  }

  /// Whether the (local) file at `url` is a directory on this host. Dropped
  /// files always come from Finder on the host, so checking the local
  /// filesystem is correct even when the current directory being browsed is
  /// remote (SSH) — the source file is still local.
  fileprivate static func isDirectoryFile(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }
}
