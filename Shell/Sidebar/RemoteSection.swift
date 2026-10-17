import ComponentKit
import Foundation
import SwiftUI
import ShellKit

/// The Remote section: saved SSH hosts, each emitting its running sessions, its
/// host-bound web pages and its tunneled database connections as indented
/// sub-rows. Hidden entirely while the ssh feature is off (this section's own
/// gate).
///
/// The Edit… sheet for a saved connection and the collapse state are local to
/// this section; the session rename, the database rename sheet and the filter
/// stay with the sidebar (`SidebarState` in SidebarChrome.swift — the Local
/// section shares them) and are handed in as `state`.
struct RemoteSectionView: View {
  @Environment(AppModel.self) private var model
  /// The sidebar's shared state (SidebarChrome.swift).
  let state: SidebarState
  /// Collapse state for this section, persisted across launches.
  @AppStorage("sidebar.remote.collapsed") private var remoteCollapsed = false
  /// The saved SSH connection currently being edited (opens the edit sheet).
  @State private var editingConfig: SSHConfig?

  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    sectionContent
      // The Edit… action on a saved SSH connection: the same form as new
      // connections, prefilled, saving in place (same id).
      .sheet(item: $editingConfig) { config in
        NewConnectionView(config: config)
      }
  }

  /// This section's card; the gate is the section's own.
  @ViewBuilder
  private var sectionContent: some View {
    if flags.isEnabled(.ssh) {
      let online = model.connections.filter { model.sessionID(for: $0) != nil }.count
      let offline = model.connections.count - online
      KitSection("Remote", systemImage: "globe", hue: .blue, isExpanded: .expanded(collapsed: $remoteCollapsed)) {
        // Each host drags with its sub-rows as one group; a file dropped on the
        // host uploads to its home folder (FileDropActions.swift).
        let shown = model.connections.filter { SSHConfigGroup.isShown($0, model: model, state: state) }
        ReorderableSection(shown, move: { source, destination in
          let move = FilteredMove(source, destination, shown: shown, in: model.connections)
          model.moveConnection(from: move.source, to: move.destination)
        }) { config in
          SSHConfigGroup(config: config, state: state, onEdit: { editingConfig = $0 })
        }
        .dragsAsGroup()
        .alsoAccepts(sidebarFileTypes) { config, _ in
          #if os(macOS)
          FileDrop.perform { model.requestFileDrop($0, on: .host(config)) }
          #else
          false
          #endif
        }
      } meta: {
        if model.connections.isEmpty {
          MetaLine("No hosts")
        } else {
          HStack(spacing: 4) {
            if online > 0 {
              StatusDot(hue: .green, size: 6)
              Text("\(online) online")
            }
            if online > 0, offline > 0 {
              Text("·").foregroundStyle(.kitTertiary)
            }
            if offline > 0 {
              StatusDot(hue: .gray, size: 6)
              Text("\(offline) offline")
            }
          }
        }
      } accessory: {
        Button("New SSH Connection", systemImage: "plus") {
          model.showingNewConnection = true
        }
        .help("New SSH connection")
      }
    } // end if (ssh section gate)
  }
}

/// A saved SSH connection (server) plus its running connections. Emits
/// one sidebar row per running session, so the sidebar shows them all.
private struct SSHConfigGroup: View {
  @Environment(AppModel.self) private var model
  let config: SSHConfig
  /// The sidebar's shared state (SidebarChrome.swift): the session rename, the
  /// database rename sheet and the filter.
  let state: SidebarState
  let onEdit: (SSHConfig) -> Void
  private var flags: FeatureFlagsStore { .shared }

  /// The host's sub-rows pass the filter by their own name, or all of them when
  /// the host's name matches.
  private func shows(_ name: String) -> Bool {
    Self.shows(name, of: config, state: state)
  }

  private static func shows(_ name: String, of config: SSHConfig, state: SidebarState) -> Bool {
    state.matches(config.displayName) || state.matches(name)
  }

  /// Whether the host shows while the filter is on: its name matches, or one of its sub-rows' does.
  static func isShown(_ config: SSHConfig, model: AppModel, state: SidebarState) -> Bool {
    state.matches(config.displayName)
      || model.shellSessions(for: config).contains { state.matches(model.displayName(for: $0)) }
      || !webSessions(of: config, model: model, state: state).isEmpty
      || !databaseConnections(of: config, model: model, state: state).isEmpty
  }

  private static func webSessions(of config: SSHConfig, model: AppModel, state: SidebarState) -> [WebSession] {
    FeatureFlagsStore.shared.isEnabled(.web)
      ? model.webSessions.all.filter { $0.sshConfigID == config.id && shows($0.sidebarTitle, of: config, state: state) }
      : []
  }

  private static func databaseConnections(of config: SSHConfig, model: AppModel, state: SidebarState)
    -> [DatabaseConnection]
  {
    FeatureFlagsStore.shared.isEnabled(.database)
      ? model.databaseConnections.filter {
        $0.sshConfigID == config.id && shows($0.displayName, of: config, state: state)
      } : []
  }

  private var webSessions: [WebSession] { Self.webSessions(of: config, model: model, state: state) }

  private var databaseConnections: [DatabaseConnection] {
    Self.databaseConnections(of: config, model: model, state: state)
  }

  private var shellSessions: [TerminalSession] { model.shellSessions(for: config) }

