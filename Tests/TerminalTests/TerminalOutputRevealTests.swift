import Foundation
import Testing
@testable import Terminal

/// Regression tests for the output reveal's changed-middle diffing. The
/// reveal diffs each line as common PREFIX + common SUFFIX (by character,
/// ignoring attributes), so only the changed middle types out while the
/// unchanged prefix and the (possibly shifted) suffix show at once.
@MainActor
struct TerminalOutputRevealTests {
  private func parser() -> TerminalOutputParser {
    let p = TerminalOutputParser(sendResponse: { _ in })
    p.resize(columns: 20, rows: 5)
    return p
  }

  private func reveal(from old: String, to new: String) -> TerminalOutputReveal {
    let p = parser()
    p.consume(Data(old.utf8))
    let r = TerminalOutputReveal()
    r.snap(to: p.snapshot())
    p.consume(Data(new.utf8))
    r.update(to: p.snapshot(), animate: true)
    return r
  }

  @Test func appendedTailTypesOnlyTheTail() {
    let r = reveal(from: "hello", to: " world")
    // Column 5 is a space in both (blank-equivalent), so the prefix covers it
    // and only "world" types.
    #expect(r.pending[0] == TerminalOutputReveal.PendingLine(cursor: 6, to: 11))
    for c in 0..<6 { #expect(r.isShown(line: 0, column: c)) }
    #expect(!r.isShown(line: 0, column: 6))
    #expect(!r.isShown(line: 0, column: 10))
  }

  @Test func typingAtLineStartShowsShiftedTextAtOnce() {
    // "hello" -> "Xhello": only the inserted "X" types; the shifted "hello"
    // shows immediately instead of blanking and re-typing per keystroke.
    let r = reveal(from: "hello", to: "\rXhello")
    #expect(r.pending[0] == TerminalOutputReveal.PendingLine(cursor: 0, to: 1))
    #expect(!r.isShown(line: 0, column: 0))
    for c in 1..<6 { #expect(r.isShown(line: 0, column: c)) }
  }

  @Test func midLineInsertionTypesOnlyTheInsertion() {
    let r = reveal(from: "abcd", to: "\rabXYcd")
    #expect(r.pending[0] == TerminalOutputReveal.PendingLine(cursor: 2, to: 4))
    #expect(r.isShown(line: 0, column: 0))
    #expect(r.isShown(line: 0, column: 1))
    #expect(!r.isShown(line: 0, column: 2))
    #expect(!r.isShown(line: 0, column: 3))
    #expect(r.isShown(line: 0, column: 4))
    #expect(r.isShown(line: 0, column: 5))
  }

  @Test func pureRecolorSettlesInstantly() {
    let r = reveal(from: "hello", to: "\r\u{1B}[1mhello\u{1B}[m")
    #expect(r.pending.isEmpty)
  }

  @Test func leadingDeletionSnapsWithoutTyping() {
    // "Xhello" -> "hello": the surviving text is a pure suffix shift, so the
    // changed middle is empty and nothing types.
    let r = reveal(from: "Xhello", to: "\rhello\u{1B}[K")
    #expect(r.pending.isEmpty)
  }

  @Test func progressRepaintTypesOnlyChangedHunks() {
    // A brew-style in-place repaint (`\r` overwrite): a spinner tick at column
    // 0 must not retype the whole line — only the spinner, the grown bar, and
    // the changed digits hide. The old single prefix+suffix middle hid
    // everything up to the shared `MB/  3.9MB` tail.
    let old = "⠞ Bottle harfbuzz (14.6.0)            #########################            Downloading   2.8MB/  3.9MB"
    let new = "\r⠙ Bottle harfbuzz (14.6.0)            #################################    Downloading   3.6MB/  3.9MB"
    let p = TerminalOutputParser(sendResponse: { _ in })
    p.resize(columns: 130, rows: 5)
    p.consume(Data(old.utf8))
    let r = TerminalOutputReveal()
    r.snap(to: p.snapshot())
    p.consume(Data(new.utf8))
    r.update(to: p.snapshot(), animate: true)
    // The spinner tick hides.
    #expect(!r.isShown(line: 0, column: 0))
    // Unchanged text between the edits stays shown ...
    #expect(r.isShown(line: 0, column: 2)) // the "B" of "Bottle"
    #expect(r.isShown(line: 0, column: 10))
    // ... including the shared tail.
    #expect(r.isShown(line: 0, column: 118))
    // Only the disjoint edits hide: spinner (1) + grown bar (8) + changed
    // digits (2) — far less than the ~80 columns the single middle hid.
    let hidden = (0..<120).filter { !r.isShown(line: 0, column: $0) }.count
    #expect(hidden == 11)
  }
}
