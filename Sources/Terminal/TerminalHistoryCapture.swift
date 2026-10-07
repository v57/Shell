import Foundation

/// Plain-text transcript of a session's output for the history archive,
/// built incrementally from published snapshots. `output` is everything that
/// has left the screen — lines scrolled off, screens erased by a clear,
/// full-screen-app screens switched away from — followed by the current
/// screen. The left-the-screen part is append-only, so it outlives the
/// scrollback limit, clears (`clear`, Ctrl-L, RIS, Cmd+K) and alt-screen
/// switches.
public struct TerminalHistoryCapture {
  /// Text that has left the screen. Append-only.
  private var committed = ""
  /// Whether `committed` holds any line (a lone blank line is "").
  private var hasCommitted = false
  /// The active screen's text not already in `committed`, replaced per
  /// capture (it is only one screen, and cursors rewrite its lines in
  /// place — line deltas would miss live updates like ping's status line).
  private var screen = ""
  /// A status message (startup, connection failure) the session shows
  /// instead of the grid. Kept after the transcript until real output
  /// replaces it, so a failed session's archive ends with the reason.
  private var message: String?
  /// Lines below these ordinals (`TerminalSnapshot.scrolledLineCount`
  /// numbering) are already in `committed`. The main and alternate screens
  /// number their lines independently.
  private var mainCapturedLines = Int.min
  private var alternateCapturedLines = Int.min
  private var onAlternateScreen: Bool
  /// The snapshot epoch the screen text was captured against: a change on
  /// the same screen means it was cleared.
  private var epoch: Int

  public init(seed: TerminalSnapshot) {
    onAlternateScreen = seed.usesAlternateScreen
    epoch = seed.selectionEpoch
    capture(seed)
  }

  public var output: String {
    var parts: [String] = []
    if hasCommitted { parts.append(committed) }
    if !screen.isEmpty { parts.append(screen) }
    if let message { parts.append(message) }
    return parts.joined(separator: "\n")
  }

  public mutating func capture(_ snapshot: TerminalSnapshot) {
    if let text = snapshot.message {
      // Not grid content (and not the parser's epoch): leave the capture
      // state alone — the parser, and its line numbering, live on.
      message = text
      return
    }
    message = nil

    if snapshot.usesAlternateScreen != onAlternateScreen {
      // Screen switch: the old screen leaves the view, so commit it. The
      // main screen comes back intact on exit (1049), so its committed
      // lines are marked captured and are not repeated when they reappear
      // or later scroll off. The alternate screen is reset on every entry,
      // so its line ordinals get reused and are left unmarked.
      let lines = Self.lineCount(screen)
      commit(screen.isEmpty ? nil : screen)
      if !onAlternateScreen { mainCapturedLines += lines }
      screen = ""
      onAlternateScreen = snapshot.usesAlternateScreen
      epoch = snapshot.selectionEpoch
    }

    var capturedLines = onAlternateScreen ? alternateCapturedLines : mainCapturedLines
    let completed = snapshot.completedLineCount
    if snapshot.selectionEpoch != epoch {
      // Same-screen clear (ED 2, Ctrl-L, RIS, Cmd+K, CSI 3 J): commit the
      // old screen's lines that are gone; lines still showing unchanged at
      // the same position (CSI 3 J leaves the whole screen, Cmd+K the
      // prompt) stay in the screen segment.
      let vanished = Self.vanishedLines(
        of: screen,
        comparedWith: Self.screenText(of: snapshot, capturedLines: capturedLines)
      )
      if let vanished {
        commit(vanished)
        // The erased rows get reused with the same ordinals: lines marked
        // captured past the seam (main-screen lines committed at an
        // alt-screen switch) no longer exist.
        capturedLines = min(capturedLines, completed)
      }
      epoch = snapshot.selectionEpoch
    }
    // Convert only the lines completed since the last capture (the
    // O(scrollback) full-text rebuild per output chunk was the CPU
    // amplifier that made history capture cost grow with session age).
    // Ordinals keep counting once the scrollback is full, so lines
    // scrolling off at the limit are still caught.
    if capturedLines < completed {
      let from = snapshot.firstLine(ofOrdinal: capturedLines)
      if from < snapshot.gridTextStart {
        commit(snapshot.scrollbackText(after: from))
      }
      capturedLines = completed
    }
    screen = Self.screenText(of: snapshot, capturedLines: capturedLines)

    if onAlternateScreen {
      alternateCapturedLines = capturedLines
    } else {
      mainCapturedLines = capturedLines
    }
  }

  private mutating func commit(_ text: String?) {
    guard let text else { return }
    committed += hasCommitted ? "\n" + text : text
    hasCommitted = true
  }

  /// The screen text not yet committed: the grid segment, or — when lines
  /// past the seam are already captured (a taller window pulled them back,
  /// or they were committed at an alt-screen switch) — only the rest.
  private static func screenText(of snapshot: TerminalSnapshot, capturedLines: Int) -> String {
    guard capturedLines > snapshot.completedLineCount else { return snapshot.gridText }
    return snapshot.plainText(fromLine: snapshot.firstLine(ofOrdinal: capturedLines))
  }

  private static func lineCount(_ text: String) -> Int {
    text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
  }

  /// The lines of `old` up to the last one that `new` does not show
  /// unchanged at the same position, or nil when every line is still there.
  private static func vanishedLines(of old: String, comparedWith new: String) -> String? {
    guard !old.isEmpty else { return nil }
    let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)
    let newLines = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false)
    guard let last = oldLines.indices.last(where: {
      $0 >= newLines.count || newLines[$0] != oldLines[$0]
    }) else { return nil }
    return oldLines[...last].joined(separator: "\n")
  }
}
