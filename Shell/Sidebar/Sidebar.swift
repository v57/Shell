import Foundation
import SwiftUI
import ShellKit
import ShellIntegrations
import ShellMonitoring

/// The sidebar: a `List` composing ONE VIEW PER SECTION — `LocalSectionView`,
/// `RemoteSectionView`, `NotesSectionView`, plus the Running and Text Files
/// sections at the bottom of this file. Each section view owns its rows, its
/// feature gate, its collapse state and any state only it uses.
///
/// `SidebarView2` (Sidebar2.swift) renders the SAME sections on a `ScrollView` +
/// `LazyVStack`. The container is the only difference, and each difference has
/// exactly one home:
///
///  - WHAT is rendered: `SidebarSections` (below) — shared;
///  - HOW a row/header is presented: `.sidebarRow(_:reorder:)` and
///    `SidebarSection` (SidebarContainer.swift), which tag for a `List` and take
///    over tap-selection, the highlight and drag-reorder for a `LazyVStack`;
///  - WHAT the sidebar does around the rows (selection routing, sheets, the
///    live-stats monitor): `.sidebarChrome(_:)` (SidebarChrome.swift) — shared;
///  - the drag-reorder plumbing the `LazyVStack` needs: SidebarReorder.swift.
///
/// This file owns the row views used by more than one section (`SessionRow`,
/// `DatabaseConnectionRow`, `DatabaseConnectionActions`, `DetachReturnBadge`),
/// `SidebarCollapseChevron` and the status-line rendering extensions.
struct SidebarView: View {
  @Environment(AppModel.self) private var model

  /// What the sections and the chrome share: the rename state, the database
  /// rename sheet and the stats monitor (see `SidebarState`). One instance per
  /// sidebar CONTAINER — `SidebarView2` carries its own.
  @State private var state = SidebarState()

  var body: some View {
    @Bindable var model = model
    List(selection: $model.selection) {
      SidebarSections(state: state)
    }
    // Everything the sidebar does around its rows — selection routing, the
    // shared sheets/alerts, the stats monitor's lifetime (SidebarChrome.swift).
    .sidebarChrome(state)
  }
}

/// The sidebar's five sections in order — the SHAPE both containers render.
///
/// `SidebarSection { rows } header: { … }` is a `Section` in the `List` and a
/// header row + its rows in a `LazyVStack`, so a section view never mentions the
/// container it ends up in.
struct SidebarSections: View {
  /// The container's shared sidebar state (`SidebarState`), handed to the
  /// sections that need it (the session rename and the database rename sheet are
  /// shared by the Local and Remote sections).
  let state: SidebarState

  var body: some View {
    RunningSectionView()

    #if os(macOS)
    // The Local section hosts local terminals (sessions), persistent
    // screen/tmux (screen), history, saved web pages and (untunneled) database
    // connections. LocalSectionView owns the section and its gate.
    LocalSectionView(state: state)
    #endif

    RemoteSectionView(state: state)

    NotesSectionView()

    #if os(macOS)
    TextFilesSectionView()
    #endif
  }
}

/// The Running section: live and just-finished action sessions. Kept in this
/// file — a header, its rows, and the collapse state, with no file of its own.
private struct RunningSectionView: View {
  @Environment(AppModel.self) private var model

  @AppStorage("sidebar.running.collapsed") private var runningCollapsed = false

  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    if flags.isEnabled(.actions), !model.actionSessions.isEmpty {
      SidebarSection {
        ForEach(runningCollapsed || !flags.isEnabled(.actions) ? [] : model.actionSessions) { session in
          ActionRunRow(session: session, spec: model.actionSpec(for: session))
            // Rows carry their own selection: an untagged row writes nil into it.
            .sidebarRow(.session(session.id))
            .contextMenu {
              if isRunning(session) {
                Button("Cancel (Ctrl+C)") { session.send(Data([0x03])) }
              }
              Button("Close", role: .destructive) {
                model.removeSession(session.id)
              }
              Button("Close All", role: .destructive) {
                model.closeAllActionSessions()
              }
            }
        }
      } header: {
        SidebarSectionHeader(collapsed: $runningCollapsed, spacing: 4) {
          Text("Running")
        }
      }
    }
  }

  /// True while an action session can still be interrupted (its process
  /// or remote exec is alive); Cancel sends Ctrl+C in that state.
  private func isRunning(_ session: TerminalSession) -> Bool {
    switch session.connectionState {
    case .starting, .connecting, .connected:
      return true
    case .failed, .closed:
      return false
    }
  }
}

