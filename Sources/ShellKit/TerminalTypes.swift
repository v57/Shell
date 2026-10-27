import SwiftUI

#if os(macOS)
import AppKit
/// The platform monospaced font type (AppKit on macOS, UIKit on iOS, a measured SwiftUI font elsewhere).
public typealias TerminalFont = NSFont
#elseif os(iOS)
import UIKit
public typealias TerminalFont = UIFont
#else
/// The terminal's monospaced font where neither AppKit nor UIKit is around (Windows): a size, measured by the
/// platform's text layout (`TextMeasurer`), with NSFont's metrics names.
public struct TerminalFont {
  public let pointSize: CGFloat
  public let weight: Font.Weight

  public static func monospacedSystemFont(ofSize size: CGFloat, weight: Font.Weight) -> TerminalFont {
    TerminalFont(pointSize: size, weight: weight)
  }

  public var font: Font { .system(size: pointSize, weight: weight, design: .monospaced) }

  /// The width of `string` on one line.
  @MainActor public func width(of string: String) -> CGFloat {
    TextMeasurer.measure(Text(string).font(font))?.width ?? CGFloat(string.count) * pointSize * 0.6
  }

  @MainActor private var line: TextMeasurer.Measurement {
    TextMeasurer.measure(Text("W").font(font))
      ?? TextMeasurer.Measurement(width: pointSize * 0.6, height: pointSize * 1.3, baseline: pointSize)
  }

  /// Top of the line to the baseline.
  @MainActor public var ascender: CGFloat { line.baseline }
  /// Baseline to the bottom of the line (negative, as NSFont's).
  @MainActor public var descender: CGFloat { line.baseline - line.height }
  public var leading: CGFloat { 0 }
}
#endif

// Terminal model types: snapshot, cells, colors.
// Extracted from the Shell app (TerminalView.swift) into the Terminal library.

/// Portable key-modifier flags. AppKit's NSEvent.ModifierFlags and UIKit's
/// UIKeyModifierFlags differ; the views convert SwiftUI EventModifiers into
/// this type so the key mapper is platform-independent.
public struct TerminalModifierFlags: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let control = TerminalModifierFlags(rawValue: 1 << 0)
  public static let option = TerminalModifierFlags(rawValue: 1 << 1)
  public static let shift = TerminalModifierFlags(rawValue: 1 << 2)
  public static let command = TerminalModifierFlags(rawValue: 1 << 3)
}

/// Platform-appropriate semantic colors for the terminal chrome (window
/// background, text selection, secondary text). Keeps the renderer free of
/// #if per color site.
public enum TerminalPalette {
  /// The terminal's ground: ComponentKit's window colour (`kitWindow`, white and #1C1C1E), as on the canvas's
  /// Shell boards, on every platform. ShellKit doesn't link the kit, so the values are repeated here and in
  /// `TerminalContrast`.
  public static let windowBackground = Color(terminalLight: 0xffffff, dark: 0x1c1c1e)
  #if os(macOS)
  public static let selectionBackground = Color(nsColor: .selectedTextBackgroundColor)
  public static let selectionForeground = Color(nsColor: .selectedTextColor)
  public static let secondaryText = Color(nsColor: .secondaryLabelColor)
  #elseif os(iOS)
  public static let selectionBackground = Color(uiColor: .tintColor)
  public static let selectionForeground = Color(uiColor: .white)
  public static let secondaryText = Color(uiColor: .secondaryLabel)
  #else
  // AppKit's colors, light and dark.
  public static let selectionBackground = Color(
    light: Color(red: 0.702, green: 0.843, blue: 1), dark: Color(red: 0.247, green: 0.396, blue: 0.584))
  public static let selectionForeground = Color.primary
  public static let secondaryText = Color.secondary
  #endif
}

// MARK: - Snapshot / Model

