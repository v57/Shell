import ComponentKit
import Foundation
import SwiftUI
import ShellDatabaseEngines
import ShellKit
import ShellIntegrations
import ShellMonitoring
import UniformTypeIdentifiers

/// The sidebar: ComponentKit's `KitSidebar` with ONE VIEW PER SECTION, each a
/// card `KitSection` — `RunningSectionView` (below), `LocalSectionView`,
/// `RemoteSectionView`, `NotesSectionView` and `TextFilesSectionView` (below).
/// Each section view owns its rows, its feature gate, its collapse state and any
/// state only it uses.
///
/// The kit draws the rows (`SidebarRow`), the gliding selection card, inline
/// rename (`.kitRename`), collapsing headers and drag-to-reorder
/// (`ReorderableSection`, which also hands session and host rows their file
/// drops). Shell adds what it does around the rows (`.sidebarChrome(_:)`,
/// SidebarChrome.swift: selection routing, sheets, the stats monitor).
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

  var body: some View {
    @Bindable var model = model
    @Bindable var state = state
    KitSidebar(
      selection: $model.selection, searchText: $state.searchText, searchPrompt: "Filter",
      columnVisibility: $columnVisibility
    ) {
      RunningSectionView(state: state)

      #if os(macOS) || os(Windows)
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
      #if os(macOS) || os(Windows)
      if FeatureFlagsStore.shared.isEnabled(.sessions) {
        Button("New Terminal", systemImage: "terminal") { model.newTerminal() }
          .help("New terminal")
      }
      #else
      Button("Settings", systemImage: "gearshape") { model.showingSettings = true }
      #endif
    }
    // The rows of a database's tree select as the sidebar's own items.
    .environment(\.databaseSidebarTag) { AnyHashable(AppModel.Selection.databaseItem($0)) }
    // Rows coming, going and reordering slide rather than jump (the kit stills
    // this in an inactive window and under Reduce Motion).
    .animation(.kit, value: rowIdentities)
    // The kit's own Hide Sidebar button and the detail column's Show Sidebar
    // (`kitSidebarToggle`) stand in for the system toggle.
    .toolbar(removing: .sidebarToggle)
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
    #if os(macOS) || os(Windows)
    hasher.combine(model.screenMonitor.sessions.map(\.name))
    hasher.combine(model.remoteScreenSessions.map(\.name))
    #endif
    #if os(macOS)
    hasher.combine(model.openedFiles.map(\.id))
    #endif
    return hasher.finalize()
  }
}

