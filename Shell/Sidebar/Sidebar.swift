import ComponentKit
import Foundation
import SwiftUI
import ShellKit
import ShellIntegrations
import ShellMonitoring

/// The sidebar: ComponentKit's `KitSidebar` with ONE VIEW PER SECTION, each a
/// card `KitSection` — `RunningSectionView` (below), `LocalSectionView`,
/// `RemoteSectionView`, `NotesSectionView` and `TextFilesSectionView` (below).
/// Each section view owns its rows, its feature gate, its collapse state and any
/// state only it uses.
///
/// The kit draws the rows (`SidebarRow`), the gliding selection card, inline
/// rename (`.kitRename`), collapsing headers and drag-to-reorder
/// (`ReorderableSection`). Shell adds what it does around the rows
/// (`.sidebarChrome(_:)`, SidebarChrome.swift: selection routing, sheets, the
/// stats monitor) and, for the rows that also take FILE drops, its own reorder
/// (SidebarReorder.swift): the kit's reorder target would shadow them.
///
/// This file owns the row views used by more than one section (`SessionRow`,
/// `DatabaseConnectionRow`, `DatabaseConnectionActions`, `DetachReturnBadge`)
/// and the status-line text.
struct SidebarView: View {
  @Environment(AppModel.self) private var model

  /// The split view's visibility, for the bottom bar's sidebar toggle on iPad.
  @Binding var columnVisibility: NavigationSplitViewVisibility

  /// What the sections and the chrome share: the rename state, the database
  /// rename sheet, the search text and the stats monitor (see `SidebarState`).
  @State private var state = SidebarState()
  /// The drag of a row that also takes file drops (SidebarReorder.swift).
  @State private var drag = SidebarDragState()

  var body: some View {
    @Bindable var model = model
    @Bindable var state = state
    KitSidebar(
      selection: $model.selection, searchText: $state.searchText, searchPrompt: "Filter",
      columnVisibility: $columnVisibility
    ) {
      RunningSectionView(state: state)

      #if os(macOS)
      // This Mac's terminals, persistent screen/tmux sessions, history, saved
      // web pages and untunneled database connections.
      LocalSectionView(state: state)
      #endif

      RemoteSectionView(state: state)

      NotesSectionView(state: state)

      #if os(macOS)
      TextFilesSectionView(state: state)
      #endif
    } bottomBar: {
      #if os(macOS)
      if FeatureFlagsStore.shared.isEnabled(.sessions) {
        Button("New Terminal", systemImage: "terminal") { model.addLocalTerminal() }
          .help("New terminal")
      }
      #else
      Button("Settings", systemImage: "gearshape") { model.showingSettings = true }
      #endif
    }
    // Rows coming, going and reordering slide rather than jump (the kit stills
    // this in an inactive window and under Reduce Motion).
    .animation(.kit, value: rowIdentities)
    .sidebarDragState(drag)
    // Everything the sidebar does around its rows — selection routing, the
    // shared sheets/alerts, the stats monitor's lifetime (SidebarChrome.swift).
    .sidebarChrome(state)
  }

  /// The identities of every row the sections render, in order: a change here
  /// is a row inserted, removed or moved, which the sidebar animates.
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

// MARK: - Section header pieces

/// A section header's icon: the kit's live icon at the header size for the
/// idiom (24pt on the Mac, 30 on iPad, 32 on iPhone).
struct SidebarSectionIcon: View {
  let systemImage: String
  var hue: Hue = .accent
  var status: WorkStatus = .idle
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    LiveIcon(systemImage: systemImage, hue: hue, status: status, size: idiom == .phone ? 32 : idiom == .pad ? 30 : 24)
  }
}

/// A row's live icon (an action run), the size of the kit's row tiles.
struct SidebarRowLiveIcon: View {
  let systemImage: String
  let status: WorkStatus
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    LiveIcon(systemImage: systemImage, status: status, size: idiom == .phone ? 30 : idiom == .pad ? 28 : 18)
  }
}

extension Binding where Value == Bool {
  /// A section's open state from its persisted COLLAPSED flag.
  static func expanded(collapsed: Binding<Bool>) -> Binding<Bool> {
    Binding(get: { !collapsed.wrappedValue }, set: { collapsed.wrappedValue = !$0 })
  }
}

