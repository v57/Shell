import SwiftUI
import Foundation

// ANSI/VT terminal output parser (byte state machine) + grid model.
// Extracted from the Shell app (TerminalView.swift) into the Terminal library.

// MARK: - Parser

public final class TerminalOutputParser {
  private let sendResponse: (String) -> Void
  private var grid = TerminalGrid(rows: 24, columns: 80)
  private var alternateGrid = TerminalGrid(rows: 24, columns: 80)
  private var usingAlternateScreen = false
  private var state: ParserState = .ground
  private var pendingOSC = ""
  private var pendingCSI = ""
  private var utf8Buffer: [UInt8] = []
  private var utf8Remaining = 0
  private(set) var bracketedPasteEnabled = false
  /// Bumped on content-invalidating events (full clears, RIS, alt-screen
  /// switches) so stale selections can be dropped (see TerminalSession).
  private(set) var selectionEpoch = 0
  /// Serializes parser mutation (consume on the parse queue) against the
  /// session's main-thread reads (snapshot, resize, clearStdout, paste
  /// mode). All mutation happens on ONE queue (the parse queue) so the
  /// lock is only contended by reads — cheap.
  private let lock = NSLock()
  /// The parse queue: background QoS so parsing lands on efficiency cores
  /// and never blocks the main thread. All parser mutation runs here.
  private let parseQueue = DispatchQueue(
    label: "Terminal.TerminalOutputParser.parse",
    qos: .utility   // background-ish: efficiency cores
  )
  
  public init(sendResponse: @escaping (String) -> Void) {
    self.sendResponse = sendResponse
    // The alternate screen (1049) has no scrollback of its own. tmux's
    // pane history comes from region scrolls ON the alt screen, which we
    // capture into the alt grid's scrollback (see recordsRegionScroll).
    alternateGrid.recordsScrollback = false
  }

  /// Consumes output asynchronously on the parse queue. The snapshot is
  /// published later by the session's coalescing timer; callers that need
  /// the result synchronously use `snapshot()` (which locks).
  public func consumeAsync(_ data: Data) {
    parseQueue.async { [self] in
      lock.lock()
      defer { lock.unlock() }
      consumeLocked(data)
    }
  }

  /// Blocks until every previously-enqueued `consumeAsync` block has run.
  /// Used by `flushPendingOutput` so a synchronous publish sees all the
  /// output that was already delivered. Safe from the main thread: the
  /// parse queue is a serial background queue, so `sync` from main never
  /// deadlocks (the parse blocks never hop back to main).
  public func drainParseQueue() {
    parseQueue.sync {}
  }

  /// Consumes output on the CALLING thread (used by tests and by
  /// synchronous paths). Serialized against other access via `lock`.
  public func consume(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    consumeLocked(data)
  }

  private func consumeLocked(_ data: Data) {
    for byte in data {
      consume(byte: byte)
    }
  }

  public func resize(columns: Int, rows: Int) {
    lock.lock()
    defer { lock.unlock() }
    grid.resize(rows: rows, columns: columns)
    alternateGrid.resize(rows: rows, columns: columns)
  }

  public func snapshot() -> TerminalSnapshot {
    snapshot(clearDirty: true)
  }