public struct TerminalSnapshot {
  public var rows: Int
  public var columns: Int
  public var cells: [TerminalCell]
  /// Lines scrolled off the top of the main screen, oldest first. Each row
  /// keeps its historical width. Empty while on the alternate screen.
  public var scrollback: [[TerminalCell]]
  /// Per-scrollback-row wrapped flag: `scrollbackWrapped[i]` is true when
  /// scrollback row `i` is a soft-wrap continuation of row `i-1`. Mirrors
  /// `gridWrapped` across the scrollback/grid seam, so copy/history can
  /// re-join logical lines instead of treating every physical row as a new
  /// line.
  public var scrollbackWrapped: [Bool]
  /// Ordinal of the next logical line to begin below the scrollback: the
  /// number of logical lines that ever started in the scrollback, including
  /// ones since trimmed at the scrollback limit or cleared. Unlike
  /// `scrollback.count` it keeps growing once the scrollback is full, so an
  /// incremental capture can still tell which lines are new; it counts
  /// LOGICAL lines, so a resize re-flow keeps every line's ordinal. Lines
  /// are numbered per grid (the alternate screen has its own count).
  public var scrolledLineCount: Int = 0
  /// Per-grid-row wrapped flag (row n continues row n-1). Together with
  /// `scrollbackWrapped` it records every soft-wrap boundary, which is what
  /// lets plainText/copy re-join wrapped lines (and resize re-flow them).
  public var gridWrapped: [Bool]
  public var cursor: TerminalCursor
  public var showCursor: Bool
  public var cursorBackground: Color
  public var message: String?
  /// Bumped whenever the visible content is wholesale invalidated (full
  /// screen clear, RIS, alternate-screen switch). Selections made against
  /// an older epoch are stale and get dropped.
  public var selectionEpoch: Int = 0
  /// Screen rows of the grid whose content changed since the previous
  /// snapshot (the snapshot consumes the set). Consumers use it to skip
  /// no-op work: empty means nothing VISUALLY changed even though bytes
  /// arrived (OSC/title-only or SGR-only output).
  public var dirtyLines: Set<Int> = []
  /// True while the child is in bracketed-paste mode (DECSET 2004) — the
  /// session consults it to wrap pasted text in the paste markers. Read
  /// on the main thread; written by the parser on its parse queue, so
  /// guarded by the parser's lock (see `bracketedPasteEnabled` below).
  public var bracketedPasteEnabled = false
  /// True while a full-screen program (vim, less, top) is on the alternate
  /// screen — its redraws are repaints, not output to type out.
  public var usesAlternateScreen = false

  /// Logical line count: scrollback plus the visible grid.
  public var totalLines: Int { scrollback.count + rows }
  /// Maximum scroll offset (lines above the bottom).
  public var maxOffset: Int { max(0, totalLines - rows) }

  /// Whether logical line `line` is a soft-wrap continuation of the line just
  /// above it. Line 0 (and any out-of-range line) is never a continuation.
  /// This is the single bit that distinguishes a long line split by autowrap
  /// from two genuinely separate lines; copy/history use it to re-join the
  /// former without inserting a spurious newline.
  public func isLineWrapped(_ line: Int) -> Bool {
    guard line > 0, line < totalLines else { return false }
    if line < scrollback.count {
      guard line < scrollbackWrapped.count else { return false }
      return scrollbackWrapped[line]
    }
    let gridRow = line - scrollback.count
    guard gridRow < gridWrapped.count else { return false }
    return gridWrapped[gridRow]
  }

