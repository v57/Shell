#if os(macOS)
import AppKit
import Darwin
#elseif os(iOS)
import UIKit
#else
import SwiftUI
#endif
import Foundation
import Observation

/// A live terminal session: owns the output parser and the UI-facing
/// state (snapshot, selection, connection state, prompts). All I/O goes
/// through a `TerminalTransport` (local pty or SSH), so the session itself
/// is transport-agnostic — the app picks the transport per session kind.
@Observable
public final class TerminalSession: Identifiable {
  public enum ConnectionState: Equatable {
    case starting
    case connecting(String)
    case connected
    /// The link dropped and the session is dialing again (`attempt` counts
    /// from 1). Only sessions created with a `reconnect` factory get here.
    case reconnecting(attempt: Int)
    case failed(String)
    case closed
  }

  public let id = UUID()

  /// Optional user-given name shown in the sidebar; nil = default name.
  public var customName: String?

  public var snapshot = TerminalSnapshot() {
    didSet { snapshotGeneration &+= 1 }
  }
  /// Bumped on every published snapshot — a cheap change token for views
  /// that react to new output (the snapshot itself isn't Equatable).
  public private(set) var snapshotGeneration = 0
  /// Text selection (LOGICAL line coordinates — see mouse handling in the
  /// terminal screen view), driven by the view.
  public var selectionStart: TerminalCursor?
  public var selectionEnd: TerminalCursor?
  /// The snapshot epoch the current selection was made against; when the
  /// snapshot's epoch advances (full clear, RIS, alt-screen switch) the
  /// selection is stale and gets dropped.
  public var selectionEpoch = 0
  public var connectionState: ConnectionState = .starting
  public var hostKeyPrompt: TerminalHostKeyPrompt?
  public var passwordPrompt: TerminalPasswordPrompt?
  /// Whether the session produced stdout recently. Observed by the sidebar
  /// `SessionRow` to show/hide the active (green) status dot: set true on
  /// stdout, then set false by the inactivity timer once `inactivityTimeout`
  /// passes with no output (idle session). See the inactivity timer below.
  public var hasActivity = false
  /// Lines scrolled up from the bottom of the scrollback (0 = at bottom).
  /// Owned by the view; stored here so copy actions can see it.
  public var scrollbackOffset = 0

  /// How many non-empty lines from the bottom the sidebar status shows
  /// (0 = the last non-empty line, the automatic default). Set by
  /// clicking the last character of a line: the clicked line becomes
  /// the status by its rank, so it follows output as lines scroll.
  public var statusRank = 0

  /// Whether the status line is explicitly pinned to a line vs following
  /// the automatic default. Kept separate from `statusRank` because a
  /// pinned line can have rank 0 (indistinguishable from automatic by
  /// rank alone); the pin flag disambiguates so the start-character
  /// granularity works on the last non-empty line too.
  public var statusPinned = false

  /// When the status is pinned, whether the line renders in
  /// start-character mode (the line shown FROM `statusStartColumn`,
  /// skipping every character before it) vs full-line mode (the whole
  /// line shown). Toggled by clicking the current start character;
  /// clicking any other character of the selected line re-anchors the
  /// start there.
  public var statusStartMarked = false

  /// The column the status line starts from in start-character mode — the
  /// clicked character. In full-line mode it is still remembered so
  /// clicking that same character toggles back to start-character mode.
  public var statusStartColumn = 0

  /// Exit code of an action session's process (bits 8-15 of the wait
  /// status; nil for non-action sessions and while running).
  public var actionExitCode: Int32?