  /// Snapshot of the active grid. When `clearDirty` is true (default), the
  /// grid's dirty-line set is consumed: the returned snapshot carries the
  /// lines that changed SINCE THE PREVIOUS snapshot, and the grid starts
  /// fresh. Callers that snapshot repeatedly without the session's
  /// coalescing (e.g. tests) pass `clearDirty: false` to accumulate.
  public func snapshot(clearDirty: Bool) -> TerminalSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotLocked(clearDirty: clearDirty)
  }

  /// Snapshot the session's coalescing timer takes: consumes the dirty set
  /// AND reflects `bracketedPasteEnabled` (a parser field the session
  /// reads for paste wrapping) into the snapshot so the main thread never
  /// touches parser state unsynchronized.
  public func snapshotForPublish() -> TerminalSnapshot {
    lock.lock()
    defer { lock.unlock() }
    var s = snapshotLocked(clearDirty: true)
    s.bracketedPasteEnabled = bracketedPasteEnabled
    return s
  }

  private func snapshotLocked(clearDirty: Bool) -> TerminalSnapshot {
    let active = activeGrid
    let dirty = clearDirty ? consumeDirtyLinesLocked() : active.dirtyLines
    return TerminalSnapshot(
      rows: active.rows,
      columns: active.columns,
      cells: active.cells,
      scrollback: active.scrollback,
      scrollbackWrapped: active.scrollbackWrapped,
      gridWrapped: active.rowWrapped,
      cursor: active.cursor,
      showCursor: active.showCursor,
      cursorBackground: active.cursorBackground,
      message: nil,
      selectionEpoch: selectionEpoch,
      dirtyLines: dirty
    )
  }

  /// Reads and clears the ACTIVE grid's dirty set (the snapshot consumes
  /// it so the next snapshot reports only what changed since). Must be
  /// called with `lock` held.
  private func consumeDirtyLinesLocked() -> Set<Int> {
    var active = activeGrid
    let dirty = active.dirtyLines
    active.clearDirtyLines()
    if usingAlternateScreen {
      alternateGrid = active
    } else {
      grid = active
    }
    return dirty
  }

  /// Cmd+K "clean stdout": erase the scrollback and every row except the
  /// cursor's, keeping the current prompt line. Bumps the selection epoch
  /// so any selection (now pointing at erased content) is dropped.
  /// Locked: called from the main thread, serialized against the parse
  /// queue.
  func clearStdout() {
    lock.lock()
    defer { lock.unlock() }
    mutateActiveGrid { $0.clearStdout() }
    selectionEpoch += 1
  }
  
  var activeGrid: TerminalGrid {
    usingAlternateScreen ? alternateGrid : grid
  }
  
  private func mutateActiveGrid(_ update: (inout TerminalGrid) -> Void) {
    var current = activeGrid
    update(&current)
    if usingAlternateScreen {
      alternateGrid = current
    } else {
      grid = current
    }
  }
  
  private func consume(byte: UInt8) {
    switch state {
    case .ground:
      handleGround(byte: byte)
      
    case .escape:
      handleEscape(byte: byte)
      
    case .charset:
      // SCS designator byte (part of ESC ( X / ESC ) X): consume and drop.
      state = .ground
      
    case .csi:
      handleCSI(byte: byte)
      
    case .osc:
      handleOSC(byte: byte)
    }
  }
  
  private func handleGround(byte: UInt8) {
    switch byte {
    case 0x1b:
      state = .escape
    case 0x07:
      break
    case 0x08:
      mutateActiveGrid { $0.backspace() }
    case 0x09:
      mutateActiveGrid { $0.tab() }
    case 0x0a:
      mutateActiveGrid { $0.lineFeed() }
    case 0x0d:
      mutateActiveGrid { $0.carriageReturn() }
    case 0x0c:
      mutateActiveGrid { $0.clearScreen() }
      selectionEpoch += 1
    case 0x0e, 0x0f:
      break
    default:
      if byte >= 0x80 {
        handleUTF8(byte: byte)
      } else if byte >= 0x20 && byte <= 0x7e {
        appendPrintable(byte: byte)
      }
    }
  }
  
  private func handleEscape(byte: UInt8) {
    switch byte {
    case UInt8(ascii: "["):
      pendingCSI = ""
      state = .csi
    case UInt8(ascii: "]"):
      pendingOSC = ""
      state = .osc
    case UInt8(ascii: "("), UInt8(ascii: ")"):
      // SCS: character-set designation, e.g. ESC ( B = select ASCII into
      // G0. tmux emits these on every redraw; the designator byte is part
      // of the sequence, NOT a printable character — print it and stray
      // "B"s appear on screen. The app only renders ASCII, so consume
      // the designator and ignore the designation.
      state = .charset
    case UInt8(ascii: "7"):
      mutateActiveGrid { $0.saveCursor() }
      state = .ground
    case UInt8(ascii: "8"):
      mutateActiveGrid { $0.restoreCursor() }
      state = .ground
    case UInt8(ascii: "c"):
      mutateActiveGrid { $0.reset() }
      selectionEpoch += 1
      state = .ground
    case UInt8(ascii: "D"):
      mutateActiveGrid { $0.lineFeed() }
      state = .ground
    case UInt8(ascii: "M"):
      mutateActiveGrid { $0.reverseIndex() }
      state = .ground
    case UInt8(ascii: "E"):
      mutateActiveGrid { grid in
        grid.carriageReturn()
        grid.lineFeed()
      }
      state = .ground
    case UInt8(ascii: "H"):
      state = .ground
    default:
      state = .ground
    }
  }
  
  private func handleCSI(byte: UInt8) {
    // Parameter bytes (0x30-0x3f) AND intermediate bytes (0x20-0x2f) stay
    // inside the CSI sequence; only the final byte (0x40-0x7e) dispatches.
    // Intermediates matter for DECSCUSR "CSI Ps SP q" (cursor style, sent
    // by ink/prompt_toolkit TUIs): treating the space as the final byte
    // ended the sequence early and leaked its trailing "q" into the grid
    // as a literal character — the "random q on updated lines" bug.
    if byte >= 0x20 && byte <= 0x3f {
      let scalar = UnicodeScalar(byte)
      pendingCSI.append(Character(scalar))
      return
    }
    
    let parsed = parseCSI(pendingCSI)
    let params = parsed.params
    let marker = parsed.marker
    let privateMode = marker == "?"
    pendingCSI = ""
    state = .ground
    
    switch byte {
    case UInt8(ascii: "A"):
      mutateActiveGrid { $0.moveCursor(rowDelta: -max(params.first ?? 1, 1), columnDelta: 0) }
    case UInt8(ascii: "B"):
      mutateActiveGrid { $0.moveCursor(rowDelta: max(params.first ?? 1, 1), columnDelta: 0) }
    case UInt8(ascii: "C"):
      mutateActiveGrid { $0.moveCursor(rowDelta: 0, columnDelta: max(params.first ?? 1, 1)) }
    case UInt8(ascii: "D"):
      mutateActiveGrid { $0.moveCursor(rowDelta: 0, columnDelta: -max(params.first ?? 1, 1)) }
    case UInt8(ascii: "E"):
      mutateActiveGrid { grid in
        grid.moveCursor(rowDelta: max(params.first ?? 1, 1), columnDelta: -grid.cursor.column)
      }
    case UInt8(ascii: "F"):
      mutateActiveGrid { grid in
        grid.moveCursor(rowDelta: -max(params.first ?? 1, 1), columnDelta: -grid.cursor.column)
      }
    case UInt8(ascii: "G"):
      mutateActiveGrid { $0.setCursor(column: max((params.first ?? 1) - 1, 0)) }
    case UInt8(ascii: "H"), UInt8(ascii: "f"):
      let row = max((params.first ?? 1) - 1, 0)
      let column = max((params.dropFirst().first ?? 1) - 1, 0)
      mutateActiveGrid { $0.setCursor(row: row, column: column) }
    case UInt8(ascii: "J"):
      mutateActiveGrid { $0.eraseDisplay(mode: params.first ?? 0) }
      // ED 2/3 clear the whole screen: any selection is stale.
      if (params.first ?? 0) >= 2 { selectionEpoch += 1 }
    case UInt8(ascii: "K"):
      mutateActiveGrid { $0.eraseLine(mode: params.first ?? 0) }
    case UInt8(ascii: "X"):
      mutateActiveGrid { $0.eraseChars(max(params.first ?? 1, 1)) }
    case UInt8(ascii: "P"):
      mutateActiveGrid { $0.deleteChars(max(params.first ?? 1, 1)) }
    case UInt8(ascii: "@"):
      mutateActiveGrid { $0.insertChars(max(params.first ?? 1, 1)) }
    case UInt8(ascii: "L"):
      mutateActiveGrid { $0.insertLines(max(params.first ?? 1, 1)) }
    case UInt8(ascii: "M"):
      mutateActiveGrid { $0.deleteLines(max(params.first ?? 1, 1)) }
    case UInt8(ascii: "S"):
      // SU: scroll the screen up (pushes lines into the scrollback).
      mutateActiveGrid { $0.scrollUp(count: max(params.first ?? 1, 1)) }
    case UInt8(ascii: "T"):
      // SD: scroll the screen down (blank lines appear at the top).
      mutateActiveGrid { $0.scrollDown(count: max(params.first ?? 1, 1)) }
    case UInt8(ascii: "m"):
      mutateActiveGrid { $0.applySGR(params) }
    case UInt8(ascii: "s"):
      mutateActiveGrid { $0.saveCursor() }
    case UInt8(ascii: "u"):
      mutateActiveGrid { $0.restoreCursor() }
    case UInt8(ascii: "c"):
      // Device Attributes: DA1 (CSI c / CSI ? c) and DA2 (CSI > c)
      if marker == ">" {
        sendResponse("\u{1b}[>1;95;0c")
      } else {
        sendResponse("\u{1b}[?1;2c")
      }
    case UInt8(ascii: "q"):
      // XTVERSION (CSI > 0 q, with or without the intermediate space) —
      // answered. DECSCUSR (CSI Ps SP q, cursor style) — deliberately
      // ignored: the view draws its own cursor, and consuming the
      // sequence without rendering is correct for shaped cursors.
      if marker == ">", params.first == 0 {
        sendResponse("\u{1b}[>0|Shell|1.0")
      }
    case UInt8(ascii: "n"):
      if params.first == 6 {
        let grid = activeGrid
        let response = "\u{1b}[\(grid.cursor.row + 1);\(grid.cursor.column + 1)R"
        sendResponse(response)
      }
    case UInt8(ascii: "h"):
      handleModeChange(params: params, privateMode: privateMode, enabled: true)
    case UInt8(ascii: "l"):
      handleModeChange(params: params, privateMode: privateMode, enabled: false)
    case UInt8(ascii: "r"):
      // DECSTBM: set scrolling region
      let top = max((params.first ?? 1) - 1, 0)
      mutateActiveGrid { grid in
        let bottom = params.count > 1 ? min(max(params[1] - 1, top), grid.rows - 1) : grid.rows - 1
        grid.scrollTop = top
        grid.scrollBottom = bottom
        grid.setCursor(row: 0, column: 0)
      }
    default:
      break
    }
  }
  
  private func handleOSC(byte: UInt8) {
    if byte == 0x07 {
      handleOSCString(pendingOSC)
      pendingOSC = ""
      state = .ground
      return
    }
    
    if byte == 0x1b {
      state = .escape
      return
    }
    
    let scalar = UnicodeScalar(byte)
    pendingOSC.append(Character(scalar))
  }
  
  private func handleOSCString(_ string: String) {
    // Title and other OSC sequences are ignored for now.
    if string.hasPrefix("0;") || string.hasPrefix("2;") {
      return
    }
  }
  
  private func appendPrintable(byte: UInt8) {
    let scalar = UnicodeScalar(byte)
    mutateActiveGrid { $0.put(Character(scalar)) }
  }
  
  /// Incremental UTF-8 decoder. Multibyte sequences (>= 0x80) are buffered in
  /// the ground state and only written to the grid once complete; invalid
  /// sequences are discarded so the grid never shows mojibake.
  private func handleUTF8(byte: UInt8) {
    if byte >= 0xc2 && byte <= 0xf4 {
      utf8Buffer = [byte]
      if byte <= 0xdf {
        utf8Remaining = 1
      } else if byte <= 0xef {
        utf8Remaining = 2
      } else {
        utf8Remaining = 3
      }
      return
    }
    
    if byte >= 0x80 && byte <= 0xbf, !utf8Buffer.isEmpty {
      utf8Buffer.append(byte)
      utf8Remaining -= 1
      if utf8Remaining == 0 {
        if let string = String(bytes: utf8Buffer, encoding: .utf8),
           let scalar = string.unicodeScalars.first {
          mutateActiveGrid { $0.put(Character(scalar)) }
        }
        utf8Buffer = []
      }
      return
    }
    
    // Stray continuation byte or invalid lead byte.
    utf8Buffer = []
    utf8Remaining = 0
  }
  
  private func parseCSI(_ raw: String) -> (marker: Character?, params: [Int]) {
    var string = raw
    var marker: Character?
    if let first = string.first, first == "?" || first == ">" || first == "<" || first == "=" {
      marker = first
      string.removeFirst()
    }
    // Strip intermediate bytes (0x20-0x2f, e.g. the space in "2 ") that
    // were accumulated alongside parameters so they still parse:
    // DECSCUSR "2 " -> [2], XTVERSION ">0 " -> marker ">", [0].
    string.removeAll { $0.asciiValue.map { $0 >= 0x20 && $0 <= 0x2f } ?? false }
    guard !string.isEmpty else { return (marker, []) }
    let params = string.split(separator: ";").compactMap { Int($0) }
    return (marker, params)
  }
  
  private func handleModeChange(params: [Int], privateMode: Bool, enabled: Bool) {
    guard privateMode else { return }
    for param in params {
      switch param {
      case 25:
        mutateActiveGrid { $0.showCursor = enabled }
      case 47, 1047, 1049:
        // Alternate screen. 1049 additionally saves/restores the cursor.
        if enabled {
          if param == 1049 {
            if usingAlternateScreen {
              alternateGrid.saveCursor()
            } else {
              grid.saveCursor()
            }
          }
          usingAlternateScreen = true
          alternateGrid.reset()
          // tmux (and other apps that scroll the WHOLE pane with a
          // top-aligned region) drives its pane history through region
          // scrolls on the alt screen; capture those lines into the
          // scrollback so tmux sessions get real scrolling.
          alternateGrid.recordsRegionScroll = true
        } else {
          usingAlternateScreen = false
          if param == 1049 {
            grid.restoreCursor()
          }
        }
        // Screen switch replaces the visible content: selections are stale.
        selectionEpoch += 1
      case 2004:
        bracketedPasteEnabled = enabled
      default:
        break
      }
    }
  }
}