/// A running or finished action session in the sidebar's Running section:
/// spinner while alive, green ✓ in the ~2s grace before a clean run
/// disappears, red ✗ + exit code/error for failures (which persist until
/// dismissed). Shows the action's live last output line like other rows.
private struct ActionRunRow: View {
  var session: TerminalSession
  let spec: ActionSpec?

  @Environment(AppModel.self) private var model
  @Environment(\.terminalBackgroundsDisabled) private var disableBackgrounds
  @Environment(\.colorScheme) private var colorScheme

  private var environmentLabel: String {
    spec?.config?.displayName ?? "Local"
  }

  var body: some View {
    let line = statusLine
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        stateIcon
        Text(spec?.action.name ?? "Action")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        DetachReturnBadge(selection: .session(session.id))
        Text(environmentLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      SidebarRowLine(isShown: line != nil) {
        line?
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .sidebarAnimation(value: stateSymbol)
    .contentShape(Rectangle())
  }

  /// The run's state as ONE symbol, so the animated sidebar morphs it
  /// (play → checkmark / xmark) rather than swapping views.
  private var stateSymbol: String {
    switch session.connectionState {
    case .starting, .connecting, .connected: "play.fill"
    case .failed: "xmark.circle.fill"
    case .closed: session.actionExitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
  }

  private var stateIcon: some View {
    let style: AnyShapeStyle = switch stateSymbol {
    case "play.fill": AnyShapeStyle(.secondary)
    case "checkmark.circle.fill": AnyShapeStyle(.green)
    default: AnyShapeStyle(.red)
    }
    return Image(systemName: stateSymbol)
      .foregroundStyle(style)
      .contentTransition(.symbolEffect(.replace))
      .accessibilityLabel(stateSymbol == "play.fill" ? "Running" : stateSymbol == "checkmark.circle.fill" ? "Finished" : "Failed")
  }

  /// The row's second line, or nil when it has none: the failure, a
  /// non-zero exit code, or the action's live last output line.
  private var statusLine: Text? {
    switch session.connectionState {
    case .failed(let message):
      return Text(message)
        .font(.caption2)
        .foregroundStyle(.red)
    case .closed:
      if let code = session.actionExitCode, code != 0 {
        return Text("exit " + String(code))
          .font(.caption2.monospaced())
          .foregroundStyle(.red)
      }
      return outputLine
    default:
      return outputLine
    }
  }

  private var outputLine: Text? {
    let status = session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme)
    guard !status.characters.isEmpty else { return nil }
    return Text(status).font(.caption2.monospaced())
  }
}

#if os(macOS)
/// The Text Files section: transient opened files (macOS only), shown only
/// while something is open. Kept in this file, like the Running section.
private struct TextFilesSectionView: View {
  @Environment(AppModel.self) private var model

  @AppStorage("sidebar.files.collapsed") private var filesCollapsed = false

  var body: some View {
    if !model.openedFiles.isEmpty {
      SidebarSection {
        ForEach(filesCollapsed ? [] : model.openedFiles) { file in
          OpenedFileRow(file: file)
            .sidebarRow(.openedFile(file.id))
            .contextMenu {
              Button("Close", role: .destructive) {
                model.closeOpenedFile(file.id)
              }
            }
        }
      } header: {
        SidebarSectionHeader(collapsed: $filesCollapsed) {
          Text("Text Files")
        }
      }
    } // end if (opened files gate)
  }
}

/// A sidebar row for an opened text file: doc icon, display name, and a dirty
/// dot when it has unsaved edits. Selecting the row shows the editor in the
/// content area; close via ⌘W or the row's context menu.
private struct OpenedFileRow: View {
  let file: OpenedFile

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text")
        .foregroundStyle(.secondary)
      Text(file.displayName)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer()
      if file.isDirty {
        Circle()
          .fill(Color.orange)
          .frame(width: 8, height: 8)
          .help("Unsaved changes")
          .transition(SidebarMotion.iconTransition)
      }
    }
    .sidebarAnimation(value: file.isDirty)
    .contentShape(Rectangle())
  }
}
#endif

/// A leading disclosure triangle that collapses/expands a sidebar section.
/// Collapsing hides the section's rows; the header (and its action buttons)
/// stays visible so the controls remain reachable. chevron.down = expanded,
/// chevron.right = collapsed. Shared by every section view.
struct SidebarCollapseChevron: View {
  @Binding var collapsed: Bool
  /// The animated sidebar turns ONE chevron and animates the rows away; the
  /// `List` sidebar swaps the glyph in place.
  @Environment(\.sidebarAnimations) private var animates

