import SwiftUI

#if os(macOS)
import AppKit
/// The platform monospaced font type (AppKit on macOS, UIKit on iOS).
public typealias TerminalFont = NSFont
#else
import UIKit
public typealias TerminalFont = UIFont
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
  #if os(macOS)
  public static let windowBackground = Color(nsColor: .windowBackgroundColor)
  public static let selectionBackground = Color(nsColor: .selectedTextBackgroundColor)
  public static let selectionForeground = Color(nsColor: .selectedTextColor)
  public static let secondaryText = Color(nsColor: .secondaryLabelColor)
  #else
  public static let windowBackground = Color(uiColor: .systemBackground)
  public static let selectionBackground = Color(uiColor: .tintColor)
  public static let selectionForeground = Color(uiColor: .white)
  public static let secondaryText = Color(uiColor: .secondaryLabel)
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

  /// Logical line count: scrollback plus the visible grid.
  public var totalLines: Int { scrollback.count + rows }
  /// Maximum scroll offset (lines above the bottom).
  public var maxOffset: Int { max(0, totalLines - rows) }

  init(rows: Int = 24, columns: Int = 80, cells: [TerminalCell] = [], scrollback: [[TerminalCell]] = [], cursor: TerminalCursor = .zero, showCursor: Bool = true, cursorBackground: Color = TerminalPalette.selectionBackground, message: String? = nil, selectionEpoch: Int = 0, dirtyLines: Set<Int> = []) {
    self.rows = rows
    self.columns = columns
    self.cells = cells.isEmpty ? Array(repeating: TerminalCell.space, count: rows * columns) : cells
    self.scrollback = scrollback
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
    var lines: [String] = []
    for row in 0..<rows {
      lines.append(lineText(line: firstLine + row, from: 0, to: columns - 1))
    }
    return lines.joined(separator: "\n")
  }
  
  public var plainText: String {
    plainText(offset: 0)
  }

  /// Plain text for the complete logical buffer: scrollback followed by the
  /// current screen. Trailing blank rows are omitted, but ordinary scrollback
  /// is retained. Alternate-screen snapshots naturally contain no scrollback.
  public var fullPlainText: String {
    guard message == nil else { return message ?? "" }
    var lines = (0..<totalLines).map { lineText(line: $0) }
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
    let top = min(start.row, end.row)
    let bottom = max(start.row, end.row)
    let leftColumn = start.row <= end.row ? start.column : end.column
    let rightColumn = start.row <= end.row ? end.column : start.column
    
    var lines: [String] = []
    if top == bottom {
      lines.append(lineText(line: firstLine + top, from: leftColumn, to: rightColumn))
    } else {
      lines.append(lineText(line: firstLine + top, from: leftColumn, to: columns - 1))
      if bottom - top > 1 {
        for row in (top + 1)..<bottom {
          lines.append(lineText(line: firstLine + row, from: 0, to: columns - 1))
        }
      }
      lines.append(lineText(line: firstLine + bottom, from: 0, to: rightColumn))
    }
    return lines.joined(separator: "\n")
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
    
    var lines: [String] = []
    if top == bottom {
      lines.append(lineText(line: top, from: leftColumn, to: rightColumn))
    } else {
      lines.append(lineText(line: top, from: leftColumn, to: columns - 1))
      if bottom - top > 1 {
        for line in (top + 1)..<bottom {
          lines.append(lineText(line: line, from: 0, to: columns - 1))
        }
      }
      lines.append(lineText(line: bottom, from: 0, to: rightColumn))
    }
    return lines.joined(separator: "\n")
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
  
  /// Trimmed text of a logical line (0 = top of scrollback).
  public func lineText(line: Int) -> String {
    lineText(line: line, from: 0, to: columns - 1)
  }

  /// Text of the visible grid — the last `rows` logical lines (logical
  /// indices `scrollback.count..<totalLines`) — joined by newline, trailing
  /// blank lines trimmed. The grid is small (one screen), so rebuilding it
  /// per publish is cheap; history capture keeps the scrollback text
  /// incremental and swaps THIS segment when the screen changes.
  public var gridText: String {
    guard message == nil else { return message ?? "" }
    var lines = (scrollback.count..<totalLines).map { lineText(line: $0) }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.joined(separator: "\n")
  }

  /// Text of scrollback rows `[from..<scrollback.count]` joined by newline.
  /// The scrollback is append-only (oldest first), so a capture that
  /// remembers how many rows it already converted can append only the new
  /// ones — O(new rows) instead of O(whole scrollback) per publish.
  public func scrollbackText(after from: Int) -> String {
    guard message == nil else { return message ?? "" }
    guard from >= 0, from < scrollback.count else { return "" }
    let lines = (from..<scrollback.count).map { lineText(line: $0) }
    return lines.joined(separator: "\n")
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

  /// Standard 16-color ANSI palette, tuned for a dark background (near-black
  /// is lifted so it stays visible; the rest are the conventional xterm
  /// hues). Stored as hex so the same source drives both the SwiftUI Color
  /// and the luminance math.
  private static let palette16Hex: [Int] = [
    0x2a2a2a, 0xe05561, 0x8cc265, 0xd18f52,
    0x4aa5f0, 0xc586c0, 0x42b3c2, 0xdfdfdf,
    0x666666, 0xff616e, 0xa5e075, 0xf0a45d,
    0x71b8f9, 0xe2a8df, 0x6cd8e0, 0xffffff
  ]

  private nonisolated static func components(_ hex: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    (CGFloat((hex >> 16) & 0xff) / 255,
     CGFloat((hex >> 8) & 0xff) / 255,
     CGFloat(hex & 0xff) / 255)
  }

  private static let palette16Components = palette16Hex.map(components)
  private static let palette16: [Color] = palette16Components.map { Color(red: $0.r, green: $0.g, blue: $0.b) }

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

  /// sRGB components of an explicit color (.rgb/.ansi); nil for .clear/.default.
  public func colorComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    switch self {
    case .rgb(let red, let green, let blue):
      return (red, green, blue)
    case .ansi(let index):
      switch index {
      case 0..<16: return Self.palette16Components[index]
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
