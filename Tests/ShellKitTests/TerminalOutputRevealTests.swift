import Foundation
import Testing
@testable import ShellKit

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
    // and only "world" types — its first 2 characters already on the same
    // frame the update lands.
    #expect(r.pending[0] == TerminalOutputReveal.PendingLine(cursor: 8, to: 11))
    for c in 0..<8 { #expect(r.isShown(line: 0, column: c)) }
    #expect(!r.isShown(line: 0, column: 8))
    #expect(!r.isShown(line: 0, column: 10))
  }

  @Test func typingAtLineStartShowsShiftedTextAtOnce() {
    // "hello" -> "XXXhello": only the insertion types; the shifted "hello"
    // shows immediately instead of blanking and re-typing per keystroke. The
    // insertion's first 2 characters show on the same frame.
    let r = reveal(from: "hello", to: "\rXXXhello")
    #expect(r.pending[0] == TerminalOutputReveal.PendingLine(cursor: 2, to: 3))
    #expect(r.isShown(line: 0, column: 0))
    #expect(r.isShown(line: 0, column: 1))
    #expect(!r.isShown(line: 0, column: 2))
    for c in 3..<8 { #expect(r.isShown(line: 0, column: c)) }
  }

  @Test func midLineInsertionTypesOnlyTheInsertion() {
    let r = reveal(from: "abcd", to: "\rabXYZcd")
    #expect(r.pending[0] == TerminalOutputReveal.PendingLine(cursor: 4, to: 5))
    #expect(r.isShown(line: 0, column: 0))
    #expect(r.isShown(line: 0, column: 1))
    #expect(r.isShown(line: 0, column: 2))
    #expect(r.isShown(line: 0, column: 3))
    #expect(!r.isShown(line: 0, column: 4))
    #expect(r.isShown(line: 0, column: 5))
    #expect(r.isShown(line: 0, column: 6))
  }

  @Test func tinyRewriteShowsAtOnce() {
    // A rewrite of 2 or fewer characters never blanks: it shows on the same
    // frame (a spinner tick, a progress digit), so percentages don't flicker.
    #expect(reveal(from: "abcd", to: "\rabXYcd").pending.isEmpty)
    #expect(reveal(from: "hello", to: "\rXhello").pending.isEmpty)
  }

  @Test func changedTextKeepsOldCharactersUntilTypedOver() {
    // "status: idle" -> "status: running": the changed middle keeps showing
    // the old text (never blanks) and is overwritten left to right; columns
    // past the old text start blank.
    let r = reveal(from: "status: idle", to: "\rstatus: running")
    #expect(r.pending[0] == TerminalOutputReveal.PendingLine(cursor: 10, to: 15))
    #expect(r.replacedCell(line: 0, column: 9) == nil) // typed on the same frame
    #expect(r.replacedCell(line: 0, column: 10)?.character == "l")
    #expect(r.replacedCell(line: 0, column: 11)?.character == "e")
    #expect(r.replacedCell(line: 0, column: 12)?.isBlank == true)
    #expect(r.replacedCell(line: 0, column: 0) == nil)
  }

  @Test func rewriteOfStillTypingLineKeepsItsOldCharacters() {
    // A line rewritten again before it finished typing keeps showing what was
    // on screen — the first update's OLD text, not its never-shown target.
    let p = parser()
    p.consume(Data("count: aaaaaaaa".utf8))
    let r = TerminalOutputReveal()
    r.snap(to: p.snapshot())
    p.consume(Data("\rcount: bbbbbbbb".utf8))
    r.update(to: p.snapshot(), animate: true)
    p.consume(Data("\rcount: cccccccc".utf8))
    r.update(to: p.snapshot(), animate: true)
    let hidden = (0..<20).filter { !r.isShown(line: 0, column: $0) }
    #expect(!hidden.isEmpty)
    for c in hidden { #expect(r.replacedCell(line: 0, column: c)?.character == "a") }
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
    // The spinner tick shows on the same frame (tiny rewrites never blank).
    #expect(r.isShown(line: 0, column: 0))
    // Unchanged text between the edits stays shown ...
    #expect(r.isShown(line: 0, column: 2)) // the "B" of "Bottle"
    #expect(r.isShown(line: 0, column: 10))
    // ... including the shared tail.
    #expect(r.isShown(line: 0, column: 118))
    // Only the disjoint edits hide, minus the 2 characters revealed with the
    // update: most of the grown bar (7) plus the changed digits (2) — far
    // less than the ~80 columns the single middle hid.
    let hidden = (0..<120).filter { !r.isShown(line: 0, column: $0) }.count
    #expect(hidden == 9)
  }
}
