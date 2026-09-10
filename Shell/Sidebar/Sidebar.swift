import Foundation
import SwiftUI
import Terminal
import TerminalIntegrations
import Monitoring

/// The sidebar: a `List` composing ONE VIEW PER SECTION — `LocalSectionView`,
/// `RemoteSectionView`, `NotesSectionView`, plus the Running and Text Files
/// sections at the bottom of this file. Each section view owns its rows, its
/// feature gate, its collapse state and any state only it uses; this file owns
/// what the sidebar SHARES:
///
///  - the selection routing (`onChange(of: model.selection)`), which turns a
///    clicked row id into a connect/attach/open action;
///  - the sheets and alerts whose STATE is shared by more than one section (the
///    web-session editor, the database rename sheet, the authorized-keys panel);
///  - the live-stats monitor's lifetime (see `statsMonitor`);
///  - the row views used by more than one section (`SessionRow`,
///    `DatabaseConnectionRow`, `DatabaseConnectionActions`, `DetachReturnBadge`,
///    `SidebarCollapseChevron`) and the status-line rendering extensions.
///
/// The section files live in `Shell/Sidebar/`.
struct SidebarView: View {
  @Environment(AppModel.self) private var model
  /// The session currently being renamed (shows an inline text field). SHARED:
  /// both the Local and the Remote section rename session rows in place.
  @State private var renamingSessionID: UUID?
  /// The database connection being renamed (drives the rename sheet), and the
  /// text field's draft value, pre-filled with the connection's display name.
  /// SHARED: database rows render in both the Local and the Remote section.
  @State private var renamingDatabaseConnection: DatabaseConnection?
  @State private var databaseRenameText = ""

  /// Collapse state for the sections defined in THIS file, persisted across
  /// launches. Local/Remote/Notes persist their own.
  @AppStorage("sidebar.running.collapsed") private var runningCollapsed = false
  #if os(macOS)
  @AppStorage("sidebar.files.collapsed") private var filesCollapsed = false
  #endif

  #if os(macOS)
  /// Live CPU/GPU/wattage for the Local section header (macOS only — the reads
  /// need IOKit's AppleSMC / IOAccelerator).
  ///
  /// Owned HERE rather than by `LocalSectionView` because its LIFETIME belongs
  /// to this List: the observer below starts it while the Monitoring feature is
  /// on and stops it the moment the feature flips off, and a Section's own
  /// onAppear/onDisappear also fire when the section scrolls out of view —
  /// which must not stop the sampling. `LocalSectionView` only RENDERS it.
  @State private var statsMonitor = SystemStatsMonitor()
  /// The stats graphs sheet, opened by clicking the Local section header.
  @State private var showingStatsGraphs = false
  /// Whether the Monitoring feature is on — gates the live stats monitor so
  /// it never samples when the feature is off.
  private var monitoringEnabled: Bool {
    FeatureFlagsStore.shared.isEnabled(.monitoring)
  }
  #endif