private enum ParserState {
  case ground
  case escape
  /// Inside a character-set designation (SCS): ESC ( X / ESC ) X.
  /// The designator byte is consumed and dropped (the app renders ASCII).
  case charset
  case csi
  case osc
}

struct TerminalGrid {
  var rows: Int
  var columns: Int
  var cells: [TerminalCell]
  var cursor: TerminalCursor
  var savedCursor: TerminalCursor?
  var currentAttributes: TerminalCell
  var showCursor: Bool
  var cursorBackground: Color
  var scrollTop: Int
  var scrollBottom: Int
  /// xterm (xenl) "wrap pending" state: a character written at the last
  /// column does not wrap until the next printable character is written.
  /// A CR (or other non-printing cursor movement) cancels the pending wrap.
  var wrapPending: Bool

  /// Per-screen-row flag: `rowWrapped[r]` is true when row `r`'s content
  /// arrived as a soft-wrap continuation of the row above it (i.e. the row
  /// above hit the last column and wrapped). This is what distinguishes a
  /// line broken by autowrap (one long logical line) from a real newline
  /// (two separate lines). It alone lets resize re-flow wrapped lines and
  /// lets copy/history re-join them — the grid keeps every other operation
  /// physical. Maintained in `put`, `scrollUp`/`scrollDown`/`eraseRow`, and
  /// shift by `insertLines`/`deleteLines`.
  private(set) var rowWrapped: [Bool]