// MARK: - Running

/// The Running section: live and just-finished action sessions (the Actions
/// palette's runs and the smart actions). Kept in this file — a header, its
/// rows, and the collapse state, with no file of its own.
private struct RunningSectionView: View {
  @Environment(AppModel.self) private var model
  let state: SidebarState

  @AppStorage("sidebar.running.collapsed") private var runningCollapsed = false

  private var flags: FeatureFlagsStore { .shared }

  private var runs: [TerminalSession] {
    model.actionSessions.filter { state.matches(model.actionSpec(for: $0)?.action.name ?? "Action") }
  }

  var body: some View {
    if flags.isEnabled(.actions), !runs.isEmpty {
      let running = runs.filter(\.isActionRunning).count
      let failed = runs.filter { $0.actionRunStatus.isFailed }.count
      KitSection(Text("Running"), isExpanded: .expanded(collapsed: $runningCollapsed)) {
        ForEach(runs) { session in
          ActionRunRow(session: session, spec: model.actionSpec(for: session))
            .contextMenu {
              if session.isActionRunning {
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
      } icon: {
        SidebarSectionIcon(systemImage: "bolt.fill", hue: .purple, status: running > 0 ? .working : .idle)
      } meta: {
        MetaLine([
          running > 0 ? "\(running) running" : "",
          failed > 0 ? "\(failed) failed" : "",
          running == 0 && failed == 0 ? "\(runs.count) finished" : "",
        ])
      } accessory: {
        EmptyView()
      }
    }
  }
}

extension TerminalSession {
  /// True while an action session can still be interrupted (its process or
  /// remote exec is alive); Cancel sends Ctrl+C in that state.
  var isActionRunning: Bool {
    switch connectionState {
    case .starting, .connecting, .reconnecting, .connected: true
    case .failed, .closed: false
    }
  }

  /// An action run's state for its live icon and run block: working while
  /// alive, done after a clean exit, failed with the exit code or the error.
  var actionRunStatus: WorkStatus {
    switch connectionState {
    case .starting, .connecting, .reconnecting, .connected:
      return .working
    case .failed(let message):
      return .failed(message)
    case .closed:
      if let code = actionExitCode, code != 0 { return .failed("exit \(code)") }
      return .done
    }
  }
}

extension WorkStatus {
  var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// A running or finished action session in the sidebar's Running section: its
/// live icon turns while it runs, checks green in the ~2s grace before a clean
/// run disappears, and stays red with the exit code or error for a failure
/// (which persists until dismissed). Shows the action's live last output line.
private struct ActionRunRow: View {
  var session: TerminalSession
  let spec: ActionSpec?

  private var environmentLabel: String {
    spec?.config?.displayName ?? "Local"
  }

  var body: some View {
    let status = session.actionRunStatus
    SidebarRow(
      value: AppModel.Selection.session(session.id), spec?.action.name ?? "Action", subtitle: subtitle(status)
    ) {
      SidebarRowLiveIcon(systemImage: "play.fill", status: status)
    } trailing: {
      DetachReturnBadge(selection: .session(session.id))
      Text(environmentLabel)
        .foregroundStyle(.kitSecondary)
    }
  }

  /// The row's second line: the failure, or the action's live last output line.
  private func subtitle(_ status: WorkStatus) -> String? {
    if case .failed(let message) = status, let message { return message }
    let line = session.statusText
    return line.isEmpty ? nil : line
  }
}

#if os(macOS)
// MARK: - Text Files

/// The Text Files section: transient opened files (macOS only), shown only
/// while something is open. Kept in this file, like the Running section.
private struct TextFilesSectionView: View {
  @Environment(AppModel.self) private var model
  let state: SidebarState

  @AppStorage("sidebar.files.collapsed") private var filesCollapsed = false

  private var files: [OpenedFile] { model.openedFiles.filter { state.matches($0.displayName) } }

  var body: some View {
    if !files.isEmpty {
      let unsaved = files.filter(\.isDirty).count
      KitSection(Text("Text Files"), isExpanded: .expanded(collapsed: $filesCollapsed)) {
        ForEach(files) { file in
          SidebarRow(value: AppModel.Selection.openedFile(file.id), file.displayName, systemImage: "doc.text") {
            if file.isDirty {
              StatusDot(hue: .orange)
                .help("Unsaved changes")
                .transition(.scale.combined(with: .opacity))
            }
          }
          .contextMenu {
            Button("Close", role: .destructive) {
              model.closeOpenedFile(file.id)
            }
          }
        }
      } icon: {
        SidebarSectionIcon(systemImage: "doc.text", hue: .gray)
      } meta: {
        MetaLine([files.count == 1 ? "1 file" : "\(files.count) files", unsaved > 0 ? "\(unsaved) unsaved" : ""])
      } accessory: {
        EmptyView()
      }
    }
  }
}
#endif

// MARK: - Shared rows

/// A session row in the sidebar: its name, its live status line (the n-th
/// non-empty terminal line from the bottom, or the line pinned by clicking its
/// last character) and its state dot. Rename… turns the title into a field in
/// place (`.kitRename`): Return applies, Escape cancels.
struct SessionRow: View {
  var session: TerminalSession
  let defaultLabel: String
  @Binding var isRenaming: Bool
  let onRename: (String) -> Void

  var body: some View {
    let status = session.statusText
    SidebarRow(
      value: AppModel.Selection.session(session.id), session.customName ?? defaultLabel,
      subtitle: status.isEmpty ? nil : status, systemImage: "terminal"
    ) {
      DetachReturnBadge(selection: .session(session.id))
      if let hue = stateDotHue {
        StatusDot(hue: hue)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .kitRename(isRenaming: $isRenaming) { onRename($0) }
    .animation(.kit, value: stateDotHue)
  }

  /// ONE dot whose hue follows the state, or none.
  private var stateDotHue: Hue? {
    switch session.connectionState {
    case .connected:
      // Green only while the session produced output recently; after
      // `TerminalSession.inactivityTimeout` of quiet the session is idle
      // and the dot hides. Read via @Observable so the row re-renders when
      // `hasActivity` flips.
      session.hasActivity ? .green : nil
    case .failed:
      .red
    case .reconnecting:
      // The link dropped and the session is dialing again.
      .orange
    case .starting, .connecting, .closed:
      .gray
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
    let isOpen = model.liveDatabaseSession(for: connection) != nil
    SidebarRow(
      value: model.rowSelection(for: connection), connection.displayName, subtitle: connection.subtitle,
      systemImage: connection.engine.systemImage
    ) {
      if isOpen {
        StatusDot(hue: .green)
          .help("Open")
          .transition(.scale.combined(with: .opacity))
      }
    }
    .animation(.kit, value: isOpen)
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

// MARK: - Status line

extension TerminalSession {
  /// The session's status line as plain text: the transport's message, or the
  /// n-th non-empty terminal line from the bottom (`statusRank`), from the
  /// character pinned by clicking it (`statusStartColumn`) when one is marked.
  /// Empty when there is nothing to show.
  var statusText: String {
    if let message = snapshot.message {
      return message
    }
    guard let line = snapshot.nonEmptyLineIndexFromBottom(statusRank) else { return "" }
    let lastColumn = snapshot.lastNonBlankColumn(ofLine: line)
    guard lastColumn >= 0 else { return "" }
    // Start-character mode shows the line FROM the clicked character; clamp
    // to the line's content so a click past its end doesn't empty it.
    let startColumn = statusStartMarked ? min(max(0, statusStartColumn), lastColumn) : 0
    var text = ""
    for column in startColumn...lastColumn {
      let cell = snapshot.cell(atLine: line, column: column)
      // Blank cells (including \0) are spaces: internal spacing must survive.
      text += cell.isBlank ? " " : String(cell.character)
    }
    return text
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
    let isDetached = model.isDetached(selection.itemID)
    Group {
      if isDetached {
        Button("Return to Main Window", systemImage: "arrowshape.turn.up.left.fill") {
          model.markAttached(selection.itemID)
          model.selection = selection
          dismissWindow(id: "detach", value: selection.itemID)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.kitIcon)
        .help("Return to main window")
        .transition(.scale.combined(with: .opacity))
      }
    }
    .animation(.kit, value: isDetached)
  }
}
