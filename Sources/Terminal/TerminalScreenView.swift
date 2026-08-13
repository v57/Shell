import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared run helpers (moved from TerminalRenderer.swift)

/// A run of consecutive cells with IDENTICAL attributes (plus identical
/// cursor/selection state), so renderers can draw one text run instead of
/// one layout per cell.
public struct TerminalCellRun {
  var column: Int
  var length: Int
  var cell: TerminalCell
  var isCursor: Bool
  var isSelected: Bool
}

/// Selection hit test in LOGICAL line coordinates (the selection is stored
/// as absolute scrollback+grid lines).
public func isCellSelected(line: Int, column: Int, start: TerminalCursor?, end: TerminalCursor?) -> Bool {
  guard let start, let end else { return false }
  let top = min(start.row, end.row)
  let bottom = max(start.row, end.row)
  guard line >= top && line <= bottom else { return false }
  if top == bottom {
    return column >= min(start.column, end.column) && column <= max(start.column, end.column)
  }
  if line == top {
    return column >= min(start.column, end.column)
  }
  if line == bottom {
    return column <= max(start.column, end.column)
  }
  return true
}

/// Splits one logical line into attribute runs. `line` is the LOGICAL line
/// (scrollback + grid); `row` is the screen row used for cursor hit-testing
/// (only meaningful when `atBottom` is true).
public func terminalCellRuns(
  snapshot: TerminalSnapshot,
  line: Int,
  row: Int,
  atBottom: Bool,
  selectionStart: TerminalCursor?,
  selectionEnd: TerminalCursor?
) -> [TerminalCellRun] {
  var runs: [TerminalCellRun] = []
  var column = 0
  while column < snapshot.columns {
    let cell = snapshot.cell(atLine: line, column: column)
    let isCursor = atBottom && snapshot.showCursor && row == snapshot.cursor.row && column == snapshot.cursor.column
    let isSelected = isCellSelected(line: line, column: column, start: selectionStart, end: selectionEnd)

    var end = column + 1
    while end < snapshot.columns {
      let next = snapshot.cell(atLine: line, column: end)
      let nextCursor = atBottom && snapshot.showCursor && row == snapshot.cursor.row && end == snapshot.cursor.column
      let nextSelected = isCellSelected(line: line, column: end, start: selectionStart, end: selectionEnd)
      if next.foreground == cell.foreground,
         next.background == cell.background,
         next.bold == cell.bold,
         next.dim == cell.dim,
         next.italic == cell.italic,
         next.underline == cell.underline,
         next.inverse == cell.inverse,
         nextCursor == isCursor,
         nextSelected == isSelected {
        end += 1
      } else {
        break
      }
    }
    runs.append(TerminalCellRun(column: column, length: end - column, cell: cell, isCursor: isCursor, isSelected: isSelected))
    column = end
  }
  return runs
}

// MARK: - The pure SwiftUI terminal (rendering AND input)

/// The entire terminal screen as pure SwiftUI — no NSView, no
/// NSViewRepresentable. Renders every logical line (scrollback + grid) as a
/// Text built from an AttributedString inside a LazyVStack, so the native
/// ScrollView owns scrolling; input comes from SwiftUI's own channels:
///
/// - keyboard: `.onKeyPress` (macOS 14+) feeding the existing
///   TerminalKeyMapper via structured parameters (no NSEvent synthesis)
/// - mouse: `DragGesture(minimumDistance: 0)` reproducing the old
///   mouseDown/Dragged/Up selection + status-pin semantics, including
///   edge auto-scroll via a repeating timer
/// - resize: GeometryReader driving session.resize()
/// - paste: `.onPasteCommand` for the Edit > Paste menu route
///
/// Scroll position is the source of truth: `anchorLine` is the first
/// visible logical line (scrollPosition(id:)); `session.scrollbackOffset`
/// is derived from it so copy/status logic keeps working unchanged.
public struct TerminalScreenView: View {
  @Bindable var session: TerminalSession

