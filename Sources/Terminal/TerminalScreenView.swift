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
  // The endpoint sitting on the TOP row sets the left edge of the highlight
  // there; the endpoint on the BOTTOM row sets the right edge there. This
  // mirrors plainText(logicalFrom:to:) so the highlight and the copied text
  // always agree. Anchoring by min/max of the two columns alone is wrong:
  // dragging down-left (anchor col 20 on an upper row, drag col 5 on a lower
  // row) would highlight the top row from col 5 — the start jumps left — and
  // the bottom row to col 20 — the end snaps to the initial x — instead of
  // top-row-from-20 and bottom-row-to-5.
  let topColumn = start.row <= end.row ? start.column : end.column
  let bottomColumn = start.row <= end.row ? end.column : start.column
  if top == bottom {
    return column >= min(topColumn, bottomColumn) && column <= max(topColumn, bottomColumn)
  }
  if line == top {
    return column >= topColumn
  }
  if line == bottom {
    return column <= bottomColumn
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
/// Behavior is split into three nested ViewModifiers so the body stays a
/// thin composition and each concern is independently testable:
///
/// - `ScrollModifier` (applied to the grid's ScrollView) owns anchor +
///   content-offset tracking, bottom-tailing, and the anchor →
///   `session.scrollbackOffset` sync
/// - `InputModifier` owns focus, keyboard, and paste
/// - `SelectionModifier` owns mouse selection, click-to-pin, and edge
///   auto-scroll
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
  // handed out as bindings: ScrollModifier writes `scrollOffset` and
  // `anchorLine` (and SelectionModifier reads both for hit-testing /
  // auto-scroll); the resize code writes `viewportHeight`, which
  // SelectionModifier reads to extend a drag to the viewport edges.

  /// The scroll view's content offset (the content's top edge y in the
  /// scroll view's space = -scrolled pixels), kept in sync via
  /// `onScrollGeometryChange` (ScrollModifier). Mouse → cell hit-testing
  /// maps through it so clicks work in CONTENT coordinates: logical line L
  /// spans content y [L*lh, (L+1)*lh) no matter where the viewport is.
  @State private var scrollOffset: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0

  @FocusState private var focused: Bool
  /// Whether the iOS on-screen keyboard should be up for this terminal. Driven
  /// by view LIFECYCLE (onAppear/onDisappear) + focus change, NOT only by the
  /// `@FocusState` value — a bare `.focusable()` view's FocusState does not
  /// reliably propagate through a body re-read into a `.background` representable
  /// on iOS, so the keyboard stayed down on session open. onAppear/onDisappear
  /// are the robust triggers.
  @State private var showKeyboard = false
  /// First visible logical line of the scroll view (nil = top).
  @State private var anchorLine: Int?
  @State private var lastGridSize = TerminalGridSize.zero

  /// Theme plumbing: whether character backgrounds are suppressed (set by the
  /// app via the environment) and the EFFECTIVE color scheme (after any
  /// preferredColorScheme override) that contrast decisions key on.
  @Environment(\.terminalBackgroundsDisabled) private var backgroundsDisabled
  @Environment(\.colorScheme) private var colorScheme
  /// Whether the cursor glides between cells (an overlay that animates to the
  /// cursor's cell) instead of being painted into the cell's text run.
  @Environment(\.terminalAnimationsEnabled) private var animationsEnabled

  public var body: some View {
    // Read observable properties in body (not inside closures) so SwiftUI
    // re-renders on every snapshot/selection change.
    let snapshot = session.snapshot
    let selectionStart = session.selectionStart
    let selectionEnd = session.selectionEnd
    // The on-screen keyboard (iOS only) is driven by the `showKeyboard` @State
    // (set in onAppear / onDisappear / tap). SwiftUI @FocusState is NOT used on
    // iOS at all — it fights the UIKeyInput proxy: the instant the proxy becomes
    // first responder, SwiftUI resigns it and collapses the keyboard. On macOS
    // the terminal uses the conventional `focused` SwiftUI focus for its
    // keyboard-input model (see InputModifier).

    Group {
      if let message = snapshot.message {
        messageView(message)
          .transition(.opacity)
      } else {
        // The live grid is the ONLY interactive branch, so resize and the
        // input/selection modifiers are scoped here; the message is a plain
        // status label with no focus, key routing, or selection gesture.
        GeometryReader { geo in
          terminalGrid(
            snapshot: snapshot,
            selectionStart: selectionStart,
            selectionEnd: selectionEnd,
            topInset: geo.safeAreaInsets.top
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .onAppear {
            #if os(iOS)
            // Raise the on-screen keyboard as soon as the live grid is on screen
            // (session open) — independent of any SwiftUI focus involvement.
            showKeyboard = true
            #endif
            resizeIfNeeded(to: geo.size, safeArea: geo.safeAreaInsets)
          }
          #if os(iOS)
          .onDisappear { showKeyboard = false }
          // The keyboard follows the terminal's on-screen presence and taps, NOT
          // SwiftUI focus (#FocusState is not used on iOS — it fights the proxy).
          #endif
          .onChange(of: geo.size) { _, newSize in
            resizeIfNeeded(to: newSize, safeArea: geo.safeAreaInsets)
          }
          .onChange(of: geo.safeAreaInsets) { _, newInsets in
            // Fullscreen / toolbar changes shift the safe area without
            // changing the size; the grid must reflow.
            resizeIfNeeded(to: geo.size, safeArea: newInsets)
          }
          .modifier(InputModifier(session: session, focused: $focused, keyboardOn: showKeyboard, anchorLine: $anchorLine))
          .modifier(SelectionModifier(
            session: session,
            focused: $focused,
            keyboardOn: $showKeyboard,
            anchorLine: $anchorLine,
            scrollOffset: $scrollOffset,
            viewportHeight: $viewportHeight
          ))
          // Floating "scroll to bottom" affordance pinned to the viewport's
          // bottom-trailing corner while the user is scrolled up; tapping it
          // snaps back to the live grid. Exists above the selection drag, so
          // clicks on it never start a selection.
          .overlay(alignment: .bottomTrailing) {
            scrollToBottomButton()
          }
        }
        .transition(.opacity)
      }
    }
    // The connecting message cross-fades into the live grid.
    .animation(animationsEnabled ? .smooth(duration: 0.3) : nil, value: snapshot.message == nil)
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
    selectionEnd: TerminalCursor?,
    topInset: CGFloat
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
              // A gliding cursor is drawn by the overlay below, not into
              // its cell's run.
              atBottom: atBottom && !animationsEnabled,
              selectionStart: selectionStart,
              selectionEnd: selectionEnd
            )
          )
          .frame(height: Self.metrics.lineHeight, alignment: .leading)
        }
      }
      .scrollTargetLayout()
      .overlay(alignment: .topLeading) {
        if animationsEnabled {
          glidingCursor(
            snapshot: snapshot,
            atBottom: atBottom,
            selectionStart: selectionStart,
            selectionEnd: selectionEnd
          )
        }
      }
      // Content margin: the scroll view spans the full safe area; only the
      // grid text is inset from its edges.
      .padding(Self.gridPadding)
    }
    // Scrolling behavior (anchor tracking, content-offset reporting,
    // bottom-tailing) lives in ScrollModifier.
    .modifier(ScrollModifier(session: session, anchorLine: $anchorLine, scrollOffset: $scrollOffset, topInset: topInset))
  }

  // MARK: - Gliding cursor

  /// The cursor as its own view over the grid, so it can glide from cell to
  /// cell: a block in the cursor color carrying the glyph beneath it, drawn
  /// exactly as the run renderer paints a cursor cell (`attributes(for:)`),
  /// positioned in CONTENT coordinates (logical line, column) and animated
  /// between positions. Shown under the same conditions the painted cursor is
  /// — pinned to the bottom, cursor visible — and hidden on a selected cell,
  /// where the selection wins.
  @ViewBuilder
  private func glidingCursor(
    snapshot: TerminalSnapshot,
    atBottom: Bool,
    selectionStart: TerminalCursor?,
    selectionEnd: TerminalCursor?
  ) -> some View {
    let line = snapshot.totalLines - snapshot.rows + snapshot.cursor.row
    let column = min(max(snapshot.cursor.column, 0), snapshot.columns - 1)
    if atBottom, snapshot.showCursor, column >= 0, line >= 0, line < snapshot.totalLines,
       !isCellSelected(line: line, column: column, start: selectionStart, end: selectionEnd) {
      let cell = snapshot.cell(atLine: line, column: column)
      let style = Self.attributes(
        for: cell,
        isCursor: true,
        isSelected: false,
        cursorBackground: snapshot.cursorBackground,
        terminalBackground: TerminalPalette.windowBackground,
        backgroundsDisabled: backgroundsDisabled,
        scheme: colorScheme
      )
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(style.background ?? snapshot.cursorBackground)
        Text(AttributedString(cell.isBlank ? " " : String(cell.character), attributes: style.attrs))
          .fixedSize()
      }
      .frame(width: Self.metrics.cellWidth, height: Self.metrics.lineHeight, alignment: .leading)
      .clipped()
      .offset(
        x: CGFloat(column) * Self.metrics.cellWidth,
        y: CGFloat(line) * Self.metrics.lineHeight
      )
      .animation(.smooth(duration: 0.12), value: [line, column])
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  // MARK: - Scroll-to-bottom affordance

  /// Whether the viewport is pinned to the bottom of the current content
  /// (the live grid). The floating button is shown only when this is false,
  /// i.e. the user has scrolled up into the scrollback.
  /// Reads `anchorLine` (@State) and `snapshot` (@Observable) so the
  /// button's visibility tracks the scroll position live.
  private var isAtBottom: Bool {
    let snapshot = session.snapshot
    return (anchorLine ?? 0) + snapshot.rows >= snapshot.totalLines
  }

  /// The floating bottom-trailing button: `chevron.down.circle.fill` at
  /// 32pt (medium) with the hierarchical rendering style. Hidden when the
  /// viewport is already at the bottom. Tapping re-pins to the live grid
  /// via `ScrollModifier.snapToBottom`.
  @ViewBuilder
  private func scrollToBottomButton() -> some View {
    if !isAtBottom {
      Button {
        ScrollModifier.snapToBottom(session: session, anchorLine: $anchorLine)
      } label: {
        Image(systemName: "chevron.down.circle.fill")
          .font(.system(size: 32, weight: .medium))
          .symbolRenderingMode(.hierarchical)
      }
      .buttonStyle(.plain)
      .padding(12)
      .help("Scroll to bottom")
      .transition(.opacity.combined(with: .scale))
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
    atBottom: Bool,
    selectionStart: TerminalCursor?,
    selectionEnd: TerminalCursor?
  ) -> [LinePiece] {
    let terminalBackground = TerminalPalette.windowBackground
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
        terminalBackground: terminalBackground,
        backgroundsDisabled: backgroundsDisabled,
        scheme: colorScheme
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
    terminalBackground: Color,
    backgroundsDisabled: Bool,
    scheme: ColorScheme
  ) -> (attrs: AttributeContainer, background: Color?) {
    let cellForeground = cell.effectiveForeground()
    let cellBackground = cell.effectiveBackground(defaultingTo: terminalBackground)

    var font = Font.system(
      size: fontSize,
      weight: cell.bold ? .semibold : .regular,
      design: .monospaced
    )
    if cell.italic { font = font.italic() }

    var foreground: Color
    var background: Color?

    if isSelected {
      foreground = TerminalPalette.selectionForeground
      background = TerminalPalette.selectionBackground
    } else if isCursor {
      background = cursorBackground
      foreground = cell.inverse ? cellForeground : (cellBackground ?? terminalBackground)
    } else if cell.inverse {
      if backgroundsDisabled {
        // Suppressed: no inverted block. The foreground candidate is the
        // cell's background color; .default/.clear resolve to the terminal
        // background itself → primary.
        background = nil
        foreground = TerminalContrast.suppressedBackgroundForeground(for: cell.background, scheme: scheme)
      } else {
        background = cellForeground
        foreground = cellBackground ?? terminalBackground
      }
    } else {
      if backgroundsDisabled {
        background = nil
        foreground = TerminalContrast.suppressedBackgroundForeground(for: cell.foreground, scheme: scheme)
      } else {
        foreground = cellForeground
        if let cellBackground { background = cellBackground }
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

  private func resizeIfNeeded(to size: CGSize, safeArea: EdgeInsets) {
    // The grid only ever occupies the safe area; the scroll view may span
    // more (auto-hidden toolbar on macOS, notch/home indicator on iOS), so
    // the size the grid can use is the proposal minus the insets.
    let contentWidth = size.width
    let contentHeight = size.height
    // The viewport's visible bottom edge in local coordinates, used by
    // SelectionModifier to extend a drag to the last visible line.
    viewportHeight = size.height - safeArea.bottom
    let columns = max(1, Int(floor((contentWidth - Self.gridPadding * 2) / Self.metrics.cellWidth)))
    let rows = max(1, Int(floor((contentHeight - Self.gridPadding * 2) / Self.metrics.lineHeight)))
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
  /// the parent view so SelectionModifier can hit-test through the content
  /// offset and auto-scroll the anchor during a drag.
  struct ScrollModifier: ViewModifier {
    @Bindable var session: TerminalSession
    @Binding var anchorLine: Int?
    @Binding var scrollOffset: CGFloat
    let topInset: CGFloat

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
          scrollOffset = -newOffset - topInset
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
    /// The focus value as read by the parent body. Passing it as a plain value
    /// (not just the binding) means a focus change re-evaluates this subtree,
    /// which is what re-invokes the iOS keyboard bridge's updateUIView and lets
    /// the hidden UIKeyInput proxy become first responder.
    let keyboardOn: Bool
    /// Anchor binding: Cmd+K / typing snap back to the bottom after the
    /// content height changes (see ScrollModifier.snapToBottom).
    @Binding var anchorLine: Int?

    func body(content: Content) -> some View {
      // macOS: the terminal holds SwiftUI focus (needed for .onKeyPress and the
      // Edit menu focus model), so it's `.focusable()` + `.focused()`.
      // iOS: DO NOT use `.focusable()/.focused()`/@FocusState. SwiftUI's focus
      // coordinator fights the UIKit first responder: the instant the hidden
      // UITextView proxy becomes first responder, SwiftUI resigns it and the
      // keyboard collapses (oscillating WillShow→DidHide→DidShow→…). The
      // software keyboard is owned by the proxy alone, driven by `keyboardOn`
      // (set from onAppear/onDisappear/tap), so iOS must not participate in
      // SwiftUI focus at all.
      content
        #if os(macOS)
        .focusable()
        .focused(focused)
        .focusEffectDisabled()
        #endif
        .onKeyPress { press in
          handleKeyPress(press)
        }
        #if os(macOS)
        .onPasteCommand(of: [UTType.plainText, UTType.utf8PlainText]) { _ in
          pasteFromPasteboard()
        }
        .onAppear {
          // Focus must be granted after the view is in the hierarchy.
          DispatchQueue.main.async { focused.wrappedValue = true }
        }
        #endif
        #if os(iOS)
        .background {
          // iOS never raises the on-screen keyboard for a bare `.focusable()`
          // view: it is not a text-input responder, so SwiftUI focus alone can
          // never summon the software keyboard (and `.onKeyPress` only delivers
          // HARDWARE keystrokes). An invisible UITextView proxy becomes first
          // responder (raising the keyboard) and forwards the typed characters/
          // backspace to the session.
          TerminalKeyboardBridge(session: session, isFocused: keyboardOn)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
        #endif
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
  /// repeating timer). Hit-testing maps through the scroll CONTENT offset, so
  /// it stays exact at every scroll position.
  struct SelectionModifier: ViewModifier {
    @Bindable var session: TerminalSession
    /// Granted on mouse-down so the first click also routes the keyboard to
    /// the terminal (owned by the parent view, see InputModifier). macOS only —
    /// on iOS SwiftUI focus is NOT used (it fights the UIKeyInput proxy), so a
    /// tap instead raises the software keyboard via `keyboardOn`.
    let focused: FocusState<Bool>.Binding
    /// On iOS, a tap on the grid raises the on-screen keyboard (the proxy is the
    /// sole first responder; there is no @FocusState). macOS uses `focused`.
    @Binding var keyboardOn: Bool
    /// Shared with ScrollModifier: auto-scroll during a drag moves the anchor.
    @Binding var anchorLine: Int?
    /// Shared with ScrollModifier: hit-testing maps clicks through the
    /// content offset.
    @Binding var scrollOffset: CGFloat
    /// Written by the resize code; the drag-to-edge extension computes the
    /// viewport's bottom line from it.
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
          #if os(iOS)
          // Tap the grid -> raise the software keyboard (proxy is the only
          // UIKit first responder; @FocusState is avoided on iOS).
          keyboardOn = true
          #else
          focused.wrappedValue = true
          #endif
          let location = value.location
          let padding = TerminalScreenView.gridPadding
          handleDragChanged(at: CGPoint(x: location.x - padding, y: location.y - padding))
        }
        .onEnded { value in
          let location = value.location
          let padding = TerminalScreenView.gridPadding
          handleDragEnded(at: CGPoint(x: location.x - padding, y: location.y - padding))
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
        // A click without dragging pins the clicked line as the sidebar
        // status — ANY character of the line pins it (full-line), clicking
        // the pinned line's start character toggles start-character mode,
        // clicking another character of the pinned line selects the start
        // character (see clickStatusPin); dragging keeps the selection.
        if start == end {
          session.selectionStart = nil
          session.selectionEnd = nil
          session.clickStatusPin(at: start)
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
        lineHeight: TerminalScreenView.metrics.lineHeight,
        totalLines: snapshot.totalLines
      )
      let column = min(max(Int(floor(location.x / TerminalScreenView.metrics.cellWidth)), 0), snapshot.columns - 1)
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

#if os(iOS)
import UIKit
import Observation

// MARK: - iOS software-keyboard proxy
//
// On iOS the on-screen keyboard is ONLY raised for a live text-input responder
// (a UIView conforming to UIKeyInput, e.g. UITextField/UITextView). A bare
// SwiftUI `.focusable()` view that holds @FocusState is not such a responder,
// so the terminal session opened with no visible on-screen keyboard and no way
// to type. These two types give the terminal a real text-input responder that
// follows SwiftUI focus and forwards the keystrokes through the SAME
// TerminalSession.handleKey(...) path the macOS keyboard uses.

// MARK: - iOS special-keys bar (compressed modifier / function / arrow keys)
//
// The software keyboard has no Tab, Esc, arrow, function or modifier keys that
// a terminal needs, so this bar is presented above it (as the keyboard's
// inputAccessoryView). It compresses alt/ctrl/shift into LATCHING ONE-SHOT
// toggles: tap to latch one or more, then the NEXT key SENT — tapped on the bar
// or typed on the system keyboard — carries them in its modifierFlags and then
// clears every toggle. Tab/Esc are one-shot keys; the arrows and F1-F12 rows
// are revealed behind their own toggle markers.

/// Shared state between the SwiftUI special-keys bar (hosted in the accessory
/// view) and the TerminalKeyInput proxy (which must consume the latch when a
/// key is typed on the system keyboard).
@MainActor
@Observable
private final class TerminalKeyBarModel {
  /// Modifiers currently latched. One-shot: cleared after the next injected
  /// or typed key.
  var latchedModifiers: TerminalModifierFlags = []
  /// Whether the ↑ ↓ ← → row is expanded.
  var showArrows = false
  /// Whether the horizontally scrollable F1-F12 row is expanded.
  var showFunction = false

  func toggle(modifier: TerminalModifierFlags) {
    if latchedModifiers.contains(modifier) {
      latchedModifiers.remove(modifier)
    } else {
      latchedModifiers.insert(modifier)
    }
  }

  /// Returns the latched modifiers and resets every toggle (the one-shot).
  func consumeLatched() -> TerminalModifierFlags {
    let latched = latchedModifiers
    latchedModifiers = []
    return latched
  }

  /// The accessory view's content height for the current expansion state
  /// (matches `.frame(minHeight:maxHeight:)` on the bar so the hosted view
  /// grows/shrinks with the reveal rows).
  var contentHeight: CGFloat {
    let base: CGFloat = 30
    let row: CGFloat = 30
    let spacing: CGFloat = 6
    let padding: CGFloat = 6
    let shownRows = (showArrows ? 1 : 0) + (showFunction ? 1 : 0)
    return padding + base + CGFloat(shownRows) * (row + spacing)
  }
}

/// SwiftUI content of the iOS special-keys bar. Hosted in a UIHostingController
/// and set as TerminalKeyInput.inputAccessoryView, so it renders directly above
/// the on-screen keyboard.
private struct TerminalKeyBar: View {
  let model: TerminalKeyBarModel
  /// Routes a structured key to the session through the SAME handleKey path the
  /// macOS keyboard uses (see InputModifier.handleKeyPress). Mirrors
  /// TerminalSession.handleKey parameters.
  let inject: (String?, String?, UInt16, TerminalModifierFlags) -> Void
  /// Reports the content height so the accessory host can resize.
  let onHeightChange: (CGFloat) -> Void

  private static let fKeyCodes: [(code: UInt16, label: String)] = [
    (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"),
    (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
    (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
  ]

  private static let arrowCodes: [(label: String, code: UInt16)] = [
    ("\u{2191}", 126), ("\u{2193}", 125), ("\u{2190}", 123), ("\u{2192}", 124),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      baseRow
      if model.showArrows { arrowRow }
      if model.showFunction { functionRow }
    }
    .padding(.vertical, 3)
    .frame(maxWidth: .infinity, minHeight: model.contentHeight, maxHeight: model.contentHeight, alignment: .top)
    .background(Color(uiColor: .systemBackground))
    .onAppear { onHeightChange(model.contentHeight) }
    .onChange(of: model.showArrows) { _, _ in onHeightChange(model.contentHeight) }
    .onChange(of: model.showFunction) { _, _ in onHeightChange(model.contentHeight) }
  }

  private var baseRow: some View {
    HStack(spacing: 4) {
      modifierToggle("⌃", modifier: .control)
      modifierToggle("⌥", modifier: .option)
      modifierToggle("⇧", modifier: .shift)
      barButton(width: 38) { keyLabel("⇥", 15, .semibold) } action: { sendKey("\t", nil, 48) }
      barButton(width: 38) { keyLabel("esc", 12, .semibold) } action: { sendKey(nil, nil, 53) }
      markerButton(width: 40, active: model.showArrows) {
        Image(systemName: "arrow.up.and.down")
          .font(.system(size: 14, weight: .medium))
      } action: { model.showArrows.toggle() }
      markerButton(width: 34, active: model.showFunction) {
        keyLabel("F", 14, .semibold)
      } action: { model.showFunction.toggle() }
    }
  }

  private var arrowRow: some View {
    HStack(spacing: 4) {
      ForEach(Self.arrowCodes, id: \.code) { arrow in
        barButton(width: 52) { keyLabel(arrow.label, 16, .medium) } action: {
          sendKey(nil, nil, arrow.code)
        }
      }
    }
  }

  private var functionRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(Self.fKeyCodes, id: \.code) { fkey in
          barButton(width: 44) { keyLabel(fkey.label, 12, .medium) } action: {
            sendKey(nil, nil, fkey.code)
          }
        }
      }
    }
  }

  // MARK: Buttons

  private func modifierToggle(_ symbol: String, modifier: TerminalModifierFlags) -> some View {
    let active = model.latchedModifiers.contains(modifier)
    return barButton(width: 30, active: active) {
      keyLabel(symbol, 15, .medium)
    } action: {
      model.toggle(modifier: modifier)
    }
  }

  private func markerButton<Label: View>(
    width: CGFloat,
    active: Bool,
    @ViewBuilder label: () -> Label,
    action: @escaping () -> Void
  ) -> some View {
    barButton(width: width, active: active, label: label, action: action)
  }

  private func barButton<Label: View>(
    width: CGFloat,
    height: CGFloat = 30,
    active: Bool = false,
    @ViewBuilder label: () -> Label,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      label()
        .foregroundStyle(active ? Color.white : Color(uiColor: .label))
        .frame(width: width, height: height)
        .background(active ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
  }

  private func keyLabel(_ text: String, _ size: CGFloat, _ weight: Font.Weight) -> some View {
    Text(text).font(.system(size: size, weight: weight))
  }

  /// Inject a special key, carrying (and clearing) any latched modifiers.
  private func sendKey(_ characters: String?, _ charactersIgnoringModifiers: String?, _ keyCode: UInt16) {
    let flags = model.consumeLatched()
    inject(characters, charactersIgnoringModifiers, keyCode, flags)
  }
}

/// The terminal's invisible software-keyboard proxy. A real UITextView (rather
/// than a bare UIView conforming to UIKeyInput) because UIKit reliably summons
/// the on-screen keyboard for a UITextView first responder; a plain UIKeyInput
/// UIView does not always raise it from inside a SwiftUI hosting view. Typed
/// characters are forwarded straight to the session and never stored in the
/// view's own text buffer (super is never called in the input overrides).
private final class TerminalKeyInput: UITextView {
  /// The session the typed characters are forwarded to (weak: the session is
  /// owned by the app model, not by this input view).
  weak var session: TerminalSession?

  /// Shared one-shot modifier / reveal state for the special-keys bar; also
  /// consumed when a key is typed on the system keyboard (so latching a
  /// modifier then typing a letter produces the modified sequence).
  let barModel = TerminalKeyBarModel()
  /// Hosts the SwiftUI special-keys bar in the keyboard accessory view.
  private var barHost: UIHostingController<TerminalKeyBar>?

  /// The special-keys bar, shown directly above the on-screen keyboard.
  /// SwiftUI's `.toolbar(.keyboard)` binds to a SwiftUI-focus-aware text input
  /// and does NOT reach this hidden UIKit proxy (which is the sole first
  /// responder and deliberately owns no SwiftUI focus), so the bar is presented
  /// as the proxy's `inputAccessoryView` instead.
  override var inputAccessoryView: UIView? {
    get {
      if barHost == nil {
        let host = UIHostingController(
          rootView: TerminalKeyBar(
            model: barModel,
            inject: { [weak self] characters, charactersIgnoringModifiers, keyCode, modifierFlags in
              self?.session?.handleKey(
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                keyCode: keyCode,
                modifierFlags: modifierFlags
              )
            },
            onHeightChange: { [weak self] height in
              self?.resizeAccessory(height: height)
            }
          )
        )
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: barModel.contentHeight)
        barHost = host
      }
      return barHost?.view
    }
    set {
      // UIKit may set inputAccessoryView on this responder (e.g. during focus
      // or teardown). The special-keys bar is owned/rebuildable via barHost, so
      // an incoming value is deliberately ignored to keep it single-sourced.
    }
  }

  private func resizeAccessory(height: CGFloat) {
    guard let view = barHost?.view else { return }
    var frame = view.frame
    frame.size.height = height
    view.frame = frame
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    configureForTerminal()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureForTerminal()
  }

  override var canBecomeFirstResponder: Bool { true }

  /// Re-sync first responder as soon as the proxy lands in a window. The first
  /// updateUIView can fire BEFORE the view is installed in a real key window
  /// (session opening / split-view detail transition), so becomeFirstResponder()
  /// silently fails; a window-change is the reliable signal to retry against the
  /// LATEST intent (applyFocus keeps wantsFirstResponder current).
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { syncFirstResponder() }
  }

  /// The view's own text buffer is always empty (we never call super in the
  /// input overrides), so `hasText` would normally be false — which makes the
  /// keyboard's backspace key grey out. The terminal buffer is the real content,
  /// so report true so every key (incl. backspace/return) stays enabled.
  override var hasText: Bool { true }

  /// The keyboard must show, so the view stays editable; every other affordance
  /// is stripped so it acts as a dumb keystroke conduit with no text UI of its
  /// own (no autocorrect/autocapitalize/caret/selection).
  private func configureForTerminal() {
    isEditable = true
    // NOT false: an editable-but-not-selectable UITextView is not reliably
    // granted the on-screen keyboard — UIKit requires the responder to be a
    // live text-input (editable AND selectable) before it raises the keyboard
    // for it. Nothing is visible/selectable in practice because text & tint are
    // .clear, the frame is 1x1, and hit-testing is off, so selectable adds no
    // UI while guaranteeing the keyboard rises.
    isSelectable = true
    isScrollEnabled = false
    backgroundColor = .clear
    textColor = .clear
    tintColor = .clear
    autocorrectionType = .no
    autocapitalizationType = .none
    spellCheckingType = .no
    smartInsertDeleteType = .no
    smartQuotesType = .no
    smartDashesType = .no
    keyboardType = .asciiCapable
    inputAssistantItem.leadingBarButtonGroups = []
    inputAssistantItem.trailingBarButtonGroups = []
  }

  override func insertText(_ text: String) {
    // The software keyboard may deliver several characters in one call, and the
    // return key delivers "\n". Route each so newline -> CR (keyCode .return)
    // as the macOS onKeyPress path does, and everything else goes down the
    // printable-character path (keyCode 0). Any latched modifier is applied to
    // each key (and cleared) so latching, say, ctrl then typing "c" on the
    // system keyboard sends Ctrl+C — mirroring the macOS handleKeyPress path.
    // Never call super: the terminal buffer is owned by the session, not by
    // this text view.
    guard let session else { return }
    for char in text {
      let flags = barModel.consumeLatched()
      if char == "\n" || char == "\r" {
        // keyCode 36 -> CR. charactersIgnoringModifiers is nil so a latched
        // ctrl can't map the enter to a nil control-sequence; the latch still
        // gets consumed and reset above.
        session.handleKey(
          characters: "\n",
          charactersIgnoringModifiers: nil,
          keyCode: 36,
          modifierFlags: flags
        )
      } else {
        let value = String(char)
        session.handleKey(
          characters: value,
          charactersIgnoringModifiers: value,
          keyCode: 0,
          modifierFlags: flags
        )
      }
    }
  }

  override func deleteBackward() {
    session?.handleKey(
      characters: "\u{7f}",
      charactersIgnoringModifiers: nil,
      keyCode: 51,
      modifierFlags: barModel.consumeLatched()
    )
  }

  /// The latest desired first-responder state. A becomeFirstResponder() retry
  /// re-checks THIS (not a captured stale `true`), so a keyboard dismissed by
  /// the user while a retry is pending resigns instead of fighting to re-raise.
  private(set) var wantsFirstResponder = false
  /// The in-flight continuous retry dispatcher, so a new intent cancels it and
  /// a satisfied/detached view stops polling.
  private var focusRetryWork: DispatchWorkItem?

  /// Align the UIKit first responder with SwiftUI focus. Called from the
  /// bridge whenever the focus value changes.
  func applyFocus(wantFirstResponder: Bool) {
    wantsFirstResponder = wantFirstResponder
    focusRetryWork?.cancel()
    syncFirstResponder()
  }

  /// Become first responder (raising the keyboard) while the terminal wants it,
  /// retrying CONTINUOUSLY until it sticks, the intent changes, or the view is
  /// not in a window. A bounded few-tick retry is not enough for a two-column
  /// `NavigationSplitView` (iPhone landscape / iPad with visible sidebar): the
  /// detail's window can take a beat to become KEY after the sidebar selection,
  /// so `becomeFirstResponder()` silently fails every bounded attempt and, once
  /// they're exhausted, a later tap doesn't re-trigger (SwiftUI sees no value
  /// change). Using a key-window guard + continuous retry covers that transition.
  private func syncFirstResponder() {
    guard wantsFirstResponder else {
      if isFirstResponder { _ = resignFirstResponder() }
      return
    }
    guard !isFirstResponder else { return }
    // Only become first responder in a KEY window; otherwise wait. Keep polling
    // only while we're actually installed in a window (a detached view re-arms
    // via didMoveToWindow instead of spinning).
    guard window?.isKeyWindow == true else {
      if window != nil { scheduleFocusRetry() }
      return
    }
    if becomeFirstResponder() { return }
    scheduleFocusRetry()
  }

  private func scheduleFocusRetry() {
    focusRetryWork?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.syncFirstResponder() }
    focusRetryWork = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
  }

  /// If the system dismisses the keyboard (interactive swipe / hardware) while
  /// we still want first responder, stop the retry loop — don't fight the user.
  override func resignFirstResponder() -> Bool {
    let ok = super.resignFirstResponder()
    if ok, wantsFirstResponder {
      wantsFirstResponder = false
      focusRetryWork?.cancel()
    }
    return ok
  }
}

/// SwiftUI host for `TerminalKeyInput`. Synchronizes SwiftUI focus with the
/// UIKit first responder so the on-screen keyboard follows the terminal's
/// focus: appear / tap -> become first responder (keyboard up), focus lost ->
/// resign (keyboard down). `isFocused` is a PLAIN bool captured by the parent
/// body, so a focus change produces a new representable value and SwiftUI
/// re-invokes updateUIView with it.
private struct TerminalKeyboardBridge: UIViewRepresentable {
  let session: TerminalSession
  let isFocused: Bool

  func makeUIView(context: Context) -> TerminalKeyInput {
    let view = TerminalKeyInput(frame: .zero)
    view.session = session
    return view
  }

  func updateUIView(_ uiView: TerminalKeyInput, context: Context) {
    uiView.session = session
    // becomeFirstResponder()/resignFirstResponder() can't be called from inside
    // a layout pass, so defer to the next runloop tick.
    DispatchQueue.main.async { uiView.applyFocus(wantFirstResponder: isFocused) }
  }
}
#endif