// MARK: - Section header pieces

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
      KitSection(
        "Running", systemImage: "bolt.fill", hue: .purple, status: running > 0 ? .working : .idle,
        isExpanded: .expanded(collapsed: $runningCollapsed)
      ) {
        ForEach(runs) { session in
          ActionRunRow(session: session, spec: model.actionSpec(for: session))
            .kitContextMenu {
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

extension TerminalSession {
  /// The link's state for a session's live icon (its row, the page title): the
  /// work indicator while an SSH session dials (or dials again after a drop),
  /// red once it failed.
  var linkStatus: WorkStatus {
    switch connectionState {
    case .connecting, .reconnecting: .working
    case .failed(let message): .failed(message)
    case .starting, .connected, .closed: .idle
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
      value: AppModel.Selection.session(session.id), spec?.action.name ?? "Action", systemImage: "play.fill",
      status: status
    ) {
      DetachReturnBadge(selection: .session(session.id))
      Text(environmentLabel)
        .foregroundStyle(.kitSecondary)
    }
    .subtitle {
      // The failure (the error, or the exit code), else the action's live last
      // output line in the terminal's colours.
      if case .failed(let message) = status, let message {
        Text(message).monospaced().foregroundStyle(Hue.red.text)
      } else {
        SessionStatusLine(session: session)
      }
    }
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
      KitSection("Text Files", systemImage: "doc.text", hue: .gray, isExpanded: .expanded(collapsed: $filesCollapsed)) {
        ForEach(files) { file in
          SidebarRow(value: AppModel.Selection.openedFile(file.id), file.displayName, systemImage: "doc.text") {
            if file.isDirty {
              StatusDot(hue: .orange)
                .help("Unsaved changes")
                .transition(.scale.combined(with: .opacity))
            }
          }
          .kitContextMenu {
            Button("Close", role: .destructive) {
              model.closeOpenedFile(file.id)
            }
          }
        }
      } meta: {
        MetaLine([files.count == 1 ? "1 file" : "\(files.count) files", unsaved > 0 ? "\(unsaved) unsaved" : ""])
      } accessory: {
        EmptyView()
      }
    }
  }
}
#endif

// MARK: - Reordering

/// What a session or host row takes besides its siblings (the kit's reorder target hands it over,
/// `ReorderableSection.alsoAccepts`): files from Finder and the Files panel on the Mac, nothing elsewhere.
var sidebarFileTypes: [UTType] {
  #if os(macOS)
  FileDrop.contentTypes
  #else
  []
  #endif
}

/// A move in a filtered list (`shown`, the rows the filter lets through) as a move in the whole list (`all`), whose
/// offsets the model's moves take: the rows land where they would in `shown`, and the hidden ones keep their places.
struct FilteredMove {
  let source: IndexSet
  let destination: Int

  init<Item: Identifiable>(_ source: IndexSet, _ destination: Int, shown: [Item], in all: [Item]) {
    func index(_ item: Item) -> Int? { all.firstIndex { $0.id == item.id } }
    self.source = IndexSet(source.compactMap { shown.indices.contains($0) ? index(shown[$0]) : nil })
    if destination < shown.count {
      self.destination = index(shown[destination]) ?? all.count
    } else {
      self.destination = shown.last.flatMap(index).map { $0 + 1 } ?? all.count
    }
  }
}

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
    SidebarRow(
      value: AppModel.Selection.session(session.id), session.customName ?? defaultLabel, systemImage: "terminal",
      status: session.linkStatus
    ) {
      DetachReturnBadge(selection: .session(session.id))
      if let hue = stateDotHue {
        StatusDot(hue: hue)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .subtitle { SessionStatusLine(session: session) }
    .kitRename(isRenaming: $isRenaming) { onRename($0) }
    .animation(.kit, value: stateDotHue)
  }

  /// The dot for what the live icon doesn't show: green while the session
  /// produced output recently (after `TerminalSession.inactivityTimeout` of
  /// quiet it is idle and the dot hides; read via @Observable so the row
  /// re-renders when `hasActivity` flips), gray once the shell ended.
  private var stateDotHue: Hue? {
    switch session.connectionState {
    case .connected: session.hasActivity ? .green : nil
    case .closed: .gray
    case .starting, .connecting, .reconnecting, .failed: nil
    }
  }
}

/// A sidebar row for a saved database connection: engine icon, display name,
/// and host:port (or file path) subtitle, plus an "open" dot when it is open.
/// Clicking the row opens it (its overview in the detail pane); its chevron
/// connects and shows Database's tree under it: databases, schemas, tables,
/// collections and key spaces, then the saved queries and open query tabs.
struct DatabaseConnectionRow: View {
  @Environment(AppModel.self) private var model
  let connection: DatabaseConnection
  /// The sidebar's shared state, for the menu's Rename… and Delete….
  let state: SidebarState
  /// The row's indent: 1 under a Remote host.
  var level = 0

  private var live: LiveConnection? { model.databases.live[connection.id] }

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { live?.expanded.contains(LiveConnection.rootID) ?? false },
      set: { open in
        withKitAnimation {
          if open {
            model.openOrFocusDatabaseConnection(connection, selects: false)
          } else {
            live?.expanded.remove(LiveConnection.rootID)
          }
        }
      })
  }

  var body: some View {
    let isOpen = model.liveDatabaseSession(for: connection) != nil
    // One view with its tree, so the row's menu, its drag and its indent stay the row's.
    VStack(alignment: .leading, spacing: 2) {
      SidebarRow(
        value: model.rowSelection(for: connection), connection.displayName, subtitle: connection.subtitle,
        systemImage: connection.engine.systemImage, status: status, isExpanded: isExpanded
      ) {
        if isOpen {
          StatusDot(hue: .green)
            .help("Open")
            .transition(.scale.combined(with: .opacity))
        }
      }
      .kitRowIndent(level)
      .kitContextMenu { DatabaseConnectionActions(connection: connection, state: state) }
      .animation(.kit, value: isOpen)
      if isExpanded.wrappedValue, let live {
        ConnectionContents(connection: live, window: model.databaseWindow, level: level + 1)
      }
    }
  }

  /// The arc while it connects, red once it failed.
  private var status: WorkStatus {
    switch live?.status {
    case .connecting: .working
    case .failed(let message): .failed(message)
    case .idle, .connected, nil: .idle
    }
  }
}

