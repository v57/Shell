import Foundation
import Observation

/// Types a terminal's new output out instead of showing it all at once.
///
/// Two buffers: the session publishes the TARGET snapshot; the view renders
/// `shown`, plus a per-line `limits` cut-off — the number of leading columns
/// already typed. Each new target is diffed against the previous one line by
/// line, by CHARACTER only, so:
///
///  - an unchanged line, or an unchanged prefix, is never typed again (a
///    recolor — zsh's syntax highlighting repainting the command line on every
///    keystroke — shows at once rather than re-typing);
///  - only the new tail of a line is typed, and a line still typing that
///    changes again keeps what it already showed.
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
  /// The snapshot the view renders: the latest target, with `limits` applied.
  private(set) var shown: TerminalSnapshot?
  /// Lines still typing (logical line → columns shown). Absent = fully shown.
  private(set) var limits: [Int: Int] = [:]
  /// Where each typing line's content ends (its last visible column + 1).
  @ObservationIgnored private var ends: [Int: Int] = [:]
  @ObservationIgnored private var ticker: Task<Void, Never>?
  /// Frames left before the typing must have caught up with the output —
  /// reset by every update that brings new output, counted down per frame.
  @ObservationIgnored private var framesLeft = 0

  /// The longest typing takes to catch up with the output, in frames.
  static let framesToCatchUp = 18
  /// The slowest typing speed, in characters per frame (~120/s at 60 fps).
  static let minimumCharactersPerFrame = 2
  private static let frame = Duration.milliseconds(16)

  /// The number of leading columns of `line` shown so far; nil = all of them.
  func limit(forLine line: Int) -> Int? {
    limits[line]
  }

  /// Shows `snapshot` at once: nothing types.
  func snap(to snapshot: TerminalSnapshot) {
    ticker?.cancel()
    ticker = nil
    ends = [:]
    if !limits.isEmpty { limits = [:] }
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
    var limits = Self.shifted(self.limits, by: shift).filter { $0.key >= firstVisible }
    var ends = Self.shifted(self.ends, by: shift).filter { $0.key >= firstVisible }

    for line in firstVisible..<target.totalLines {
      let end = Self.contentEnd(of: target, line: line)
      let previousLine = line + shift
      let common = previousLine < previous.totalLines
        ? Self.commonPrefix(previous, previousLine, target, line, upTo: end)
        : 0
      // A typing line keeps what it showed; a settled one shows its unchanged
      // prefix and types the rest.
      let limit = min(limits[line] ?? Int.max, common)
      if limit >= end {
        limits[line] = nil
        ends[line] = nil
      } else {
        limits[line] = limit
        ends[line] = end
      }
    }

    shown = target
    if limits != self.limits { self.limits = limits }
    self.ends = ends
    framesLeft = Self.framesToCatchUp
    if ends.isEmpty {
      ticker?.cancel()
      ticker = nil
    } else {
      startTicking()
    }
  }

  // MARK: - Typing

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
    let pending = ends.reduce(0) { total, entry in
      total + max(0, entry.value - (limits[entry.key] ?? entry.value))
    }
    // An even pace that lands the backlog by the deadline (a share of what is
    // LEFT each frame would decay and crawl through the tail).
    let frames = max(1, framesLeft)
    framesLeft -= 1
    var budget = max(Self.minimumCharactersPerFrame, (pending + frames - 1) / frames)
    var limits = self.limits
    for line in ends.keys.sorted() {
      guard budget > 0 else { break }
      guard let limit = limits[line], let end = ends[line] else {
        ends[line] = nil
        continue
      }
      let step = min(budget, end - limit)
      budget -= step
      if limit + step >= end {
        limits[line] = nil
        ends[line] = nil
      } else {
        limits[line] = limit + step
      }
    }
    self.limits = limits
    return !ends.isEmpty
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

  private static func shifted(_ lines: [Int: Int], by shift: Int) -> [Int: Int] {
    guard shift != 0 else { return lines }
    var result: [Int: Int] = [:]
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
}
