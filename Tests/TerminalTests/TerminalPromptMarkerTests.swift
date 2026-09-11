import Foundation
import Testing
@testable import Terminal

/// Regression tests for the pty-width/grid-width invariant.
///
/// zsh's `preprompt` (PROMPT_SP + PROMPT_CR, both on by default) prints a
/// bold+standout `%` marker at the cursor, pads spaces to the last column,
/// then sends a CR and one space to erase the marker again. That erase only
/// lands on the marker when the padding stays on the row the marker was
/// written on — i.e. when the grid is exactly as wide as the pty the child is
/// writing for. A grid NARROWER than the pty wraps the padding onto the next
/// row, the erase space lands there, and the `%` is stranded on the first
/// screen:
///
///      %
///      ~
///
/// That is what the launch-time default terminal showed. Its session (and pty)
/// are created in `AppModel.init`, before its view exists, so zsh's first
/// prompt is emitted before the view's first layout can resize the pty: the
/// grid was still at its 80x24 default while the pty was at its 200x24 spawn
/// size. A terminal opened later (⌘T) lays out and resizes well inside zsh's
/// ~400ms startup, so it never showed the stray marker.
///
/// The fix is the invariant these tests pin: a transport declares the size it
/// starts its child at (`TerminalTransport.initialGridSize`) and
/// `TerminalSession.init` seeds the parser grid with it.
struct TerminalPromptMarkerTests {
  /// The bytes zsh actually emits before its first prompt on a pty `columns`
  /// wide (captured from `/bin/zsh -l -i`): marker, `columns - 1` padding
  /// spaces, CR, erase space, CR, reset + erase-to-end-of-screen, prompt,
  /// bracketed paste on.
  private func zshFirstPrompt(columns: Int, prompt: String = "~ ") -> Data {
    var text = "\u{1b}[1m\u{1b}[7m%\u{1b}[27m\u{1b}[1m\u{1b}[0m"
    text += String(repeating: " ", count: columns - 1)
    text += "\r \r\r"
    text += "\u{1b}[0m\u{1b}[27m\u{1b}[24m\u{1b}[J"
    text += "\u{1b}[1m\u{1b}[38;5;143m" + prompt + "\u{1b}[39m\u{1b}[0m\u{1b}[K\u{1b}[?2004h"
    return Data(text.utf8)
  }

  @Test @MainActor func markerIsErasedWhenTheGridMatchesThePtyWidth() {
    let spawn = LocalPTYTransport.spawnSize
    let p = TerminalOutputParser(sendResponse: { _ in })
    // Both at the local pty's spawn size — the invariant the session
    // establishes before the first byte can arrive.
    p.resize(columns: spawn.columns, rows: spawn.rows)
    p.consume(zshFirstPrompt(columns: spawn.columns))

    let s = p.snapshot()
    #expect(s.lineText(line: 0) == "~")
    #expect(s.cursor.row == 0)
    #expect(s.scrollback.isEmpty)
    for line in 0..<s.totalLines {
      #expect(!s.lineText(line: line).contains("%"))
    }
  }

  /// The failure mode itself: the same bytes parsed on a grid narrower than
  /// the pty strand the marker. Pinned so a regression in grid sizing or
  /// wrap handling fails loudly rather than silently reintroducing the stray
  /// `%` line.
  @Test @MainActor func markerIsStrandedWhenTheGridIsNarrowerThanThePty() {
    let p = TerminalOutputParser(sendResponse: { _ in })   // default 24x80 grid
    p.consume(zshFirstPrompt(columns: LocalPTYTransport.spawnSize.columns))

    let s = p.snapshot()
    #expect(s.lineText(line: 0) == "%")   // the stray marker line
    #expect(s.lineText(line: 2) == "~")   // prompt pushed two rows down
  }

  @Test @MainActor func sessionSeedsItsGridFromTheTransportsStartSize() {
    let transport = StartSizeStubTransport(initialGridSize: TerminalGridSize(rows: 24, columns: 200))
    let session = TerminalSession(transport: transport)
    defer { session.close() }

    #expect(session.snapshot.columns == 200)
    #expect(session.snapshot.rows == 24)
  }

  @Test @MainActor func localPtyDeclaresAWideStartSizeMatchingItsWinsize() {
    // The winsize the pty is forked with and the declared start size must be
    // the SAME value: the child sees the former, the parser is seeded from
    // the latter.
    #expect(LocalPTYTransport.zsh.initialGridSize == LocalPTYTransport.spawnSize)
    #expect(LocalPTYTransport.spawnSize.columns > 80)
  }

  /// Shrinking (the first layout resize of the default terminal: 200 -> the
  /// real width). The child must be narrowed BEFORE the grid: a child that
  /// has not picked up the new width yet can still emit output laid out for
  /// the old one, and if the grid has already shrunk that output wraps a row
  /// early — stranding the `%` marker. Observed from inside the transport's
  /// own `resize`, which is called at exactly that moment.
  @Test @MainActor func shrinkNarrowsTheChildWhileTheGridIsStillWide() {
    let transport = StartSizeStubTransport(initialGridSize: LocalPTYTransport.spawnSize)
    let session = TerminalSession(transport: transport)
    defer { session.close() }

    var gridWidthWhenChildResized: Int?
    transport.onResize = { [weak session] in
      guard let session else { return }
      // Publish the parser's CURRENT grid so the test can read its width at
      // the instant the child was resized.
      session.flushPendingOutput()
      gridWidthWhenChildResized = session.snapshot.columns
    }
    // Output the child produced while it was still 200 columns wide.
    transport.inject(zshFirstPrompt(columns: LocalPTYTransport.spawnSize.columns))
    session.resize(columns: 100, rows: 30)

    #expect(gridWidthWhenChildResized == 200)   // child narrowed first
    let s = session.snapshot
    #expect(s.columns == 100)
    for line in 0..<s.totalLines {
      #expect(!s.lineText(line: line).contains("%"))
    }
  }

  /// Growing: the grid widens FIRST, so the child's not-yet-updated narrow
  /// output is never parsed at a width it was not laid out for either.
  @Test @MainActor func growWidensTheGridBeforeTheChild() {
    let transport = StartSizeStubTransport(initialGridSize: TerminalGridSize(rows: 24, columns: 100))
    let session = TerminalSession(transport: transport)
    defer { session.close() }

    var gridWidthWhenChildResized: Int?
    transport.onResize = { [weak session] in
      guard let session else { return }
      session.flushPendingOutput()
      gridWidthWhenChildResized = session.snapshot.columns
    }
    transport.inject(zshFirstPrompt(columns: 100))
    session.resize(columns: 200, rows: 30)

    #expect(gridWidthWhenChildResized == 200)   // grid widened first
  }
}

/// Minimal transport: records when the CHILD is resized (via `onResize`) so a
/// test can observe the session's grid/child resize ordering, and lets the
/// test inject child output.
@MainActor
private final class StartSizeStubTransport: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?
  let initialGridSize: TerminalGridSize
  /// Called from `resize`, i.e. the moment the child would be resized.
  var onResize: (() -> Void)?

  init(initialGridSize: TerminalGridSize) {
    self.initialGridSize = initialGridSize
  }

  func inject(_ data: Data) { onOutput?(data) }
  func start() { onConnected?() }   // drives the session to `.connected`
  func write(_ data: Data) {}
  func resize(columns: Int, rows: Int) { onResize?() }
  func close() {}
}
