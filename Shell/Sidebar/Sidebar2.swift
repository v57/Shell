//
//  Sidebar2.swift
//  Shell
//
//  Created by Dmitry on 18.09.26.
//

import SwiftUI
import Terminal
import TerminalIntegrations

/// The sidebar on a `ScrollView` + `LazyVStack` instead of a `List`.
///
/// Everything but the container is SHARED with `SidebarView` (Sidebar.swift):
/// the same `SidebarSections` render the same section views, and
/// `.sidebarChrome(_:)` (SidebarChrome.swift) adds the same selection routing,
/// sheets and stats-monitor lifetime. What a `LazyVStack` does NOT have is what
/// a `List` does for its rows, so this container supplies it:
///
///  - `.sidebarStyle(.lazyStack)` tells every shared row/header to take over
///    tap-selection, the selection highlight and section-header styling
///    (`.sidebarRow(_:reorder:)`, `SidebarSection`, SidebarContainer.swift);
///  - `SidebarDragState` (SidebarReorder.swift) is what makes drag-to-reorder
///    work: each reorderable row publishes the list it is in and its index, and
///    a row it is dragged over moves it to that position — the same model `move`
///    call the `List` makes through `.onMove`.
struct SidebarView2: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// What the sections and the chrome share (see `SidebarState`); this container
  /// carries its OWN instance, like `SidebarView` does.
  @State private var state = SidebarState()
  /// The row drag in progress — how a drop target finds the dragged row.
  @State private var drag = SidebarDragState()
  /// Whether the sidebar holds keyboard focus, as a `List` does once a row is
  /// clicked — what turns its selection highlight from gray to the accent color.
  @FocusState private var focused: Bool
  /// While the window is unfocused every animation in here goes still — but
  /// the container stays mounted (ContentView picks the container from the
  /// feature flag alone, so focus never swaps SidebarView2 for SidebarView).
  @WindowAppearsActive private var appearsActive
  /// Where the selection highlight glides between rows.
  @Namespace private var selectionNamespace

  private var flags: FeatureFlagsStore { .shared }

  /// The Animations feature, unless the system asks for reduced motion or the
  /// window is unfocused (frozen windows go still, but stay mounted).
  private var animates: Bool {
    flags.isEnabled(.animations) && !reduceMotion && appearsActive
  }

  var body: some View {
    ScrollView {
      // Rows and headers carry the `List` insets themselves (`SidebarMetrics`).
      LazyVStack(alignment: .leading, spacing: 0) {
        SidebarSections(state: state)
      }
      // Rows coming, going and reordering (and sections collapsing — the
      // chevron animates its own toggle) slide rather than jump.
      .animation(animates ? SidebarMotion.rows : nil, value: rowIdentities)
      // The selection highlight glides to the newly selected row, and turns
      // accent-colored or gray as the sidebar gains or loses focus.
      .animation(animates ? SidebarMotion.selection : nil, value: model.selection)
      .animation(animates ? SidebarMotion.selection : nil, value: focused)
    }
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    // A click on a row focuses the sidebar, like a click into a `List`.
    .simultaneousGesture(TapGesture().onEnded { focused = true })
    .environment(\.sidebarFocused, focused)
    .environment(\.sidebarAnimations, animates)
    .environment(\.sidebarSelectionNamespace, selectionNamespace)
    .sidebarStyle(.lazyStack)
    .sidebarDragState(drag)
    .sidebarChrome(state)
  }

  /// The identities of every row the sections render, in order: a change here
  /// is a row inserted, removed or moved, which the stack animates.
  private var rowIdentities: Int {
    var hasher = Hasher()
    hasher.combine(model.sessions.map(\.id))
    hasher.combine(model.connections.map(\.id))
    hasher.combine(model.notes.notes.map(\.id))
    hasher.combine(model.webSessions.all.map(\.id))
    hasher.combine(model.databaseConnections.map(\.id))
    hasher.combine(model.history.sessions.map(\.id))
    hasher.combine(model.historyMode)
    #if os(macOS)
    hasher.combine(model.screenMonitor.sessions.map(\.name))
    hasher.combine(model.remoteScreenSessions.map(\.name))
    hasher.combine(model.openedFiles.map(\.id))
    #endif
    return hasher.finalize()
  }
}