  /// True when lines scrolled off the top should be kept in `scrollback`.
  /// The alternate screen (1049) has no scrollback, so its grid sets false.
  var recordsScrollback = true
  /// True when lines that scroll off the top in a REGION scroll (scroll
  /// region narrower than the full screen) should be kept in `scrollback`.
  /// tmux scrolls its pane with a top-aligned region (rows 1..N-1, the
  /// status line excluded) — that scrolling IS the tmux history, so the
  /// alt screen captures it into the scrollback (giving tmux sessions
  /// real scrollback). Ordinary apps that use mid-screen regions (vim,
  /// less) keep their old behavior: those lines are not terminal history.
  var recordsRegionScroll = false
  /// Screen rows whose VISIBLE content changed since the last snapshot
  /// (the snapshot consumes the set). Only cell-writing operations mark
  /// rows — pure cursor movement and SGR changes do not (nothing paints).
  /// Used by the session to skip no-op publishes and by the renderer to
  /// rebuild only changed lines.
  fileprivate(set) var dirtyLines: Set<Int> = []
  /// Scrollback lines, oldest first. Each row keeps its historical width;
  /// trailing blank/clear-background cells are trimmed to save memory.
  private(set) var scrollback: [[TerminalCell]] = []
  /// Per-scrollback-row version of `rowWrapped`, kept in sync with
  /// `scrollback` (same index, either may hold the flag across the
  /// scrollback/grid seam).
  private(set) var scrollbackWrapped: [Bool] = []
  /// Matches Terminal.app's default scrollback size.
  static let scrollbackLimit = 10_000

  init(rows: Int, columns: Int) {
    self.rows = rows
    self.columns = columns
    self.cells = Array(repeating: TerminalCell.space, count: max(rows, 1) * max(columns, 1))
    self.rowWrapped = Array(repeating: false, count: max(rows, 1))
    self.cursor = .zero
    self.savedCursor = nil
    self.currentAttributes = TerminalCell.space
    self.showCursor = true
    self.cursorBackground = TerminalPalette.selectionBackground
    self.scrollTop = 0
    self.scrollBottom = max(rows - 1, 0)
    self.wrapPending = false
  }
  
