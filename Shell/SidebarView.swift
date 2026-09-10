import Foundation
import SwiftUI
import Terminal
import TerminalIntegrations
import Monitoring

/// Sidebar: lists local terminals and saved SSH connections.
struct SidebarView: View {
  @Environment(AppModel.self) private var model
  /// The session currently being renamed (shows an inline text field).
  @State private var renamingSessionID: UUID?
  /// The saved SSH connection currently being edited (opens the edit sheet).
  @State private var editingConfig: SSHConfig?
  /// The database connection being renamed (drives the rename sheet), and the
  /// text field's draft value, pre-filled with the connection's display name.
  @State private var renamingDatabaseConnection: DatabaseConnection?
  @State private var databaseRenameText = ""
  #if os(macOS)
  /// The screen session currently being renamed (keyed by full name).
  @State private var renamingScreenName: String?
  /// Live CPU/GPU/wattage for the Local section header (macOS only —
  /// the reads need IOKit's AppleSMC / IOAccelerator).
  @State private var statsMonitor = SystemStatsMonitor()
  /// The stats graphs sheet, opened by clicking the Local section header.
  @State private var showingStatsGraphs = false
  /// Whether the Monitoring feature is on — gates the live stats monitor so
  /// it never samples when the feature is off.
  private var monitoringEnabled: Bool {
    FeatureFlagsStore.shared.isEnabled(.monitoring)
  }
  #endif

  /// Collapse state for each sidebar section, persisted across launches.
  @AppStorage("sidebar.running.collapsed") private var runningCollapsed = false
  @AppStorage("sidebar.local.collapsed") private var localCollapsed = false
  @AppStorage("sidebar.remote.collapsed") private var remoteCollapsed = false
  @AppStorage("sidebar.notes.collapsed") private var notesCollapsed = false
  #if os(macOS)
  @AppStorage("sidebar.files.collapsed") private var filesCollapsed = false
  #endif

  /// The feature-flag source of truth. Reads `.isEnabled(_:)` here so a
  /// disabled feature's rows/sections vanish from the sidebar. Accessing it
  /// through `@Observable` re-renders the sidebar when a flag flips.
  private var flags: FeatureFlagsStore { .shared }

  private var localSessions: [TerminalSession] {
    model.sessions.filter { model.kind(of: $0) == .local }
  }

  /// Saved web pages shown in the Local section: those not bound to an SSH
  /// host. A page is "local" when no sshConfigID is set — the WebView loads
  /// its URL directly (this covers localhost URLs).
  private var localWebSessions: [WebSession] {
    model.webSessions.all.filter { $0.sshConfigID == nil }
  }

  /// Local database connections: those reached directly (no SSH tunnel), so
  /// they render under Local alongside local shells. Connections bound to an
  /// SSH host render under Remote, grouped by that host.
  private var localDatabaseConnections: [DatabaseConnection] {
    model.databaseConnections.filter { $0.sshConfigID == nil }
  }
  