  init(rows: Int = 24, columns: Int = 80, cells: [TerminalCell] = [], scrollback: [[TerminalCell]] = [], scrollbackWrapped: [Bool] = [], scrolledLineCount: Int = 0, gridWrapped: [Bool] = [], cursor: TerminalCursor = .zero, showCursor: Bool = true, cursorBackground: Color = TerminalPalette.selectionBackground, message: String? = nil, selectionEpoch: Int = 0, dirtyLines: Set<Int> = []) {
    self.rows = rows
    self.columns = columns
    self.cells = cells.isEmpty ? Array(repeating: TerminalCell.space, count: rows * columns) : cells
    self.scrollback = scrollback
    self.scrollbackWrapped = scrollbackWrapped
    self.scrolledLineCount = scrolledLineCount
    self.gridWrapped = gridWrapped
    self.cursor = cursor
    self.showCursor = showCursor
    self.cursorBackground = cursorBackground
    self.message = message
    self.selectionEpoch = selectionEpoch
    self.dirtyLines = dirtyLines
  }
  
  public func cell(atRow row: Int, column: Int) -> TerminalCell {
    guard row >= 0, row < rows, column >= 0, column < columns else { return .space }
    let index = row * columns + column
    guard index >= 0, index < cells.count else { return .space }
    return cells[index]
  }
  
  /// Cell at a logical line (0 = top of scrollback, then the grid) and
  /// column. Columns past a scrollback row's historical width are blank.
  public func cell(atLine line: Int, column: Int) -> TerminalCell {
    guard column >= 0, column < columns else { return .space }
    if line < scrollback.count {
      let row = scrollback[line]
      guard column < row.count else { return .space }
      return row[column]
    }
    return cell(atRow: line - scrollback.count, column: column)
  }
  
  /// Plain text of the visible window: the grid plus `offset` scrollback
  /// lines above it.
  public func plainText(offset: Int) -> String {
    guard message == nil else { return message ?? "" }
    let off = min(max(0, offset), maxOffset)
    let firstLine = maxOffset - off
    return gluedLines(first: firstLine, last: firstLine + rows - 1).joined(separator: "\n")
  }
  
  public var plainText: String {
    plainText(offset: 0)
  }

  /// Plain text for the complete logical buffer: scrollback followed by the
  /// current screen. Trailing blank rows are omitted, but ordinary scrollback
  /// is retained. Alternate-screen snapshots naturally contain no scrollback.
  public var fullPlainText: String {
    plainText(fromLine: 0)
  }

  /// Text of logical lines `first..<totalLines` joined by newline, trailing
  /// blank lines trimmed.
  public func plainText(fromLine first: Int) -> String {
    guard message == nil else { return message ?? "" }
    var lines = gluedLines(first: first, last: totalLines - 1)
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.joined(separator: "\n")
  }
  
  /// Stream-wise selection text: the first row starts at the anchor column,
  /// the last row ends at the active column, and rows in between are taken in
  /// full. Trailing whitespace is trimmed on every line. Rows are viewport
  /// coordinates; `offset` is the scroll offset they were made against.
  public func plainText(from start: TerminalCursor, to end: TerminalCursor, offset: Int = 0) -> String {
    guard message == nil else { return message ?? "" }
    let off = min(max(0, offset), maxOffset)
    let firstLine = maxOffset - off
    let top = min(start.row, end.row) + firstLine
    let bottom = max(start.row, end.row) + firstLine
    let leftColumn = start.row <= end.row ? start.column : end.column
    let rightColumn = start.row <= end.row ? end.column : start.column
    
    var segments: [(line: Int, start: Int, end: Int)] = []
    if top == bottom {
      segments.append((top, leftColumn, rightColumn))
    } else {
      segments.append((top, leftColumn, columns - 1))
      if bottom - top > 1 {
        for row in (top + 1)..<bottom {
          segments.append((row, 0, columns - 1))
        }
      }
      segments.append((bottom, 0, rightColumn))
    }
    return gluedSegments(segments)
  }
  