  /// The host row and its sub-rows; the Remote section shows the group only when `isShown`.
  var body: some View {
    let sessions = shellSessions
    let shown = sessions.filter { shows(model.displayName(for: $0)) }
    hostRow
    // Only SSH SHELL sessions get a terminal row here. A host-bound web page or
    // database connection has its own row view in the loops below; emitting one
    // here too would render its name twice (once with a terminal icon). They are
    // a reorderable list of their own, so dragging a session never moves the host.
    ReorderableSection(shown, move: { source, destination in
      let move = FilteredMove(source, destination, shown: shown, in: sessions)
      model.moveSSHSession(for: config, from: move.source, to: move.destination)
    }) { session in
      SessionRow(
        session: session,
        defaultLabel: model.displayName(for: session),
        isRenaming: state.isRenamingSession(session.id),
        onRename: { model.renameSession(session.id, to: $0) }
      )
      .kitRowIndent(1)
      .kitContextMenu {
        Button("Rename…") { state.renamingSessionID = session.id }
        Divider()
        Button("Close Connection", role: .destructive) {
          model.removeSession(session.id)
        }
      }
    }
    // A file dropped on a running SSH session's row: ask whether to upload it
    // to the session's remote cwd or, for a file on this same host, to type
    // its path or go to its folder (FileDropActions.swift).
    .alsoAccepts(sidebarFileTypes) { session, _ in
      #if os(macOS)
      FileDrop.perform { model.requestFileDrop($0, on: .session(session.id)) }
      #else
      false
      #endif
    }
    // Saved web pages bound to this host render as indented sub-rows, like the
    // connection's terminals. Hidden when the web feature is disabled.
    ForEach(webSessions) { web in
      WebSessionRow(web: web, environmentName: config.displayName)
        .kitRowIndent(1)
    }
    // Database connections tunneled through this host render as sub-rows,
    // grouped per host the same way web sessions are. Hidden when the database
    // feature is disabled; orphaned refs (a removed host) simply don't render.
    ForEach(databaseConnections) { connection in
      DatabaseConnectionRow(connection: connection)
        .kitRowIndent(1)
        .kitContextMenu { DatabaseConnectionActions(connection: connection) { state.beginRenameDatabase($0) } }
    }
  }

  /// The saved connection. A file dropped on it (the group's drop, in the Remote
  /// section) has no terminal cwd to follow, so it uploads to the server's home
  /// directory (~), once confirmed.
  private var hostRow: some View {
    SSHConfigRow(config: config)
      .kitContextMenu {
        Button("Connect") { model.connect(to: config) }
        Divider()
        // New-session entries bound to this host: the same preset actions the
        // row's trailing + menu offers while connected, but reachable from the
        // right-click menu even when the connection is closed. A web session
        // opens IMMEDIATELY (no setup sheet) with the URL field empty — the
        // user types the host's address and the page names itself.
        if flags.isEnabled(.web) {
          Button("Web Session", systemImage: "globe") {
            model.openNewWebSession(on: config)
          }
        }
        if flags.isEnabled(.database) {
          Button("Database", systemImage: "cylinder.split.1x2") {
            model.databasePresetSSHConfigID = config.id
            model.editingDatabaseConnection = nil
            model.showingNewDatabaseConnection = true
          }
        }
        #if os(macOS)
        if flags.isEnabled(.screen) {
          Button("Persistent Session", systemImage: "shield.fill") {
            model.createRemoteScreenSession(on: config)
          }
          // A remote create must exec on the host's LIVE connection; it is
          // the only entry here that requires the host to be connected.
          .disabled(!model.hasLiveSSHConnection(to: config))
          Button("Refresh Sessions", systemImage: "arrow.clockwise") {
            model.refreshPersistentSessions()
          }
        }
        #endif
        Divider()
        Button("Edit…") { onEdit(config) }
        Button("Copy Public Key") { model.copyPublicKey() }
        if flags.isEnabled(.authorizedKeys) {
          Button("Authorized Keys", systemImage: "key.2.on.ring") {
            model.showAuthorizedKeys(for: .ssh(config))
          }
          .help("Manage the selected connection's authorized keys")
          .accessibilityIdentifier("ssh-cell-\(config.host)")
        }
        Divider()
        Button("Delete Connection", role: .destructive) {
          model.deleteConnection(config)
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
    let isConnected = model.sessionID(for: config) != nil
    SidebarRow(value: AppModel.Selection.ssh(config.id), config.displayName, systemImage: "network") {
      if isConnected {
        StatusDot(hue: .green)
          .accessibilityLabel("Connected")
          .transition(.scale.combined(with: .opacity))
        // Trailing + menu: create an ssh-tunnelled Web/Database session for
        // this connected host. Visible only while connected, items gated by
        // their feature flag. A web session opens immediately (no sheet).
        if flags.isEnabled(.web) || flags.isEnabled(.database) {
          MenuToolButton("New Session for This Host", systemImage: "plus") {
            if flags.isEnabled(.web) {
              Button("Web Session", systemImage: "globe") {
                model.openNewWebSession(on: config)
              }
            }
            if flags.isEnabled(.database) {
              Button("Database", systemImage: "cylinder.split.1x2") {
                model.databasePresetSSHConfigID = config.id
                model.editingDatabaseConnection = nil
                model.showingNewDatabaseConnection = true
              }
            }
          }
          .buttonStyle(.kitIcon)
          .help("New session for this host")
          .transition(.scale.combined(with: .opacity))
        }
      }
    }
    .animation(.kit, value: isConnected)
  }
}
