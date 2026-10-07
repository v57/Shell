import Testing
import Foundation
@testable import Terminal

/// Parser regression tests — the byte state machine that turns raw pty/SSH
/// output into the grid model. Run with `swift test`.
struct TerminalParserTests {
  private func parser(_ onResponse: @escaping (String) -> Void = { _ in }) -> TerminalOutputParser {
    TerminalOutputParser(sendResponse: onResponse)
  }

  @Test func plainTextEcho() {
    let p = parser()
    p.consume(Data("hello world".utf8))
    // plainText is the full 24-row buffer; the first line carries the text.
    #expect(p.snapshot().plainText.hasPrefix("hello world"))
  }

  @Test func cursorPositioning() {
    let p = parser()
    p.consume(Data("A\u{1b}[5;10HB".utf8))
    let s = p.snapshot()
    // CUP is 1-based: row 5, column 10 -> index (4, 9); writing "B" there
    // advanced the cursor one column.
    #expect(s.cursor == TerminalCursor(row: 4, column: 10))
    #expect(s.cell(atRow: 4, column: 9).character == "B")
    #expect(s.cell(atRow: 0, column: 0).character == "A")
  }

  @Test func sgrAttributes() {
    let p = parser()
    p.consume(Data("\u{1b}[1;31mX\u{1b}[38;5;196mY\u{1b}[38;2;1;2;3mZ".utf8))
    let s = p.snapshot()
    let x = s.cell(atRow: 0, column: 0)
    #expect(x.character == "X")
    #expect(x.bold)
    #expect(x.foreground == .ansi(1))
    let y = s.cell(atRow: 0, column: 1)
    #expect(y.foreground == .ansi(196))
    let expectedRGB = TerminalColor.rgb(red: 1.0 / 255, green: 2.0 / 255, blue: 3.0 / 255)
    let z = s.cell(atRow: 0, column: 2)
    #expect(z.foreground == expectedRGB)
  }

  @Test func alternateScreen1049() {
    let p = parser()
    p.consume(Data("hi\u{1b}[?1049hA\u{1b}[?1049l".utf8))
    let s = p.snapshot()
    // Main grid restored after 1049 exit ("A" was written on the alt
    // screen); the saved main cursor (after "hi") is restored.
    #expect(s.plainText.hasPrefix("hi"))
    #expect(s.cursor == TerminalCursor(row: 0, column: 2))
  }

  @Test func scrollbackGrowsOnLineFeed() {
    let p = parser()
    p.consume(Data("line\u{1b}[1;1H".utf8))
    p.consume(Data(String(repeating: "\n", count: 25).utf8))
    let s = p.snapshot()
    // 24-row grid: 24 LFs move to the bottom, the 25th scrolls a row out.
    #expect(s.scrollback.count == 2)
    #expect(s.totalLines == 26)
    #expect(s.maxOffset == 2)
    // Scrollback keeps the "line" text row at the top.
    #expect(s.cell(atLine: 0, column: 0).character == "l")
  }

  @Test func eraseScrollbackCSI3J() {
    let p = parser()
    p.consume(Data(("x\u{1b}[1;1H" + String(repeating: "\n", count: 25)).utf8))
    #expect(p.snapshot().scrollback.count == 2)
    p.consume(Data("\u{1b}[3J".utf8))
    let s = p.snapshot()
    #expect(s.scrollback.isEmpty)
    #expect(s.totalLines == s.rows)
  }

  @Test func cleanStdoutKeepsCurrentLine() {
    let p = parser()
    p.resize(columns: 20, rows: 3)
    // Output fills the screen, one LF scrolls "one" into the scrollback.
    p.consume(Data("one\ntwo\nthree".utf8))
    p.consume(Data("\n".utf8))
    // A fresh prompt on the bottom line (the cursor row).
    p.consume(Data("\rprompt$".utf8))
    let before = p.snapshot()
    #expect(before.scrollback.count == 1)
    #expect(before.cursor == TerminalCursor(row: 2, column: 7))

    p.clearStdout()

    let s = p.snapshot()
    // Scrollback wiped, the prompt line survives, the rest is blank.
    #expect(s.scrollback.isEmpty)
    #expect(s.cell(atRow: 2, column: 0).character == "p")
    #expect(s.cell(atRow: 0, column: 0).character == " ")
    #expect(s.cell(atRow: 1, column: 0).character == " ")
    // Cursor stays where the shell's line editor thinks it is.
    #expect(s.cursor == before.cursor)
    // Content was wholesale invalidated: stale selections are dropped.
    #expect(s.selectionEpoch == before.selectionEpoch + 1)
  }