  /// Must match the font used by every other part of the app so metrics
  /// and hit-testing agree.
  private static let fontSize: CGFloat = 14
  private static let metrics = fontMetrics(
    for: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
  )

  // MARK: - Scroll offset tracking (content-space hit testing)

  /// The scroll view's content offset (the content's top edge y in the
  /// scroll view's space = -scrolled pixels), kept in sync via
  /// `onScrollGeometryChange`. Mouse → cell hit-testing maps through it so
  /// clicks work in CONTENT coordinates: logical line L spans content y
  /// [L*lh, (L+1)*lh) no matter where the viewport is.
  @State private var scrollOffset: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0

  @FocusState private var focused: Bool
  /// First visible logical line of the scroll view (nil = top).
  @State private var anchorLine: Int?
  @State private var lastGridSize = TerminalGridSize.zero
  /// Non-nil while a drag is in progress (its first change is "mouseDown").
  @State private var dragStart: TerminalCursor?
  @State private var autoScrollTimer: Timer?
  @State private var autoScrollDirection = 0

  public var body: some View {
    // Read observable properties in body (not inside closures) so SwiftUI
    // re-renders on every snapshot/selection change.
    let snapshot = session.snapshot
    let selectionStart = session.selectionStart
    let selectionEnd = session.selectionEnd

    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        if let message = snapshot.message {
          Text(message)
            .font(.system(size: Self.fontSize, design: .monospaced))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .padding(16)
        } else {
          terminalGrid(
            snapshot: snapshot,
            selectionStart: selectionStart,
            selectionEnd: selectionEnd
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onAppear {
        resizeIfNeeded(to: geo.size)
        snapToBottom()
        // Focus must be granted after the view is in the hierarchy.
        DispatchQueue.main.async { focused = true }
      }
      .onChange(of: geo.size) { _, newSize in
        resizeIfNeeded(to: newSize)
      }
    }
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress { press in
      handleKeyPress(press)
    }
    .gesture(dragGesture)
    .onPasteCommand(of: [UTType.plainText, UTType.utf8PlainText]) { _ in
      pasteFromPasteboard()
    }
    .onChange(of: session.snapshot.totalLines) { oldTotal, _ in
      // New output: keep following the bottom only when already at bottom.
      // The at-bottom test must use the PREVIOUS total — after a line is
      // appended the stale anchor sits exactly `rows` above the new bottom,
      // so `anchor + rows == oldTotal < newTotal` and the guard would fail
      // on the very first new line, stopping tailing forever.
      followIfAtBottom(wasAtBottomOf: oldTotal)
    }
    .onChange(of: session.snapshot.rows) { _, _ in
      // Resize reflows the grid but keeps scrollback, so totalLines changed
      // through rows alone; the current values are the correct baseline (at
      // the bottom this is an exact equality — the anchor does not move).
      followIfAtBottom(wasAtBottomOf: session.snapshot.totalLines)
    }
    .onChange(of: anchorLine) { _, newAnchor in
      // Keep session.scrollbackOffset (used by copy/status) in sync.
      let snapshot = session.snapshot
      let maxOffset = snapshot.maxOffset
      session.scrollbackOffset = max(0, maxOffset - (newAnchor ?? 0))
    }
    .onDisappear {
      stopAutoScroll()
    }
  }

  // MARK: - Rendering

  private func terminalGrid(
    snapshot: TerminalSnapshot,
    selectionStart: TerminalCursor?,
    selectionEnd: TerminalCursor?
  ) -> some View {
    let rows = snapshot.rows
    let totalLines = snapshot.totalLines
    let atBottom = (anchorLine ?? 0) + rows >= totalLines

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(0..<totalLines, id: \.self) { line in
          lineView(
            linePieces(
              snapshot: snapshot,
              line: line,
              atBottom: atBottom,
              selectionStart: selectionStart,
              selectionEnd: selectionEnd
            )
          )
          .frame(height: Self.metrics.lineHeight, alignment: .leading)
        }
      }
      .scrollTargetLayout()
    }
    // anchor: .top is REQUIRED — without it SwiftUI scrolls the MINIMAL
    // amount on programmatic sets: the re-anchored bottom line is usually
    // already inside the viewport, so the viewport never moves while the
    // binding claims the new bottom (viewport no longer tails, and
    // selection maps anchorLine + row to lines below the cursor). With
    // .top, writing the binding aligns that line to the viewport's top
    // edge deterministically, and the binding reports the true top-most
    // line as the user scrolls.
    .scrollPosition(id: $anchorLine, anchor: .top)
    // The content offset, reported live by the scroll system. Hit-testing
    // maps clicks through it (content coordinates) so the mapping is exact
    // at every scroll position. NOTE: this MUST be onScrollGeometryChange
    // (macOS 15+), not a background-GeometryReader preference — the scroll
    // view moves the content without re-evaluating the reader, so a
    // preference only fires at initial layout and hit-testing silently
    // falls back to "scrolled to the top" (verified empirically Aug 2026).
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      geometry.contentOffset.y
    } action: { _, newOffset in
      scrollOffset = -newOffset
    }
  }

  // MARK: - Per-glyph advance normalization
  //
  // "Monospaced" only guarantees the font's OWN glyphs share an advance.
  // Characters SF Mono doesn't own fall back to other fonts with different
  // advances (measured at 14pt: braille -> AppleBraille 9.57, CJK -> PingFang
  // 13.89, emoji -> Apple Color Emoji 20.0, vs the cell's 8.654). The old
  // single cellKern tracking then over/under-shoots every such glyph and the
  // drift compounds across the line. Fix: give each grapheme cluster a
  // (font size, tracking) pair that lands it on an exact cell boundary:
  //   normal  (advance ~= W, incl. stacking marks/ZWJ) 14pt,  cellKern
  //   tight   (W < a <= 1.2W)  braille                   14pt,  cellWidth - a
  //   scale   (a > 1.2W, single scalar, fits)  CJK/emoji 14*W/a pt,
  //                                                   cellWidth - a'(scaled)
  //   clip    (a > 1.2W multi-scalar, or no fit) ZWJ emoji/flags:
  //                                                   per-cell frame + clip
  // Consecutive clusters with the same (size, tracking) merge into one Text
  // so clean lines stay a single Text (the fast path).
  //
  // NOTE: scaled advances are MEASURED, not assumed — Apple Color Emoji is
  // bitmap-staircased and does not scale linearly (20.0 @14pt -> 9.0 @6.06pt,
  // not 8.65), so tracking absorbs the residual: cellWidth - a'(scaled).

  /// Natural advance of the terminal font's own glyphs (== advance of "W").
  private static let naturalCellWidth = metrics.cellWidth - metrics.cellKern

  /// Per-cluster measured advances. `scaled` is populated only for the
  /// scale class: (size, measured advance at that size). Built lazily;
  /// only non-"W" clusters are ever measured.
  private static var clusterMetrics: [String: (base: CGFloat, scaled: (size: CGFloat, advance: CGFloat)?)] = [:]
  private static func measure(_ cluster: String, at size: CGFloat) -> CGFloat {
    (cluster as NSString).size(
      withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)]
    ).width
  }
  private static func metrics(for cluster: String) -> (base: CGFloat, scaled: (size: CGFloat, advance: CGFloat)?) {
    if let cached = clusterMetrics[cluster] { return cached }
    let base = measure(cluster, at: fontSize)
    var scaled: (size: CGFloat, advance: CGFloat)? = nil
    if base > 1.2 * naturalCellWidth, cluster.unicodeScalars.count == 1 {
      let size = fontSize * naturalCellWidth / base
      let advance = measure(cluster, at: size)
      if advance >= 0.5 * naturalCellWidth {
        scaled = (size, advance)
      }
    }
    let result = (base, scaled)
    clusterMetrics[cluster] = result
    return result
  }

  /// One piece of a rendered line. `.text` pieces are exact-width by
  /// construction (count * cellWidth); `.cell` pieces are single clipped
  /// cells, also cellWidth wide. `background` is the cell-run background
  /// painted as a full-line-height rect behind the glyphs (never embedded
  /// as a text attribute — SwiftUI paints that attribute short, see
  /// pieceView); `cellCount` is the number of cells the piece spans, which
  /// sizes the rect.
  private enum LinePiece {
    case text(AttributedString, background: Color?, cellCount: Int)
    case cell(AttributedString, background: Color?, cellCount: Int)
  }

  /// One logical line as exact-width pieces. Runs come from
  /// terminalCellRuns(); within a run, consecutive clusters whose
  /// (font size, tracking) pair matches merge into one `.text` piece.
  private func linePieces(
    snapshot: TerminalSnapshot,
    line: Int,
    atBottom: Bool,
    selectionStart: TerminalCursor?,
    selectionEnd: TerminalCursor?
  ) -> [LinePiece] {
    let terminalBackground = NSColor.windowBackgroundColor
    let screenRow = line - (snapshot.totalLines - snapshot.rows)
    var pieces: [LinePiece] = []

    for run in terminalCellRuns(
      snapshot: snapshot,
      line: line,
      row: screenRow,
      atBottom: atBottom,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    ) {
      let base = Self.attributes(
        for: run.cell,
        isCursor: run.isCursor,
        isSelected: run.isSelected,
        cursorBackground: snapshot.cursorBackground,
        terminalBackground: terminalBackground
      )
      let baseAttrs = base.attrs
      let baseBackground = base.background
      var segText = ""
      var segCells = 0
      var segSize: CGFloat = 0
      var segTracking: CGFloat = 0

      func flushSegment() {
        guard !segText.isEmpty else { return }
        var font = Font.system(
          size: segSize,
          weight: run.cell.bold ? .semibold : .regular,
          design: .monospaced
        )
        if run.cell.italic { font = font.italic() }
        var attrs = baseAttrs
        attrs.font = font
        attrs.tracking = segTracking
        pieces.append(.text(
          AttributedString(segText, attributes: attrs),
          background: baseBackground,
          cellCount: segCells
        ))
        segText = ""
        segCells = 0
      }

      for column in run.column..<(run.column + run.length) {
        let cell = snapshot.cell(atLine: line, column: column)
        let cluster = cell.isBlank ? " " : String(cell.character)
        guard let pair = Self.segmentMetrics(cluster: cluster) else {
          // .clip: per-cell frame, overflow cut at the cell edge.
          flushSegment()
          pieces.append(.cell(
            AttributedString(cluster, attributes: baseAttrs),
            background: baseBackground,
            cellCount: 1
          ))
          continue
        }
        if segText.isEmpty {
          segText = cluster
          segCells = 1
          segSize = pair.size
          segTracking = pair.tracking
        } else if abs(pair.size - segSize) < 0.25, abs(pair.tracking - segTracking) < 0.1 {
          segText.append(cluster)
          segCells += 1
        } else {
          flushSegment()
          segText = cluster
          segCells = 1
          segSize = pair.size
          segTracking = pair.tracking
        }
      }
      flushSegment()
    }
    return pieces
  }

  /// (font size, tracking) that lands the cluster's glyph on an exact cell
  /// boundary; nil when the cluster needs the clipped per-cell path.
  private static func segmentMetrics(cluster: String) -> (size: CGFloat, tracking: CGFloat)? {
    let m = metrics(for: cluster)
    let base = m.base
    let w = naturalCellWidth
    let cellWidth = metrics.cellWidth
    if base < 0.3 * w || abs(base - w) < 0.1 {
      // SF Mono's own repertoire, plus combining marks / ZWJ / VS: zero-ish
      // advance + cellKern still lands the next glyph on the boundary.
      return (fontSize, metrics.cellKern)
    }
    if base <= 1.2 * w {
      // Slightly over W (braille 9.57): negative tracking, native size.
      // Safe while the overrun is absorbed by side bearing (<= 1.2W).
      return (fontSize, cellWidth - base)
    }
    if cluster.unicodeScalars.count == 1, let scaled = m.scaled {
      // Wide single glyph: scale so the MEASURED advance at the scaled size
      // lands exactly on the boundary (staircased bitmap emoji included).
      return (scaled.size, cellWidth - scaled.advance)
    }
    return nil // multi-scalar wide cluster (ZWJ emoji, flags) -> clip
  }

  /// Assembles the pieces into the line view. Clean lines (one `.text`
  /// piece) render as before — a single Text over one background rect.
  /// Lines with `.clip` cells become an HStack of exact-width pieces
  /// (spacing 0, so piece k starts at column k * cellWidth); clipped cells
  /// overflow their frame rightward and are cut at the cell edge
  /// (Terminal.app behavior).
  @ViewBuilder
  private func lineView(_ pieces: [LinePiece]) -> some View {
    if pieces.count == 1 {
      pieceView(pieces[0])
    } else {
      HStack(alignment: .top, spacing: 0) {
        ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
          pieceView(piece)
        }
      }
    }
  }

  /// A piece with its cell background painted as an exact rect (run width ×
  /// line height) BEHIND the text. The `backgroundColor` text attribute is
  /// never used: SwiftUI paints that attribute over the font-metrics box
  /// (ascender..descender), which is shorter than the line height — colored
  /// cells, selection, the cursor and inverse video then showed horizontal
  /// gaps between rows.
  ///
  /// The rect is painted ALWAYS (`background ?? .clear`) so every piece is
  /// exactly lineHeight tall. Mixed-height pieces in the line's HStack
  /// (short plain Texts next to tall rect Texts) get top-aligned by the
  /// HStack, which lifts the short pieces' text above the centered text of
  /// the background runs — "text shifts up on lines with background".
  @ViewBuilder
  private func pieceView(_ piece: LinePiece) -> some View {
    switch piece {
    case .text(let attr, let background, let cellCount):
      textWithBackground(
        attr,
        background: background,
        width: CGFloat(cellCount) * Self.metrics.cellWidth
      )
    case .cell(let attr, let background, _):
      textWithBackground(
        attr,
        background: background,
        width: Self.metrics.cellWidth
      )
      .frame(width: Self.metrics.cellWidth, alignment: .leading)
      .clipped()
    }
  }

  @ViewBuilder
  private func textWithBackground(
    _ attr: AttributedString,
    background: Color?,
    width: CGFloat
  ) -> some View {
    ZStack(alignment: .leading) {
      Rectangle()
        .fill(background ?? .clear)
        .frame(width: width, height: Self.metrics.lineHeight)
      Text(attr).fixedSize(horizontal: true, vertical: false)
    }
  }

  /// SwiftUI-scoped attributes for one cell run, mirroring the CG renderer's
  /// makeAttributes() semantics exactly: selection wins; the cursor paints a
  /// block in cursorBackground (text in the cell's background color, inverse
  /// cells keep their foreground); inverse swaps fg/bg; dim = 60% alpha;
  /// tracking(kern) lands glyph k on cell k.
  ///
  /// The background color is RETURNED, not embedded: SwiftUI's
  /// `backgroundColor` text attribute paints over the font-metrics box
  /// (ascender..descender), which is shorter than the line height — colored
  /// cells then show gaps between rows. Callers paint the returned color as
  /// an exact full-cell rect behind the text instead.
  private static func attributes(
    for cell: TerminalCell,
    isCursor: Bool,
    isSelected: Bool,
    cursorBackground: NSColor,
    terminalBackground: NSColor
  ) -> (attrs: AttributeContainer, background: Color?) {
    let cellForeground = cell.effectiveForeground()
    let cellBackground = cell.effectiveBackground(defaultingTo: terminalBackground)

    var font = Font.system(
      size: fontSize,
      weight: cell.bold ? .semibold : .regular,
      design: .monospaced
    )
    if cell.italic {
      font = font.italic()
    }

    var foreground: Color
    var background: Color?

    if isSelected {
      foreground = Color(nsColor: .selectedTextColor)
      background = Color(nsColor: .selectedTextBackgroundColor)
    } else if isCursor {
      background = Color(nsColor: cursorBackground)
      foreground = Color(nsColor: cell.inverse ? cellForeground : (cellBackground ?? terminalBackground))
    } else if cell.inverse {
      background = Color(nsColor: cellForeground)
      foreground = Color(nsColor: cellBackground ?? terminalBackground)
    } else {
      foreground = Color(nsColor: cellForeground)
      if let cellBackground {
        background = Color(nsColor: cellBackground)
      }
    }
    if cell.dim && !isSelected {
      foreground = foreground.opacity(0.6)
    }

    var attrs = AttributeContainer()
    attrs.font = font
    attrs.foregroundColor = foreground
    if cell.underline {
      attrs.underlineStyle = .single
    }
    attrs.tracking = metrics.cellKern
    return (attrs, background)
  }

  // MARK: - Keyboard

  private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
    guard press.phase == .down || press.phase == .repeat else { return .ignored }

    let flags = Self.nsFlags(from: press.modifiers)
    if !flags.contains(.command) {
      // Typing clears the selection and snaps back to the bottom.
      session.selectionStart = nil
      session.selectionEnd = nil
      snapToBottom()
    }

    let keyCode = Self.keyCode(for: press.key)
    // charactersIgnoringModifiers is only consulted for ctrl+key control
    // sequences; printable keys report their KeyEquivalent character, while
    // special keys (arrows etc., which have a real keyCode) report nil.
    let charactersIgnoringModifiers = keyCode == 0 ? String(press.key.character) : nil
    session.handleKey(
      characters: press.characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      keyCode: keyCode,
      modifierFlags: flags
    )
    return .handled
  }

  /// SwiftUI EventModifiers → AppKit modifier flags (no direct initializer
  /// exists for this conversion in the current SDK).
  private static func nsFlags(from modifiers: EventModifiers) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags()
    if modifiers.contains(.command) { flags.insert(.command) }
    if modifiers.contains(.shift) { flags.insert(.shift) }
    if modifiers.contains(.option) { flags.insert(.option) }
    if modifiers.contains(.control) { flags.insert(.control) }
    if modifiers.contains(.capsLock) { flags.insert(.capsLock) }
    if modifiers.contains(.numericPad) { flags.insert(.numericPad) }
    if modifiers.contains(.function) { flags.insert(.function) }
    return flags
  }

  /// Maps a SwiftUI KeyEquivalent to the AppKit keyCode the terminal's key
  /// mapper switches on (arrows, home/end, page keys, delete, tab, return,
  /// escape). Printable characters don't need a keyCode (the mapper uses
  /// characters for those), so they map to 0.
  private static func keyCode(for key: KeyEquivalent) -> UInt16 {
    switch key {
    case .upArrow: return 126
    case .downArrow: return 125
    case .leftArrow: return 123
    case .rightArrow: return 124
    case .home: return 115
    case .end: return 119
    case .pageUp: return 116
    case .pageDown: return 121
    case .delete: return 51
    case .deleteForward: return 117
    case .return: return 36
    case .tab: return 48
    case .space: return 49
    case .escape: return 53
    case .clear: return 71
    default: return 0
    }
  }

  // MARK: - Mouse / selection

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { value in
        focused = true
        handleDragChanged(at: value.location)
      }
      .onEnded { value in
        handleDragEnded(at: value.location)
      }
  }

  /// First change = mouseDown (pin on last char or start selection);
  /// later changes = mouseDragged (extend selection, edge auto-scroll).
  private func handleDragChanged(at location: CGPoint) {
    let snapshot = session.snapshot
    guard snapshot.message == nil else { return }
    let target = cell(at: location)

    if dragStart == nil {
      dragStart = target
      // target.row is already the LOGICAL line (content-space mapping).
      let line = target.row
      // Clicking the LAST character of a line pins (or unpins) that line
      // as the sidebar status; clicking anywhere else starts a selection.
      if target.column == snapshot.lastNonBlankColumn(ofLine: line) {
        session.selectionStart = nil
        session.selectionEnd = nil
        session.toggleStatusPin(line)
        return
      }
      let start = TerminalCursor(row: line, column: target.column)
      session.selectionStart = start
      session.selectionEnd = start
      session.selectionEpoch = snapshot.selectionEpoch
      return
    }

    guard session.selectionStart != nil else { return }
    let rawRow = Int(floor(location.y / Self.metrics.lineHeight))
    // Dragging past the top/bottom edge auto-scrolls the viewport and
    // keeps extending the selection (Terminal.app behavior).
    if rawRow < 0 {
      startAutoScroll(direction: 1)  // toward older content
      extendSelectionToEdge(direction: 1)
    } else if rawRow >= snapshot.rows {
      startAutoScroll(direction: -1)  // toward the live grid
      extendSelectionToEdge(direction: -1)
    } else {
      stopAutoScroll()
      session.selectionEnd = cell(at: location)
    }
  }

  private func handleDragEnded(at location: CGPoint) {
    stopAutoScroll()
    if let start = session.selectionStart {
      let end = cell(at: location)
      session.selectionEnd = end
      // A click without dragging clears the selection.
      if start == end {
        session.selectionStart = nil
        session.selectionEnd = nil
      }
    }
    dragStart = nil
  }

  /// The LOGICAL line/column under a point in the view's local space.
  ///
  /// Mapping goes through the scroll CONTENT offset, not the viewport:
  /// logical line L spans content y [L*lh, (L+1)*lh) no matter where the
  /// viewport is, so the result is exact at every scroll position. The old
  /// `anchorLine + floor(localY / lineHeight)` formula assumed grid row 0
  /// sat at the viewport's top — when the viewport height isn't a multiple
  /// of lineHeight, scrolled to the bottom the grid actually sits
  /// `H mod lineHeight` px BELOW the viewport top, and clicks in the lower
  /// part of each line landed on the line BELOW the targeted one (and the
  /// scrollback sliver peeking in above the grid hit the grid's first
  /// line). Reported: "cursor selects the line below the targeted line,
  /// around after half a line; only when scrolled to the bottom."
  private func cell(at location: CGPoint) -> TerminalCursor {
    let snapshot = session.snapshot
    let line = Self.logicalLine(
      contentOffset: scrollOffset,
      localY: location.y,
      lineHeight: Self.metrics.lineHeight,
      totalLines: snapshot.totalLines
    )
    let column = min(max(Int(floor(location.x / Self.metrics.cellWidth)), 0), snapshot.columns - 1)
    return TerminalCursor(row: line, column: column)
  }

  /// Pure hit-test mapping (unit-tested): the logical line under a click at
  /// `localY` (view-local), given the scroll content offset and geometry.
  static func logicalLine(contentOffset: CGFloat, localY: CGFloat, lineHeight: CGFloat, totalLines: Int) -> Int {
    min(max(Int(floor((localY - contentOffset) / lineHeight)), 0), totalLines - 1)
  }

  // MARK: - Edge auto-scroll (selection drag)

  private func startAutoScroll(direction: Int) {
    guard autoScrollDirection != direction else { return }
    stopAutoScroll()
    autoScrollDirection = direction
    let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
      self.autoScrollTick()
    }
    RunLoop.main.add(timer, forMode: .common)
    autoScrollTimer = timer
  }

  private func stopAutoScroll() {
    autoScrollTimer?.invalidate()
    autoScrollTimer = nil
    autoScrollDirection = 0
  }

  private func autoScrollTick() {
    guard autoScrollDirection != 0 else { return }
    let snapshot = session.snapshot
    let anchor = anchorLine ?? 0
    let newAnchor = min(max(0, anchor - autoScrollDirection * 2), snapshot.maxOffset)
    if newAnchor != anchor {
      anchorLine = newAnchor
    }
    extendSelectionToEdge(direction: autoScrollDirection)
  }

  /// Extends the selection endpoint to the viewport's top (direction > 0)
  /// or bottom (direction < 0) edge line, computed in CONTENT coordinates
  /// (exact — no anchor bookkeeping).
  private func extendSelectionToEdge(direction: Int) {
    let snapshot = session.snapshot
    let topLine = Self.logicalLine(
      contentOffset: scrollOffset,
      localY: 0,
      lineHeight: Self.metrics.lineHeight,
      totalLines: snapshot.totalLines
    )
    let bottomLine = Self.logicalLine(
      contentOffset: scrollOffset,
      localY: viewportHeight,
      lineHeight: Self.metrics.lineHeight,
      totalLines: snapshot.totalLines
    )
    let edgeLine = direction > 0 ? topLine : bottomLine
    let edgeColumn = direction > 0 ? 0 : snapshot.columns - 1
    session.selectionEnd = TerminalCursor(row: edgeLine, column: edgeColumn)
  }

  // MARK: - Scroll position

  /// Re-anchors to the new bottom when output arrived while the viewport was
  /// pinned to the bottom of the PREVIOUS content (live tailing). When
  /// scrolled up, the anchor is left alone — the frozen viewport keeps
  /// showing the same logical lines (line ids are stable across scrollback
  /// growth). `previousTotalLines` is the content height the current anchor
  /// was computed against; judging against the new total instead fails the
  /// guard the moment a line is added while at the bottom (see the
  /// totalLines onChange above).
  private func followIfAtBottom(wasAtBottomOf previousTotalLines: Int) {
    let snapshot = session.snapshot
    let anchor = anchorLine ?? 0
    guard anchor + snapshot.rows >= previousTotalLines else { return }
    anchorLine = max(0, snapshot.totalLines - snapshot.rows)
  }

  private func snapToBottom() {
    let snapshot = session.snapshot
    anchorLine = max(0, snapshot.totalLines - snapshot.rows)
  }

  // MARK: - Resize

  private func resizeIfNeeded(to size: CGSize) {
    viewportHeight = size.height
    let columns = max(1, Int(floor(size.width / Self.metrics.cellWidth)))
    let rows = max(1, Int(floor(size.height / Self.metrics.lineHeight)))
    let grid = TerminalGridSize(rows: rows, columns: columns)
    guard grid != lastGridSize else { return }
    lastGridSize = grid
    session.resize(columns: columns, rows: rows)
  }

  // MARK: - Paste

  private func pasteFromPasteboard() {
    if let string = NSPasteboard.general.string(forType: .string) {
      session.paste(string)
    }
  }

  // MARK: - Metrics (moved from TerminalInputView)

  /// Font metrics shared by every renderer so cell grids match exactly
  /// (cellWidth/lineHeight/baseline/kern all derive from the same font).
  public static func fontMetrics(for font: NSFont) -> TerminalFontMetrics {
    let sample = NSString(string: "W")
    let size = sample.size(withAttributes: [.font: font])
    let cellWidth = max(1, ceil(size.width))
    let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading + 4))
    // NSAttributedString.draw(at:) treats the point as the top of the line
    // fragment (the baseline lands `ascender` below it), so offset the line
    // top so the text block is vertically centered in the cell.
    let textHeight = font.ascender - font.descender
    let baselineOffset = max(0, (lineHeight - textHeight) / 2)
    // Cell width is the CEILED advance; the font's real glyph advance is
    // smaller. When batching cells into text runs, kern each glyph by the
    // difference so glyph k lands exactly on the k-th cell boundary.
    let cellKern = cellWidth - size.width
    return TerminalFontMetrics(cellWidth: cellWidth, lineHeight: lineHeight, baselineOffset: baselineOffset, cellKern: cellKern)
  }
}