  mutating func resize(rows newRows: Int, columns newColumns: Int) {
    guard newRows > 0, newColumns > 0 else { return }
    let oldRows = self.rows
    let oldColumns = self.columns
    let oldCells = cells
    let oldRowWrapped = rowWrapped
    let oldScrollback = scrollback
    let oldCursor = cursor

    // 1. Gather the old buffer as ONE ordered sequence of physical rows
    //    (scrollback first, then the grid), each with its wrapped flag.
    var rowsSeq: [[TerminalCell]] = []
    rowsSeq.reserveCapacity(oldScrollback.count + oldRows)
    rowsSeq.append(contentsOf: oldScrollback)
    for r in 0..<oldRows {
      rowsSeq.append(Array(oldCells[(r * oldColumns)..<((r + 1) * oldColumns)]))
    }
    var wrappedSeq: [Bool] = []
    wrappedSeq.reserveCapacity(oldScrollback.count + oldRows)
    wrappedSeq.append(contentsOf: scrollbackWrapped)
    wrappedSeq.append(contentsOf: oldRowWrapped)

    // 2. Split into logical lines (each a contiguous cell array). The first
    //    row always starts a line; a row whose wrapped flag is set continues
    //    the line above it.
    var lines: [[TerminalCell]] = []
    var lineStarts: [Int] = []   // index into rowsSeq where each logical line begins
    var current: [TerminalCell] = []
    var currentStart = -1
    for i in 0..<rowsSeq.count {
      let row = rowsSeq[i]
      if currentStart == -1 {
        currentStart = i
        current = row
      } else if i < wrappedSeq.count && wrappedSeq[i] {
        current.append(contentsOf: row)
      } else {
        lines.append(trimmedLine(current))
        lineStarts.append(currentStart)
        currentStart = i
        current = row
      }
    }
    if currentStart != -1 {
      lines.append(trimmedLine(current))
      lineStarts.append(currentStart)
    }

    // 3. Locate the cursor's logical line and its column offset within it.
    //    Absolute cell index of the cursor = cells before its physical row +
    //    the column; the line's absolute start is subtracted to get the
    //    offset inside the logical line.
    var prefix: [Int] = [0]
    prefix.reserveCapacity(rowsSeq.count + 1)
    var acc = 0
    for row in rowsSeq { acc += row.count; prefix.append(acc) }
    let cursorPhysical = oldScrollback.count + oldCursor.row
    let cursorAbsCell = prefix[cursorPhysical] + oldCursor.column
    var cursorLine = 0
    for (idx, start) in lineStarts.enumerated() where start <= cursorPhysical {
      cursorLine = idx
    }
    let cursorOffsetInLine = cursorAbsCell - prefix[lineStarts[cursorLine]]

    // Drop grid filler: trailing EMPTY logical lines below the cursor's line
    // and the last content line are just unused screen space (the blank rows
    // a grid holds below the prompt), not real history — they must not
    // re-wrap into a phantom scrollback on a resize from the default grid.
    // Keep everything up to and including the last non-empty line and the
    // cursor's line (the cursor may be sitting on a blank prompt line).
    var lastNonEmpty = lines.count - 1
    while lastNonEmpty >= 0 && lines[lastNonEmpty].isEmpty { lastNonEmpty -= 1 }
    let contentWatermark = max(lastNonEmpty, cursorLine)
    if contentWatermark < lines.count - 1 {
      lines = Array(lines[0...contentWatermark])
      lineStarts = Array(lineStarts[0...contentWatermark])
    }

    // 4. Re-wrap every logical line at the new width into physical rows,
    //    remembering where the cursor's line lands (global row index).
    var newRowsSeq: [[TerminalCell]] = []
    var newWrapped: [Bool] = []
    var cursorLineGlobalStart = -1
    for (li, line) in lines.enumerated() {
      if li == cursorLine { cursorLineGlobalStart = newRowsSeq.count }
      let rw = Self.rewrap(line, width: newColumns)
      newRowsSeq.append(contentsOf: rw)
      // First row of a logical line is a hard start (false); the rest wrap.
      for j in 0..<rw.count { newWrapped.append(j > 0) }
    }

    // 5. Grid = the last newRows physical rows; scrollback = the rest.
    let gridCount = min(newRows, newRowsSeq.count)
    let gridStart = newRowsSeq.count - gridCount

    var newCells = Array(repeating: TerminalCell.space, count: newRows * newColumns)
    var newRowWrapped = Array(repeating: false, count: newRows)
    for j in 0..<gridCount {
      let srcRow = newRowsSeq[gridStart + j]
      for c in 0..<srcRow.count where c < newColumns {
        newCells[j * newColumns + c] = srcRow[c]
      }
      newRowWrapped[j] = newWrapped[gridStart + j]
    }

    var newScrollback = Array(newRowsSeq[0..<gridStart])
    var newScrollbackWrapped = Array(newWrapped[0..<gridStart])
    for i in 0..<newScrollback.count {
      var row = newScrollback[i]
      while let last = row.last, last.isBlank, last.background == .clear {
        row.removeLast()
      }
      newScrollback[i] = row
    }
    if newScrollback.count > Self.scrollbackLimit {
      let overflow = newScrollback.count - Self.scrollbackLimit
      newScrollback.removeFirst(overflow)
      newScrollbackWrapped.removeFirst(overflow)
    }

    // 6. Recompute the cursor's position relative to the grid.
    var newCursorRow: Int
    var newCursorCol: Int
    if cursorLineGlobalStart >= 0 {
      newCursorRow = cursorLineGlobalStart + cursorOffsetInLine / newColumns - gridStart
      newCursorCol = cursorOffsetInLine % newColumns
    } else {
      newCursorRow = gridCount - 1
      newCursorCol = 0
    }

    // 7. Commit.
    self.rows = newRows
    self.columns = newColumns
    self.cells = newCells
    self.rowWrapped = newRowWrapped
    self.scrollback = newScrollback
    self.scrollbackWrapped = newScrollbackWrapped
    self.scrollTop = 0
    self.scrollBottom = newRows - 1
    self.wrapPending = false
    self.cursor = TerminalCursor(
      row: min(max(0, newCursorRow), newRows - 1),
      column: min(max(0, newCursorCol), newColumns - 1)
    )
    markAllDirty()
  }