  /// The feature-flag source of truth. Reads `.isEnabled(_:)` here so a
  /// disabled feature's rows/sections vanish from the sidebar. Accessing it
  /// through `@Observable` re-renders the sidebar when a flag flips.
  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    @Bindable var model = model
    List(selection: $model.selection) {
      RunningSectionView()

      #if os(macOS)
      // The Local section hosts local terminals (sessions), persistent
      // screen/tmux (screen), history, saved web pages and (untunneled)
      // database connections. LocalSectionView owns the section and its gate.
      LocalSectionView(
        renamingSessionID: $renamingSessionID,
        monitor: statsMonitor,
        onShowStatsGraphs: { showingStatsGraphs = true },
        onRenameDatabase: beginRenameDatabase
      )
      #endif

      RemoteSectionView(
        renamingSessionID: $renamingSessionID,
        onRenameDatabase: beginRenameDatabase
      )

      NotesSectionView()

      #if os(macOS)
      TextFilesSectionView()
      #endif
    }
    // Clicking an SSH row selects its config id; turn that into an
    // actual connection (select the existing session or create one).
    // Screen rows select a deterministic tagID; attach a local terminal
    // to that screen session.
    .onChange(of: model.selection) { _, newValue in
      if renamingSessionID != nil { renamingSessionID = nil }
      guard let id = newValue else { return }
      if let config = model.connections.first(where: { $0.id == id }) {
        model.connect(to: config)
        return
      }
      // A web-session row id: open (or focus) its page. A closed row tags
      // with the web id; an open row tags with the live session id (which is
      // already selected). Mirrors the screen rows' attach/focus behavior.
      if let web = model.webSessions.all.first(where: { $0.id == id }) {
        model.openOrFocusWebSession(web)
        return
      }
      // A database-connection row id: open (or focus) its browser. A closed
      // row tags with the connection id; an open row tags with the live
      // session id (already selected).
      if let connection = model.databaseConnections.first(where: { $0.id == id }) {
        model.openOrFocusDatabaseConnection(connection)
        return
      }
      #if os(macOS)
      if let info = model.screenMonitor.sessions.first(where: { $0.tagID == id }) {
        if let existing = model.attachedSession(toScreen: info) {
          // Already attached: just focus the open terminal instead of
          // spawning a second client (multi-attach would leave the
          // session "Attached" even after one terminal closes).
          model.selection = existing.id
        } else {
          model.attach(toScreen: info)
        }
      } else if let info = model.remoteScreenSessions.first(where: { $0.tagID == id }) {
        // Remote persistent row: attach a local terminal to it over SSH.
        if let existing = model.attachedSession(toScreen: info) {
          // Already attached: focus the open terminal (see above).
          model.selection = existing.id
        } else if let config = model.connections.first(where: { $0.id == info.remoteOrigin?.sshConfigID }) {
          model.attach(toRemoteScreen: info, on: config)
        }
      }
      #endif
    }
    .navigationTitle("Terminals")
    // Drive the history-mode → terminals swap with a blur-replace transition
    // (both branches carry .transition(.blurReplace)).
    .animation(.easeInOut(duration: 0.25), value: model.historyMode)
    #if os(macOS)
    .alert(item: $model.screenMonitor.actionError) { error in
      Alert(
        title: Text(error.title),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    #endif
    // The authorized-keys panel (key.2.on.ring in the Local/Remote
    // headers); opens for this Mac or the selected SSH connection.
    .sheet(isPresented: $model.showingAuthorizedKeys) {
      if let target = model.authorizedKeysTarget {
        AuthorizedKeysView(target: target)
          .environment(model)
      }
    }
    // The Edit… action on a saved web session: the same form as new,
    // prefilled, saving in place (same id). Creating a page has no sheet — the
    // SSH host menu items open one immediately (openNewWebSession).
    .sheet(item: $model.editingWebSession) { web in
      NewWebSessionView(web: web)
    }
    // The Rename… action on a database connection: a small sheet with a
    // TextField pre-filled with the connection's current name/display name.
    // Empty input resets to the engine display name.
    .sheet(item: $renamingDatabaseConnection) { connection in
      DatabaseRenameSheet(
        connection: connection,
        text: $databaseRenameText,
        onCommit: { commitRenameDatabase(connection) },
        onCancel: { renamingDatabaseConnection = nil }
      )
      .environment(model)
    }
    .alert("Authorized Keys", isPresented: Binding(
      get: { model.authorizedKeysError != nil },
      set: { if !$0 { model.authorizedKeysError = nil } }
    )) {
      Button("OK", role: .cancel) { model.authorizedKeysError = nil }
    } message: {
      Text(model.authorizedKeysError ?? "")
    }
    #if os(macOS)
    .background {
      // The observer owns the enable-state policy: it starts the monitor when
      // the Monitoring feature is on and stops it the moment the feature is
      // toggled off (and never restarts it while disabled). Always installed
      // so the enable toggle is handled here rather than by view teardown.
      WindowStatsObserver(monitor: statsMonitor, enabled: monitoringEnabled)
    }
    .onAppear {
      if monitoringEnabled { statsMonitor.start() }
    }
    .onDisappear { statsMonitor.stop() }
    // Stats graphs for the last minute, opened from the Local header.
    .sheet(isPresented: $showingStatsGraphs) {
      StatsGraphView(monitor: statsMonitor)
    }
    #endif
#if os(iOS)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button {
          model.showingSettings = true
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
      }
    }
#endif
  }

  /// Opens the database rename sheet pre-filled with the connection's current
  /// name (or its display name fallback).
  private func beginRenameDatabase(_ connection: DatabaseConnection) {
    databaseRenameText = connection.displayName
    renamingDatabaseConnection = connection
  }

  /// Applies a database rename (empty input resets to the engine display name)
  /// and dismisses the sheet.
  private func commitRenameDatabase(_ connection: DatabaseConnection) {
    model.renameDatabaseConnection(connection, to: databaseRenameText)
    renamingDatabaseConnection = nil
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
      Section {
        ForEach(runningCollapsed || !flags.isEnabled(.actions) ? [] : model.actionSessions) { session in
          ActionRunRow(session: session, spec: model.actionSpec(for: session))
            .tag(session.id)   // mandatory: untagged rows write nil into selection
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
        HStack(spacing: 4) {
          SidebarCollapseChevron(collapsed: $runningCollapsed)
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
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        stateIcon
        Text(spec?.action.name ?? "Action")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        DetachReturnBadge(itemID: session.id)
        Text(environmentLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      statusLine
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var stateIcon: some View {
    switch session.connectionState {
    case .starting, .connecting, .connected:
      Image(systemName: "play.fill")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Running")
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .closed:
      if session.actionExitCode == 0 {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      } else {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    switch session.connectionState {
    case .failed(let message):
      Text(message)
        .font(.caption2)
        .foregroundStyle(.red)
        .lineLimit(1)
    case .closed:
      if let code = session.actionExitCode, code != 0 {
        Text("exit " + String(code))
          .font(.caption2.monospaced())
          .foregroundStyle(.red)
          .lineLimit(1)
      } else if !session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme).characters.isEmpty {
        Text(session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme))
          .font(.caption2.monospaced())
          .lineLimit(1)
          .truncationMode(.tail)
      }
    default:
      if !session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme).characters.isEmpty {
        Text(session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme))
          .font(.caption2.monospaced())
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
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
      Section {
        ForEach(filesCollapsed ? [] : model.openedFiles) { file in
          OpenedFileRow(file: file)
            .tag(file.id)
            .contextMenu {
              Button("Close", role: .destructive) {
                model.closeOpenedFile(file.id)
              }
            }
        }
      } header: {
        HStack {
          SidebarCollapseChevron(collapsed: $filesCollapsed)
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
      }
    }
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

  var body: some View {
    Button {
      collapsed.toggle()
    } label: {
      Image(systemName: collapsed ? "chevron.right" : "chevron.down")
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
    VStack(alignment: .leading, spacing: 2) {
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
        DetachReturnBadge(itemID: session.id)
        stateDot
      }
      // Second line: the session's status (n-th non-empty terminal line
      // from the bottom, or the line pinned by clicking its last
      // character), rendered in the terminal's own colors.
      if !session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme).characters.isEmpty {
        Text(session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme)).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
          .clipShape(.capsule)
      }
    }
    .onChange(of: isRenaming) { _, newValue in
      if newValue {
        draft = currentLabel
        fieldFocused = true
      }
    }
    .contentShape(Rectangle())
  }
  
  @ViewBuilder
  private var stateDot: some View {
    switch session.connectionState {
    case .connected:
      // Green only while the session produced output recently; after
      // `TerminalSession.inactivityTimeout` of quiet the session is idle
      // and the dot hides. Read via @Observable so the row re-renders when
      // `hasActivity` flips.
      if session.hasActivity {
        Circle().fill(.green).frame(width: 7, height: 7)
      }
    case .failed:
      Circle().fill(.red).frame(width: 7, height: 7)
    case .starting, .connecting, .closed:
      Circle().fill(.secondary).frame(width: 7, height: 7)
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
        }
      }
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
  let itemID: UUID

  var body: some View {
    if model.isDetached(itemID) {
      Button {
        model.markAttached(itemID)
        model.selection = itemID
        dismissWindow(id: "detach", value: itemID)
      } label: {
        Image(systemName: "arrowshape.turn.up.left.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Return to main window")
    }
  }
}
