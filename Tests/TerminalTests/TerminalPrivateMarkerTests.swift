import Foundation
import Testing
@testable import Terminal

/// Regression tests for CSI sequences that carry a private marker (? > < =).
///
/// Those are distinct sequences that only share a final byte with a plain
/// one. The parser used to dispatch them by final byte alone, so Claude
/// Code's startup kitty-keyboard query `CSI ? u` ran as SCORC (restore
/// cursor): the cursor jumped back to where its launch `ESC 7` had saved it
/// (the row under the shell prompt), and every later relative redraw of the
/// trust dialog's menu landed on the dialog's top rows instead of the menu.
struct TerminalPrivateMarkerTests {
  private func parser(columns: Int = 40, rows: Int = 12) -> TerminalOutputParser {
    let p = TerminalOutputParser(sendResponse: { _ in })
    p.resize(columns: columns, rows: rows)
    return p
  }

  /// The shape of what Claude Code's trust dialog emits (captured through a
  /// pty, trimmed): save cursor + reset region + restore, a few lines of
  /// content, the menu, then the cursor moved up into the menu and the
  /// terminal queries (XTVERSION, kitty keyboard, DA1). Pressing ↓ redraws
  /// the menu with relative moves only.
  @Test func kittyKeyboardQueryDoesNotRestoreTheCursor() {
    let p = parser()
    p.consume(Data("~ claude\r\n".utf8))
    var initial = "\u{1b}7\u{1b}[r\u{1b}8\u{1b}[?25l\u{1b}[?2004h\r\r\n"
    initial += "header\r\r\n\r\r\n"
    initial += "\u{1b}[2G>\u{1b}[4GNo\r\r\n"
    initial += "\u{1b}[4GYes\r\r\n\r\r\n"
    initial += "\u{1b}[2Gfooter\r\r\n"
    initial += "\u{1b}[1C\u{1b}[4A\u{1b}[>0q\u{1b}[?u\u{1b}[c"
    p.consume(Data(initial.utf8))
    #expect(p.snapshot().cursor == TerminalCursor(row: 4, column: 1))

    var down = "\u{1b}[1D\u{1b}[4B\r\u{1b}[1C\u{1b}[4A \u{1b}[4GNo"
    down += "\r\u{1b}[1C\u{1b}[1B> Yes\r\r\n\r\n\r\n\u{1b}[1C\u{1b}[3A"
    p.consume(Data(down.utf8))

    let s = p.snapshot()
    #expect(s.lineText(line: 0) == "~ claude")
    #expect(s.lineText(line: 2) == "header")
    #expect(s.lineText(line: 4) == "   No")
    #expect(s.lineText(line: 5) == " > Yes")
    #expect(s.lineText(line: 7) == " footer")
  }

  @Test func kittyPushAndPopLeaveTheCursorAlone() {
    let p = parser()
    p.consume(Data("\u{1b}7ab\r\nc".utf8))
    p.consume(Data("\u{1b}[>1u\u{1b}[<u\u{1b}[=1;1u".utf8))
    #expect(p.snapshot().cursor == TerminalCursor(row: 1, column: 1))
  }

  @Test func modifyOtherKeysIsNotSGR() {
    let p = parser()
    p.consume(Data("\u{1b}[>4;2m\u{1b}[>4mx".utf8))
    let cell = p.snapshot().cell(atRow: 0, column: 0)
    #expect(cell.character == "x")
    #expect(!cell.underline)
    #expect(!cell.dim)
  }

  @Test func xtsaveAndXtrestoreDoNotTouchCursorOrRegion() {
    let p = parser()
    p.consume(Data("ab\r\ncd".utf8))
    p.consume(Data("\u{1b}[?1049s\u{1b}[?1049r".utf8))
    #expect(p.snapshot().cursor == TerminalCursor(row: 1, column: 2))
    // The scroll region is still the whole screen: a line feed from the
    // bottom row scrolls rather than sticking.
    p.consume(Data("\u{1b}[12;1H\nz".utf8))
    let s = p.snapshot()
    #expect(s.scrollback.count == 1)
    #expect(s.lineText(line: s.totalLines - 1) == "z")
  }

  @Test func plainSaveRestoreStillWorks() {
    let p = parser()
    p.consume(Data("ab\u{1b}[s\r\ncd\u{1b}[u!".utf8))
    #expect(p.snapshot().lineText(line: 0) == "ab!")
  }
}