  /// Re-wraps one logical line (a contiguous cell array with no wrap markers)
  /// into physical rows of `width` columns, reproducing the xenl autowrap
  /// rule used by `put`. Every row but the last is exactly `width` cells; the
  /// last row may be shorter. Because a new row is created only when the
  /// previous row reached the last column, every row after the first of a
  /// line is a soft-wrap continuation.
  private static func rewrap(_ line: [TerminalCell], width: Int) -> [[TerminalCell]] {
    guard width > 0 else { return [[]] }
    if line.isEmpty {
      return [[]]
    }
    var out: [[TerminalCell]] = []
    var row: [TerminalCell] = []
    for cell in line {
      if row.count == width {
        out.append(row)
        row = []
      }
      row.append(cell)
    }
    out.append(row)
    return out
  }

  /// Strips trailing blank cells that carry no background (the padding the
  /// grid stores to fill a full-width row). A logical line's real content ends
  /// at its last non-blank (or BCE) cell; the padding must not be re-wrapped
  /// or it becomes phantom continuation rows.
  private func trimmedLine(_ cells: [TerminalCell]) -> [TerminalCell] {
    var out = cells
    while let last = out.last, last.isBlank, last.background == .clear {
      out.removeLast()
    }
    return out
  }
  
  mutating func reset() {
    cells = Array(repeating: TerminalCell.space, count: rows * columns)
    rowWrapped = Array(repeating: false, count: rows)
    cursor = .zero
    savedCursor = nil
    currentAttributes = TerminalCell.space
    showCursor = true
    scrollTop = 0
    scrollBottom = max(rows - 1, 0)
    wrapPending = false
    scrollback.removeAll()
    scrollbackWrapped.removeAll()
    recordsRegionScroll = false
    markAllDirty()
  }
  
  mutating func saveCursor() {
    savedCursor = cursor
  }
  
  mutating func restoreCursor() {
    if let savedCursor {
      cursor = savedCursor
    }
  }
  
  mutating func setCursor(row: Int? = nil, column: Int? = nil) {
    wrapPending = false
    if let row {
      cursor.row = clamp(row, min: 0, max: rows - 1)
    }
    if let column {
      cursor.column = clamp(column, min: 0, max: columns - 1)
    }
  }
  
  mutating func moveCursor(rowDelta: Int, columnDelta: Int) {
    setCursor(row: cursor.row + rowDelta, column: cursor.column + columnDelta)
  }
  
  mutating func put(_ character: Character) {
    guard rows > 0, columns > 0 else { return }
    var byWrap = false
    if wrapPending {
      // The wrap deferred by the previous last-column write happens now.
      wrapPending = false
      cursor.column = 0
      cursor.row += 1
      if cursor.row > scrollBottom {
        scrollUp()
        cursor.row = scrollBottom
      }
      byWrap = true
    }
    if cursor.column >= columns {
      cursor.column = 0
      cursor.row += 1
      if cursor.row > scrollBottom {
        scrollUp()
        cursor.row = scrollBottom
      }
      byWrap = false
    }

    // The row we're about to write on is a soft-wrap continuation when the
    // cursor arrived here through a deferred wrap; otherwise a write at the
    // first column (after a newline / CR / explicit move) starts a fresh
    // logical line. Writing mid-row (col > 0) leaves the row's structure
    // flag untouched — a wrapped line being partially overwritten is still a
    // wrapped line.
    if byWrap {
      rowWrapped[cursor.row] = true
    } else if cursor.column == 0 {
      rowWrapped[cursor.row] = false
    }

    let index = cursor.row * columns + cursor.column
    guard index >= 0, index < cells.count else { return }
    var cell = currentAttributes
    cell.character = character
    cells[index] = cell
    markDirty(cursor.row)
    if cursor.column < columns - 1 {
      cursor.column += 1
    } else {
      // Reached the last column: enter the wrap-pending state instead of
      // wrapping eagerly. A CR at this point cancels the wrap (this is what
      // makes zsh's PROMPT_SP padding overwrite its % marker instead of
      // leaving it stranded on its own line).
      wrapPending = true
    }
  }
  
  mutating func backspace() {
    wrapPending = false
    cursor.column = max(0, cursor.column - 1)
  }
  
  mutating func tab() {
    wrapPending = false
    let next = ((cursor.column / 8) + 1) * 8
    cursor.column = min(columns - 1, next)
  }
  
  mutating func carriageReturn() {
    wrapPending = false
    cursor.column = 0
  }
  
  mutating func lineFeed() {
    // xterm (xenl): a line feed preserves the column and keeps the pending
    // wrap state, so the next printable character still wraps to the next
    // line (matching xterm.js). Only CR and explicit cursor movement cancel
    // the pending wrap.
    cursor.row += 1
    if cursor.row > scrollBottom {
      scrollUp()
      cursor.row = scrollBottom
    }
  }
  