  /// Stream-wise selection text with LOGICAL line coordinates (rows are
  /// absolute scrollback+grid lines, as stored by the canvas's selection).
  /// The first row starts at the anchor column, the last ends at the active
  /// column, and rows in between are taken in full; trailing whitespace is
  /// trimmed per line.
  public func plainText(logicalFrom start: TerminalCursor, to end: TerminalCursor) -> String {
    guard message == nil else { return message ?? "" }
    let top = min(start.row, end.row)
    let bottom = max(start.row, end.row)
    let leftColumn = start.row <= end.row ? start.column : end.column
    let rightColumn = start.row <= end.row ? end.column : start.column
    
    var segments: [(line: Int, start: Int, end: Int)] = []
    if top == bottom {
      segments.append((top, leftColumn, rightColumn))
    } else {
      segments.append((top, leftColumn, columns - 1))
      if bottom - top > 1 {
        for line in (top + 1)..<bottom {
          segments.append((line, 0, columns - 1))
        }
      }
      segments.append((bottom, 0, rightColumn))
    }
    return gluedSegments(segments)
  }
  
  private func lineText(line: Int, from startColumn: Int, to endColumn: Int) -> String {
    guard line >= 0, line < totalLines else { return "" }
    var text = ""
    let lastColumn = min(endColumn, columns - 1)
    guard startColumn <= lastColumn else { return "" }
    for column in startColumn...lastColumn {
      let cell = cell(atLine: line, column: column)
      text.append(cell.isBlank ? " " : cell.character)
    }
    while text.last == " " {
      text.removeLast()
    }
    return text
  }

  /// Glues soft-wrap continuation rows into the previous output line, so a
  /// long logical line split across several physical rows becomes ONE string
  /// (no spurious newline). A row that is NOT a continuation starts a new
  /// output line. `first` is always treated as a line-start: a continuation
  /// of a row OUTSIDE the range is not glued (the caller can't see it), which
  /// matches how terminals copy a selection that begins mid-line.
  private func gluedLines(first: Int, last: Int) -> [String] {
    let lo = max(first, 0)
    let hi = min(last, totalLines - 1)
    guard lo <= hi else { return [] }
    var out: [String] = []
    var current = ""
    var started = false
    for line in lo...hi {
      let text = lineText(line: line)
      if !started {
        current = text
        started = true
      } else if isLineWrapped(line) {
        current += text
      } else {
        out.append(current)
        current = text
      }
    }
    if started { out.append(current) }
    return out
  }

  /// The segment-version of `gluedLines` for stream selections: the top row
  /// starts at `start`, the bottom row ends at `end`, rows in between are
  /// taken in full, and a row that is a continuation of the one above is
  /// glued to it (no newline) exactly as the visible highlight implies.
  private func gluedSegments(_ segments: [(line: Int, start: Int, end: Int)]) -> String {
    var out: [String] = []
    var current = ""
    var started = false
    for seg in segments {
      let text = lineText(line: seg.line, from: seg.start, to: seg.end)
      if !started {
        current = text
        started = true
      } else if isLineWrapped(seg.line) {
        current += text
      } else {
        out.append(current)
        current = text
      }
    }
    if started { out.append(current) }
    return out.joined(separator: "\n")
  }
  
  /// Trimmed text of a logical line (0 = top of scrollback).
  public func lineText(line: Int) -> String {
    lineText(line: line, from: 0, to: columns - 1)
  }

  /// First logical line of the screen's text segment: the grid's top row,
  /// or — when that row is a soft-wrap continuation — the scrollback row its
  /// line starts on. A line wrapped across the scrollback/grid seam belongs
  /// wholly to the screen segment, so `scrollbackText` + newline + `gridText`
  /// equals `fullPlainText` without any seam special-casing.
  public var gridTextStart: Int {
    var line = scrollback.count
    while line > 0, isLineWrapped(line) { line -= 1 }
    return line
  }

  /// Text of the visible grid from `gridTextStart`, joined by newline,
  /// trailing blank lines trimmed. The grid is small (one screen), so
  /// rebuilding it per publish is cheap; history capture keeps the
  /// scrollback text incremental and swaps THIS segment when the screen
  /// changes.
  public var gridText: String {
    plainText(fromLine: gridTextStart)
  }