  @Test func deviceAttributesResponse() {
    var responses: [String] = []
    let p = parser { responses.append($0) }
    p.consume(Data("\u{1b}[c".utf8))
    #expect(responses == ["\u{1b}[?1;2c"])
  }

  @Test func utf8Multibyte() {
    let p = parser()
    // "é" (C3 A9) and "中" (E4 B8 AD) written byte by byte.
    p.consume(Data([0xC3, 0xA9, 0xE4, 0xB8, 0xAD]))
    let s = p.snapshot()
    #expect(s.cell(atRow: 0, column: 0).character == "é")
    #expect(s.cell(atRow: 0, column: 1).character == "中")
  }

  @Test func crCancelsPendingWrap() {
    let p = parser()
    p.resize(columns: 5, rows: 3)
    // "12345" fills the last column and defers the wrap; CR cancels it,
    // so "A" overwrites column 0 instead of wrapping to row 1.
    p.consume(Data("12345\rA".utf8))
    let s = p.snapshot()
    #expect(s.cell(atRow: 0, column: 0).character == "A")
    #expect(s.cursor == TerminalCursor(row: 0, column: 1))
  }

  @Test func deferredWrapOnNextPrintable() {
    let p = parser()
    p.resize(columns: 5, rows: 3)
    p.consume(Data("12345X".utf8))
    let s = p.snapshot()
    #expect(s.cell(atRow: 0, column: 4).character == "5")
    #expect(s.cell(atRow: 1, column: 0).character == "X")
  }

  @Test func bracketedPasteMode() {
    let p = parser()
    p.consume(Data("\u{1b}[?2004h".utf8))
    #expect(p.bracketedPasteEnabled)
    p.consume(Data("\u{1b}[?2004l".utf8))
    #expect(!p.bracketedPasteEnabled)
  }

  @Test func dirtyLinesTrackedAcrossMutations() {
    let p = parser()
    p.resize(columns: 10, rows: 5)
    var s = p.snapshot()
    // A resize dirties every row (the whole grid reflows).
    #expect(s.dirtyLines.count == 5)
    // The snapshot consumed the set: a no-op read reports nothing dirty.
    s = p.snapshot()
    #expect(s.dirtyLines.isEmpty)

    // Writing "abc" dirties row 0; LF moves the cursor without painting.
    p.consume(Data("abc\n".utf8))
    s = p.snapshot()
    #expect(s.dirtyLines == [0])

    // Writing on row 1 dirties only row 1.
    p.consume(Data("x".utf8))
    s = p.snapshot()
    #expect(s.dirtyLines == [1])

    // ED 2 (clearScreen) dirties every row.
    p.consume(Data("\u{1b}[2J".utf8))
    s = p.snapshot()
    #expect(s.dirtyLines.count == 5)

    // The snapshot consumed the set: a no-op read reports nothing dirty.
    s = p.snapshot()
    #expect(s.dirtyLines.isEmpty)
  }

  @Test func historyCaptureComposesIncrementally() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    // Seed: the full text at capture start.
    p.consume(Data("one\n".utf8))
    let seed = p.snapshot()
    var capturedScrollback = seed.scrollback.count

    // Output that scrolls "one" into the scrollback and writes a new
    // grid.
    p.consume(Data("two\nthree\nfour\n".utf8))
    let snapshot = p.snapshot()

