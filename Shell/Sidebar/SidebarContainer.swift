import Foundation
import SwiftUI

/// The sidebar exists in TWO containers — `SidebarView` (a `List`) and
/// `SidebarView2` (a `ScrollView` + `LazyVStack`). Everything that is not "how a
/// row is drawn" is shared between them: the section composition
/// (`SidebarSections`, Sidebar.swift), the behavior around the rows
/// (`.sidebarChrome(_:)`, SidebarChrome.swift) and the FORMS below, which let
/// ONE set of section views and rows serve both containers.
///
/// A `List` does a lot for its rows: it owns click-selection (through `.tag`),
/// draws the selection highlight and reorders with `.onMove`. A `LazyVStack`
/// does none of it. So the container publishes a `SidebarStyle` and the shared
/// views adapt: rows through `.sidebarRow(_:reorder:)`, sections through
/// `SidebarSection`.

/// HOW the sidebar's rows and headers behave in the container rendering them.
enum SidebarStyle {
  /// A `List` with a `selection` binding: it owns click-selection, the selection
  /// highlight and `.onMove` reordering, so a shared row only TAGS itself with
  /// its `AppModel.Selection`.
  case list
  /// A `ScrollView` + `LazyVStack`: it owns none of that, so a shared row
  /// supplies it itself — tap-selection, the highlight and (for a reorderable
  /// row) drag-to-reorder.
  case lazyStack
}

private struct SidebarStyleKey: EnvironmentKey {
  static let defaultValue: SidebarStyle = .list
}

extension EnvironmentValues {
  /// Set once by the container (`.sidebarStyle`); every shared row and section
  /// header below reads it.
  var sidebarStyle: SidebarStyle {
    get { self[SidebarStyleKey.self] }
    set { self[SidebarStyleKey.self] = newValue }
  }
}

extension View {
  /// Publishes the container style to every row and section header below.
  func sidebarStyle(_ style: SidebarStyle) -> some View {
    environment(\.sidebarStyle, style)
  }
}

private struct SidebarFocusedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Whether the `.lazyStack` container holds keyboard focus — what a `List`
  /// means by an EMPHASIZED selection (accent fill, white text) as opposed to the
  /// gray one it draws while focus is elsewhere. Set by `SidebarView2`.
  var sidebarFocused: Bool {
    get { self[SidebarFocusedKey.self] }
    set { self[SidebarFocusedKey.self] = newValue }
  }
}

private struct SidebarAnimationsKey: EnvironmentKey {
  static let defaultValue = false
}

private struct SidebarSelectionNamespaceKey: EnvironmentKey {
  static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
  /// Whether the sidebar animates (hover, rows coming and going, the selection,
  /// icon changes). Set by `SidebarView2` from the Animations feature and the
  /// system's Reduce Motion; never set by the `List` sidebar, which stays the
  /// system reference.
  var sidebarAnimations: Bool {
    get { self[SidebarAnimationsKey.self] }
    set { self[SidebarAnimationsKey.self] = newValue }
  }

  /// The namespace the selection highlight glides between rows in.
  var sidebarSelectionNamespace: Namespace.ID? {
    get { self[SidebarSelectionNamespaceKey.self] }
    set { self[SidebarSelectionNamespaceKey.self] = newValue }
  }
}

/// The sidebar's motion, in one place.
enum SidebarMotion {
  /// The selection highlight gliding to the newly selected row.
  static let selection = Animation.smooth(duration: 0.3)
  /// Rows inserted, removed, reordered, or a section collapsing.
  static let rows = Animation.smooth(duration: 0.3)
  /// The hover highlight fading in and out.
  static let hover = Animation.easeOut(duration: 0.15)
  /// A row's icons, dots and badges changing.
  static let icon = Animation.smooth(duration: 0.25)

  /// A row slides in from the leading edge and shrinks away when removed.
  static let rowTransition = AnyTransition.asymmetric(
    insertion: .opacity.combined(with: .offset(x: -16)),
    removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .leading))
  )
  /// A dot, badge or icon appearing in or leaving a row.
  static let iconTransition = AnyTransition.scale(scale: 0.4).combined(with: .opacity)
}