  var body: some View {
    @Bindable var model = model
    List(selection: $model.selection) {
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
            sidebarCollapseChevron(collapsed: $runningCollapsed)
            Text("Running")
          }
        }
      }

      #if os(macOS)
      // The Local section hosts local terminals (sessions), persistent
      // screen/tmux (screen), history, and web sessions. It stays visible
      // while ANY of these features is enabled; each is filtered to its own
      // rows below.
      if flags.isEnabled(.sessions) || flags.isEnabled(.screen) || flags.isEnabled(.history) || flags.isEnabled(.web) || flags.isEnabled(.database) {
      Section {
        if model.historyMode {
          ForEach(localCollapsed || !flags.isEnabled(.history) ? [] : model.history.sessions) { record in
            HistorySessionRow(session: record)
              .tag(record.id)
          }
          .transition(.blurReplace)
        } else {
          ForEach(localCollapsed || !flags.isEnabled(.sessions) ? [] : localSessions) { session in
            SessionRow(
              session: session,
              defaultLabel: model.displayName(for: session),
              subtitle: nil,
              isRenaming: renamingSessionID == session.id,
              onCommitRename: { commitRename(session.id, $0) },
              onCancelRename: { renamingSessionID = nil }
            )
            .tag(session.id)
            .dropDestination(for: ShellFile.self) { files, _ in
              // A file dropped on this session cell — from Finder (decoded as a
              // ShellFile via the FileRepresentation importing closure) or dragged
              // from the Files panel (custom-UTType Codable payload). Each is
              // materialized (a remote row is SFTP-downloaded) then copied into
              // the session's cwd.
              model.dropFiles(files, on: session)
              return true
            }
            .contextMenu {
              Button("Rename…") { renamingSessionID = session.id }
              Button("Authorized Keys", systemImage: "key.2.on.ring.fill") {
                model.openLocalAuthorizedKeys()
              }.buttonStyle(.borderless).help("Manage this Mac's authorized keys")
              Divider()
              Button("Close Terminal", role: .destructive) {
                model.removeSession(session.id)
              }
            }
          }
          .onMove { source, destination in
            model.moveLocalSession(from: source, to: destination)
          }
          ForEach(localCollapsed || !flags.isEnabled(.screen) ? [] : model.screenMonitor.sessions) { info in
            ScreenSessionRow(
              info: info,
              isRenaming: renamingScreenName == info.name,
              onCommitRename: { commitScreenRename(info, $0) },
              onCancelRename: { renamingScreenName = nil }
            )
            // Tag with the open session's id when attached (so the row shows
            // selected while its terminal is open), else the stable tagID.
            .tag(model.attachedSession(toScreen: info)?.id ?? info.tagID)
            .contextMenu {
              Button("Rename…") { renamingScreenName = info.name }
              Divider()
              if model.attachedSession(toScreen: info) == nil {
                Button("Attach") { model.attach(toScreen: info) }
              }
              // Kills the session itself (screen -S <name> -X quit); the
              // row disappears from the list. Works for detached sessions
              // too, which the toolbar's Close button can't reach.
              Button("Close Session", role: .destructive) {
                model.closeScreenSession(info)
              }
            }
          }
          ForEach(localCollapsed || !flags.isEnabled(.screen) ? [] : model.remoteScreenSessions) { info in
            ScreenSessionRow(
              info: info,
              isRenaming: false,
              onCommitRename: { _ in },
              onCancelRename: {}
            )
            // Tag with the open session's id when attached (so the row shows
            // selected while its terminal is open), else the stable tagID.
            .tag(model.attachedSession(toScreen: info)?.id ?? info.tagID)
            .contextMenu {
              // Remote persistent sessions are identified by their SSH origin;
              // renaming runs on the host, which is out of scope here.
              if model.attachedSession(toScreen: info) == nil {
                Button("Attach") {
                  if let config = model.connections.first(where: { $0.id == info.remoteOrigin?.sshConfigID }) {
                    model.attach(toRemoteScreen: info, on: config)
                  }
                }
              }
              // Kills the session on the host itself (screen -S <name> -X
              // quit / tmux kill-session); the row disappears from the list.
              Button("Close Session", role: .destructive) {
                model.closeRemoteScreenSession(info)
              }
            }
          }
          ForEach(localCollapsed || !flags.isEnabled(.web) ? [] : localWebSessions) { web in
            WebSessionRow(web: web)
              // Tag with the open session's id when the page is open (so the
              // row shows selected while its WebView is up), else the stable
              // web id — same convention as the screen rows above.
              .tag(model.liveWebSession(for: web)?.id ?? web.id)
          }
          .onMove { source, destination in
            model.moveLocalWebSession(from: source, to: destination)
          }
          // Local database connections (no SSH tunnel) live in the Local
          // section like local shells; remote ones group under Remote instead.
          ForEach(localCollapsed || !flags.isEnabled(.database) ? [] : localDatabaseConnections) { connection in
            DatabaseConnectionRow(connection: connection)
              .tag(model.liveDatabaseSession(for: connection)?.id ?? connection.id)
              .contextMenu { DatabaseConnectionActions(connection: connection) { beginRenameDatabase($0) } }
          }
          .onMove { source, destination in
            model.moveLocalDatabaseConnection(from: source, to: destination)
          }
          .transition(.blurReplace)
        }
      } header: {
        HStack {
          sidebarCollapseChevron(collapsed: $localCollapsed)
          #if os(macOS)
          Group {
            if model.historyMode {
              Text("Local History")
            } else if flags.isEnabled(.monitoring) {
              statsHeader
            } else {
              Text("Local")
            }
          }.transition(.blurReplace)
          #else
          Text(model.historyMode ? "Local History" : "Local")
          #endif
          if model.historyMode, flags.isEnabled(.history) {
            Button(role: .destructive) {
              model.deleteAllHistory()
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete all local history")
            .transition(.blurReplace)
          }
          Spacer()
          // Only meaningful when there is something to show; hidden while
          // the list is empty (the trash button still serves as the exit
          // when viewing history).
          if flags.isEnabled(.history), !model.history.sessions.isEmpty {
            Button {
              model.toggleHistoryMode()
            } label: {
              Image(systemName: "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted")
                .foregroundStyle(model.historyMode ? Color.blue : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.historyMode ? "Show local terminals" : "Show local history")
            .transition(.blurReplace)
          }
          if flags.isEnabled(.sessions) || flags.isEnabled(.web) || flags.isEnabled(.database) {
          Menu {
            if flags.isEnabled(.sessions) {
              Button {
                model.addLocalTerminal()
              } label: {
                Label("New Session", systemImage: "terminal")
              }
            }
            if flags.isEnabled(.web) {
              Button {
                model.openEmptyWebSession()
              } label: {
                Label("Web Session", systemImage: "globe")
              }
            }
            if flags.isEnabled(.database) {
              Button {
                model.editingDatabaseConnection = nil
                model.showingNewDatabaseConnection = true
              } label: {
                Label("Database", systemImage: "cylinder.split.1x2")
              }
            }
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
          .menuIndicator(.hidden)
          }
        }.padding(.trailing, 4)
      }
      } // end if (local section gate)

      #endif // os(macOS) — Local section (no local terminals on iOS)

      // Remote SSH section: hidden entirely when the ssh feature is off.
      if flags.isEnabled(.ssh) {
      Section {
        ForEach(remoteCollapsed || !flags.isEnabled(.ssh) ? [] : model.connections) { config in
          SSHConfigGroup(
            config: config,
            renamingSessionID: renamingSessionID,
            onBeginRename: { renamingSessionID = $0 },
            onCommitRename: commitRename,
            onCancelRename: { renamingSessionID = nil },
            onRenameDatabase: beginRenameDatabase,
            onEdit: { editingConfig = $0 }
          )
        }
        .onMove { source, destination in
          model.moveConnection(from: source, to: destination)
        }
      } header: {
        HStack {
          sidebarCollapseChevron(collapsed: $remoteCollapsed)
          Text("Remote")
          Spacer()
          if flags.isEnabled(.ssh) {
          Button {
            model.showingNewConnection = true
          } label: {
            Image(systemName: "plus")
          }.buttonStyle(.borderless).help("New SSH connection")
          }
        }.padding(.trailing, 4)
      }
      } // end if (ssh section gate)

      // Notes section: hidden entirely when the notes feature is off.
      if flags.isEnabled(.notes) {
      Section {
        ForEach(notesCollapsed || !flags.isEnabled(.notes) ? [] : model.notes.notes) { note in
          NoteRow(note: note)
            .tag(note.id)
            .contextMenu {
              Button("Delete Note", role: .destructive) {
                model.deleteNote(note.id)
              }
            }
        }
      } header: {
        HStack {
          sidebarCollapseChevron(collapsed: $notesCollapsed)
          Text("Notes")
          Spacer()
          if flags.isEnabled(.notes) {
          Button {
            model.newNote()
          } label: {
            Image(systemName: "plus")
          }.buttonStyle(.borderless).help("New note")
          }
        }.padding(.trailing, 4)
      }
      } // end if (notes section gate)

#if os(macOS)
      // Opened text files (transient/scratch) — mirrors the Notes section but
      // in its own grouping that never persists to NotesStore. Shown only
      // while a file is open; empty on a fresh launch. Close via ⌘W or the
      // row's context menu.
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
          sidebarCollapseChevron(collapsed: $filesCollapsed)
          Text("Text Files")
        }
      }
      } // end if (opened files gate)
