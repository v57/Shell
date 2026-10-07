import Foundation
import Observation

/// Types a terminal's new output out instead of showing it all at once.
///
/// Two buffers: the session publishes the TARGET snapshot; the view renders
/// `shown`, minus each still-typing line's hidden range (see `PendingLine`).
/// Each new target is diffed against the previous one line by line, by
/// CHARACTER only (attributes are ignored), as the cheaper of:
/// - column-aligned hunks (an in-place repaint: only the disjointly changed
///   columns type — a spinner tick no longer retypes the whole line), and
/// - a common PREFIX plus a common SUFFIX (a SHIFT: typing at the line's
///   start pushes the rest right, which column comparison misreads), so:
///
///  - an unchanged line, or an unchanged prefix, is never typed again (a
///    recolor — zsh's syntax highlighting repainting the command line on every
///    keystroke — shows at once rather than re-typing);
///  - only the CHANGED middle of a line is typed: text past the edit that
///    merely shifted (typing at the start of the line pushes the rest right,
///    a picker swapping its marker) is recognized by the suffix match and
///    shows at once, never blanking and re-typing;
///  - a line still typing that changes again keeps what it already showed.
///
/// Typing runs top line first (line by line), a few characters per frame, at a
/// speed that adapts to the backlog so everything lands within about
/// `framesToCatchUp` frames — a `cat` of a large file never falls behind.
///
/// Anything that isn't output being appended SNAPS to the target: the
/// alternate screen (vim, less, top repaint, they don't print), a resize, a
/// clear (selection epoch bump), a status message, and a scrollback trim it
/// can't line up.
@MainActor
@Observable
final class TerminalOutputReveal {
  /// One line's still-typing ranges: sorted non-overlapping half-open column
  /// spans that render blank and fill in left to right, top line first.
  /// Everything OUTSIDE those spans — unchanged text between disjoint edits
  /// (a spinner tick plus a grown progress bar plus a changed digit on one
  /// rewritten line) — renders at once, so unchanged text never blanks and
  /// re-types. A single contiguous edit stays a single span.
  struct PendingLine: Equatable {
    var spans: [Range<Int>]

    init(cursor: Int, to: Int) {
      spans = cursor < to ? [cursor..<to] : []
    }

    init(spans: [Range<Int>]) {
      self.spans = spans
    }

    /// Typing head: the first column still hidden (the single-span cursor).
    var cursor: Int { spans.first?.lowerBound ?? 0 }
    /// End of the hidden tail (the single-span end).
    var to: Int { spans.last?.upperBound ?? 0 }

    /// Columns still hidden.
    var hiddenCount: Int { spans.reduce(0) { $0 + $1.count } }
  }

  /// The snapshot the view renders: the latest target, with `pending` applied.
  private(set) var shown: TerminalSnapshot?
  /// Lines still typing (logical line → their hidden range). Absent = fully shown.
  private(set) var pending: [Int: PendingLine] = [:]
  @ObservationIgnored private var ticker: Task<Void, Never>?
  /// Frames left before the typing must have caught up with the output —
  /// reset by every update that brings new output, counted down per frame.
  @ObservationIgnored private var framesLeft = 0

  /// The longest typing takes to catch up with the output, in frames.
  static let framesToCatchUp = 18
  /// The slowest typing speed, in characters per frame (~120/s at 60 fps).
  static let minimumCharactersPerFrame = 2
  private static let frame = Duration.milliseconds(16)

  /// Whether `column` of `line` renders its cell already (false = still blank
  /// while the line's changed middle types out). Lines with no pending entry
  /// are fully shown.
  func isShown(line: Int, column: Int) -> Bool {
    guard let p = pending[line] else { return true }
    for span in p.spans {
      if column < span.lowerBound { return true }
      if span.contains(column) { return false }
    }
    return true
  }

  /// Shows `snapshot` at once: nothing types.
  func snap(to snapshot: TerminalSnapshot) {
    ticker?.cancel()
    ticker = nil
    if !pending.isEmpty { pending = [:] }
    shown = snapshot
  }