  /// Text of scrollback lines `[from..<gridTextStart]` joined by newline.
  /// The scrollback is append-only (oldest first), so a capture that
  /// remembers where it stopped can append only the new lines — O(new rows)
  /// instead of O(whole scrollback) per publish. `from` should start a
  /// logical line (see `firstLine(ofOrdinal:)`).
  public func scrollbackText(after from: Int) -> String {
    guard message == nil else { return message ?? "" }
    let end = gridTextStart
    guard from >= 0, from < end else { return "" }
    return gluedLines(first: from, last: end - 1).joined(separator: "\n")
  }

  /// Ordinal (in `scrolledLineCount` numbering) of the line at
  /// `gridTextStart`: every line before it is complete in the scrollback.
  public var completedLineCount: Int {
    let seam = gridTextStart
    return seam < scrollback.count && startsLine(seam) ? scrolledLineCount - 1 : scrolledLineCount
  }

  /// First logical line of the line numbered `ordinal` (see
  /// `scrolledLineCount`). Walks from the seam, so it costs O(distance) — a
  /// capture asking for the lines since its last publish never scans the
  /// whole scrollback. Lines already trimmed off clamp to 0; lines not yet
  /// started clamp to `totalLines`.
  public func firstLine(ofOrdinal ordinal: Int) -> Int {
    var line = gridTextStart
    var current = completedLineCount
    while current > ordinal, line > 0 {
      line -= 1
      if startsLine(line) { current -= 1 }
    }
    while current < ordinal, line < totalLines {
      line += 1
      if line < totalLines, startsLine(line) { current += 1 }
    }
    return line
  }

  /// Whether logical line `line` begins a logical line by its own wrapped
  /// flag. Unlike `isLineWrapped`, line 0 is not special-cased: a scrollback
  /// head trimmed mid-line is a continuation (its start was counted when it
  /// scrolled in), which keeps `firstLine(ofOrdinal:)` consistent with
  /// `scrolledLineCount`.
  private func startsLine(_ line: Int) -> Bool {
    if line < scrollback.count {
      return !(line < scrollbackWrapped.count && scrollbackWrapped[line])
    }
    let row = line - scrollback.count
    return !(row < gridWrapped.count && gridWrapped[row])
  }
  
  /// Column of the last non-blank cell in a logical line, or -1 when the
  /// line is empty. Used to detect a click on a line's last character.
  public func lastNonBlankColumn(ofLine line: Int) -> Int {
    guard line >= 0, line < totalLines else { return -1 }
    for column in stride(from: columns - 1, through: 0, by: -1) {
      if !cell(atLine: line, column: column).isBlank { return column }
    }
    return -1
  }

  /// Column of the FIRST non-blank cell in a logical line, or -1 when the
  /// line is blank. This is the "start character" the status line anchors
  /// on when rendering in start-character mode.
  public func firstNonBlankColumn(ofLine line: Int) -> Int {
    guard line >= 0, line < totalLines else { return -1 }
    for column in 0..<columns {
      if !cell(atLine: line, column: column).isBlank { return column }
    }
    return -1
  }
  
  /// Logical line index of the n-th non-empty line from the bottom
  /// (n = 0 → the last non-empty line). Clamps to the topmost
  /// non-empty line when n exceeds the count; nil when the terminal
  /// has no non-empty lines.
  public func nonEmptyLineIndexFromBottom(_ n: Int) -> Int? {
    guard n >= 0, totalLines > 0 else { return nil }
    var seen = 0
    var topmost: Int?
    for line in stride(from: totalLines - 1, through: 0, by: -1) {
      if !lineText(line: line).isEmpty {
        topmost = line
        if seen == n { return line }
        seen += 1
      }
    }
    return topmost
  }
  