extension View {
  /// Animates this view's changes to `value` — only in the sidebar that
  /// animates (`sidebarAnimations`), so the `List` sidebar stays still.
  func sidebarAnimation<V: Equatable>(_ animation: Animation = SidebarMotion.icon, value: V) -> some View {
    modifier(SidebarAnimationModifier(animation: animation, value: value))
  }
}

private struct SidebarAnimationModifier<V: Equatable>: ViewModifier {
  @Environment(\.sidebarAnimations) private var animates
  let animation: Animation
  let value: V

  func body(content: Content) -> some View {
    content.animation(animates ? animation : nil, value: value)
  }
}

/// The geometry a macOS sidebar `List` gives its rows and section headers,
/// measured against the system one so the `.lazyStack` container reproduces it.
enum SidebarMetrics {
  /// The inset of a row's selection highlight from the sidebar's edges.
  static let rowInset: CGFloat = 10
  /// The padding between a row's highlight and its content.
  static let rowPadding = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
  /// The selection highlight's corner radius.
  static let selectionCornerRadius: CGFloat = 8
  /// A section header's height, its insets from the sidebar's edges, and the
  /// gap a section leaves after its last row.
  static let headerHeight: CGFloat = 19
  static let headerInsets = EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 2)
  static let sectionSpacing: CGFloat = 13

  /// The colors a sidebar `List` draws with. Its rows sit on a vibrant material,
  /// which renders the standard label colors differently from plain SwiftUI
  /// content: primary text fully opaque, secondary and tertiary lighter — and in
  /// an inactive window primary text drops to the secondary level. These are the
  /// measured equivalents, per appearance.
  #if os(macOS)
  static func primary(active: Bool) -> Color {
    active ? Color(nsColor: .textColor) : secondary
  }
  static let secondary = vibrant(light: 0.43, dark: 0.36)
  /// A section header's title.
  static let tertiary = vibrant(light: 0.33, dark: 0.24)
  /// The gray (unemphasized) selection highlight; half as strong in an inactive
  /// window.
  static func unemphasizedSelection(active: Bool) -> Color {
    vibrant(light: 0.09, dark: 0.14).opacity(active ? 1 : 0.5)
  }
  /// The hover highlight (animated sidebar only — a `List` has none): a third of
  /// the gray selection.
  static let hover = vibrant(light: 0.03, dark: 0.05)

  /// Black at `light` alpha in the light appearance, white at `dark` alpha in the
  /// dark one.
  private static func vibrant(light: CGFloat, dark: CGFloat) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(white: 1, alpha: dark)
        : NSColor(white: 0, alpha: light)
    })
  }
  #endif

  /// A single-line row's height at the system's sidebar icon size (System
  /// Settings › Appearance) — taller rows (a status line, a subtitle) grow
  /// past it.
  static func rowHeight(_ size: SidebarRowSize) -> CGFloat {
    switch size {
    case .small: 24
    case .large: 40
    default: 32
    }
  }
}

// MARK: - Sections

/// One sidebar section, in the SHAPE the container needs — so a section view
/// never mentions the container it is rendered in:
///
///  - a `List` renders `Section { rows } header: { … }` and styles the header
///    itself;
///  - a `LazyVStack` has no section chrome at all, so the header is emitted as
///    the first view of the group and styles itself (`.sidebarSectionHeader`).
///
/// Takes the same shape as `Section` on purpose, so a section view reads the
/// same either way.
struct SidebarSection<Content: View, Header: View>: View {
  @Environment(\.sidebarStyle) private var style

  private let content: Content
  private let header: Header

  init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
    self.content = content()
    self.header = header()
  }

  var body: some View {
    if style == .lazyStack {
      header
      content
      // The gap a `List` leaves between a section's last row and the next
      // section's header.
      Color.clear.frame(height: SidebarMetrics.sectionSpacing)
    } else {
      Section { content } header: { header }
    }
  }
}

