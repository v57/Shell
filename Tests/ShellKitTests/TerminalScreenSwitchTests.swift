import Foundation
import Testing
@testable import ShellKit

/// The cursor stays on the grid across alternate-screen switches, resizes and
/// scroll regions. On iPhone, htop quit with F10 after the special-keys bar's
/// arrows and Fn rows had opened (the screen lost rows while htop ran) crashed
/// Shell: leaving the alternate screen restored the main screen's cursor saved
/// on the taller screen, and the next character indexed `rowWrapped` past its
/// last row (Issues S-002).
struct TerminalScreenSwitchTests {
  private func parser(columns: Int = 40, rows: Int = 24) -> TerminalOutputParser {
    let p = TerminalOutputParser(sendResponse: { _ in })
    p.resize(columns: columns, rows: rows)
    return p
  }

  private func feed(_ p: TerminalOutputParser, _ text: String) {
    p.consume(Data(text.utf8))
  }

  private func rowText(_ s: TerminalSnapshot, _ r: Int) -> String {
    var t = ""
    for c in 0..<s.columns { t.append(s.cell(atRow: r, column: c).character) }
    return t.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
  }

  /// The sequence htop and the shell sent: a prompt on the last row, htop
  /// entering the alternate screen (1049 saves the cursor), the screen getting
  /// shorter, htop drawing and leaving (F10), the shell printing its prompt.
  @Test func quittingHtopAfterTheScreenShrankKeepsTheCursorOnTheGrid() {
    let p = parser()
    for i in 1...23 { feed(p, "line \(i)\r\n") }
    feed(p, "alpine:~$ htop\r\n")
    feed(p, "\u{1b}[?1049h\u{1b}[22;0;0t\u{1b}[1;24r\u{1b}[H\u{1b}[2J")
    feed(p, "  0[|||   5.0%]\r\n  1[||    3.1%]\r\n")
    // The arrows and Fn rows open: 24 rows become 15.
    p.resize(columns: 40, rows: 15)
    feed(p, "\u{1b}[1;15r\u{1b}[H\u{1b}[2J  0[|||   5.0%]\r\n  1[||    3.1%]")
    feed(p, "\u{1b}[15;1HF1Help  F10Quit")
    // F10: htop restores the main screen and the shell prints its prompt.
    feed(p, "\u{1b}[?1l\u{1b}>\u{1b}[r\u{1b}[?1049l\u{1b}[23;0;0t")
    feed(p, "alpine:~$ ")

    let s = p.snapshot()
    #expect(s.rows == 15)
    #expect(s.cursor.row >= 0 && s.cursor.row < s.rows)
    #expect(rowText(s, s.cursor.row) == "alpine:~$")
    // The prompt follows the line htop was started from.
    #expect(rowText(s, s.cursor.row - 1) == "alpine:~$ htop")
  }

  @Test func restoringACursorSavedOnATallerScreenClampsIt() {
    let p = parser(columns: 20, rows: 10)
    feed(p, "\u{1b}[?1049h\u{1b}[10;20H\u{1b}7")
    p.resize(columns: 10, rows: 4)
    feed(p, "\u{1b}8xyz")
    let s = p.snapshot()
    #expect(s.cursor.row < 4)
    #expect(s.cursor.column < 10)
  }

  @Test func theAlternateScreenCropsInsteadOfReflowing() {
    let p = parser(columns: 20, rows: 6)
    feed(p, "\u{1b}[?1049h\u{1b}[H")
    feed(p, "CPU 0 [|||||   12%]\r\nCPU 1 [||       4%]\r\nMem")
    p.resize(columns: 10, rows: 4)
    let s = p.snapshot()
    // No re-wrapped rows pushed into a scrollback above the program's screen.
    #expect(s.scrollback.isEmpty)
    #expect(rowText(s, 0) == "CPU 0 [|||")
    #expect(rowText(s, 1) == "CPU 1 [||")
    #expect(rowText(s, 2) == "Mem")
  }

  @Test func aScrollRegionBelowTheScreenIsIgnored() {
    let p = parser(columns: 10, rows: 5)
    // Rows 30-40 on a 5-row screen, then a reverse index and a character.
    feed(p, "\u{1b}[30;40r\u{1b}Mx\u{1b}[5;1H\u{1b}My")
    let s = p.snapshot()
    #expect(s.cursor.row < 5)
    #expect(rowText(s, 3) == "y")
  }

  @Test func aLineFeedBelowTheRegionStopsAtTheLastRow() {
    let p = parser(columns: 10, rows: 5)
    feed(p, "top\u{1b}[1;3r\u{1b}[5;1Hlast\n\n\nX")
    let s = p.snapshot()
    #expect(s.cursor.row == 4)
    // The region (rows 1-3) didn't scroll.
    #expect(rowText(s, 0) == "top")
    #expect(rowText(s, 4).hasSuffix("X"))
  }
}