    // The incremental composition (new scrollback rows + current grid)
    // must equal a full rebuild of the SAME snapshot — the invariant the
    // history capture relies on.
    let newScrollback = snapshot.scrollbackText(after: capturedScrollback)
    let grid = snapshot.gridText
    var composed = newScrollback
    if !grid.isEmpty {
      if !composed.isEmpty { composed += "\n" }
      composed += grid
    }
    #expect(composed == snapshot.fullPlainText)
    #expect(snapshot.scrollback.count >= capturedScrollback)
    capturedScrollback = snapshot.scrollback.count
    // A later capture with nothing new appends nothing.
    let later = p.snapshot()
    #expect(later.scrollbackText(after: capturedScrollback).isEmpty)
  }

  @Test func historyCaptureSeesLinesScrolledOffAtTheLimit() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    let limit = TerminalGrid.scrollbackLimit
    // limit + 3 rows scroll off, so the scrollback is full and trimmed.
    let filler = (0..<(limit + 5)).map { "\($0)\r\n" }.joined()
    p.consume(Data(filler.utf8))
    let full = p.snapshot()
    #expect(full.scrollback.count == limit)
    let captured = full.completedLineCount
    #expect(captured == limit + 3)

    // Three more rows scroll off; scrollback.count stays at the limit, the
    // line ordinals keep counting.
    p.consume(Data("x\r\ny\r\nz\r\n".utf8))
    let later = p.snapshot()
    #expect(later.scrollback.count == limit)
    #expect(later.completedLineCount == captured + 3)
    let from = later.firstLine(ofOrdinal: captured)
    #expect(later.scrollbackText(after: from) == "\(limit + 3)\n\(limit + 4)\nx")
    #expect(later.gridText == "y\nz")
  }

  @Test func historyCaptureKeepsAClearedScreen() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    p.consume(Data("old\r\n$ clear\r\n".utf8))
    var capture = TerminalHistoryCapture(seed: p.snapshot())
    p.consume(Data("\u{1b}[H\u{1b}[2J$ ls\r\nnew".utf8))
    capture.capture(p.snapshot())
    #expect(capture.output == "old\n$ clear\n$ ls\nnew")
  }

  @Test func historyCaptureKeepsCapturedTextWhenScrollbackIsErased() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    p.consume(Data("a\r\nb\r\nc\r\nd\r\ne".utf8))
    var capture = TerminalHistoryCapture(seed: p.snapshot())
    // CSI 3 J erases only the scrollback: nothing is lost or repeated.
    p.consume(Data("\u{1b}[3J".utf8))
    capture.capture(p.snapshot())
    #expect(capture.output == "a\nb\nc\nd\ne")
    // RIS wipes everything; the transcript keeps it.
    p.consume(Data("\u{1b}c$".utf8))
    capture.capture(p.snapshot())
    #expect(capture.output == "a\nb\nc\nd\ne\n$")
  }

  @Test func historyCaptureCleanStdoutKeepsErasedRowsOnce() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    p.consume(Data("out\r\n$ ".utf8))
    var capture = TerminalHistoryCapture(seed: p.snapshot())
    p.clearStdout()
    capture.capture(p.snapshot())
    // "out" is committed; the kept prompt line is not repeated.
    #expect(capture.output == "out\n\n$")
  }

  @Test func historyCaptureSpansAlternateScreenRoundTrip() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    p.consume(Data("x\r\n$ vim\r\n".utf8))
    var capture = TerminalHistoryCapture(seed: p.snapshot())
    p.consume(Data("\u{1b}[?1049hVIM".utf8))
    capture.capture(p.snapshot())
    #expect(capture.output == "x\n$ vim\nVIM")

    // Leaving restores the main screen: its lines are not repeated, neither
    // on screen nor when they later scroll off.
    p.consume(Data("\u{1b}[?1049l$".utf8))
    capture.capture(p.snapshot())
    #expect(capture.output == "x\n$ vim\nVIM\n$")
    p.consume(Data("\r\nl1\r\nl2\r\nl3".utf8))
    capture.capture(p.snapshot())
    #expect(capture.output == "x\n$ vim\nVIM\n$\nl1\nl2\nl3")
  }

  @Test func historyCaptureKeepsOutputWhenTheSessionFails() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    p.consume(Data("a\r\n\u{1b}[2Jb".utf8))   // epoch > 0 (ED 2 homes the cursor)
    var capture = TerminalHistoryCapture(seed: TerminalSnapshot(message: "Starting…"))
    capture.capture(p.snapshot())
    #expect(capture.output == "b")
    capture.capture(TerminalSnapshot(message: "Connection lost"))
    #expect(capture.output == "b\nConnection lost")
  }

  @Test func historyLineOrdinalsSurviveResizeReflow() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    // "a" x15 wraps into two rows; a, b, c end up in the scrollback.
    p.consume(Data("\(String(repeating: "a", count: 15))\r\nb\r\nc\r\nd\r\ne\r\n".utf8))
    let before = p.snapshot()
    #expect(before.completedLineCount == 3)
    #expect(before.lineText(line: before.firstLine(ofOrdinal: 1)) == "b")

    // Narrower: "a" re-wraps into three rows, but every line keeps its
    // ordinal.
    p.resize(columns: 5, rows: 3)
    let after = p.snapshot()
    #expect(after.completedLineCount == 3)
    #expect(after.lineText(line: after.firstLine(ofOrdinal: 1)) == "b")
    #expect(after.scrollbackText(after: after.firstLine(ofOrdinal: 0))
      == "\(String(repeating: "a", count: 15))\nb\nc")
  }

  @Test func regionScrollRespectsDECSTBM() {
    let p = parser()
    p.resize(columns: 10, rows: 5)
    // Scrolling region rows 2..4 (1-based): LF at the bottom scrolls only
    // the region, and the line above the region is untouched.
    p.consume(Data("\u{1b}[2;4r\u{1b}[3;1Habc\u{1b}[4;1Hdef".utf8))
    p.consume(Data(String(repeating: "\n", count: 3).utf8))
    let s = p.snapshot()
    // The line above the region (row 0) never moved; no scrollback recorded.
    #expect(s.cell(atRow: 0, column: 0).character == " ")
    #expect(s.scrollback.isEmpty)
  }

  @Test func sshConfigIgnoresRemovedLegacyFields() throws {
    // Configs saved while `useSensitiveKey` existed carry that key; the
    // synthesized decoder must ignore unknown keys (pitfall: a custom
    // decoder that throws keyNotFound empties the whole list).
    let json = """
    [{"id":"6D28B4C5-2F7A-4E3B-9C1D-0A5B8E6F2C41","name":"box","host":"example.com","user":"me","port":22,"authMethod":"keychainKey","savePassword":true,"useSensitiveKey":true}]
    """
    let configs = try JSONDecoder().decode([SSHConfig].self, from: Data(json.utf8))
    #expect(configs.count == 1)
    #expect(configs[0].host == "example.com")
    #expect(configs[0].displayName == "box")
  }

  @Test func fullPlainTextUsesScrollbackButAlternateScreenResetsIt() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    p.consume(Data("first\r\nsecond\r\nthird\r\nfourth".utf8))
    #expect(p.snapshot().fullPlainText.contains("first"))
    #expect(p.snapshot().fullPlainText.contains("fourth"))

    p.consume(Data("\u{1b}[?1049hcurrent".utf8))
    #expect(p.snapshot().fullPlainText == "current")
  }

  @MainActor
  @Test func terminalSessionCapturesUserCommandsButNotParserResponses() {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)
    var commands: [String] = []
    session.commandSubmittedHandler = { commands.append($0) }

    for character in ["e", "c", "h", "o", " ", "h", "i"] {
      session.handleKey(
        characters: character,
        charactersIgnoringModifiers: character,
        keyCode: 0,
        modifierFlags: []
      )
    }
    session.handleKey(
      characters: "\r",
      charactersIgnoringModifiers: "\r",
      keyCode: 36,
      modifierFlags: []
    )
    #expect(commands == ["echo hi"])

    transport.injectOutput(Data("\u{1b}[c".utf8))
    #expect(commands == ["echo hi"])
    session.submitCommand("pwd")
    #expect(commands == ["echo hi", "pwd"])
  }

  @MainActor
  @Test func terminalSessionCloseStopsTransportImmediatelyAndOnlyOnce() {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)

    session.close()
    session.close()

    #expect(transport.closeCount == 1)
  }

  @MainActor
  @Test func terminalSessionReportsGeneralTransportExit() {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)
    var exitCodes: [Int32] = []
    session.exitHandler = { exitCodes.append($0) }

    transport.injectExit(7)

    #expect(exitCodes == [7])
    #expect(session.connectionState == .closed)
  }

  @MainActor
  @Test func clearStdoutSendsCtrlLToChildAndWipesScrollback() {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)
    // Fill the grid + scrollback so there's something to clear. The flush
    // settles the background parse queue first (real usage: output has
    // rendered before Cmd+K); otherwise queued pre-clear bytes are parsed
    // AFTER the wipe and repopulate the scrollback, making the assertion
    // below timing-dependent.
    transport.injectOutput(Data((0..<40).map { "line\($0)\n" }.joined().utf8))
    session.flushPendingOutput()
    #expect(!session.snapshot.scrollback.isEmpty)  // precondition: content to clear

    session.clearStdout()

    // The shell-sync part: Cmd+K sends Ctrl-L to the child, so zsh's own
    // line editor clears the screen and redraws the prompt at the TOP
    // (cursor stays in sync). Terminal-side clears can't do this.
    #expect(transport.writes.contains(Data([0x0c])))
    // The safety-net part: the scrollback is wiped locally for programs
    // that ignore ^L.
    #expect(session.snapshot.scrollback.isEmpty)
  }

  @Test func localPTYReadSourceStopsAfterEOF() async throws {
    let transport = LocalPTYTransport(
      executable: "/bin/sh",
      argv: ["sh", "-c", "exit 0"]
    )
    let events = LockedCounter()
    transport.onReadEventForTesting = { events.increment() }
    defer { transport.close() }

    transport.start()
    try await Task.sleep(for: .milliseconds(250))
    let countAfterExit = events.value
    try await Task.sleep(for: .milliseconds(100))

    #expect(countAfterExit > 0)
    #expect(events.value == countAfterExit)
  }

  /// The session reads the child's cwd live from the OS: a local shell
  /// spawned in the home directory reports it without any shell
  /// cooperation (no `pwd` round-trip).
  @MainActor
  @Test func currentDirectoryReportsLocalChildCwd() async throws {
    let transport = LocalPTYTransport(
      executable: "/bin/sh",
      argv: ["sh", "-c", "sleep 30"]
    )
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    try await Task.sleep(for: .milliseconds(250))

    #expect(session.currentDirectory?.path == URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path)
  }

  /// The working-directory transport (⌘T) spawns the child in the given
  /// directory, not the home directory. Verified live via proc_pidinfo.
  @MainActor
  @Test func workingDirectoryStartsChildInThatDirectory() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("hermes-cwd-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let transport = LocalPTYTransport(
      executable: "/bin/sh",
      argv: ["sh", "-c", "sleep 30"],
      workingDirectory: dir.path
    )
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    try await Task.sleep(for: .milliseconds(250))

    // proc_pidinfo returns the symlink/firmlink-resolved path (e.g. /var →
    // /private/var). Foundation's resolvingSymlinksInPath does NOT follow
    // macOS firmlinks, so resolve with realpath (what the kernel does).
    var expected = dir.path
    if let resolved = realpath(dir.path, nil) {
      expected = String(cString: resolved)
      free(resolved)
    }
    #expect(session.currentDirectory?.path == expected)
  }

  /// Non-local transports (SSH, test doubles) have no child process to
  /// probe — currentDirectory stays nil.
  @MainActor
  @Test func currentDirectoryIsNilWithoutChildProcess() {
    let session = TerminalSession(transport: CapturingTransport())
    #expect(session.currentDirectory == nil)
  }
}