  /// Rank of a logical line from the bottom (0 = the last non-empty
  /// line); nil for empty or out-of-range lines. The clicked line's
  /// rank is what the sidebar status shows when pinned.
  public func nonEmptyRank(fromBottomOf line: Int) -> Int? {
    guard line >= 0, line < totalLines else { return nil }
    var rank = 0
    for candidate in stride(from: totalLines - 1, through: line, by: -1) {
      if !lineText(line: candidate).isEmpty {
        if candidate == line { return rank }
        rank += 1
      }
    }
    return nil
  }
}

public struct TerminalCell: Equatable {
  public var character: Character
  public var foreground: TerminalColor
  public var background: TerminalColor
  public var bold: Bool
  public var dim: Bool
  public var italic: Bool
  public var underline: Bool
  public var inverse: Bool
  
  public static let space = TerminalCell(character: " ", foreground: .defaultForeground, background: .clear, bold: false, dim: false, italic: false, underline: false, inverse: false)
  
  public var isBlank: Bool {
    character == " " || character == "\0"
  }
  
  /// Foreground color for drawing; `.default` resolves to the system label color.
  public func effectiveForeground() -> Color {
    foreground.color ?? Color.primary
  }

  /// Background color for drawing: `.default` resolves to the terminal
  /// background, explicit colors stay, `.clear` means no fill.
  public func effectiveBackground(defaultingTo terminalBackground: Color) -> Color? {
    switch background {
    case .clear:
      return nil
    case .default:
      return terminalBackground
    case .rgb, .ansi:
      return background.color
    }
  }
}

public struct TerminalCursor: Equatable {
  public var row: Int
  public var column: Int
  
  public static let zero = TerminalCursor(row: 0, column: 0)
}

public struct TerminalGridSize: Equatable {
  public var rows: Int
  public var columns: Int
  
  public static let zero = TerminalGridSize(rows: 0, columns: 0)
}

public struct TerminalFontMetrics {
  public var cellWidth: CGFloat
  public var lineHeight: CGFloat
  public var baselineOffset: CGFloat
  /// Extra per-glyph spacing (cellWidth - font advance) that makes batched
  /// text runs land on the exact cell grid.
  public var cellKern: CGFloat
}

public enum TerminalColor: Equatable {
  case clear
  case `default`
  case rgb(red: CGFloat, green: CGFloat, blue: CGFloat)
  case ansi(Int)
  
  public static let defaultForeground = TerminalColor.default
  
  public var color: Color? {
    switch self {
    case .clear:
      return .clear
    case .default:
      return nil
    case .rgb(let red, let green, let blue):
      return Color(red: red, green: green, blue: blue)
    case .ansi(let index):
      return TerminalColor.color(forAnsiIndex: index)
    }
  }

  /// The 16 ANSI colors, light and dark, from ComponentKit's hues (red, green, yellow, blue, purple, teal), as the
  /// canvas's Shell boards color a terminal: in light the normal colors are the hues' text colors (dark enough to
  /// read on white) and the bright ones halfway to their fills (yellow a third of the way), which keeps them at 3:1
  /// or more on white, where the fills themselves fall to 1.5:1; in dark the normal colors are the fills and the
  /// bright ones the lighter text colors. Black and white are grays that stay visible on either ground. Stored as hex
  /// so the same source drives both the SwiftUI Color and the luminance math.
  private static let palette16LightHex: [Int] = [
    0x262628, 0xc00012, 0x146c2e, 0x8a6d00,
    0x0a5cc2, 0x8a35b5, 0x1d6f84, 0x8e8e93,
    0x5f5f64, 0xe01e21, 0x1e9c38, 0xad8a00,
    0x056be0, 0x9c44ca, 0x3b8ea4, 0xaeaeb2
  ]
  private static let palette16DarkHex: [Int] = [
    0x48484a, 0xff453a, 0x32d74b, 0xffd60a,
    0x0a84ff, 0xbf5af2, 0x6ac4dc, 0xe0e0e0,
    0x98989d, 0xff6961, 0x4cd964, 0xffe066,
    0x5eaaff, 0xd08bf5, 0x7fd3ea, 0xffffff
  ]

