#if os(macOS)
import AppKit
import Darwin
#else
import UIKit
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
    case failed(String)
    case closed
  }

  public let id = UUID()

  /// Optional user-given name shown in the sidebar; nil = default name.
  public var customName: String?

  public var snapshot = TerminalSnapshot()
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
  /// Lines scrolled up from the bottom of the scrollback (0 = at bottom).
  /// Owned by the view; stored here so copy actions can see it.
  public var scrollbackOffset = 0

  /// How many non-empty lines from the bottom the sidebar status shows
  /// (0 = the last non-empty line, the automatic default). Set by
  /// clicking the last character of a line: the clicked line becomes
  /// the status by its rank, so it follows output as lines scroll.
  public var statusRank = 0

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
  private let transport: any TerminalTransport
  @ObservationIgnored
  private lazy var parser = TerminalOutputParser(sendResponse: { [weak self] response in
    self?.send(response)
  })
  @ObservationIgnored
  private var inputAnchor: TerminalCursor?
  @ObservationIgnored
  private var inputFallback = ""
  @ObservationIgnored
  private var didCloseTransport = false

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

  /// Creates a session over `transport` and starts it immediately.
  /// `startupMessage` is shown while connecting (SSH: "Connecting to
  /// host…"); nil starts in `.starting` (local pty).
  public init(transport: any TerminalTransport, startupMessage: String? = nil) {
    self.transport = transport
    if let startupMessage {
      connectionState = .connecting(startupMessage)
      snapshot = TerminalSnapshot(message: startupMessage)
    }
    transport.onOutput = { [weak self] data in
      self?.receiveOutput(data)
    }
    transport.onConnected = { [weak self] in
      self?.transportConnected()
    }
    transport.onTerminated = { [weak self] message in
      self?.transportTerminated(message)
    }
    transport.onExit = { [weak self] code in
      self?.transportExited(code)
    }
    transport.onHostKeyPrompt = { [weak self] prompt in
      self?.hostKeyPrompt = prompt
    }
    transport.onPasswordPrompt = { [weak self] prompt in
      self?.passwordPrompt = prompt
    }
    transport.start()
    // The initial grid is visible immediately (no pty output may ever
    // arrive before the view appears). Force: it is the first publish.
    publishNow(force: true)
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
    publishTimer?.invalidate()
    publishTimer = nil
    pendingPublish = false
    transport.close()
  }

  public func send(_ string: String) {
    send(Data(string.utf8))
  }

  public func send(_ data: Data) {
    transport.write(data)
  }

  public func resize(columns: Int, rows: Int) {
    guard columns > 0, rows > 0 else { return }

    parser.resize(columns: columns, rows: rows)
    if connectionState == .connected {
      // Interactive: publish immediately so the reflow is visible now
      // (force: the reflow can be pure cursor/geometry change).
      publishNow(force: true)
    }
    transport.resize(columns: columns, rows: rows)
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

  /// Cmd+K "clean stdout": erase the scrollback and every row except the
  /// cursor's (the current prompt line survives), drop any selection, and
  /// publish the refreshed snapshot. Local-only — nothing is sent to the
  /// shell, so its line editor keeps the cursor exactly where it was.
  public func clearStdout() {
    parser.clearStdout()
    selectionStart = nil
    selectionEnd = nil
    scrollbackOffset = 0
    // Force: the epoch bump + scrollback wipe must reach the view now.
    publishNow()
  }

  public func paste(_ string: String) {
    guard !string.isEmpty else { return }

    beginInputIfNeeded()
    inputFallback.append(
      string.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    )

    if parser.bracketedPasteEnabled {
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
    #else
    UIPasteboard.general.string = text
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
    #else
    UIPasteboard.general.string = text
    #endif
  }

  private func pasteFromPasteboard() {
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    if let string = pasteboard.string(forType: .string) {
      paste(string)
    }
    #else
    if let string = UIPasteboard.general.string {
      paste(string)
    }
    #endif
  }

  /// Pins a line as the sidebar status by its rank from the bottom
  /// (0 = the last non-empty line); clicking the line that is already
  /// the status returns to automatic (rank 0).
  public func toggleStatusPin(_ line: Int) {
    guard let rank = snapshot.nonEmptyRank(fromBottomOf: line) else { return }
    statusRank = (rank == statusRank) ? 0 : rank
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
    parser.consume(data)
    schedulePublish()
  }

  /// Coalesces bulk output into at most one publish per `publishInterval`
  /// (10fps). Cheap per chunk: just marks pending and ensures the timer
  /// is armed. Interactive paths call `flushPendingOutput()` directly.
  private func schedulePublish() {
    guard !pendingPublish else { return }
    pendingPublish = true
    if publishTimer == nil {
      let timer = Timer(timeInterval: Self.publishInterval, repeats: true) { [weak self] _ in
        self?.publishNow()
      }
      RunLoop.main.add(timer, forMode: .common)
      publishTimer = timer
    }
  }

  /// Publishes the latest parser state immediately if something is
  /// pending. Interactive paths (typing, resize, clear, connect/exit) and
  /// tests call this directly; the timer calls it on each tick.
  public func flushPendingOutput() {
    guard pendingPublish else { return }
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

    let newSnapshot = parser.snapshot()  // consumes the dirty set
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

  private func transportConnected() {
    connectionState = .connected
    // Force: clears the startup message even if the grid pixels match.
    publishNow(force: true)
  }

  private func transportTerminated(_ message: String) {
    connectionState = .failed(message)
    snapshot = TerminalSnapshot(message: message)
    snapshotUpdateHandler?(snapshot)
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

    if modifierFlags.contains(.control) {
      switch charactersIgnoringModifiers?.lowercased() {
      case "c", "u":
        inputFallback = ""
        if charactersIgnoringModifiers?.lowercased() == "c" { inputAnchor = nil }
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

    let command = rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? inputFallback
      : rendered
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalized.isEmpty {
      commandSubmittedHandler?(normalized)
    }
  }
}

// MARK: - Local pty preset init

#if os(macOS)
public extension TerminalSession {
  /// Short form for local terminals: `TerminalSession(session: .zsh)` for
  /// an interactive login shell, `.screen(name)` to attach to a GNU screen
  /// session. tmux needs unwrapping (`LocalPTYTransport.tmux(name)` is nil
  /// when tmux isn't installed). Equivalent to
  /// `TerminalSession(transport: LocalPTYTransport(...))`. macOS only —
  /// local ptys (forkpty) don't exist on iOS.
  convenience init(session transport: LocalPTYTransport, startupMessage: String? = nil) {
    self.init(transport: transport, startupMessage: startupMessage)
  }
}
#endif