// MARK: - Selection hit-testing (content-space mapping)

/// Regression for "cursor selects the line below the targeted line (around
/// after half a line) — only when the session is scrollable and scrolled to
/// the bottom": the old mapping was `anchorLine + floor(localY / lineHeight)`,
/// which assumes grid row 0 sits at the viewport's top. The grid is
/// `rows * lineHeight` tall while the viewport is `rows * lineHeight + r`
/// tall (r = H mod lineHeight), so scrolled to the bottom the grid sits r px
/// BELOW the viewport top; clicks in the lower part of every line then land
/// on the NEXT line. The fix maps through the scroll CONTENT offset, where
/// logical line L spans content y [L*lh, (L+1)*lh) at any scroll position.
struct SelectionHitTestingTests {
  @Test func bottomHitTestIsExact() {
    let lh: CGFloat = 17
    let viewportHeight: CGFloat = 24 * lh + 8   // r = 8 (~half a line)
    let totalLines = 30
    let contentHeight = CGFloat(totalLines) * lh
    // Scrolled to the bottom: the content's top edge sits at -(content - viewport).
    let bottomOffset = -(contentHeight - viewportHeight)

    // Grid row 0 (logical line 6) spans viewport y [8, 25). A click in its
    // LOWER half (y = 20) must hit line 6 — the old mapping gave line 7.
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: bottomOffset, localY: 20, lineHeight: lh, totalLines: totalLines) == 6)
    // The scrollback sliver peeking in above the grid (y = 4) is line 5,
    // not the grid's first line.
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: bottomOffset, localY: 4, lineHeight: lh, totalLines: totalLines) == 5)
    // Bottom of the viewport: the last line.
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: bottomOffset, localY: viewportHeight - 1, lineHeight: lh, totalLines: totalLines) == 29)
  }

  @Test func scrolledUpOneLineStaysExact() {
    let lh: CGFloat = 17
    let viewportHeight: CGFloat = 24 * lh + 8
    let totalLines = 30
    let contentHeight = CGFloat(totalLines) * lh
    // One line above the bottom: the content slid DOWN one line.
    let oneLineUp = -(contentHeight - viewportHeight) + lh

    // y = 20 now shows line 5 (its row spans viewport y [8, 25)).
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: oneLineUp, localY: 20, lineHeight: lh, totalLines: totalLines) == 5)
    // The last line (29) has scrolled off; the last visible is 28.
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: oneLineUp, localY: viewportHeight - 8, lineHeight: lh, totalLines: totalLines) == 28)
  }

  @Test func exactMultipleViewportHeightIsUnaffected() {
    let lh: CGFloat = 17
    let viewportHeight: CGFloat = 24 * lh           // r = 0
    let totalLines = 30
    let bottomOffset = -(CGFloat(totalLines) * lh - viewportHeight)

    // Grid row 0 (line 6) spans viewport y [0, 17); y = 20 is row 1 = line 7.
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: bottomOffset, localY: 20, lineHeight: lh, totalLines: totalLines) == 7)
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: bottomOffset, localY: 0, lineHeight: lh, totalLines: totalLines) == 6)
  }

  @Test func clampsToContentBounds() {
    // Dragging past the top/bottom still maps to the first/last line.
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: 0, localY: -50, lineHeight: 17, totalLines: 10) == 0)
    #expect(TerminalScreenView.SelectionModifier.logicalLine(contentOffset: -500, localY: 500, lineHeight: 17, totalLines: 10) == 9)
  }
}