#endif

    }

    // Clicking an SSH row selects its config id; turn that into an
    // actual connection (select the existing session or create one).
    // Screen rows select a deterministic tagID; attach a local terminal
    // to that screen session.
    .onChange(of: model.selection) { _, newValue in
      if renamingSessionID != nil { renamingSessionID = nil }
      #if os(macOS)
      renamingScreenName = nil
      #endif
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
    // The Edit… action on a saved SSH connection: the same form as new
    // connections, prefilled, saving in place (same id).
    .sheet(item: $editingConfig) { config in
      NewConnectionView(config: config)
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

  #if os(macOS)
  /// The Local section header showing live CPU/GPU usage and total
  /// wattage, e.g. "  5% 12% 13W" (percentages right-aligned to 3 chars,
  /// wattage right-aligned to 2 chars). Falls back to plain "Local" when
  /// the stats aren't available yet (first tick). Clicking it opens the
  /// stats graphs for the last minute.
  @ViewBuilder
  private var statsHeader: some View {
    let cpu = Int(statsMonitor.cpuPercent.rounded())
    let gpu = Int(statsMonitor.gpuPercent.rounded())
    if statsMonitor.watts > 0 {
      Button {
        showingStatsGraphs = true
      } label: {
        Text("\(String(format: "%3d", cpu))% \(String(format: "%3d", gpu))% \(String(format: "%2d", statsMonitor.watts))W")
          .font(.caption.weight(.medium))
          .monospaced()
      }
      .buttonStyle(.plain)
      .help("CPU · GPU · System power draw — click for graphs")
    } else {
      Text("Local")
    }
  }
  #endif

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

  /// Applies a rename and exits edit mode.
  private func commitRename(_ id: UUID, _ name: String) {
    model.renameSession(id, to: name)
    renamingSessionID = nil
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

  /// A leading disclosure triangle that collapses/expands a sidebar section.
  /// Collapsing hides the section's rows; the header (and its action buttons)
  /// stays visible so the controls remain reachable. chevron.down = expanded,
  /// chevron.right = collapsed.
  private func sidebarCollapseChevron(collapsed: Binding<Bool>) -> some View {
    Button {
      collapsed.wrappedValue.toggle()
    } label: {
      Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(collapsed.wrappedValue ? "Expand section" : "Collapse section")
  }
  
  #if os(macOS)
  /// Renames a screen session on the local machine and exits edit mode.
  private func commitScreenRename(_ info: ScreenSessionInfo, _ name: String) {
    model.screenMonitor.rename(info, to: name)
    renamingScreenName = nil
  }
  #endif
}

private struct HistorySessionRow: View {
  let session: HistorySession

  var body: some View {
    HStack(spacing: 8) {
      Text(session.title)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Text(session.activityDate, style: .relative)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
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

/// A saved SSH connection (server) plus its running connections. Emits
/// one sidebar row per running session, so the List shows them all.
private struct SSHConfigGroup: View {
  @Environment(AppModel.self) private var model
  let config: SSHConfig
  let renamingSessionID: UUID?
  let onBeginRename: (UUID) -> Void
  let onCommitRename: (UUID, String) -> Void
  let onCancelRename: () -> Void
  let onRenameDatabase: (DatabaseConnection) -> Void
  let onEdit: (SSHConfig) -> Void
  private var flags: FeatureFlagsStore { .shared }
  
  var body: some View {
    SSHConfigRow(config: config)
      .tag(config.id)
#if os(macOS)
      .dropDestination(for: ShellFile.self) { files, _ in
        // A file dropped on the saved connection — no terminal cwd to follow,
        // so it lands in the server's home directory (~).
        model.dropFiles(files, toSSH: config)
        return true
      }
#endif
      .contextMenu {
        Button("Connect") { model.connect(to: config) }
        Divider()
        // New-session entries bound to this host: the same preset actions the
        // row's trailing + menu offers while connected, but reachable from the
        // right-click menu even when the connection is closed. A web session
        // opens IMMEDIATELY (no setup sheet) with the URL field empty — the
        // user types the host's address and the page names itself.
        if flags.isEnabled(.web) {
          Button {
            model.openNewWebSession(on: config)
          } label: {
            Label("Web Session", systemImage: "globe")
          }
        }
        if flags.isEnabled(.database) {
          Button {
            model.databasePresetSSHConfigID = config.id
            model.editingDatabaseConnection = nil
            model.showingNewDatabaseConnection = true
          } label: {
            Label("Database", systemImage: "cylinder.split.1x2")
          }
        }
        #if os(macOS)
        if flags.isEnabled(.screen) {
          Button {
            model.createRemoteScreenSession(on: config)
          } label: {
            Label("Persistent Session", systemImage: "shield.fill")
          }
          // A remote create must exec on the host's LIVE connection; it is
          // the only entry here that requires the host to be connected.
          .disabled(!model.hasLiveSSHConnection(to: config))
          Button {
            model.refreshPersistentSessions()
          } label: {
            Label("Refresh Sessions", systemImage: "arrow.clockwise")
          }
        }
        #endif
        Divider()
        Button("Edit…") { onEdit(config) }
        Button("Copy Public Key") { model.copyPublicKey() }
        Button("Authorized Keys", systemImage: "key.2.on.ring") {
          model.showAuthorizedKeys(for: .ssh(config))
        }.buttonStyle(.borderless).help("Manage the selected connection's authorized keys")
          .accessibilityIdentifier("ssh-cell-\(config.host)")
        Divider()
        Button("Delete Connection", role: .destructive) {
          model.deleteConnection(config)
        }
      }
    ForEach(model.sessions(for: config)) { session in
      SessionRow(
        session: session,
        defaultLabel: model.displayName(for: session),
        subtitle: "\(config.user)@\(config.host):\(config.port)",
        isRenaming: renamingSessionID == session.id,
        onCommitRename: { onCommitRename(session.id, $0) },
        onCancelRename: onCancelRename
      )
      .padding(.leading, 14)
      .tag(session.id)
#if os(macOS)
      .dropDestination(for: ShellFile.self) { files, _ in
        // A file dropped on a running SSH session's row: materialize it locally
        // (a remote row is SFTP-downloaded) then upload to the session's remote
        // cwd — the same semantics as a local cell, but over the SFTP subsystem.
        model.dropFiles(files, on: session)
        return true
      }
#endif
      .contextMenu {
        Button("Rename…") { onBeginRename(session.id) }
        Divider()
        Button("Close Connection", role: .destructive) {
          model.removeSession(session.id)
        }
      }
    }
    .onMove { source, destination in
      model.moveSSHSession(for: config, from: source, to: destination)
    }
    // Saved web pages bound to this host render as SSH-section rows, in the
    // same indented sub-row layout as the connection's terminals. Hidden when
    // the web feature is disabled.
    if FeatureFlagsStore.shared.isEnabled(.web) {
    ForEach(model.webSessions.all.filter { $0.sshConfigID == config.id }) { web in
      WebSessionRow(web: web, environmentName: config.displayName)
        .padding(.leading, 14)
        .tag(model.liveWebSession(for: web)?.id ?? web.id)
    }
    }
    // Database connections tunneled through this host render as SSH-section
    // sub-rows, grouped per host the same way web sessions are. Hidden when
    // the database feature is disabled; orphaned refs (a removed host) simply
    // don't render, matching the web-session behavior.
    if FeatureFlagsStore.shared.isEnabled(.database) {
    ForEach(model.databaseConnections.filter { $0.sshConfigID == config.id }) { connection in
      DatabaseConnectionRow(connection: connection)
        .padding(.leading, 14)
        .tag(model.liveDatabaseSession(for: connection)?.id ?? connection.id)
        .contextMenu { DatabaseConnectionActions(connection: connection) { onRenameDatabase($0) } }
    }
    }
  }
}

/// A saved SSH connection (server) in the sidebar. Clicking it opens a
/// new connection to that server.
private struct SSHConfigRow: View {
  @Environment(AppModel.self) private var model
  let config: SSHConfig
  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "network")
        .foregroundStyle(.secondary)
      Text(config.displayName)
      Spacer()
      if model.sessionID(for: config) != nil {
        Circle()
          .fill(.green)
          .frame(width: 7, height: 7)
          .accessibilityLabel("Connected")
        // Trailing + menu: create an ssh-tunnelled Web/Database session for
        // this connected host. Visible only while connected, items gated by
        // their feature flag. A web session opens immediately (no sheet).
        if flags.isEnabled(.web) || flags.isEnabled(.database) {
          Menu {
            if flags.isEnabled(.web) {
              Button {
                model.openNewWebSession(on: config)
              } label: {
                Label("Web Session", systemImage: "globe")
              }
            }
            if flags.isEnabled(.database) {
              Button {
                model.databasePresetSSHConfigID = config.id
                model.editingDatabaseConnection = nil
                model.showingNewDatabaseConnection = true
              } label: {
                Label("Database", systemImage: "cylinder.split.1x2")
              }
            }
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
          .menuIndicator(.hidden)
          .help("New session for this host")
        }
      }
    }
    .contentShape(Rectangle())
  }
}

/// A GNU screen or tmux persistent session in the sidebar. Clicking it
/// attaches a new local terminal to that session. While renaming, shows
/// a focused text field prefilled with the session name; Enter applies,
/// Escape cancels.
private struct ScreenSessionRow: View {
  @Environment(AppModel.self) private var model
  @Environment(\.terminalBackgroundsDisabled) private var disableBackgrounds
  @Environment(\.colorScheme) private var colorScheme
  let info: ScreenSessionInfo
  let isRenaming: Bool
  let onCommitRename: (String) -> Void
  let onCancelRename: () -> Void
  
  @State private var draft = ""
  @FocusState private var fieldFocused: Bool
  
  /// The open terminal attached to this screen session, if any. Its
  /// status line is shown under the row.
  private var attachedSession: TerminalSession? {
    model.attachedSession(toScreen: info)
  }
  
  private var icon: String {
    "shield.fill"
  }
  
  private var kindLabel: String {
    info.kind == .tmux ? "tmux" : "screen"
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: icon)
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
          // Sidebar shows the short name (no "pid." prefix); the full
          // "pid.name" spec stays in the window title (navigationTitle).
          Text(info.shortName).lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        Circle()
          .fill(info.isAttached ? Color.green : Color.gray)
          .frame(width: 7, height: 7)
          .accessibilityLabel(info.state)
          .help(info.kind == .tmux
            ? "tmux session"
            : "GNU screen session")
      }
      // Remote rows carry their SSH origin so they're distinguishable from
      // local rows in the same merged section (e.g. "swiftui-optimization"
      // with a "build-server" subtitle).
      if let origin = info.remoteOrigin, !origin.displayName.isEmpty {
        Text(origin.displayName)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      if let session = attachedSession, !session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme).characters.isEmpty {
        Text(session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme))
          .font(.caption2.monospaced())
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .onChange(of: isRenaming) { _, newValue in
      if newValue {
        // Prefill the session name without the "pid." prefix — the
        // pid is screen's identity and shouldn't be edited.
        draft = info.shortName
        fieldFocused = true
      }
    }
    .contentShape(Rectangle())
  }
}

/// A session row in the sidebar. While renaming, shows a focused text
/// field instead of the label; Enter applies, Escape cancels.
private struct SessionRow: View {
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

/// A note row in the sidebar. The title is the first non-empty line of the
/// note (editing it renames it); the preview is the next non-empty line.
/// Both are DECRYPTED IN THE VIEW via `decryptedNote(id:)` — SwiftUI's List
/// materializes visible rows only, so only visible cells decrypt (results
/// cached by the store).
private struct NoteRow: View {
  @Environment(AppModel.self) private var model
  let note: NotesStore.NoteSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: "note.text")
          .foregroundStyle(.secondary)
        Text(model.notes.title(for: note.id))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        DetachReturnBadge(itemID: note.id)
        if note.storedInICloud {
          Image(systemName: "icloud.fill")
            .font(.caption2)
            .foregroundStyle(Color.blue)
            .help("Stored in iCloud (encrypted)")
        }
      }
      if let subtitle = model.notes.subtitle(for: note.id) {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .contentShape(Rectangle())
  }
}

/// A sidebar row for a saved database connection: engine icon, display name,
/// and host:port (or file path) subtitle, plus an "open" dot when the browser
/// is live. Clicking the row opens/focuses the database browser.
private struct DatabaseConnectionRow: View {
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
private struct DatabaseConnectionActions: View {
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

#if os(macOS)
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

/// A trailing return badge shown on a sidebar row whose item is currently
/// detached: an `arrowshape.turn.up.left.fill` button that re-attaches the
/// item — removing it from `AppModel.detachedIDs`, selecting it in the main
/// window, and dismissing its detached window/scene (`WindowGroup` id
/// "detach"). Hidden for attached items. Reading `model.isDetached` through
/// the @Observable model re-renders the row when detach state flips.
private struct DetachReturnBadge: View {
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