  /// Moves to a newly published snapshot: types what is new in its visible
  /// lines when `animate`, else snaps.
  func update(to target: TerminalSnapshot, animate: Bool) {
    guard animate,
          let previous = shown,
          target.message == nil, previous.message == nil,
          !target.usesAlternateScreen, !previous.usesAlternateScreen,
          target.columns == previous.columns, target.rows == previous.rows,
          target.selectionEpoch == previous.selectionEpoch,
          let shift = Self.scrollbackShift(from: previous, to: target)
    else {
      snap(to: target)
      return
    }

    // Only the visible grid types; anything above it is already history.
    let firstVisible = max(0, target.totalLines - target.rows)
    var pending = Self.shifted(self.pending, by: shift).filter { $0.key >= firstVisible }

    for line in firstVisible..<target.totalLines {
      let end = Self.contentEnd(of: target, line: line)
      let previousLine = line + shift
      if end == 0 || previousLine >= previous.totalLines {
        // An emptied line snaps (a deletion has nothing to type); a genuinely
        // new line types whole.
        pending[line] = end == 0 ? nil : PendingLine(cursor: 0, to: end)
        continue
      }
      // Fresh spans for this line, then unioned with what this line had not
      // typed yet (clipped to the new end): columns already revealed stay
      // revealed, columns never typed keep typing even when unchanged again.
      let fresh = Self.freshSpans(previous, previousLine, target, line, end: end)
      let kept = pending[line].map { Self.clipped($0.spans, to: end) } ?? []
      let spans = Self.merged(kept + fresh)
      pending[line] = spans.isEmpty ? nil : PendingLine(spans: spans)
    }

    shown = target
    // The animation's first characters show on the SAME frame the update
    // lands (not a ticker frame later): tiny rewrites — a spinner tick, a
    // progress digit — never visibly blank, and every animation starts with
    // something already visible.
    Self.revealImmediately(&pending)
    if pending != self.pending { self.pending = pending }
    framesLeft = Self.framesToCatchUp
    if pending.isEmpty {
      ticker?.cancel()
      ticker = nil
    } else {
      startTicking()
    }
  }

  // MARK: - Typing

  /// Characters revealed synchronously inside `update()`, on the same frame.
  private static let immediateCharacters = 2

  /// Reveals the animation's first characters at once, top line first (no
  /// frame elapses, so the deadline is untouched).
  private static func revealImmediately(_ pending: inout [Int: PendingLine]) {
    var budget = immediateCharacters
    for line in pending.keys.sorted() {
      guard budget > 0 else { break }
      guard var spans = pending[line]?.spans, !spans.isEmpty else { continue }
      take(&spans, budget: &budget)
      pending[line] = spans.isEmpty ? nil : PendingLine(spans: spans)
    }
  }

  /// Consumes `budget` characters off the front of `spans`.
  private static func take(_ spans: inout [Range<Int>], budget: inout Int) {
    while budget > 0, !spans.isEmpty {
      let step = min(budget, spans[0].count)
      budget -= step
      let lower = spans[0].lowerBound + step
      if lower >= spans[0].upperBound {
        spans.removeFirst()
      } else {
        spans[0] = lower..<spans[0].upperBound
      }
    }
  }