/// Which cells the drag selection highlights, given the anchor (`start`) and
/// the live drag endpoint (`end`). Regression coverage for the down-left /
/// up-right bug: the highlight was anchored by min/max of the two columns,
/// so dragging down-left jumped the top row's left edge to the drag column
/// and pinned the bottom row's right edge to the anchor's column — moving
/// the "start" left and the "end" to the initial x. The highlight must anchor
/// by the endpoint sitting on each row, matching plainText(logicalFrom:to:).
struct CellSelectionTests {
  // anchor on an upper row at col 20, drag down-left to col 5 on a lower row.
  @Test func downLeftDragAnchorsByRow() {
    let start = TerminalCursor(row: 5, column: 20)
    let end = TerminalCursor(row: 8, column: 5)
    // Top row: highlight starts at the anchor column, NOT the drag column.
    #expect(isCellSelected(line: 5, column: 19, start: start, end: end) == false)
    #expect(isCellSelected(line: 5, column: 20, start: start, end: end) == true)
    #expect(isCellSelected(line: 5, column: 79, start: start, end: end) == true)
    // Middle rows are fully selected.
    #expect(isCellSelected(line: 6, column: 0, start: start, end: end) == true)
    #expect(isCellSelected(line: 7, column: 79, start: start, end: end) == true)
    // Bottom row: highlight ends at the drag column, NOT the anchor column.
    #expect(isCellSelected(line: 8, column: 5, start: start, end: end) == true)
    #expect(isCellSelected(line: 8, column: 6, start: start, end: end) == false)
    // Rows outside the span are not selected.
    #expect(isCellSelected(line: 4, column: 20, start: start, end: end) == false)
    #expect(isCellSelected(line: 9, column: 5, start: start, end: end) == false)
  }