/// A sidebar section's header: the collapse chevron, the section's title (or
/// whatever the section shows beside it) on the left and its controls on the
/// right.
///
/// ONE header view for every section, so its layout and its container styling
/// live in one place. `spacing` is the gap between its views — the Local and
/// Running sections pack their headers tighter than the others.
struct SidebarSectionHeader<Leading: View, Trailing: View>: View {
  @Binding private var collapsed: Bool
  private let spacing: CGFloat
  private let leading: Leading
  private let trailing: Trailing

  init(
    collapsed: Binding<Bool>,
    spacing: CGFloat = 8,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    _collapsed = collapsed
    self.spacing = spacing
    self.leading = leading()
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: spacing) {
      SidebarCollapseChevron(collapsed: $collapsed)
      leading.sidebarSectionTitle()
      Spacer()
      trailing
    }
    .padding(.trailing, 4)
    .sidebarSectionHeader()
  }
}

extension SidebarSectionHeader where Trailing == EmptyView {
  /// A header with no trailing controls (the Running and Text Files sections).
  init(
    collapsed: Binding<Bool>,
    spacing: CGFloat = 8,
    @ViewBuilder leading: () -> Leading
  ) {
    self.init(collapsed: collapsed, spacing: spacing, leading: leading, trailing: { EmptyView() })
  }
}

/// The `.lazyStack` half of a section header: a `LazyVStack` shows the header as
/// an ordinary view, so it carries the height, insets and font a `List` would
/// have applied — the font to the WHOLE header, as a `List` does, so its controls
/// shrink with the title. In a `List` this is a no-op — the list styles and
/// insets the header itself.
private struct SidebarSectionHeaderModifier: ViewModifier {
  @Environment(\.sidebarStyle) private var style

  func body(content: Content) -> some View {
    if style == .lazyStack {
      content
        .font(.subheadline.weight(.semibold))
        .frame(height: SidebarMetrics.headerHeight)
        .padding(SidebarMetrics.headerInsets)
    } else {
      content
    }
  }
}

/// The `.lazyStack` half of a section header's TITLE: a `List` renders section
/// header titles in a dimmer style than the header's controls. Applied by
/// `SidebarSectionHeader` to its leading content only, so the header's controls
/// keep their own styling.
private struct SidebarSectionTitleModifier: ViewModifier {
  @Environment(\.sidebarStyle) private var style

  func body(content: Content) -> some View {
    if style == .lazyStack {
      #if os(macOS)
      content.foregroundStyle(SidebarMetrics.tertiary)
      #else
      content.foregroundStyle(.secondary)
      #endif
    } else {
      content
    }
  }
}

extension View {
  /// Marks this view as a section header's title (see
  /// `SidebarSectionTitleModifier`).
  func sidebarSectionTitle() -> some View {
    modifier(SidebarSectionTitleModifier())
  }

  /// Marks this view as a section header (see `SidebarSectionHeaderModifier`).
  func sidebarSectionHeader() -> some View {
    modifier(SidebarSectionHeaderModifier())
  }
}

// MARK: - Rows

extension View {
  /// Presents this sidebar row the way the ENCLOSING CONTAINER needs it, so ONE
  /// set of rows serves both sidebars:
  ///
  ///  - `List` (`.list`): the row is TAGGED with `selection`; the list then owns
  ///    click-selection, the highlight and `.onMove` reordering. `reorder` is
  ///    ignored — the `List` reorders through its group's `.onMove`.
  ///  - `LazyVStack` (`.lazyStack`): the row takes all of that over — it is
  ///    padded, highlighted while `selection` is the model's selection, selected
  ///    on tap, and (when `reorder` is given) dragged into a new position in its
  ///    list.
  ///
  /// Every sidebar row uses this instead of a bare `.tag(…)`; a section's
  /// `ForEach` passes the row's `SidebarReorderGroup.row(at:)` so the same list
  /// reorders identically in either container.
  func sidebarRow(_ selection: AppModel.Selection, reorder: SidebarReorder? = nil) -> some View {
    modifier(SidebarRowModifier(selection: selection, reorder: reorder))
  }
}