  /// The current working directory of the child process, read live from
  /// the OS on each access. Follows the shell's `cd` without any shell
  /// cooperation (libproc `PROC_PIDVNODEPATHINFO`). Nil for non-local
  /// transports (SSH has no local child) and while no child is running.
  ///
  /// Cheap to call (one syscall), so a view can poll it on a timer to
  /// keep a subtitle or status line in sync.
  public var currentDirectory: URL? {
    #if os(macOS)
    guard let pid = transport.childProcessID else { return nil }
    var info = proc_vnodepathinfo()
    let size = MemoryLayout<proc_vnodepathinfo>.size
    let status = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
    guard status == Int32(size), info.pvi_cdir.vip_path.0 != 0 else { return nil }
    var pathBytes = info.pvi_cdir.vip_path
    let path = withUnsafeBytes(of: &pathBytes) { raw -> String? in
      guard let base = raw.baseAddress else { return nil }
      return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
    return path.map { URL(fileURLWithPath: $0) }
    #else
    return nil
    #endif
  }

  /// The current working directory of a REMOTE (SSH-backed) child process,
  /// read by running `pwd` over the already-connected transport — no new
  /// SSH dial, unlike `currentDirectory` which is local-only (libproc).
  /// Follows the shell's `cd` on the remote host. Nil for local sessions
  /// (use `currentDirectory`), for non-SSH transports, and while the SSH
  /// channel isn't connected. Polled on a throttle (see `refreshRemoteDirectory`)
  /// so the sidebar subtitle and file browser can show/follow the remote cwd,
  /// which is otherwise unknown from outside the host.
  public var remoteCurrentDirectory: URL?

  @ObservationIgnored
  private var lastRemoteCWDReadAt: Date?

  /// Seconds between remote `pwd` polls. A `pwd` opens a second exec channel
  /// over the live connection (same mechanism as the persistent-session
  /// scanner), so it must not run every frame — the subtitle's 1s timer drives
  /// `refreshRemoteDirectory`, and this tradeoff mirrors `DirectoryBrowserModel`'s
  /// remote tick cadence.
  public static let remoteCWDThrottle: TimeInterval = 3

  /// Re-reads the remote shell's cwd via a throttled `pwd` on the live
  /// transport and publishes it to `remoteCurrentDirectory`. No-op (and clears
  /// the value) for non-SSH sessions and while not connected.
  public func refreshRemoteDirectory() {
    guard case .connected = connectionState, let ssh = sshTransport else {
      remoteCurrentDirectory = nil
      return
    }
    if let last = lastRemoteCWDReadAt,
       Date().timeIntervalSince(last) < Self.remoteCWDThrottle { return }
    lastRemoteCWDReadAt = Date()
    ssh.runCommand("pwd") { [weak self] result in
      guard case .success(let remote) = result, remote.exitStatus == 0 else { return }
      // `pwd` on a remote shell returns an absolute path; ignore anything else
      // (e.g. a bare "~" or an empty reply) so we never publish a bogus URL.
      let line = remote.stdout
        .split(whereSeparator: { $0.isNewline })
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
      guard let line, line.hasPrefix("/") else { return }
      // The engine delivers the completion on the main thread, so assume the
      // actor and publish directly — avoids a captured-var warning that a
      // `Task { @MainActor in self?... }` would otherwise trip.
      MainActor.assumeIsolated {
        self?.remoteCurrentDirectory = URL(fileURLWithPath: line)
      }
    }
  }

  /// Called once when an action session completes (process exit or
  /// remote exec exit status). AppModel decides keep-vs-remove.
  public var actionCompletionHandler: (() -> Void)?

  /// Called whenever the underlying child or remote exec exits. Unlike the
  /// action-specific callback, this is also used by persistent attachments
  /// to reconcile a detached or terminated tmux/screen client.
  public var exitHandler: ((Int32) -> Void)?

  /// Called for commands submitted through the interactive user-input path,
  /// or explicitly through `submitCommand`. Parser replies and direct `send`
  /// calls are intentionally excluded.
  public var commandSubmittedHandler: ((String) -> Void)?

  /// Called whenever parser-backed rendered output is replaced.
  public var snapshotUpdateHandler: ((TerminalSnapshot) -> Void)?

  @ObservationIgnored
  private var transport: any TerminalTransport
  /// Builds a fresh transport for the same destination when the link
  /// drops (SSH: a new `SSHSession` for the config). Nil = no reconnect:
  /// a dropped link is a plain failure.
  @ObservationIgnored
  private let makeReconnectTransport: (() -> any TerminalTransport)?
  /// The message shown while the first connection was being made
  /// ("Connecting to host…"); reused for the reconnect status.
  @ObservationIgnored
  private let startupMessage: String?
  /// Why the link dropped, shown above the reconnect status.
  @ObservationIgnored
  private var lossMessage: String?
  /// How many dials the current reconnect has made or scheduled; 0 while
  /// the original connection is up (or was never lost).
  @ObservationIgnored
  private var reconnectAttempt = 0
  @ObservationIgnored
  private var reconnectTimer: Timer?
  /// Seconds to wait before dial `attempt` (1-based). Test seam; the default
  /// is `defaultReconnectDelay`.
  @ObservationIgnored
  public var reconnectDelay: (Int) -> TimeInterval = TerminalSession.defaultReconnectDelay
  @ObservationIgnored
  private lazy var parser = TerminalOutputParser(sendResponse: { [weak self] response in
    self?.send(response)
  })
  @ObservationIgnored
  private var inputAnchor: TerminalCursor?
  @ObservationIgnored
  private var inputFallback = ""
  /// Input went in while the child had echo off (a password prompt), so the
  /// typed keys are never recorded as a command.
  @ObservationIgnored
  private var inputHidden = false
  @ObservationIgnored
  private var didCloseTransport = false
  /// The size the parser grid currently has. `resize` compares against it to
  /// decide the order of the child/grid resizes (see the comment there); it
  /// is seeded from the transport's start size in `init`.
  @ObservationIgnored
  private var lastGridSize = TerminalGridSize(rows: 24, columns: 80)

  // MARK: Coalesced snapshot publishing
  //
  // Bulk pty output arrives in many small chunks (~100+/sec under
  // `ping -i 0.01`). Publishing a full snapshot + re-render per chunk is
  // the CPU amplifier that grows with scrollback length. Instead,
  // receiveOutput only schedules a publish; a 30fps timer (or an explicit
  // flush from interactive paths) coalesces chunks into ONE snapshot
  // publish. Publishes that changed nothing VISIBLE (empty dirty set,
  // same cursor/epoch/size) are skipped entirely.

  /// 30fps: the publish throttle for bulk output. Interactive paths
  /// (typing, resize, clear, connect/exit) flush immediately.
  public static let publishInterval: TimeInterval = 1.0 / 30.0

  /// Seconds of stdout quiet before `hasActivity` flips false and the
  /// sidebar hides the active (green) dot for an idle session.
  public static let inactivityTimeout: TimeInterval = 30
  @ObservationIgnored
  private var pendingPublish = false
  @ObservationIgnored
  private var publishTimer: Timer?
  @ObservationIgnored
  private var lastPublishedEpoch = 0
  @ObservationIgnored
  private var lastPublishedTotalLines = 0
  @ObservationIgnored
  private var lastPublishedCursor = TerminalCursor.zero
  @ObservationIgnored
  private var lastPublishedShowCursor = true
  @ObservationIgnored
  private var lastPublishedCursorBackground = TerminalPalette.selectionBackground

  // MARK: Activity inactivity timer
  //
  // Single-fire debounce that hides the sidebar's active (green) dot after
  // `inactivityTimeout` of stdout quiet. Optimization: it is armed ONLY
  // when no timer is running (the first activity after an idle period); the
  // deadline slides, not by touching the timer on every chunk (bulk output
  // is ~100+ chunks/sec), but by the firing tick re-reading the last
  // activity time and re-arming to `lastActivity + timeout` when output
  // arrived inside the window. At most ONE timer is ever alive.

  @ObservationIgnored
  private var inactivityTimer: Timer?
  /// When the most recent stdout chunk arrived (the sliding deadline anchor).
  @ObservationIgnored
  private var lastActivityDate: Date?
  /// Whether any stdout arrived since the timer was last armed — the firing
  /// tick uses this to decide re-arm (still active) vs confirm idle.
  @ObservationIgnored
  private var activityPending = false

  /// Creates a session over `transport` and starts it immediately.
  /// `startupMessage` is shown while connecting (SSH: "Connecting to
  /// host…"); nil starts in `.starting` (local pty). With `reconnect`, a
  /// dropped link (host rebooting, network gone) does not end the session:
  /// it keeps dialing with transports from the factory, backing off to one
  /// dial every five seconds, until the host answers again or the session
  /// is closed. The scrollback survives; the new shell continues below a
  /// "reconnected" line.
  public init(
    transport: any TerminalTransport,
    startupMessage: String? = nil,
    reconnect: (() -> any TerminalTransport)? = nil
  ) {
    self.transport = transport
    self.makeReconnectTransport = reconnect
    self.startupMessage = startupMessage
    // Seed the parser grid with the size the transport STARTS the child at
    // (`initialGridSize`). The child's first output can beat the view's
    // first layout, and that is exactly what happens for a session created
    // before its view exists (the launch-time default terminal): parsing
    // those bytes at a different width wraps every width-sensitive escape
    // on the wrong row. zsh's PROMPT_SP padding then fails to erase its
    // reverse-video "%" marker, which stays stranded on the first screen.
    let initialGrid = transport.initialGridSize
    parser.resize(columns: initialGrid.columns, rows: initialGrid.rows)
    lastGridSize = initialGrid
    if let startupMessage {
      connectionState = .connecting(startupMessage)
      snapshot = TerminalSnapshot(message: startupMessage)
    }
    wire(transport)
    transport.start()
    // The initial grid is visible immediately (no pty output may ever
    // arrive before the view appears). Force: it is the first publish.
    // A startup message stays up instead until the transport connects.
    if startupMessage == nil {
      publishNow(force: true)
    }
  }

  /// Points `transport`'s callbacks at this session. Callbacks capture the
  /// transport too, so a replaced (dead) transport whose last events are
  /// still queued on the main thread cannot speak for the live one.
  private func wire(_ transport: any TerminalTransport) {
    transport.onOutput = { [weak self, weak transport] data in
      guard let self, self.isCurrent(transport) else { return }
      self.receiveOutput(data)
    }
    transport.onConnected = { [weak self, weak transport] in
      guard let self, self.isCurrent(transport) else { return }
      self.transportConnected()
    }
    transport.onTerminated = { [weak self, weak transport] message in
      guard let self, self.isCurrent(transport) else { return }
      self.transportTerminated(message)
    }
    transport.onConnectionLost = { [weak self, weak transport] message in
      guard let self, self.isCurrent(transport) else { return }
      self.transportConnectionLost(message)
    }
    transport.onExit = { [weak self, weak transport] code in
      guard let self, self.isCurrent(transport) else { return }
      self.transportExited(code)
    }
    transport.onHostKeyPrompt = { [weak self, weak transport] prompt in
      guard let self, self.isCurrent(transport) else { return }
      self.hostKeyPrompt = prompt
    }
    transport.onPasswordPrompt = { [weak self, weak transport] prompt in
      guard let self, self.isCurrent(transport) else { return }
      self.passwordPrompt = prompt
    }
  }

  private func isCurrent(_ transport: (any TerminalTransport)?) -> Bool {
    guard let transport else { return false }
    return transport === self.transport
  }

  deinit {
    if !didCloseTransport {
      transport.close()
    }
  }

  /// Stops the underlying PTY or network transport immediately. Session
  /// owners call this before dropping their reference; relying on `deinit`
  /// can leave I/O sources alive while SwiftUI retains an outgoing view.
  public func close() {
    guard !didCloseTransport else { return }
    didCloseTransport = true
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    publishTimer?.invalidate()
    publishTimer = nil
    pendingPublish = false
    inactivityTimer?.invalidate()
    inactivityTimer = nil
    lastActivityDate = nil
    activityPending = false
    transport.close()
  }

  /// The SSH transport backing this session, when it is SSH-backed. Lets the
  /// remote persistent-session scanner run a one-shot command over the
  /// ALREADY-CONNECTED connection (currentConnectionState says connected, so
  /// the transport's engine is live) rather than dialing a throwaway SSH
  /// connection. Nil for local, action, and test-double transports.
  public var sshTransport: SSHSession? { transport as? SSHSession }

  public func send(_ string: String) {
    send(Data(string.utf8))
  }

  public func send(_ data: Data) {
    transport.write(data)
  }

  public func resize(columns: Int, rows: Int) {
    guard columns > 0, rows > 0 else { return }

    // resize/clearStdout run on the main thread but mutate the parser;
    // the parser's internal lock serializes them against the parse queue.
    //
    // The grid must never be NARROWER than the width the child still
    // believes it has: a child picks up the new winsize at its NEXT prompt,
    // not at the ioctl, so mid-resize it can still emit output laid out for
    // the old width. If the grid has already shrunk, that output wraps a row
    // early — zsh's PROMPT_SP padding then misses the CR that erases its
    // "%" marker and leaves it stranded on screen (the launch-time default
    // terminal is the resize that hits this: it shrinks 200 -> real width
    // while the first prompt is still being drawn). So shrink the child
    // first, and grow the grid first.
    let size = TerminalGridSize(rows: rows, columns: columns)
    let shrinking = size.columns < lastGridSize.columns

    if shrinking {
      transport.resize(columns: columns, rows: rows)
    }
    parser.resize(columns: columns, rows: rows)
    parser.drainParseQueue()
    if !shrinking {
      transport.resize(columns: columns, rows: rows)
    }
    lastGridSize = size

    if connectionState == .connected {
      // Interactive: publish immediately so the reflow is visible now
      // (force: the reflow can be pure cursor/geometry change).
      publishNow(force: true)
    }
  }

  /// Keyboard input from the pure-SwiftUI view (onKeyPress). Structured
  /// parameters instead of an NSEvent so no AppKit event object is needed.
  public func handleKey(characters: String?, charactersIgnoringModifiers: String?, keyCode: UInt16, modifierFlags: TerminalModifierFlags) {
    if modifierFlags.contains(.command) {
      switch charactersIgnoringModifiers?.lowercased() {
      case "v":
        pasteFromPasteboard()
      case "c":
        if let start = selectionStart, let end = selectionEnd {
          copySelection(from: start, to: end)
        } else {
          copyVisibleBuffer()
        }
      case "k":
        clearStdout()
      default:
        break
      }
      return
    }

    if let bytes = TerminalKeyMapper.bytes(
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      keyCode: keyCode,
      modifierFlags: modifierFlags
    ) {
      if keyCode == 36 || keyCode == 76 {
        submitCapturedCommand()
      } else {
        recordUserInput(
          bytes,
          characters: characters,
          charactersIgnoringModifiers: charactersIgnoringModifiers,
          keyCode: keyCode,
          modifierFlags: modifierFlags
        )
      }
      send(bytes)
    }
  }

  /// Cmd+K "clean stdout": tell the shell to redraw its prompt at the top
  /// of the screen (Ctrl-L — zsh's line editor handles it itself, so the
  /// shell's internal cursor stays in sync and the prompt MOVES UP like
  /// Terminal.app), then erase the scrollback and every row except the
  /// cursor's locally as a safety net for programs that ignore ^L. Drops
  /// any selection and publishes the refreshed snapshot.
  public func clearStdout() {
    sendClearScreen()
    parser.clearStdout()
    parser.drainParseQueue()
    selectionStart = nil
    selectionEnd = nil
    scrollbackOffset = 0
    // Force: the epoch bump + scrollback wipe must reach the view now.
    publishNow()
  }

  /// Sends Ctrl-L to the child. zsh's line editor (zle) handles it itself:
  /// it emits ESC[H ESC[2J and redraws the prompt at the TOP of the
  /// screen, cursor included — so the current line MOVES UP and the shell's
  /// internal cursor stays in sync (the key difference from a terminal-side
  /// clear, which zsh can't see and which leaves its editor pointing at a
  /// stale screen row). Interactive programs that don't bind ^L (a running
  /// ping, top) just pass it through as literal input, so callers must
  /// still clear the local grid afterward.
  public func sendClearScreen() {
    send(Data([0x0c]))
  }

  public func paste(_ string: String) {
    guard !string.isEmpty else { return }

    beginInputIfNeeded()
    if !transport.echoesInput { inputHidden = true }
    inputFallback.append(
      string.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    )

    // The parser's bracketed-paste flag is mirrored onto the snapshot on
    // every publish, so this main-thread read never races the parse queue.
    if snapshot.bracketedPasteEnabled {
      send(Data("\u{1b}[200~".utf8))
      send(string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
      send(Data("\u{1b}[201~".utf8))
    } else {
      send(string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }
  }

  /// Submits one recorded command to the child. Used by history replay so
  /// replayed commands are themselves captured as user-visible input.
  public func submitCommand(_ command: String) {
    let normalized = command.trimmingCharacters(in: .newlines)
    guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    commandSubmittedHandler?(normalized)
    send(normalized)
    send(Data([0x0d]))
  }

  private func copyVisibleBuffer() {
    let text = snapshot.plainText(offset: scrollbackOffset)
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    #elseif os(iOS)
    UIPasteboard.general.string = text
    #else
    Pasteboard.general.setString(text)
    #endif
  }

  private func copySelection(from start: TerminalCursor, to end: TerminalCursor) {
    // Selection rows are LOGICAL lines; the snapshot maps them directly.
    let text = snapshot.plainText(logicalFrom: start, to: end)
    guard !text.isEmpty else { return }
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    #elseif os(iOS)
    UIPasteboard.general.string = text
    #else
    Pasteboard.general.setString(text)
    #endif
  }

  private func pasteFromPasteboard() {
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    if let string = pasteboard.string(forType: .string) {
      paste(string)
    }
    #elseif os(iOS)
    if let string = UIPasteboard.general.string {
      paste(string)
    }
    #else
    if let string = Pasteboard.general.string() {
      paste(string)
    }
    #endif
  }

  /// A click (mouse-down == mouse-up) on the terminal grid.
  ///
  /// The mode is sticky: full-line mode keeps the whole line when you click
  /// a DIFFERENT line, and offset mode (the line shown FROM the clicked
  /// character) keeps offsetting when you click a different line. You can
  /// only switch modes on the currently observed line:
  ///  - Full-line mode: click the observed line → switch to offset mode,
  ///    anchored at the clicked character. Click a different line → keep
  ///    the whole line for it.
  ///  - Offset mode: click a different line → keep offsetting that line
  ///    from the clicked character. Click a non-start character of the
  ///    observed line → re-anchor. Click the current start character →
  ///    back to full-line mode.
  public func clickStatusPin(at cursor: TerminalCursor) {
    guard let rank = snapshot.nonEmptyRank(fromBottomOf: cursor.row) else { return }
    if rank != statusRank {
      // Clicking a different line: select it, preserving the current mode
      // (offset stays offset; full-line stays full-line).
      statusRank = rank
      statusPinned = true
      statusStartColumn = cursor.column
      // statusStartMarked is intentionally left unchanged — the mode is sticky.
      return
    }
    // Clicking the currently observed line (rank == statusRank): engaging it
    // makes it explicitly selected, even if it was the automatic (unpinned)
    // default line.
    statusPinned = true
    if statusStartMarked {
      // Offset mode.
      if cursor.column == statusStartColumn {
        // Clicking the current start character → back to full-line mode.
        statusStartMarked = false
      } else {
        // Clicking any other character re-anchors the offset.
        statusStartColumn = cursor.column
        statusStartMarked = true
      }
    } else {
      // Full-line mode → clicking the observed line switches to offset
      // mode, anchored at the clicked character.
      statusStartColumn = cursor.column
      statusStartMarked = true
    }
  }

  /// How far up the scrollback can go with the current snapshot.
  public var maxScrollbackOffset: Int {
    max(0, snapshot.totalLines - snapshot.rows)
  }

  public func acceptHostKey(_ prompt: TerminalHostKeyPrompt) {
    prompt.respond(true)
    hostKeyPrompt = nil
  }

  public func rejectHostKey(_ prompt: TerminalHostKeyPrompt) {
    prompt.respond(false)
    hostKeyPrompt = nil
  }

  // MARK: - Transport callbacks (all on the main thread)

  private func receiveOutput(_ data: Data) {
    // Parse on the background parse queue (efficiency cores) — never block
    // the main thread on byte parsing. The 30fps publish timer picks up
    // the latest state when it fires.
    parser.consumeAsync(data)
    noteActivity()
    schedulePublish()
  }

  /// Coalesces bulk output into at most one publish per `publishInterval`
  /// (10fps). Cheap per chunk: just marks pending and ensures the timer
  /// is armed. Interactive paths call `flushPendingOutput()` directly.
  private func schedulePublish() {
    guard !pendingPublish else { return }
    pendingPublish = true
    if publishTimer == nil {
      let timer = Timer(fire: Date(timeIntervalSinceNow: Self.publishInterval), interval: Self.publishInterval, repeats: true) { [weak self] _ in
        self?.publishNow()
      }
      RunLoop.main.add(timer, forMode: .common)
      publishTimer = timer
    }
  }

  /// Publishes the latest parser state immediately if something is
  /// pending. Interactive paths (typing, resize, clear, connect/exit) and
  /// tests call this directly; the timer calls it on each tick.
  ///
  /// Synchronous-by-construction: drains the parse queue first so any
  /// `consumeAsync` work enqueued before the flush has landed in the grid
  /// before the snapshot is taken. (Safe from the main thread — the parse
  /// queue is a serial background queue, never the main queue, so
  /// `sync` can't deadlock.)
  public func flushPendingOutput() {
    guard pendingPublish else { return }
    parser.drainParseQueue()
    publishNow()
  }

  /// The one place a snapshot becomes visible: rebuilds from the parser,
  /// skips publishes that changed nothing VISIBLE, and notifies observers.
  /// Called by the coalescing timer, explicit flushes, and interactive
  /// paths (`force: true` — state transitions like connect/exit must
  /// publish even when the grid pixels are unchanged, e.g. the startup
  /// message clearing).
  private func publishNow(force: Bool = false) {
    pendingPublish = false
    publishTimer?.invalidate()
    publishTimer = nil
    // A status message (connecting, reconnecting, failed) stays up until
    // the transport connects (a forced publish): output that was still
    // being parsed when the link dropped must not replace it.
    guard force || snapshot.message == nil else { return }

    let newSnapshot = parser.snapshotForPublish()  // consumes the dirty set
    // Skip when nothing VISIBLE changed since the last publish (bytes
    // arrived, but they were OSC/title-only, SGR-only, or cursor moves):
    // empty dirty set + same cursor + same epoch/size. Keeps `ping`-style
    // no-op traffic from re-rendering the whole view at 10fps.
    let visuallyChanged =
      force
      || !newSnapshot.dirtyLines.isEmpty
      || newSnapshot.selectionEpoch != lastPublishedEpoch
      || newSnapshot.totalLines != lastPublishedTotalLines
      || newSnapshot.cursor != lastPublishedCursor
      || newSnapshot.showCursor != lastPublishedShowCursor
      || newSnapshot.cursorBackground != lastPublishedCursorBackground
    guard visuallyChanged else { return }

    snapshot = newSnapshot
    lastPublishedEpoch = newSnapshot.selectionEpoch
    lastPublishedTotalLines = newSnapshot.totalLines
    lastPublishedCursor = newSnapshot.cursor
    lastPublishedShowCursor = newSnapshot.showCursor
    lastPublishedCursorBackground = newSnapshot.cursorBackground
    snapshotUpdateHandler?(snapshot)

    // Ordinary output keeps the selection; only content-invalidating
    // events (full clears, alt-screen switches — a snapshot epoch change)
    // drop it.
    if selectionStart != nil, newSnapshot.selectionEpoch != selectionEpoch {
      selectionStart = nil
      selectionEnd = nil
    }
  }

  // MARK: - Activity inactivity timer

  /// Called on every stdout chunk (main thread). Marks the session active
  /// (hasActivity flips true only on the first chunk after idle) and arms
  /// the single inactivity timer if none is running. The deadline is NOT
  /// reset per chunk — the running timer's firing tick re-anchors it to the
  /// last real activity time, so the timer is never churned under bulk
  /// output (see THE inactivity timer definition above).
  private func noteActivity() {
    let now = Date()
    lastActivityDate = now
    activityPending = true
    if !hasActivity {
      hasActivity = true
    }
    if inactivityTimer == nil {
      armInactivityTimer(at: now.addingTimeInterval(Self.inactivityTimeout))
    }
  }

  /// Arms a single-fire (never repeating) timer to run `self`'s firing tick
  /// at `deadline`. Called only when no timer is running (the first activity
  /// after idle) or to re-anchor after a firing tick found fresh output.
  private func armInactivityTimer(at deadline: Date) {
    activityPending = false
    let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
      self?.inactivityTimerFired()
    }
    RunLoop.main.add(timer, forMode: .common)
    inactivityTimer = timer
  }

  /// The single inactivity timer's firing tick (main thread). If stdout
  /// arrived while it was armed, re-arm to `lastActivity + timeout` (the
  /// deadline slides forward from the most recent real output, and still
  /// exactly one timer is live). Otherwise the full `inactivityTimeout` of
  /// quiet is confirmed: flip `hasActivity` false (the sidebar hides the
  /// active dot) and clear the anchor.
  private func inactivityTimerFired() {
    inactivityTimer?.invalidate()
    inactivityTimer = nil
    if activityPending, let last = lastActivityDate {
      let deadline = last.addingTimeInterval(Self.inactivityTimeout)
      if deadline > Date() {
        armInactivityTimer(at: deadline)
        return
      }
    }
    // Confirmed idle: no stdout for the full timeout.
    hasActivity = false
    lastActivityDate = nil
    activityPending = false
  }

  private func transportConnected() {
    let reconnected = reconnectAttempt > 0
    reconnectAttempt = 0
    lossMessage = nil
    connectionState = .connected
    if reconnected {
      // The fresh transport started its pty at the default size; bring it
      // to the grid's real size before the new shell draws its prompt.
      transport.resize(columns: lastGridSize.columns, rows: lastGridSize.rows)
      // Leave whatever screen the dead shell was on (alt screen, colors)
      // and mark the seam, so the new prompt starts on its own line below
      // the old output instead of over it.
      receiveOutput(Data("\u{1B}[?1049l\u{1B}[0m\r\n\u{1B}[2m\u{2500}\u{2500} reconnected \u{2500}\u{2500}\u{1B}[0m\r\n".utf8))
    }
    // Force: clears the startup message even if the grid pixels match.
    publishNow(force: true)
  }

  private func transportTerminated(_ message: String) {
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    connectionState = .failed(message)
    snapshot = TerminalSnapshot(message: message)
    snapshotUpdateHandler?(snapshot)
  }

  // MARK: - Reconnect

  /// Whether a dropped link is dialed again (the session was created with
  /// a `reconnect` factory). Also what `reconnectNow()` needs.
  public var canReconnect: Bool { makeReconnectTransport != nil }

  /// 1s, 2s, 3s, then every 5s: quick enough that a host back from a
  /// reboot is picked up within seconds, slow enough not to hammer one
  /// that stays down. Each dial itself times out after 20s.
  public nonisolated static func defaultReconnectDelay(attempt: Int) -> TimeInterval {
    attempt < 4 ? TimeInterval(attempt) : 5
  }

  /// The link dropped (transport says the host is unreachable or stopped
  /// answering, not that the configuration is wrong). With a reconnect
  /// factory: schedule the next dial. Without: a failure, as before.
  private func transportConnectionLost(_ message: String) {
    guard !didCloseTransport else { return }
    guard canReconnect else {
      transportTerminated(message)
      return
    }
    lossMessage = message
    scheduleReconnect()
  }

  /// Dials again right away: from a scheduled reconnect (skipping the
  /// wait), a final failure (the user fixed what was wrong: password, host
  /// key) or an ended shell. No-op while the session is live or closed.
  public func reconnectNow() {
    guard canReconnect, !didCloseTransport else { return }
    switch connectionState {
    case .starting, .connecting, .connected:
      return
    case .reconnecting, .failed, .closed:
      reconnectTimer?.invalidate()
      reconnectTimer = nil
      reconnectAttempt += 1
      showReconnecting()
      dial()
    }
  }

  private func scheduleReconnect() {
    reconnectAttempt += 1
    showReconnecting()
    reconnectTimer?.invalidate()
    let delay = reconnectDelay(reconnectAttempt)
    // `Timer(fire:…)`: swift-corelibs-foundation's `Timer(timeInterval:…)` fires at once instead of after the delay.
    let timer = Timer(fire: Date(timeIntervalSinceNow: delay), interval: 0, repeats: false) { [weak self] _ in
      DispatchQueue.main.async { self?.dial() }
    }
    RunLoop.main.add(timer, forMode: .common)
    reconnectTimer = timer
  }

  private func showReconnecting() {
    connectionState = .reconnecting(attempt: reconnectAttempt)
    var lines: [String] = []
    if let lossMessage { lines.append("Connection lost: \(lossMessage)") }
    lines.append("\(startupMessage ?? "Reconnecting…") (attempt \(reconnectAttempt))")
    snapshot = TerminalSnapshot(message: lines.joined(separator: "\n\n"))
    snapshotUpdateHandler?(snapshot)
  }

  /// Replaces the dead transport with a fresh one and starts it. The old
  /// one is closed first (its engine thread, socket); its callbacks are
  /// already orphaned by `wire`'s identity check.
  private func dial() {
    guard !didCloseTransport, let makeReconnectTransport else { return }
    reconnectTimer = nil
    transport.close()
    let fresh = makeReconnectTransport()
    transport = fresh
    wire(fresh)
    fresh.start()
  }

  private func transportExited(_ code: Int32) {
    actionExitCode = code
    connectionState = .closed
    // Keep the final output on screen (the parser holds the last state).
    // Force: the exit can be the only change (e.g. `exit` after output).
    publishNow(force: true)
    exitHandler?(code)
    actionCompletionHandler?()
  }

  // MARK: - Submitted command capture

  private func beginInputIfNeeded() {
    guard inputAnchor == nil else { return }
    inputAnchor = TerminalCursor(
      row: snapshot.scrollback.count + snapshot.cursor.row,
      column: snapshot.cursor.column
    )
  }

  private func recordUserInput(
    _ bytes: Data,
    characters: String?,
    charactersIgnoringModifiers: String?,
    keyCode: UInt16,
    modifierFlags: TerminalModifierFlags
  ) {
    beginInputIfNeeded()
    if !transport.echoesInput { inputHidden = true }

    if modifierFlags.contains(.control) {
      switch charactersIgnoringModifiers?.lowercased() {
      case "c", "u":
        inputFallback = ""
        if charactersIgnoringModifiers?.lowercased() == "c" {
          inputAnchor = nil
          inputHidden = false
        }
      case "w":
        while inputFallback.last?.isWhitespace == true { inputFallback.removeLast() }
        while inputFallback.last?.isWhitespace == false { inputFallback.removeLast() }
      case "k":
        break
      default:
        break
      }
      return
    }

    switch keyCode {
    case 51: // backspace
      if !inputFallback.isEmpty { inputFallback.removeLast() }
    case 117: // forward delete; rendered snapshot is the reliable source
      break
    case 123, 124, 125, 126, 115, 119, 116, 121, 48, 53:
      break
    default:
      if let characters, !characters.isEmpty {
        inputFallback.append(characters)
      } else if let text = String(data: bytes, encoding: .utf8) {
        inputFallback.append(text)
      }
    }
  }

  private func submitCapturedCommand() {
    defer {
      inputAnchor = nil
      inputFallback = ""
      inputHidden = false
    }

    let rendered: String
    if let inputAnchor {
      let cursorLine = snapshot.scrollback.count + snapshot.cursor.row
      let end = TerminalCursor(
        row: cursorLine,
        column: max(inputAnchor.column, snapshot.cursor.column - 1)
      )
      rendered = snapshot.plainText(logicalFrom: inputAnchor, to: end)
    } else {
      rendered = ""
    }

    // Nothing echoed: either the echo hasn't been published yet (fast typing
    // over a slow link), so the typed keys stand in, or the input was hidden
    // (a password), which must never reach history or the actions list.
    var hidden = inputHidden || !transport.echoesInput
    if let inputAnchor, inputAnchor.column > 0 {
      let prompt = snapshot.plainText(
        logicalFrom: TerminalCursor(row: inputAnchor.row, column: 0),
        to: TerminalCursor(row: inputAnchor.row, column: inputAnchor.column - 1)
      )
      hidden = hidden || Self.looksLikeSecretPrompt(prompt)
    }
    let command = rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (hidden ? "" : inputFallback)
      : rendered
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalized.isEmpty {
      commandSubmittedHandler?(normalized)
    }
  }

  /// Whether the text before the input reads like a prompt for a secret
  /// ("Password:", "[sudo] password for v57:", "Enter passphrase for key
  /// '…':", "Enter PIN:"). Covers SSH sessions, whose echo state is remote.
  static func looksLikeSecretPrompt(_ prompt: String) -> Bool {
    let text = prompt.trimmingCharacters(in: .whitespaces).lowercased()
    guard text.hasSuffix(":") || text.hasSuffix("?") else { return false }
    return text.range(
      of: #"\b(password|passphrase|passcode|pin|otp|token|secret|verification code)\b"#,
      options: .regularExpression
    ) != nil
  }
}

// MARK: - Local pty preset init

#if os(macOS) || os(Windows)
public extension TerminalSession {
  /// Short form for local terminals: `TerminalSession(session: .zsh)` for
  /// an interactive login shell, `.screen(name)` to attach to a GNU screen
  /// session. tmux needs unwrapping (`LocalPTYTransport.tmux(name)` is nil
  /// when tmux isn't installed). Equivalent to
  /// `TerminalSession(transport: LocalPTYTransport(...))`. macOS and Windows
  /// (ConPTY) — local ptys don't exist on iOS.
  convenience init(session transport: LocalPTYTransport, startupMessage: String? = nil) {
    self.init(transport: transport, startupMessage: startupMessage)
  }
}
#endif