  // mirror case: anchor on a lower row at col 5, drag up-right to col 20.
  @Test func upRightDragAnchorsByRow() {
    let start = TerminalCursor(row: 8, column: 5)
    let end = TerminalCursor(row: 5, column: 20)
    #expect(isCellSelected(line: 5, column: 19, start: start, end: end) == false)
    #expect(isCellSelected(line: 5, column: 20, start: start, end: end) == true)
    #expect(isCellSelected(line: 6, column: 0, start: start, end: end) == true)
    #expect(isCellSelected(line: 8, column: 5, start: start, end: end) == true)
    #expect(isCellSelected(line: 8, column: 6, start: start, end: end) == false)
  }

  // end on the same row as start: a plain column range of the two columns.
  @Test func sameRowSelectsColumnRange() {
    let start = TerminalCursor(row: 3, column: 5)
    let end = TerminalCursor(row: 3, column: 9)
    #expect(isCellSelected(line: 3, column: 4, start: start, end: end) == false)
    #expect(isCellSelected(line: 3, column: 5, start: start, end: end) == true)
    #expect(isCellSelected(line: 3, column: 9, start: start, end: end) == true)
    #expect(isCellSelected(line: 3, column: 10, start: start, end: end) == false)
  }

  // dragging straight down at the same column: the top row starts at the
  // anchor column (nothing left of it), and the bottom row ends at the drag
  // column. Bottom row's left side (0..drag column) is selected.
  @Test func straightDownTopRowStartsAtAnchorColumn() {
    let start = TerminalCursor(row: 0, column: 7)
    let end = TerminalCursor(row: 2, column: 7)
    #expect(isCellSelected(line: 0, column: 7, start: start, end: end) == true)
    #expect(isCellSelected(line: 0, column: 8, start: start, end: end) == true) // extends right of anchor on top row
    #expect(isCellSelected(line: 0, column: 6, start: start, end: end) == false) // nothing left of the anchor on top row
    #expect(isCellSelected(line: 2, column: 7, start: start, end: end) == true) // ends at drag column
    #expect(isCellSelected(line: 2, column: 6, start: start, end: end) == true) // left of drag column is selected
    #expect(isCellSelected(line: 2, column: 8, start: start, end: end) == false) // past drag column not selected
  }