/// The context menu for a database connection row, shared by the Local and
/// Remote (per-host) sections: Database's own (New Query, Refresh,
/// Connect/Disconnect, Edit, Duplicate, Copy Link, Delete) with Shell's
/// Rename.
struct DatabaseConnectionActions: View {
  @Environment(AppModel.self) private var model
  let connection: DatabaseConnection
  let state: SidebarState

  var body: some View {
    ConnectionMenu(
      connection: model.databases.connection(for: connection.id), window: model.databaseWindow,
      onDelete: { state.deletingDatabaseConnection = connection }
    ) {
      Button("Rename…", systemImage: "character.cursor.ibeam") { state.beginRenameDatabase(connection) }
    }
  }
}

// MARK: - Status line

/// A session's status line under its sidebar row, in the terminal's own
/// colours and weights (prompts, git status, vim bars): the transport's
/// message, or the n-th non-empty terminal line from the bottom
/// (`statusRank`), from the character pinned by clicking it
/// (`statusStartColumn`) when one is marked. Nothing when there is no line.
/// Runs without a colour of their own keep the row's caption style.
struct SessionStatusLine: View {
  var session: TerminalSession
  /// Shown before the line, in the caption style (a remote session's host).
  var prefix: String?
  @Environment(\.terminalBackgroundsDisabled) private var disableBackgrounds
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let line = session.statusLine(disableBackgrounds: disableBackgrounds, scheme: colorScheme)
    let parts = [prefix.map { Text($0) }, line.characters.isEmpty ? nil : Text(line).monospaced()].compactMap { $0 }
    if !parts.isEmpty {
      parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
    }
  }
}

extension TerminalSession {
  /// The status line as styled text (see `SessionStatusLine`); empty when
  /// there is nothing to show.
  ///
  /// `disableBackgrounds: true` mirrors the canvas's background-suppression
  /// theme ("Disable Background Colors"): no character backgrounds, and
  /// explicit low-contrast colours replaced per `TerminalContrast`. `scheme`
  /// is the EFFECTIVE colour scheme, matching the canvas's contrast keys.
  func statusLine(disableBackgrounds: Bool, scheme: ColorScheme) -> AttributedString {
    if let message = snapshot.message {
      return AttributedString(message)
    }
    guard let line = snapshot.nonEmptyLineIndexFromBottom(statusRank) else { return AttributedString() }
    let lastColumn = snapshot.lastNonBlankColumn(ofLine: line)
    guard lastColumn >= 0 else { return AttributedString() }
    // Start-character mode shows the line FROM the clicked character; clamp
    // to the line's content so a click past its end doesn't empty it.
    let startColumn = statusStartMarked ? min(max(0, statusStartColumn), lastColumn) : 0
    var result = AttributedString()
    for column in startColumn...lastColumn {
      let cell = snapshot.cell(atLine: line, column: column)
      // Blank cells (including \0) are spaces: internal spacing must survive.
      var attributes = AttributeContainer()
      if cell.bold { attributes.inlinePresentationIntent = .stronglyEmphasized }
      // Inverse swaps the background into the foreground (like the canvas).
      if disableBackgrounds {
        attributes.foregroundColor = TerminalContrast.suppressedBackgroundForeground(
          for: cell.inverse ? cell.background : cell.foreground, scheme: scheme)
      } else {
        if let color = (cell.inverse ? cell.background : cell.foreground).statusLineColor {
          attributes.foregroundColor = color
        }
        if !cell.inverse, let background = cell.background.statusLineColor {
          attributes.backgroundColor = background
        }
      }
      result.append(AttributedString(cell.isBlank ? " " : String(cell.character), attributes: attributes))
    }
    return result
  }
}

extension TerminalColor {
  /// The cell colour in a status line, or nil to keep the row's own.
  fileprivate var statusLineColor: Color? {
    switch self {
    case .clear, .default: nil
    default: color
    }
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