  mutating func reverseIndex() {
    wrapPending = false
    if cursor.row == scrollTop {
      scrollDown()
    } else {
      cursor.row = max(scrollTop, cursor.row - 1)
    }
  }
  
  mutating func clearScreen() {
    for index in 0..<cells.count {
      cells[index] = erasedCell()
    }
    rowWrapped = Array(repeating: false, count: rows)
    cursor = .zero
    markAllDirty()
  }

  /// Cmd+K "clean stdout": erase the scrollback and every row except the
  /// cursor's, keeping the prompt line and the cursor position untouched.
  /// The shell's line editor model of the screen stays valid (only rows it
  /// never redraws are blanked), so no escape sequence needs to go to the
  /// shell.
  mutating func clearStdout() {
    scrollback.removeAll()
    scrollbackWrapped.removeAll()
    let keepRow = cursor.row
    for row in 0..<rows where row != keepRow {
      eraseRow(row)
    }
  }  
  mutating func eraseDisplay(mode: Int) {
    switch mode {
    case 0:
      eraseLineFromCursor()
      if cursor.row + 1 < rows {
        for row in (cursor.row + 1)..<rows {
          eraseRow(row)
        }
      }
    case 1:
      if cursor.row > 0 {
        for row in 0..<cursor.row {
          eraseRow(row)
        }
      }
      eraseLineToCursor()
    case 2:
      clearScreen()
    case 3:
      // CSI 3 J: erase the scrollback (xterm). The visible screen is
      // untouched.
      scrollback.removeAll()
      scrollbackWrapped.removeAll()
    default:
      break
    }
  }
  
  mutating func eraseLine(mode: Int) {
    switch mode {
    case 0:
      eraseLineFromCursor()
    case 1:
      eraseLineToCursor()
    case 2:
      eraseRow(cursor.row)
    default:
      break
    }
  }
  
  mutating func applySGR(_ params: [Int]) {
    let codes = params.isEmpty ? [0] : params
    var index = 0
    while index < codes.count {
      let code = codes[index]
      switch code {
      case 0:
        currentAttributes = TerminalCell.space
      case 1:
        currentAttributes.bold = true
      case 2:
        currentAttributes.dim = true
      case 3:
        currentAttributes.italic = true
      case 4:
        currentAttributes.underline = true
      case 7:
        currentAttributes.inverse = true
      case 22:
        currentAttributes.bold = false
        currentAttributes.dim = false
      case 23:
        currentAttributes.italic = false
      case 24:
        currentAttributes.underline = false
      case 27:
        currentAttributes.inverse = false
      case 30...37:
        currentAttributes.foreground = .ansi(code - 30)
      case 39:
        currentAttributes.foreground = .default
      case 40...47:
        currentAttributes.background = .ansi(code - 40)
      case 49:
        currentAttributes.background = .clear
      case 90...97:
        currentAttributes.foreground = .ansi(code - 90 + 8)
      case 100...107:
        currentAttributes.background = .ansi(code - 100 + 8)
      case 38, 48:
        let isForeground = code == 38
        if index + 1 < codes.count {
          switch codes[index + 1] {
          case 5 where index + 2 < codes.count:
            let colorIndex = codes[index + 2]
            if isForeground {
              currentAttributes.foreground = .ansi(colorIndex)
            } else {
              currentAttributes.background = .ansi(colorIndex)
            }
            index += 2
          case 2 where index + 4 < codes.count:
            let red = CGFloat(codes[index + 2]) / 255
            let green = CGFloat(codes[index + 3]) / 255
            let blue = CGFloat(codes[index + 4]) / 255
            if isForeground {
              currentAttributes.foreground = .rgb(red: red, green: green, blue: blue)
            } else {
              currentAttributes.background = .rgb(red: red, green: green, blue: blue)
            }
            index += 4
          default:
            break
          }
        }
      default:
        break
      }
      index += 1
    }
  }
  
  mutating func eraseLineFromCursor() {
    guard cursor.row >= 0, cursor.row < rows else { return }
    let start = cursor.row * columns + cursor.column
    let end = cursor.row * columns + columns
    guard start < end else { return }
    for index in start..<end {
      cells[index] = erasedCell()
    }
  }
  
  mutating func eraseLineToCursor() {
    guard cursor.row >= 0, cursor.row < rows else { return }
    let start = cursor.row * columns
    let end = cursor.row * columns + min(cursor.column, columns - 1) + 1
    guard start < end else { return }
    for index in start..<end {
      cells[index] = erasedCell()
    }
  }
  
  mutating func scrollUp() {
    guard rows > 0, columns > 0, scrollTop < scrollBottom else { return }
    // Only full-screen scrolls enter the scrollback, plus top-aligned
    // region scrolls when the grid wants them (tmux's pane history on the
    // alt screen).
    let recordsHistory = recordsScrollback && scrollTop == 0 && (scrollBottom == rows - 1 || recordsRegionScroll)
    if recordsHistory {
      pushScrollbackRow()
    }
    for row in scrollTop..<scrollBottom {
      for column in 0..<columns {
        cells[row * columns + column] = cells[(row + 1) * columns + column]
      }
      // The wrapped flag travels with the row's content.
      rowWrapped[row] = rowWrapped[row + 1]
    }
    eraseRow(scrollBottom)
    if scrollTop > 0 {
      for row in scrollTop...scrollBottom {
        markDirty(row)
      }
    } else {
      // Full-screen scroll: every row shifted up one, all dirty.
      markAllDirty()
    }
  }
  