  // No selection (nil endpoints) selects nothing.
  @Test func nilEndpointsSelectNothing() {
    #expect(isCellSelected(line: 3, column: 0, start: nil, end: nil) == false)
  }
}

/// The sidebar-status pin: clicking a character shows the line FROM that
/// character (offset mode) or the whole line (full-line mode). The mode is
/// sticky across line changes; you only switch it on the currently observed
/// line. Dragging selects. Tests establish a starting state then exercise
/// one click.
struct StatusPinTests {
  private func fixture() -> (session: TerminalSession, snapshot: TerminalSnapshot) {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)
    transport.injectOutput(Data("line one\nline two\nline three\n".utf8))
    session.flushPendingOutput()
    return (session, session.snapshot)
  }

  /// In full-line mode, clicking a DIFFERENT line keeps it a full (whole)
  /// line — it does not switch to offset mode.
  @MainActor
  @Test func lineModeDifferentLineStaysWholeLine() {
    let (session, snapshot) = fixture()
    let top = snapshot.nonEmptyLineIndexFromBottom(2)!
    // Establish full-line mode observing the middle line (rank 1).
    session.statusRank = 1
    session.statusPinned = true
    session.statusStartMarked = false
    session.statusStartColumn = 0
    let col = snapshot.firstNonBlankColumn(ofLine: top) + 1

    session.clickStatusPin(at: TerminalCursor(row: top, column: col))
    #expect(session.statusRank == 2)
    #expect(session.statusPinned == true)
    #expect(session.statusStartMarked == false)   // stays full-line
    #expect(snapshot.nonEmptyLineIndexFromBottom(session.statusRank) == top)
  }

  /// In full-line mode, clicking the CURRENTLY OBSERVED line switches to
  /// offset mode, anchored at the clicked character.
  @MainActor
  @Test func lineModeObservedLineEntersOffset() {
    let (session, snapshot) = fixture()
    let middle = snapshot.nonEmptyLineIndexFromBottom(1)!
    session.statusRank = 1
    session.statusPinned = true
    session.statusStartMarked = false
    session.statusStartColumn = 0
    let anchor = snapshot.firstNonBlankColumn(ofLine: middle) + 1

    session.clickStatusPin(at: TerminalCursor(row: middle, column: anchor))
    #expect(session.statusStartMarked == true)   // → offset mode
    #expect(session.statusStartColumn == anchor)
    #expect(session.statusRank == 1)
  }

  /// In offset mode, clicking a DIFFERENT line keeps offset mode and
  /// offsets that line from the clicked character.
  @MainActor
  @Test func offsetModeDifferentLineKeepsOffset() {
    let (session, snapshot) = fixture()
    let top = snapshot.nonEmptyLineIndexFromBottom(2)!
    session.statusRank = 1
    session.statusPinned = true
    session.statusStartMarked = true
    session.statusStartColumn = 9
    let col = snapshot.firstNonBlankColumn(ofLine: top) + 1

    session.clickStatusPin(at: TerminalCursor(row: top, column: col))
    #expect(session.statusRank == 2)
    #expect(session.statusStartMarked == true)    // offset persists
    #expect(session.statusStartColumn == col)
  }

  /// In offset mode, clicking a NON-start character of the observed line
  /// re-anchors the offset there.
  @MainActor
  @Test func offsetModeObservedLineNonStartReanchors() {
    let (session, snapshot) = fixture()
    let middle = snapshot.nonEmptyLineIndexFromBottom(1)!
    let first = snapshot.firstNonBlankColumn(ofLine: middle)
    let anchor = first + 1
    session.statusRank = 1
    session.statusPinned = true
    session.statusStartMarked = true
    session.statusStartColumn = anchor
    let reanchor = first + 5

    session.clickStatusPin(at: TerminalCursor(row: middle, column: reanchor))
    #expect(session.statusStartMarked == true)   // stays offset
    #expect(session.statusStartColumn == reanchor)
  }

  /// In offset mode, clicking the CURRENT start character returns to
  /// full-line mode (whole line), remembering the anchor.
  @MainActor
  @Test func offsetModeObservedStartCharReturnsToLineMode() {
    let (session, snapshot) = fixture()
    let middle = snapshot.nonEmptyLineIndexFromBottom(1)!
    let anchor = snapshot.firstNonBlankColumn(ofLine: middle) + 1
    session.statusRank = 1
    session.statusPinned = true
    session.statusStartMarked = true
    session.statusStartColumn = anchor

    session.clickStatusPin(at: TerminalCursor(row: middle, column: anchor))
    #expect(session.statusStartMarked == false)   // → full-line mode
    #expect(session.statusStartColumn == anchor)   // remembered
  }

  /// Clicking the auto (unpinned) observed line in full-line mode also
  /// enters offset mode (rank 0 line).
  @MainActor
  @Test func autoObservedLineEntersOffset() {
    let (session, snapshot) = fixture()
    let last = snapshot.nonEmptyLineIndexFromBottom(0)!
    // Auto state: rank 0, unpinned, full-line mode.
    #expect(session.statusRank == 0)
    #expect(session.statusPinned == false)
    #expect(session.statusStartMarked == false)
    let anchor = snapshot.firstNonBlankColumn(ofLine: last) + 1

    session.clickStatusPin(at: TerminalCursor(row: last, column: anchor))
    #expect(session.statusRank == 0)   // rank stays 0
    #expect(session.statusPinned == true)
    #expect(session.statusStartMarked == true)   // → offset mode
    #expect(session.statusStartColumn == anchor)
  }

  /// The click/drag rule: same cell = click (pin), any movement = drag.
  @Test func clickIsPinDragIsSelection() {
    let start = TerminalCursor(row: 10, column: 3)
    #expect(TerminalScreenView.SelectionModifier.isClick(start: start, end: TerminalCursor(row: 10, column: 3)))
    #expect(!TerminalScreenView.SelectionModifier.isClick(start: start, end: TerminalCursor(row: 10, column: 4)))
    #expect(!TerminalScreenView.SelectionModifier.isClick(start: start, end: TerminalCursor(row: 11, column: 3)))
    #expect(!TerminalScreenView.SelectionModifier.isClick(start: start, end: TerminalCursor(row: 9, column: 1)))
  }
}

