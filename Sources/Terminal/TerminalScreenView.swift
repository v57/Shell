#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
/// (scrollback + grid). The cursor is matched at its absolute content line
/// (`scrollback.count + cursor.row`), so it scrolls with the content: it
/// appears at its content position whenever that line is visible (pinned to
/// the bottom that is the grid row; scrolled up, the scroll offset places
/// it), and is naturally absent once scrolled past it.
public func terminalCellRuns(
  snapshot: TerminalSnapshot,
  line: Int,
  selectionStart: TerminalCursor?,
  selectionEnd: TerminalCursor?
) -> [TerminalCellRun] {
  var runs: [TerminalCellRun] = []
  var column = 0
  let cursorLine = snapshot.scrollback.count + snapshot.cursor.row
  while column < snapshot.columns {
    let cell = snapshot.cell(atLine: line, column: column)
    let isCursor = snapshot.showCursor && line == cursorLine && column == snapshot.cursor.column
    let isSelected = isCellSelected(line: line, column: column, start: selectionStart, end: selectionEnd)

    var end = column + 1
    while end < snapshot.columns {
      let next = snapshot.cell(atLine: line, column: end)
      let nextCursor = snapshot.showCursor && line == cursorLine && end == snapshot.cursor.column
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
/// Behavior is split into three nested ViewModifiers so the body stays a
/// thin composition and each concern is independently testable:
///
/// - `ScrollModifier` (applied to the grid's ScrollView) owns anchor +
///   content-offset tracking, bottom-tailing, and the anchor →
///   `session.scrollbackOffset` sync
/// - `InputModifier` (applied to the whole grid area) owns focus, keyboard,
///   and paste
/// - `SelectionModifier` (applied to the grid's ScrollView — the gesture's
///   `.local` space is the scroll CONTENT space, which its hit-testing maps
///   directly) owns mouse selection, click-to-pin, and edge auto-scroll
///
/// Scroll position is the source of truth: `anchorLine` is the first
/// visible logical line (scrollPosition(id:)); `session.scrollbackOffset`
/// is derived from it so copy/status logic keeps working unchanged.
public struct TerminalScreenView: View {
  @Bindable var session: TerminalSession

  /// Must match the font used by every other part of the app so metrics
  /// and hit-testing agree.
  private static let fontSize: CGFloat = 14
  private static let metrics = fontMetrics(for: monoFont(ofSize: fontSize))

  /// Inset of the grid content from the scroll view's edges (the old
  /// TerminalView `.padding(4)`, moved INSIDE the ScrollView). The scroll
  /// view itself now spans the full safe area — scroll indicators sit at
  /// the edge and content scrolls under the toolbar/notch — while the grid
  /// text keeps a small margin. Must stay below lineHeight/cellWidth:
  /// hit-testing maps through content coordinates, and a shift under one
  /// cell keeps every click on the right line/column.
  private static let gridPadding: CGFloat = 4

  /// The platform monospaced font at the terminal size (regular weight).
  private static func monoFont(ofSize size: CGFloat) -> TerminalFont {
    #if os(macOS)
    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #else
    UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #endif
  }

  // MARK: - Shared interaction state
  //
  // Produced by one modifier, consumed by another, so it lives here and is
  // handed out as bindings: ScrollModifier writes `scrollOffset`,
  // `viewportHeight` (from the scroll geometry — the scroll view's own
  // space) and `anchorLine`; SelectionModifier reads them for the
  // drag-to-edge extension (scrollOffset + viewportHeight) and the
  // drag auto-scroll (anchorLine).

  /// The scroll view's content offset (the content's top edge y in the
  /// scroll view's FRAME space = -scrolled pixels), kept in sync via
  /// `onScrollGeometryChange` (ScrollModifier). SelectionModifier consumes
  /// it to extend a drag to the viewport's top/bottom edge: the edge
  /// inputs (0 / viewportHeight) are frame-space, and the offset converts
  /// them to content lines. The gesture's own hits are ALREADY in content
  /// space and do not go through this.
  @State private var scrollOffset: CGFloat = 0
  /// The scroll view's visible height, reported by the scroll geometry
  /// (`visibleRect.height`) — the drag-to-edge bottom edge, in frame
  /// space. Comes from the scroll view itself, not the GeometryReader, so
  /// it matches the actual viewport whatever its relation to the reader's
  /// size (the scroll view's frame can differ on macOS 15 full-size
  /// content views).
  @State private var viewportHeight: CGFloat = 0

  @FocusState private var focused: Bool
  /// First visible logical line of the scroll view (nil = top).
  @State private var anchorLine: Int?
  @State private var lastGridSize = TerminalGridSize.zero

  public var body: some View {
    // Read observable properties in body (not inside closures) so SwiftUI
    // re-renders on every snapshot/selection change.
    let snapshot = session.snapshot
    let selectionStart = session.selectionStart
    let selectionEnd = session.selectionEnd

    if let message = snapshot.message {
      messageView(message)
    } else {
      // The live grid is the ONLY interactive branch, so resize and the
      // input/selection modifiers are scoped here; the message is a plain
      // status label with no focus, key routing, or selection gesture.
      GeometryReader { geo in
        terminalGrid(
          snapshot: snapshot,
          selectionStart: selectionStart,
          selectionEnd: selectionEnd
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onAppear {
          resizeIfNeeded(to: geo.size)
        }
        .onChange(of: geo.size) { _, newSize in
          resizeIfNeeded(to: newSize)
        }
        .modifier(InputModifier(session: session, focused: $focused, anchorLine: $anchorLine))
      }
    }
  }

  /// The non-interactive status label (connecting / failed). Deliberately
  /// NOT inside the GeometryReader and NOT under InputModifier /
  /// SelectionModifier: the message can't take input, so it shouldn't be
  /// focusable, clickable, or steal keyboard focus.
  private func messageView(_ message: String) -> some View {
    Text(message)
      .font(.system(size: Self.fontSize, design: .monospaced))
      .foregroundStyle(TerminalPalette.secondaryText)
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Rendering

  private func terminalGrid(
    snapshot: TerminalSnapshot,
    selectionStart: TerminalCursor?,
    selectionEnd: TerminalCursor?
  ) -> some View {
    let totalLines = snapshot.totalLines

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(0..<totalLines, id: \.self) { line in
          lineView(
            linePieces(
              snapshot: snapshot,
              line: line,
              selectionStart: selectionStart,
              selectionEnd: selectionEnd
            )
          )
          .frame(height: Self.metrics.lineHeight, alignment: .leading)
        }
      }
      .scrollTargetLayout()
      // Content margin: the scroll view spans the full safe area; only the
      // grid text is inset from its edges.
      .padding(Self.gridPadding)
    }
    // Scrolling behavior (anchor tracking, content-offset reporting,
    // bottom-tailing) lives in ScrollModifier; selection in
    // SelectionModifier. Both are applied DIRECTLY to the ScrollView so
    // the gesture and the scroll geometry share the scroll view's
    // coordinate space — its frame can extend above the GeometryReader's
    // (macOS 15 full-size content under the toolbar), and mixing spaces
    // offsets every hit by the top inset.
    .modifier(ScrollModifier(
      session: session,
      anchorLine: $anchorLine,
      scrollOffset: $scrollOffset,
      viewportHeight: $viewportHeight
    ))
    .modifier(SelectionModifier(
      session: session,
      focused: $focused,
      anchorLine: $anchorLine,
      scrollOffset: $scrollOffset,
      viewportHeight: $viewportHeight
    ))
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
      withAttributes: [.font: monoFont(ofSize: size)]
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
    selectionStart: TerminalCursor?,
    selectionEnd: TerminalCursor?
  ) -> [LinePiece] {
    let terminalBackground = TerminalPalette.windowBackground
    var pieces: [LinePiece] = []

    for run in terminalCellRuns(
      snapshot: snapshot,
      line: line,
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
    cursorBackground: Color,
    terminalBackground: Color
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
      foreground = TerminalPalette.selectionForeground
      background = TerminalPalette.selectionBackground
    } else if isCursor {
      background = cursorBackground
      foreground = cell.inverse ? cellForeground : (cellBackground ?? terminalBackground)
    } else if cell.inverse {
      background = cellForeground
      foreground = cellBackground ?? terminalBackground
    } else {
      foreground = cellForeground
      if let cellBackground {
        background = cellBackground
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

  // MARK: - Resize

  private func resizeIfNeeded(to size: CGSize) {
    // The grid spans the FULL proposal: the GeometryReader already sits
    // inside the safe area (its size excludes the toolbar/sidebar), so
    // rows/columns come straight from it. The scroll view's viewport can
    // extend above the reader (macOS 15 full-size content under the
    // toolbar); that is the scroll geometry's truth and is tracked
    // separately via viewportHeight for drag-to-edge hit-testing.
    let columns = max(1, Int(floor((size.width - Self.gridPadding * 2) / Self.metrics.cellWidth)))
    let rows = max(1, Int(floor((size.height - Self.gridPadding * 2) / Self.metrics.lineHeight)))
    let grid = TerminalGridSize(rows: rows, columns: columns)
    guard grid != lastGridSize else { return }
    lastGridSize = grid
    session.resize(columns: columns, rows: rows)
  }

  // MARK: - Metrics (moved from TerminalInputView)

  /// Font metrics shared by every renderer so cell grids match exactly
  /// (cellWidth/lineHeight/baseline/kern all derive from the same font).
  public static func fontMetrics(for font: TerminalFont) -> TerminalFontMetrics {
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

// MARK: - Scrolling (ScrollModifier)

extension TerminalScreenView {
  /// Scrolling: applied to the grid's ScrollView, it owns the anchor
  /// (`scrollPosition`) and content-offset (`onScrollGeometryChange`)
  /// tracking, follows the bottom when output arrives while pinned there,
  /// and keeps `session.scrollbackOffset` in sync with the anchor (copy and
  /// sidebar status read it). `anchorLine` and `scrollOffset` are owned by
  /// the parent view so SelectionModifier can extend a drag to the viewport
  /// edges (frame-space edges → content lines via the offset) and
  /// auto-scroll the anchor during a drag.
  struct ScrollModifier: ViewModifier {
    @Bindable var session: TerminalSession
    @Binding var anchorLine: Int?
    @Binding var scrollOffset: CGFloat
    @Binding var viewportHeight: CGFloat

    /// The scroll metrics SelectionModifier needs for its frame-space edge
    /// mapping. `contentOffsetY` converts a FRAME-space localY (the
    /// viewport's 0 / viewportHeight edges) to a content line; the
    /// gesture's own hits are already in content space and skip it.
    private struct ScrollMetrics: Equatable {
      var contentOffsetY: CGFloat
      var viewportHeight: CGFloat
    }

    func body(content: Content) -> some View {
      content
        // anchor: .top is REQUIRED — without it SwiftUI scrolls the MINIMAL
        // amount on programmatic sets: the re-anchored bottom line is usually
        // already inside the viewport, so the viewport never moves while the
        // binding claims the new bottom (viewport no longer tails, and
        // selection maps anchorLine + row to lines below the cursor). With
        // .top, writing the binding aligns that line to the viewport's top
        // edge deterministically, and the binding reports the true top-most
        // line as the user scrolls.
        .scrollPosition(id: $anchorLine, anchor: .top)
        // The content offset and viewport height, reported live by the
        // scroll system (the content inset is included in contentOffset.y).
        // SelectionModifier consumes both for the drag-to-edge extension.
        // NOTE: this MUST be onScrollGeometryChange
        // (macOS 15+), not a background-GeometryReader preference — the
        // scroll view moves the content without re-evaluating the reader,
        // so a preference only fires at initial layout and hit-testing
        // silently falls back to "scrolled to the top" (verified
        // empirically Aug 2026).
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
          ScrollMetrics(
            contentOffsetY: geometry.contentOffset.y,
            viewportHeight: geometry.visibleRect.height
          )
        } action: { _, newMetrics in
          scrollOffset = -newMetrics.contentOffsetY
          viewportHeight = newMetrics.viewportHeight
        }
        .onChange(of: session.snapshot.totalLines) { oldTotal, _ in
          // New output: keep following the bottom only when already at bottom.
          // The at-bottom test must use the PREVIOUS total — after a line is
          // appended the stale anchor sits exactly `rows` above the new bottom,
          // so `anchor + rows == oldTotal < newTotal` and the guard would fail
          // on the very first new line, stopping tailing forever.
          Self.followIfAtBottom(wasAtBottomOf: oldTotal, session: session, anchorLine: $anchorLine)
        }
        .onChange(of: session.snapshot.rows) { _, _ in
          // Resize reflows the grid but keeps scrollback, so totalLines changed
          // through rows alone; the current values are the correct baseline (at
          // the bottom this is an exact equality — the anchor does not move).
          Self.followIfAtBottom(wasAtBottomOf: session.snapshot.totalLines, session: session, anchorLine: $anchorLine)
        }
        .onChange(of: anchorLine) { _, newAnchor in
          // Keep session.scrollbackOffset (used by copy/status) in sync.
          session.scrollbackOffset = max(0, session.snapshot.maxOffset - (newAnchor ?? 0))
        }
        .onAppear {
          Self.snapToBottom(session: session, anchorLine: $anchorLine)
        }
    }

    /// Re-anchors to the new bottom when output arrived while the viewport was
    /// pinned to the bottom of the PREVIOUS content (live tailing). When
    /// scrolled up, the anchor is left alone — the frozen viewport keeps
    /// showing the same logical lines (line ids are stable across scrollback
    /// growth). `previousTotalLines` is the content height the current anchor
    /// was computed against; judging against the new total instead fails the
    /// guard the moment a line is added while at the bottom (see the
    /// totalLines onChange above).
    static func followIfAtBottom(wasAtBottomOf previousTotalLines: Int, session: TerminalSession, anchorLine: Binding<Int?>) {
      let snapshot = session.snapshot
      let anchor = anchorLine.wrappedValue ?? 0
      guard anchor + snapshot.rows >= previousTotalLines else { return }
      anchorLine.wrappedValue = max(0, snapshot.totalLines - snapshot.rows)
    }

    /// Re-anchors to the (new) bottom: the initial pin on appear, and the
    /// snap after input that changes the content height (Cmd+K wipes the
    /// scrollback; typing snaps back to the live grid).
    static func snapToBottom(session: TerminalSession, anchorLine: Binding<Int?>) {
      let snapshot = session.snapshot
      anchorLine.wrappedValue = max(0, snapshot.totalLines - snapshot.rows)
    }
  }
}

// MARK: - Input (InputModifier)

extension TerminalScreenView {
  /// Input: focus (the terminal is focusable and grabs focus on appear;
  /// selection flips the same state on mouse-down), keyboard via
  /// `.onKeyPress` feeding TerminalKeyMapper, and Edit > Paste.
  struct InputModifier: ViewModifier {
    @Bindable var session: TerminalSession
    /// The screen's focus state — owned by the parent view, applied here so
    /// every input channel can reach it (the drag gesture's mouse-down also
    /// grants focus).
    let focused: FocusState<Bool>.Binding
    /// Anchor binding: Cmd+K / typing snap back to the bottom after the
    /// content height changes (see ScrollModifier.snapToBottom).
    @Binding var anchorLine: Int?

    func body(content: Content) -> some View {
      content
        .focusable()
        .focused(focused)
        #if os(macOS)
        .focusEffectDisabled()
        #endif
        .onKeyPress { press in
          handleKeyPress(press)
        }
        #if os(macOS)
        .onPasteCommand(of: [UTType.plainText, UTType.utf8PlainText]) { _ in
          pasteFromPasteboard()
        }
        #endif
        .onAppear {
          // Focus must be granted after the view is in the hierarchy.
          DispatchQueue.main.async { focused.wrappedValue = true }
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
      guard press.phase == .down || press.phase == .repeat else { return .ignored }

      let flags = Self.nsFlags(from: press.modifiers)
      // Cmd+K: clean stdout — the scrollback is wiped, so the viewport must
      // snap to the (new) bottom too.
      if flags.contains(.command), press.key.character.lowercased() == "k" {
        session.clearStdout()
        ScrollModifier.snapToBottom(session: session, anchorLine: $anchorLine)
        return .handled
      }
      if !flags.contains(.command) {
        // Typing clears the selection and snaps back to the bottom.
        session.selectionStart = nil
        session.selectionEnd = nil
        ScrollModifier.snapToBottom(session: session, anchorLine: $anchorLine)
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

    /// SwiftUI EventModifiers → portable TerminalModifierFlags (no direct
    /// initializer exists for this conversion in the current SDK).
    private static func nsFlags(from modifiers: EventModifiers) -> TerminalModifierFlags {
      var flags = TerminalModifierFlags()
      if modifiers.contains(.command) { flags.insert(.command) }
      if modifiers.contains(.shift) { flags.insert(.shift) }
      if modifiers.contains(.option) { flags.insert(.option) }
      if modifiers.contains(.control) { flags.insert(.control) }
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

    private func pasteFromPasteboard() {
      #if os(macOS)
      if let string = NSPasteboard.general.string(forType: .string) {
        session.paste(string)
      }
      #else
      if let string = UIPasteboard.general.string {
        session.paste(string)
      }
      #endif
    }
  }
}

// MARK: - Mouse / selection (SelectionModifier)

extension TerminalScreenView {
  /// Mouse selection: a `DragGesture(minimumDistance: 0)` reproducing the old
  /// mouseDown/Dragged/Up semantics — a click on ANY character pins the line
  /// as the sidebar status, dragging selects (with edge auto-scroll via a
  /// repeating timer).
  ///
  /// Applied DIRECTLY to the grid's ScrollView (with ScrollModifier). A
  /// ScrollView's gesture `.local` space is the scroll CONTENT space
  /// (localY already includes the scroll offset and the top content inset),
  /// so `cell(at:)` reads the logical line straight from it — subtracting
  /// the scroll offset again double-counts it and lands every hit `top
  /// inset / lineHeight` lines above the pointer.
  struct SelectionModifier: ViewModifier {
    @Bindable var session: TerminalSession
    /// Granted on mouse-down so the first click also routes the keyboard to
    /// the terminal (owned by the parent view, see InputModifier).
    let focused: FocusState<Bool>.Binding
    /// Shared with ScrollModifier: auto-scroll during a drag moves the anchor.
    @Binding var anchorLine: Int?
    /// Shared with ScrollModifier: hit-testing maps clicks through the
    /// content offset (scroll view space).
    @Binding var scrollOffset: CGFloat
    /// The scroll view's visible height (from the scroll geometry — may
    /// exceed the GeometryReader's height under the toolbar); the
    /// drag-to-edge extension computes the viewport's bottom line from it.
    @Binding var viewportHeight: CGFloat

    /// Non-nil while a drag is in progress (its first change is "mouseDown").
    @State private var dragStart: TerminalCursor?
    @State private var autoScrollTimer: Timer?
    @State private var autoScrollDirection = 0

    func body(content: Content) -> some View {
      content
        .gesture(dragGesture)
        .onDisappear {
          stopAutoScroll()
        }
    }

    private var dragGesture: some Gesture {
      DragGesture(minimumDistance: 0, coordinateSpace: .local)
        .onChanged { value in
          focused.wrappedValue = true
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
      // Defense in depth: the gesture now only exists on the grid branch,
      // but the session can fail between a queued drag event and the view
      // update that swaps in the message.
      guard snapshot.message == nil else { return }
      let target = cell(at: location)

      if dragStart == nil {
        dragStart = target
        // Every mouse-down tentatively starts a selection; mouse-up decides
        // whether it was a CLICK (pins the line as the sidebar status on
        // ANY character) or a drag (keeps the selection).
        let start = TerminalCursor(row: target.row, column: target.column)
        session.selectionStart = start
        session.selectionEnd = start
        session.selectionEpoch = snapshot.selectionEpoch
        return
      }

      guard session.selectionStart != nil else { return }
      let rawRow = Int(floor(location.y / TerminalScreenView.metrics.lineHeight))
      // rawRow is the CONTENT row under the pointer (the gesture's local
      // space is content space). Dragging past the top/bottom edge
      // auto-scrolls the viewport and keeps extending the selection
      // (Terminal.app behavior).
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
        // A click without dragging pins the clicked line as the sidebar
        // status — ANY character of the line works (previously only the
        // last non-blank character did); dragging keeps the selection.
        if start == end {
          session.selectionStart = nil
          session.selectionEnd = nil
          session.toggleStatusPin(start.row)
        }
      }
      dragStart = nil
    }

    /// A mouse-up on the same cell as mouse-down is a CLICK (pins the line
    /// as the sidebar status, any character); any movement is a selection
    /// drag. Kept as a named rule so the click/drag semantics are testable.
    static func isClick(start: TerminalCursor, end: TerminalCursor) -> Bool {
      start == end
    }

    /// The LOGICAL line/column under a point in the drag gesture's space.
    ///
    /// The gesture's `.local` space on a ScrollView is the scroll CONTENT
    /// space: localY already includes the scroll offset and the top content
    /// inset, so the logical line is read straight from it — line k spans
    /// content y [k*lh + gridPadding, (k+1)*lh + gridPadding). Subtracting
    /// the scroll offset a second time double-counts it (a click on content
    /// line 3, localY ≈ 62.5, mapped to line 0). `extendSelectionToEdge`
    /// still maps FRAME-space edges (0 / viewportHeight) and keeps the
    /// scroll-offset formula.
    private func cell(at location: CGPoint) -> TerminalCursor {
      let snapshot = session.snapshot
      let line = min(
        max(
          Int(floor((location.y - TerminalScreenView.gridPadding) / TerminalScreenView.metrics.lineHeight)),
          0
        ),
        snapshot.totalLines - 1
      )
      // The column needs the same gridPadding offset (the content is inset
      // 4pt on both axes); without it the rightmost `gridPadding` px of
      // every cell maps to the NEXT column.
      let column = min(
        max(
          Int(floor((location.x - TerminalScreenView.gridPadding) / TerminalScreenView.metrics.cellWidth)),
          0
        ),
        snapshot.columns - 1
      )
      return TerminalCursor(row: line, column: column)
    }

    /// Pure mapping (unit-tested): the content line under a FRAME-space
    /// `localY` (0 = viewport top, viewportHeight = bottom), given the
    /// scroll content offset. Only the drag-to-edge extension uses this —
    /// the gesture's own hits are already in content space and are read
    /// directly by `cell(at:)`.
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
        lineHeight: TerminalScreenView.metrics.lineHeight,
        totalLines: snapshot.totalLines
      )
      let bottomLine = Self.logicalLine(
        contentOffset: scrollOffset,
        localY: viewportHeight,
        lineHeight: TerminalScreenView.metrics.lineHeight,
        totalLines: snapshot.totalLines
      )
      let edgeLine = direction > 0 ? topLine : bottomLine
      let edgeColumn = direction > 0 ? 0 : snapshot.columns - 1
      session.selectionEnd = TerminalCursor(row: edgeLine, column: edgeColumn)
    }
  }
}