  mutating func scrollUp(count: Int) {
    guard count > 0 else { return }
    for _ in 0..<count {
      scrollUp()
    }
  }
  
  mutating func scrollDown(count: Int) {
    guard count > 0 else { return }
    for _ in 0..<count {
      scrollDown()
    }
  }
  
  mutating func scrollDown() {
    guard rows > 0, columns > 0, scrollTop < scrollBottom else { return }
    for row in stride(from: scrollBottom, through: scrollTop + 1, by: -1) {
      for column in 0..<columns {
        cells[row * columns + column] = cells[(row - 1) * columns + column]
      }
      // The wrapped flag travels with the row's content.
      rowWrapped[row] = rowWrapped[row - 1]
    }
    eraseRow(scrollTop)
    for row in scrollTop...scrollBottom {
      markDirty(row)
    }
  }
  
  // MARK: Character / line editing (ECH, DCH, ICH, IL, DL)
  
  mutating func eraseChars(_ count: Int) {
    guard count > 0, cursor.column < columns else { return }
    let n = min(count, columns - cursor.column)
    let start = cursor.row * columns + cursor.column
    for index in start..<(start + n) {
      cells[index] = erasedCell()
    }
    markDirty(cursor.row)
  }
  
  mutating func deleteChars(_ count: Int) {
    guard count > 0, cursor.column < columns else { return }
    let n = min(count, columns - cursor.column)
    let rowStart = cursor.row * columns
    for column in cursor.column..<(columns - n) {
      cells[rowStart + column] = cells[rowStart + column + n]
    }
    for column in (columns - n)..<columns {
      cells[rowStart + column] = erasedCell()
    }
    markDirty(cursor.row)
  }
  
  mutating func insertChars(_ count: Int) {
    guard count > 0, cursor.column < columns else { return }
    let n = min(count, columns - cursor.column)
    let rowStart = cursor.row * columns
    for column in stride(from: columns - 1, through: cursor.column + n, by: -1) {
      cells[rowStart + column] = cells[rowStart + column - n]
    }
    for column in cursor.column..<(cursor.column + n) {
      cells[rowStart + column] = erasedCell()
    }
    markDirty(cursor.row)
  }
  
  mutating func insertLines(_ count: Int) {
    guard count > 0, cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
    let n = min(count, scrollBottom - cursor.row + 1)
    for row in stride(from: scrollBottom, through: cursor.row + n, by: -1) {
      for column in 0..<columns {
        cells[row * columns + column] = cells[(row - n) * columns + column]
      }
      rowWrapped[row] = rowWrapped[row - n]
    }
    for row in cursor.row..<(cursor.row + n) {
      eraseRow(row)
    }
    for row in cursor.row...scrollBottom {
      markDirty(row)
    }
  }
  
  mutating func deleteLines(_ count: Int) {
    guard count > 0, cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
    let n = min(count, scrollBottom - cursor.row + 1)
    // Deleting lines at the top of the full screen is a scroll: the lines
    // that leave the screen enter the scrollback like a line feed would.
    if recordsScrollback, cursor.row == 0, scrollTop == 0, scrollBottom == rows - 1 {
      scrollUp(count: n)
      return
    }
    for row in cursor.row...(scrollBottom - n) {
      for column in 0..<columns {
        cells[row * columns + column] = cells[(row + n) * columns + column]
      }
      rowWrapped[row] = rowWrapped[row + n]
    }
    for row in (scrollBottom - n + 1)...scrollBottom {
      eraseRow(row)
    }
    for row in cursor.row...scrollBottom {
      markDirty(row)
    }
  }
  
  mutating func eraseRow(_ row: Int) {
    guard row >= 0, row < rows else { return }
    let start = row * columns
    let end = start + columns
    for index in start..<end {
      cells[index] = erasedCell()
    }
    // A blanked row is not a continuation of the row above.
    rowWrapped[row] = false
    markDirty(row)
  }
  
  /// A blank cell carrying the current SGR attributes (background color
  /// preservation, aka "bce"). Erasures use this so colored editors keep
  /// their background fills across EL/ED/DL/IL operations.
  private func erasedCell() -> TerminalCell {
    var cell = currentAttributes
    cell.character = " "
    return cell
  }

  // MARK: Dirty-line tracking

  fileprivate mutating func markDirty(_ row: Int) {
    guard row >= 0, row < rows else { return }
    dirtyLines.insert(row)
  }

  fileprivate mutating func markAllDirty() {
    guard rows > 0 else { return }
    dirtyLines.formUnion(0..<rows)
  }

  /// Consumed by `TerminalOutputParser.snapshot(clearDirty:)`.
  fileprivate mutating func clearDirtyLines() {
    dirtyLines.removeAll()
  }

  /// Pushes the current top row into the scrollback, trimming trailing
  /// blanks that carry no background (BCE rows keep their colored blanks
  /// so fills don't leave gaps when redrawn).
  private mutating func pushScrollbackRow() {
    var row = Array(cells[0..<columns])
    while let last = row.last, last.isBlank, last.background == .clear {
      row.removeLast()
    }
    scrollback.append(row)
    // The row keeps its wrapped flag with it as it moves off-screen.
    scrollbackWrapped.append(rowWrapped[0])
    if scrollback.count > Self.scrollbackLimit {
      let overflow = scrollback.count - Self.scrollbackLimit
      scrollback.removeFirst(overflow)
      scrollbackWrapped.removeFirst(overflow)
    }
  }
  
  private func clamp(_ value: Int, min: Int, max: Int) -> Int {
    Swift.max(min, Swift.min(max, value))
  }
}