  private nonisolated static func components(_ hex: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    (CGFloat((hex >> 16) & 0xff) / 255,
     CGFloat((hex >> 8) & 0xff) / 255,
     CGFloat(hex & 0xff) / 255)
  }

  private static let palette16LightComponents = palette16LightHex.map(components)
  private static let palette16DarkComponents = palette16DarkHex.map(components)
  private static let palette16: [Color] = zip(palette16LightHex, palette16DarkHex).map {
    Color(terminalLight: $0, dark: $1)
  }

  /// 6x6x6 color cube (indices 16...231), kept as components.
  private static let colorCubeComponents: [(r: CGFloat, g: CGFloat, b: CGFloat)] = {
    let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
    var colors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
    colors.reserveCapacity(216)
    for red in levels { for green in levels { for blue in levels {
      colors.append((red / 255, green / 255, blue / 255))
    } } }
    return colors
  }()
  private static let colorCube: [Color] = colorCubeComponents.map { Color(red: $0.r, green: $0.g, blue: $0.b) }

  /// Grayscale ramp (indices 232...255), kept as components.
  private static let grayscaleComponents: [(r: CGFloat, g: CGFloat, b: CGFloat)] = {
    var colors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
    colors.reserveCapacity(24)
    for step in 0..<24 {
      let value = CGFloat(8 + 10 * step) / 255
      colors.append((value, value, value))
    }
    return colors
  }()
  private static let grayscale: [Color] = grayscaleComponents.map { Color(red: $0.r, green: $0.g, blue: $0.b) }

  /// xterm-256color palette lookup. Returns nil for out-of-range indices so
  /// the caller can fall back to the default label color.
  public static func color(forAnsiIndex index: Int) -> Color? {
    switch index {
    case 0..<16:
      return palette16[index]
    case 16..<232:
      return colorCube[index - 16]
    case 232..<256:
      return grayscale[index - 232]
    default:
      return nil
    }
  }

  /// sRGB components of an explicit color (.rgb/.ansi) in `scheme` (the 16 ANSI colors differ between light and
  /// dark); nil for .clear/.default.
  public func colorComponents(in scheme: ColorScheme = .dark) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    switch self {
    case .rgb(let red, let green, let blue):
      return (red, green, blue)
    case .ansi(let index):
      switch index {
      case 0..<16: return (scheme == .dark ? Self.palette16DarkComponents : Self.palette16LightComponents)[index]
      case 16..<232: return Self.colorCubeComponents[index - 16]
      case 232..<256: return Self.grayscaleComponents[index - 232]
      default: return nil
      }
    case .clear, .default:
      return nil
    }
  }
}

extension TerminalColor: Hashable {}   // synthesized; CGFloat components are Hashable

extension Color {
  /// A color that follows the appearance: `light` in light mode, `dark` in dark mode (sRGB hex, 0xRRGGBB).
  init(terminalLight light: Int, dark: Int) {
    func component(_ hex: Int, _ shift: Int) -> CGFloat { CGFloat((hex >> shift) & 0xff) / 255 }
    #if os(macOS)
    self.init(nsColor: NSColor(name: nil) { appearance in
      let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: component(hex, 16), green: component(hex, 8), blue: component(hex, 0), alpha: 1)
    })
    #elseif os(iOS)
    self.init(uiColor: UIColor { traits in
      let hex = traits.userInterfaceStyle == .dark ? dark : light
      return UIColor(red: component(hex, 16), green: component(hex, 8), blue: component(hex, 0), alpha: 1)
    })
    #else
    self.init(
      light: Color(red: component(light, 16), green: component(light, 8), blue: component(light, 0)),
      dark: Color(red: component(dark, 16), green: component(dark, 8), blue: component(dark, 0)))
    #endif
  }
}