/// Output-publishing coalescing: bulk pty chunks publish at most once per
/// 30fps window, no-op publishes (nothing VISIBLE changed) are skipped, and
/// interactive paths flush synchronously.
struct TerminalSessionCoalescingTests {
  @MainActor
  @Test func outputPublishingIsCoalesced() {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)
    var published = 0
    session.snapshotUpdateHandler = { _ in published += 1 }

    // Two chunks arrive before the 30fps timer fires: still zero publishes.
    transport.injectOutput(Data("hello\n".utf8))
    transport.injectOutput(Data("world\n".utf8))
    #expect(published == 0)

    // One explicit flush coalesces both into a single publish.
    session.flushPendingOutput()
    #expect(published == 1)
    #expect(session.snapshot.plainText.contains("hello"))
    #expect(session.snapshot.plainText.contains("world"))
  }

  @MainActor
  @Test func flushIsIdempotent() {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)
    var published = 0
    session.snapshotUpdateHandler = { _ in published += 1 }

    transport.injectOutput(Data("a".utf8))
    session.flushPendingOutput()
    session.flushPendingOutput()
    #expect(published == 1)
  }

  @MainActor
  @Test func cursorOnlyOutputSkipsPublish() {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)
    var published = 0
    session.snapshotUpdateHandler = { _ in published += 1 }
    transport.injectOutput(Data("x".utf8))
    session.flushPendingOutput()
    #expect(published == 1)   // the "x" published

    // A pure cursor-move sequence paints nothing: the dirty set is empty,
    // the cursor may move — but if the cursor is UNCHANGED after the move
    // (e.g. OSC/title-only bytes), the publish is skipped.
    transport.injectOutput(Data("\u{1b}]0;title\u{7}".utf8))
    session.flushPendingOutput()
    #expect(published == 1)   // skipped: nothing visible changed
  }

  @MainActor
  @Test func closeInvalidatesPublishTimer() async throws {
    let transport = CapturingTransport()
    let session = TerminalSession(transport: transport)
    var published = 0
    session.snapshotUpdateHandler = { _ in published += 1 }
    transport.injectOutput(Data("x\n".utf8))
    session.close()
    try await Task.sleep(for: .milliseconds(150))  // well past one 30fps tick
    #expect(published == 0)   // the timer never fired after close
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

@MainActor
private final class CapturingTransport: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?
  var writes: [Data] = []
  var closeCount = 0

  func start() { onConnected?() }

  func write(_ data: Data) {
    writes.append(data)
    // A real pty echoes printable user input. Avoid echoing terminal replies
    // (ESC-prefixed) so parser query responses cannot recurse in this fake.
    if data.first != 0x1b { onOutput?(data) }
  }

  func resize(columns: Int, rows: Int) {}
  func close() { closeCount += 1 }

  func injectOutput(_ data: Data) { onOutput?(data) }
  func injectExit(_ code: Int32) { onExit?(code) }
}
