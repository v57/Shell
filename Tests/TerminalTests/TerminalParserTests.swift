import Foundation
import Testing
@testable import Terminal

/// Regression tests for the terminal grid's soft-wrap handling. The terminal
/// stores PRE-WRAPPED physical rows (`gridWrapped`/`scrollbackWrapped` record
/// which rows are soft-wrap continuations of the row above). These tests pin
/// the two behaviours the flag enables:
///
/// 1. **Resize re-flow** — a long logical line that wrapped at a narrow width
///    must collapse back into fewer rows when the window widens, and expand
///    again when it narrows. The old raster-copy resize did NOT do this
///    (grid/Sources/Terminal.html `TerminalGrid.resize`).
/// 2. **Wrap-aware copy/history** — `snapshot.plainText*` must re-join a
///    wrapped line into ONE line (no spurious newline at the wrap point), but
///    must still split at a REAL newline.
struct TerminalGridWrapTests {
  private func parser() -> TerminalOutputParser {
    TerminalOutputParser(sendResponse: { _ in })
  }

  private func rowText(_ s: TerminalSnapshot, _ r: Int) -> String {
    var t = ""
    for c in 0..<s.columns { t.append(s.cell(atRow: r, column: c).character) }
    return t
  }

  @Test func resizeWideningReflowsWrappedLineToSingleRow() {
    let p = parser()
    p.resize(columns: 5, rows: 3)
    p.consume(Data("ABCDEF".utf8)) // 6 chars @ width 5 -> wraps to 2 rows
    var s = p.snapshot()
    #expect(s.scrollback.isEmpty)          // no phantom scrollback
    #expect(s.gridWrapped[1])              // row 1 is a wrap continuation
    #expect(rowText(s, 0) == "ABCDE")
    #expect(rowText(s, 1).hasPrefix("F"))

    p.resize(columns: 10, rows: 3)
    s = p.snapshot()
    #expect(s.scrollback.isEmpty)
    #expect(rowText(s, 0).hasPrefix("ABCDEF"))  // single row again
    #expect(!s.gridWrapped[1])
    #expect(!s.gridWrapped[2])
  }

  @Test func resizeNarrowingAgainWrapsTheLine() {
    let p = parser()
    p.resize(columns: 10, rows: 3)
    p.consume(Data("ABCDEFGHIJ".utf8)) // exactly 10: not wrapped, but wrap-pending
    var s = p.snapshot()
    #expect(!s.gridWrapped[1])

    p.resize(columns: 5, rows: 3)
    s = p.snapshot()
    #expect(s.gridWrapped[1])
    #expect(rowText(s, 1).hasPrefix("FGHIJ"))

    p.resize(columns: 10, rows: 3)
    s = p.snapshot()
    #expect(rowText(s, 0).hasPrefix("ABCDEFGHIJ"))
    #expect(!s.gridWrapped[1])
  }

  @Test func resizeNeverCreatesPhantomScrollbackFromBlankGrid() {
    // Resizing the default 24x80 blank grid down must not push blank filler
    // rows into the scrollback; a fresh terminal stays blank with no history.
    let p = parser()
    p.resize(columns: 5, rows: 3)
    let s = p.snapshot()
    #expect(s.scrollback.isEmpty)
    #expect(s.totalLines == s.rows)
    #expect(s.fullPlainText.isEmpty)
  }

  @Test func copyRejoinsWrappedLine() {
    let p = parser()
    p.resize(columns: 5, rows: 3)
    p.consume(Data("ABCDEF".utf8))
    let s = p.snapshot()
    let copied = s.plainText(offset: 0)
    #expect(!copied.contains("ABCDE\nF"))      // no newline at the wrap
    #expect(copied.contains("ABCDEF"))
  }

  @Test func selectionAcrossWrapRejoins() {
    let p = parser()
    p.resize(columns: 5, rows: 3)
    p.consume(Data("ABCDEF".utf8))
    let s = p.snapshot()
    let sel = s.plainText(logicalFrom: TerminalCursor(row: 0, column: 0),
                          to: TerminalCursor(row: 1, column: 5))
    #expect(sel == "ABCDEF")
  }

  @Test func realNewlineIsNotGlued() {
    let p = parser()
    p.resize(columns: 5, rows: 3)
    p.consume(Data("AB\r\nCD".utf8))
    let s = p.snapshot()
    #expect(!s.gridWrapped[1])               // CRLF made a genuine new line
    let copied = s.plainText(offset: 0)
    #expect(copied.contains("AB\n"))         // the real newline survives
  }

  @Test func fullPlainTextRoundTripsAcrossReflow() {
    let p = parser()
    p.resize(columns: 4, rows: 2)
    p.consume(Data("AAAAAAAA\r\nBBBBB\r\n".utf8))
    let before = p.snapshot().fullPlainText
    p.resize(columns: 10, rows: 2)
    let after = p.snapshot().fullPlainText
    #expect(after == before)
  }

  @Test func mixedLinesAndWrapPreserved() {
    let p = parser()
    p.resize(columns: 4, rows: 5)
    p.consume(Data("AAA\r\nBBBBCC\r\nDD".utf8))
    var s = p.snapshot()
    #expect(s.plainText(offset: 0).contains("BBBBCC"))  // glued, not BBBB\nCC
    p.resize(columns: 8, rows: 5)
    s = p.snapshot()
    let reflowed = s.plainText(offset: 0)
    #expect(reflowed.contains("AAA\nBBBBCC\nDD"))
    #expect(!reflowed.contains("BBBB\nCC"))
  }
}