/// A `.lazyStack` row's text and icon colors: white on the accent fill, as a
/// `List` draws an emphasized selection, else the `List`'s vibrant label colors
/// (`SidebarMetrics`).
private struct SidebarRowForeground: ViewModifier {
  let emphasized: Bool
  let active: Bool

  func body(content: Content) -> some View {
    if emphasized {
      content.environment(\.backgroundProminence, .increased)
    } else {
      #if os(macOS)
      content.foregroundStyle(SidebarMetrics.primary(active: active), SidebarMetrics.secondary, SidebarMetrics.tertiary)
      #else
      content
      #endif
    }
  }
}

/// The row modifier behind `.sidebarRow(_:reorder:)`.
private struct SidebarRowModifier: ViewModifier {
  @Environment(AppModel.self) private var model
  @Environment(\.sidebarStyle) private var style
  @Environment(\.sidebarDragState) private var drag
  @Environment(\.sidebarFocused) private var sidebarFocused
  @Environment(\.sidebarRowSize) private var rowSize
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.sidebarAnimations) private var animates
  @Environment(\.sidebarSelectionNamespace) private var selectionNamespace
  let selection: AppModel.Selection
  let reorder: SidebarReorder?

  /// The pointer is over the row (drives the animated sidebar's hover highlight).
  @State private var hovering = false

  private var isSelected: Bool { model.selection == selection }

  /// A `List` draws its selection in the accent color only while it has focus in
  /// the key window; otherwise the highlight is gray.
  private var isEmphasized: Bool { isSelected && sidebarFocused && appearsActive }

  private var selectionFill: Color {
    #if os(macOS)
    isEmphasized ? Color.accentColor : SidebarMetrics.unemphasizedSelection(active: appearsActive)
    #else
    isEmphasized ? Color.accentColor : Color.secondary.opacity(0.2)
    #endif
  }

  private var highlightShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: SidebarMetrics.selectionCornerRadius, style: .continuous)
  }

  private var hoverFill: Color {
    #if os(macOS)
    SidebarMetrics.hover
    #else
    Color.secondary.opacity(0.08)
    #endif
  }

  func body(content: Content) -> some View {
    if style == .lazyStack {
      content
        .padding(SidebarMetrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: SidebarMetrics.rowHeight(rowSize), alignment: .leading)
        .background {
          ZStack {
            if animates, hovering, !isSelected {
              highlightShape
                .fill(hoverFill)
                .transition(.opacity)
            }
            if isSelected {
              highlightShape
                .fill(selectionFill)
                // The highlight glides from the previously selected row.
                .modifier(SidebarSelectionGeometry(namespace: animates ? selectionNamespace : nil))
            }
          }
        }
        .modifier(SidebarRowForeground(emphasized: isEmphasized, active: appearsActive))
        .padding(.horizontal, SidebarMetrics.rowInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(animates ? SidebarMotion.hover : nil, value: hovering)
        .transition(animates ? SidebarMotion.rowTransition : .identity)
        // A `List` writes the selection itself; here the row does, and the
        // container's chrome routes it (connect / attach / open / focus).
        .onTapGesture { model.selection = selection }
        // Drag-to-reorder, for the rows that opted in.
        .modifier(SidebarRowDrag(reorder: reorder, drag: drag))
    } else {
      content.tag(selection)
    }
  }
}

/// Ties a selection highlight to the sidebar's selection namespace, so the one
/// highlight moves between rows instead of blinking from one to the next. A nil
/// namespace (animations off) leaves the highlight in place.
private struct SidebarSelectionGeometry: ViewModifier {
  let namespace: Namespace.ID?

  func body(content: Content) -> some View {
    if let namespace {
      content.matchedGeometryEffect(id: "sidebar.selection", in: namespace)
    } else {
      content
    }
  }
}