  var body: some View {
    Button {
      withAnimation(animates ? SidebarMotion.rows : nil) {
        collapsed.toggle()
      }
    } label: {
      Group {
        if animates {
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(collapsed ? 0 : 90))
        } else {
          Image(systemName: collapsed ? "chevron.right" : "chevron.down")
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(collapsed ? "Expand section" : "Collapse section")
  }
}

/// A session row in the sidebar. While renaming, shows a focused text
/// field instead of the label; Enter applies, Escape cancels.
struct SessionRow: View {
  var session: TerminalSession
  let defaultLabel: String
  let subtitle: String?
  let isRenaming: Bool
  let onCommitRename: (String) -> Void
  let onCancelRename: () -> Void

  @Environment(AppModel.self) private var model
  @Environment(\.terminalBackgroundsDisabled) private var disableBackgrounds
  @Environment(\.colorScheme) private var colorScheme
  
  @State private var draft = ""
  @FocusState private var fieldFocused: Bool
  
  private var currentLabel: String {
    session.customName ?? defaultLabel
  }
  
  var body: some View {
    let status = session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "terminal")
          .foregroundStyle(.secondary)
        if isRenaming {
          TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .focused($fieldFocused)
            .onSubmit { onCommitRename(draft) }
            #if os(macOS)
            .onExitCommand(perform: onCancelRename)
            #endif
        } else {
          Text(currentLabel)
        }
        Spacer()
        DetachReturnBadge(selection: .session(session.id))
        stateDot
      }
      // Second line: the session's status (n-th non-empty terminal line
      // from the bottom, or the line pinned by clicking its last
      // character), rendered in the terminal's own colors.
      SidebarRowLine(isShown: !status.characters.isEmpty) {
        Text(status).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
          .clipShape(.capsule)
      }
    }
    .onChange(of: isRenaming) { _, newValue in
      if newValue {
        draft = currentLabel
        fieldFocused = true
      }
    }
    .sidebarAnimation(value: session.connectionState)
    .sidebarAnimation(value: session.hasActivity)
    .contentShape(Rectangle())
  }

  /// ONE dot whose color follows the state (so the animated sidebar fades it
  /// between colors), or none.
  @ViewBuilder
  private var stateDot: some View {
    if let color = stateDotColor {
      Circle().fill(color).frame(width: 7, height: 7)
        .transition(SidebarMotion.iconTransition)
    }
  }

  private var stateDotColor: AnyShapeStyle? {
    switch session.connectionState {
    case .connected:
      // Green only while the session produced output recently; after
      // `TerminalSession.inactivityTimeout` of quiet the session is idle
      // and the dot hides. Read via @Observable so the row re-renders when
      // `hasActivity` flips.
      session.hasActivity ? AnyShapeStyle(.green) : nil
    case .failed:
      AnyShapeStyle(.red)
    case .starting, .connecting, .closed:
      AnyShapeStyle(.secondary)
    }
  }
}

/// A sidebar row for a saved database connection: engine icon, display name,
/// and host:port (or file path) subtitle, plus an "open" dot when the browser
/// is live. Clicking the row opens/focuses the database browser.
struct DatabaseConnectionRow: View {
  @Environment(AppModel.self) private var model
  let connection: DatabaseConnection

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: connection.engine.systemImage)
          .foregroundStyle(.secondary)
        Text(connection.displayName)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        if model.liveDatabaseSession(for: connection) != nil {
          Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
            .help("Open")
            .transition(SidebarMotion.iconTransition)
        }
      }
      .sidebarAnimation(value: model.liveDatabaseSession(for: connection) != nil)
      Text(connection.subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .contentShape(Rectangle())
  }
}

/// The context menu for a database connection row, shared by the Local and
/// Remote (per-host) sections so both offer the same actions. Connect and
/// Disconnect flip on whether the engine is live; Rename opens the rename
/// sheet; Duplicate clones the row and its Keychain credential (fresh id);
/// Edit opens the prefilled sheet; Delete closes the browser, drops the
/// credential, then the record.
struct DatabaseConnectionActions: View {
  @Environment(AppModel.self) private var model
  let connection: DatabaseConnection
  /// Called when the user picks Rename… so the parent view can open the
  /// rename sheet pre-filled with this connection's display name.
  let onRename: (DatabaseConnection) -> Void

  var body: some View {
    if model.liveDatabaseSession(for: connection) != nil {
      Button("Disconnect") { model.closeDatabaseSession(connection) }
    } else {
      Button("Connect") { model.openOrFocusDatabaseConnection(connection) }
    }
    Button("Rename…") { onRename(connection) }
    Button("Duplicate") { model.duplicateDatabaseConnection(connection) }
    Button("Edit…") {
      model.editingDatabaseConnection = connection
      model.showingNewDatabaseConnection = true
    }
    Divider()
    Button("Delete", role: .destructive) { model.deleteDatabaseConnection(connection) }
  }
}