  private func startTicking() {
    guard ticker == nil else { return }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.frame)
        guard !Task.isCancelled, let self else { return }
        if !self.advance() {
          self.ticker = nil
          return
        }
      }
    }
  }

  /// Types the next characters, top line first. Returns whether anything is
  /// still typing.
  private func advance() -> Bool {
    let outstanding = pending.values.reduce(0) { $0 + $1.hiddenCount }
    // An even pace that lands the backlog by the deadline (a share of what is
    // LEFT each frame would decay and crawl through the tail).
    let frames = max(1, framesLeft)
    framesLeft -= 1
    var budget = max(Self.minimumCharactersPerFrame, (outstanding + frames - 1) / frames)
    var pending = self.pending
    for line in pending.keys.sorted() {
      guard budget > 0 else { break }
      guard var spans = pending[line]?.spans, !spans.isEmpty else { continue }
      Self.take(&spans, budget: &budget)
      pending[line] = spans.isEmpty ? nil : PendingLine(spans: spans)
    }
    self.pending = pending
    return !pending.isEmpty
  }

  // MARK: - Diffing

  /// How far the scrollback's top was trimmed between `previous` and `target`
  /// (target line L is previous line L + shift) — the scrollback is capped, so
  /// once full every new line drops the oldest. Nil when they can't be lined
  /// up (cleared, or more trimmed than a few screens), which snaps.
  private static func scrollbackShift(from previous: TerminalSnapshot, to target: TerminalSnapshot) -> Int? {
    guard let first = target.scrollback.first else {
      return previous.scrollback.isEmpty ? 0 : nil
    }
    guard !previous.scrollback.isEmpty else { return 0 }
    if previous.scrollback[0] == first { return 0 }
    let searchLimit = min(previous.scrollback.count - 1, 4 * target.rows)
    guard searchLimit >= 1 else { return nil }
    for shift in 1...searchLimit where previous.scrollback[shift] == first {
      return shift
    }
    return nil
  }

  private static func shifted<V>(_ lines: [Int: V], by shift: Int) -> [Int: V] {
    guard shift != 0 else { return lines }
    var result: [Int: V] = [:]
    for (line, value) in lines where line - shift >= 0 {
      result[line - shift] = value
    }
    return result
  }

  /// The column just past `line`'s last visible cell — a character, or a
  /// colored background (a powerline prompt segment).
  private static func contentEnd(of snapshot: TerminalSnapshot, line: Int) -> Int {
    var column = snapshot.columns
    while column > 0 {
      let cell = snapshot.cell(atLine: line, column: column - 1)
      if !cell.isBlank || cell.background != .clear { break }
      column -= 1
    }
    return column
  }

  /// The fresh hidden spans for one line: the cheaper of the column-aligned
  /// hunks (an in-place repaint: spinner tick, grown progress bar, changed
  /// digits — unchanged columns between disjoint edits stay shown) and the
  /// single prefix→suffix middle (a SHIFT: typing at the line's start pushes
  /// the rest right, which column comparison misreads as all-changed).
  /// By character, ignoring attributes, so a recolor settles instantly.
  private static func freshSpans(
    _ a: TerminalSnapshot, _ lineA: Int,
    _ b: TerminalSnapshot, _ lineB: Int,
    end: Int
  ) -> [Range<Int>] {
    let prefix = Self.commonPrefix(a, lineA, b, lineB, upTo: end)
    let prevEnd = Self.contentEnd(of: a, line: lineA)
    let maxSuffix = min(prevEnd, end) - prefix
    let suffix = maxSuffix > 0
      ? Self.commonSuffix(a, lineA, prevEnd, b, lineB, end, maxCount: maxSuffix)
      : 0
    let single: [Range<Int>] = prefix < end - suffix ? [prefix..<(end - suffix)] : []
    let hunks = Self.columnHunks(a, lineA, b, lineB, end: end)
    let singleCount = single.reduce(0) { $0 + $1.count }
    let hunksCount = hunks.reduce(0) { $0 + $1.count }
    return hunksCount < singleCount ? hunks : single
  }

  /// Runs of columns whose characters differ, compared at the SAME column
  /// (an in-place `\r` repaint overwrites each cell where it stands).
  private static func columnHunks(
    _ a: TerminalSnapshot, _ lineA: Int,
    _ b: TerminalSnapshot, _ lineB: Int,
    end: Int
  ) -> [Range<Int>] {
    var spans: [Range<Int>] = []
    var column = 0
    while column < end {
      let cellA = a.cell(atLine: lineA, column: column)
      let cellB = b.cell(atLine: lineB, column: column)
      guard cellA.character != cellB.character && !(cellA.isBlank && cellB.isBlank) else {
        column += 1
        continue
      }
      var next = column + 1
      while next < end {
        let ca = a.cell(atLine: lineA, column: next)
        let cb = b.cell(atLine: lineB, column: next)
        guard ca.character != cb.character && !(ca.isBlank && cb.isBlank) else { break }
        next += 1
      }
      spans.append(column..<next)
      column = next
    }
    return spans
  }

  /// Old still-hidden spans clipped to the line's new end (a shrunk line
  /// drops spans past it).
  private static func clipped(_ spans: [Range<Int>], to end: Int) -> [Range<Int>] {
    spans.compactMap { span in
      let lower = max(0, span.lowerBound)
      let upper = min(end, span.upperBound)
      return lower < upper ? lower..<upper : nil
    }
  }

  /// Sorted non-overlapping spans (overlaps and adjacencies merged).
  private static func merged(_ spans: [Range<Int>]) -> [Range<Int>] {
    let sorted = spans.sorted { $0.lowerBound < $1.lowerBound }
    var result: [Range<Int>] = []
    for span in sorted {
      guard span.lowerBound < span.upperBound else { continue }
      if let last = result.last, span.lowerBound <= last.upperBound {
        result[result.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
      } else {
        result.append(span)
      }
    }
    return result
  }

  /// How many leading columns two lines share, by CHARACTER (attributes are
  /// ignored: a recolor isn't new output), up to `end`.
  private static func commonPrefix(
    _ a: TerminalSnapshot, _ lineA: Int,
    _ b: TerminalSnapshot, _ lineB: Int,
    upTo end: Int
  ) -> Int {
    var column = 0
    while column < end {
      let cellA = a.cell(atLine: lineA, column: column)
      let cellB = b.cell(atLine: lineB, column: column)
      guard cellA.character == cellB.character || (cellA.isBlank && cellB.isBlank) else { break }
      column += 1
    }
    return column
  }

  /// How many trailing columns two lines share, by CHARACTER (same
  /// blank-equivalence as `commonPrefix`), aligning their content ends
  /// (`endA`, `endB`) and capped at `maxCount` so the suffix never overlaps
  /// the prefix. What this recognizes is a SHIFT: text that moved right
  /// (typing at the line's start) or stayed put past an edit types nothing.
  private static func commonSuffix(
    _ a: TerminalSnapshot, _ lineA: Int, _ endA: Int,
    _ b: TerminalSnapshot, _ lineB: Int, _ endB: Int,
    maxCount: Int
  ) -> Int {
    var count = 0
    while count < maxCount {
      let cellA = a.cell(atLine: lineA, column: endA - 1 - count)
      let cellB = b.cell(atLine: lineB, column: endB - 1 - count)
      guard cellA.character == cellB.character || (cellA.isBlank && cellB.isBlank) else { break }
      count += 1
    }
    return count
  }
}
