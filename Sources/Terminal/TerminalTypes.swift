import AppKit

// Terminal model types: snapshot, cells, colors.
// Extracted from the Shell app (TerminalView.swift) into the Terminal library.

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
  public var cursorBackground: NSColor
  public var message: String?
  /// Bumped whenever the visible content is wholesale invalidated (full
  /// screen clear, RIS, alternate-screen switch). Selections made against
  /// an older epoch are stale and get dropped.
  public var selectionEpoch: Int = 0
  
  /// Logical line count: scrollback plus the visible grid.
  public var totalLines: Int { scrollback.count + rows }
  /// Maximum scroll offset (lines above the bottom).
  public var maxOffset: Int { max(0, totalLines - rows) }
  
  init(rows: Int = 24, columns: Int = 80, cells: [TerminalCell] = [], scrollback: [[TerminalCell]] = [], cursor: TerminalCursor = .zero, showCursor: Bool = true, cursorBackground: NSColor = .selectedTextBackgroundColor, message: String? = nil, selectionEpoch: Int = 0) {
    self.rows = rows
    self.columns = columns
    self.cells = cells.isEmpty ? Array(repeating: TerminalCell.space, count: rows * columns) : cells
    self.scrollback = scrollback
    self.cursor = cursor
    self.showCursor = showCursor
    self.cursorBackground = cursorBackground
    self.message = message
    self.selectionEpoch = selectionEpoch
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
  public func effectiveForeground() -> NSColor {
    foreground.nsColor ?? NSColor.labelColor
  }
  
  /// Background color for drawing: `.default` resolves to the terminal
  /// background, explicit colors stay, `.clear` means no fill.
  public func effectiveBackground(defaultingTo terminalBackground: NSColor) -> NSColor? {
    switch background {
    case .clear:
      return nil
    case .default:
      return terminalBackground
    case .rgb, .ansi:
      return background.nsColor
    }
  }
  
  public func makeAttributes(font: NSFont, inverted: Bool, selected: Bool = false, terminalBackground: NSColor) -> [NSAttributedString.Key: Any] {
    let cellForeground = effectiveForeground()
    let cellBackground = effectiveBackground(defaultingTo: terminalBackground)
    let useInverse = inverse != inverted
    
    // NOTE: no .backgroundColor attribute here — the draw loop fills the exact
    // cell rect itself. AppKit paints the attributed-string background box
    // using font metrics (not the cell rect), which bleeds into adjacent rows.
    let finalForeground: NSColor
    if selected {
      finalForeground = NSColor.selectedTextColor
    } else if useInverse {
      finalForeground = cellBackground ?? terminalBackground
    } else {
      finalForeground = cellForeground
    }
    
    let finalFont = bold ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold) : font
    
    var attrs: [NSAttributedString.Key: Any] = [
      .font: finalFont,
      .foregroundColor: finalForeground
    ]
    if underline {
      attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if italic {
      attrs[.obliqueness] = 0.2
    }
    if dim && !selected {
      attrs[.foregroundColor] = finalForeground.withAlphaComponent(0.6)
    }
    return attrs
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
  
  public var nsColor: NSColor? {
    switch self {
    case .clear:
      return .clear
    case .default:
      return nil
    case .rgb(let red, let green, let blue):
      return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    case .ansi(let index):
      return TerminalColor.color(forAnsiIndex: index)
    }
  }
  
  /// Standard 16-color ANSI palette, tuned for a dark background
  /// (near-black is lifted so it stays visible; the rest are the
  /// conventional xterm hues).
  private static let palette16: [NSColor] = [
    rgb(0x2a, 0x2a, 0x2a), // 0 black
    rgb(0xe0, 0x55, 0x61), // 1 red
    rgb(0x8c, 0xc2, 0x65), // 2 green
    rgb(0xd1, 0x8f, 0x52), // 3 yellow
    rgb(0x4a, 0xa5, 0xf0), // 4 blue
    rgb(0xc5, 0x86, 0xc0), // 5 magenta
    rgb(0x42, 0xb3, 0xc2), // 6 cyan
    rgb(0xdf, 0xdf, 0xdf), // 7 white
    rgb(0x66, 0x66, 0x66), // 8 bright black
    rgb(0xff, 0x61, 0x6e), // 9 bright red
    rgb(0xa5, 0xe0, 0x75), // 10 bright green
    rgb(0xf0, 0xa4, 0x5d), // 11 bright yellow
    rgb(0x71, 0xb8, 0xf9), // 12 bright blue
    rgb(0xe2, 0xa8, 0xdf), // 13 bright magenta
    rgb(0x6c, 0xd8, 0xe0), // 14 bright cyan
    rgb(0xff, 0xff, 0xff)  // 15 bright white
  ]
  
  /// 6x6x6 color cube (indices 16...231).
  private static let colorCube: [NSColor] = {
    let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
    var colors: [NSColor] = []
    colors.reserveCapacity(216)
    for red in levels {
      for green in levels {
        for blue in levels {
          colors.append(NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1))
        }
      }
    }
    return colors
  }()
  
  /// Grayscale ramp (indices 232...255).
  private static let grayscale: [NSColor] = {
    var colors: [NSColor] = []
    colors.reserveCapacity(24)
    for step in 0..<24 {
      let value = CGFloat(8 + 10 * step) / 255
      colors.append(NSColor(calibratedRed: value, green: value, blue: value, alpha: 1))
    }
    return colors
  }()
  
  /// xterm-256color palette lookup. Returns nil for out-of-range indices so
  /// the caller can fall back to the default label color.
  public static func color(forAnsiIndex index: Int) -> NSColor? {
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
  
  private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
    NSColor(calibratedRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
  }
}