// MARK: - Sidebar status rendering (moved from the old app-side TerminalView.swift)

extension TerminalColor {
  /// SwiftUI color for explicit terminal colors (ANSI/rgb); nil for
  /// default/clear so the sidebar's own text style shows through.
  var sidebarColor: Color? {
    switch self {
    case .clear, .default:
      return nil
    case .rgb(let red, let green, let blue):
      return Color(red: red, green: green, blue: blue)
    case .ansi(let index):
      return TerminalColor.color(forAnsiIndex: index)
    }
  }
}

extension TerminalSession {
  /// The status line rendered with the terminal's own per-cell colors
  /// and styles (prompts, git status, vim bars, ...). Runs without an
  /// explicit color keep the sidebar's secondary style; bold cells use
  /// a semibold monospaced face.
  ///
  /// `disableBackgrounds: true` mirrors the canvas's background-suppression
  /// theme (the "Disable Background Colors" option): no character
  /// backgrounds, and explicit low-contrast colors replaced with `.primary`
  /// per `TerminalContrast`. `scheme` is the EFFECTIVE color scheme (after
  /// any preferredColorScheme override), matching the canvas's contrast keys.
  func statusAttributedString(disableBackgrounds: Bool, scheme: ColorScheme) -> AttributedString {
    if let message = snapshot.message {
      return AttributedString(message)
    }
    guard let line = snapshot.nonEmptyLineIndexFromBottom(statusRank) else {
      return AttributedString()
    }
    let lastColumn = snapshot.lastNonBlankColumn(ofLine: line)
    guard lastColumn >= 0 else { return AttributedString() }
    // Start-character mode shows the line FROM the clicked character
    // (skipping the prefix before it); full-line mode shows the whole
    // line. Clamp to the line's content so a click past its end doesn't
    // produce an empty range.
    let startColumn = statusStartMarked ? min(max(0, statusStartColumn), lastColumn) : 0
    
    let baseFont = Font.caption2.monospaced()
    let boldFont = Font.caption2.monospaced().weight(.semibold)
    var result = AttributedString()
    for column in startColumn...lastColumn {
      let cell = snapshot.cell(atLine: line, column: column)
      // Blank cells (including \0) render as spaces — internal spacing
      // must survive; lastColumn already bounds trailing blanks.
      let character = cell.isBlank ? " " : String(cell.character)
      var attrs = AttributeContainer()
      attrs.font = cell.bold ? boldFont : baseFont
      // Inverse swaps the background into the foreground (like the canvas).
      if disableBackgrounds {
        // Apple theme: no character backgrounds; the cell's own color
        // (the background color for inverse cells) unless low-contrast,
        // then primary. Exactly the canvas's suppression contract.
        attrs.foregroundColor = TerminalContrast.suppressedBackgroundForeground(
          for: cell.inverse ? cell.background : cell.foreground,
          scheme: scheme
        )
      } else {
        if cell.inverse {
          if let color = cell.background.sidebarColor {
            attrs.foregroundColor = color
          }
        } else if let color = cell.foreground.sidebarColor {
          attrs.foregroundColor = color
        }
        if !cell.inverse, let background = cell.background.sidebarColor {
          attrs.backgroundColor = background
        }
      }
      result.append(AttributedString(character, attributes: attrs))
    }
    return result
  }
}

/// A trailing return badge shown on a sidebar row whose item is currently
/// detached: an `arrowshape.turn.up.left.fill` button that re-attaches the
/// item — removing it from `AppModel.detachedIDs`, selecting it in the main
/// window, and dismissing its detached window/scene (`WindowGroup` id
/// "detach"). Hidden for attached items. Reading `model.isDetached` through
/// the @Observable model re-renders the row when detach state flips.
struct DetachReturnBadge: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismissWindow) private var dismissWindow
  /// The row's own selection, so the item comes back SELECTED as the right
  /// kind (a session vs a note) without a lookup.
  let selection: AppModel.Selection

  var body: some View {
    Group {
      if model.isDetached(selection.itemID) {
        Button {
          model.markAttached(selection.itemID)
          model.selection = selection
          dismissWindow(id: "detach", value: selection.itemID)
        } label: {
          Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Return to main window")
        .transition(SidebarMotion.iconTransition)
      }
    }
    .sidebarAnimation(value: model.isDetached(selection.itemID))
  }
}
