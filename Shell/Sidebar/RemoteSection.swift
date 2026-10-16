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

  /// The saved SSH hosts reorder with Shell's own drag: a host row also takes
  /// file drops (SidebarReorder.swift).
  private var connectionReorder: SidebarReorderGroup {
    SidebarReorderGroup(.sshConnections) { model.moveConnection(from: $0, to: $1) }
  }

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
      KitSection(Text("Remote"), isExpanded: .expanded(collapsed: $remoteCollapsed)) {
        ForEach(Array(model.connections.enumerated()), id: \.element.id) { index, config in
          SSHConfigGroup(
            config: config,
            state: state,
            reorder: connectionReorder.row(at: index),
            onEdit: { editingConfig = $0 }
          )
        }
      } icon: {
        SidebarSectionIcon(systemImage: "globe", hue: .blue)
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
  /// This host's row in the sidebar's host list.
  let reorder: SidebarReorder
  let onEdit: (SSHConfig) -> Void
  private var flags: FeatureFlagsStore { .shared }

  /// This host's running shell rows — a reorderable list of their OWN, so
  /// dragging a session row never moves the host row (and vice versa).
  private var sessionReorder: SidebarReorderGroup {
    SidebarReorderGroup(.sshSessions(config.id)) { model.moveSSHSession(for: config, from: $0, to: $1) }
  }

  /// The host's sub-rows pass the filter by their own name, or all of them when
  /// the host's name matches.
  private func shows(_ name: String) -> Bool {
    state.matches(config.displayName) || state.matches(name)
  }

  private var webSessions: [WebSession] {
    flags.isEnabled(.web) ? model.webSessions.all.filter { $0.sshConfigID == config.id && shows($0.sidebarTitle) } : []
  }

  private var databaseConnections: [DatabaseConnection] {
    flags.isEnabled(.database)
      ? model.databaseConnections.filter { $0.sshConfigID == config.id && shows($0.displayName) } : []
  }

  private var shellSessions: [TerminalSession] { model.shellSessions(for: config) }

  var body: some View {
    let visibleSessions = shellSessions.filter { shows(model.displayName(for: $0)) }
    if state.matches(config.displayName) || !visibleSessions.isEmpty || !webSessions.isEmpty
      || !databaseConnections.isEmpty
    {
      hostRow
      // Only SSH SHELL sessions get a terminal row here. A host-bound web page or
      // database connection has its own row view in the loops below; emitting one
      // here too would render its name twice (once with a terminal icon).
      ForEach(Array(shellSessions.enumerated()), id: \.element.id) { index, session in
        if shows(model.displayName(for: session)) {
          SessionRow(
            session: session,
            defaultLabel: model.displayName(for: session),
            isRenaming: state.isRenamingSession(session.id),
            onRename: { model.renameSession(session.id, to: $0) }
          )
          .kitRowIndent(1)
          .sidebarReorderable(sessionReorder.row(at: index))
          #if os(macOS)
          // A file dropped on a running SSH session's row: ask whether to upload it
          // to the session's remote cwd or, for a file on this same host, to type
          // its path or go to its folder (FileDropActions.swift). Outside the
          // reorder, whose drop target reads its handler (SidebarReorder.swift).
          .sidebarFileDrop { files in model.requestFileDrop(files, on: .session(session.id)) }
          #endif
          .contextMenu {
            Button("Rename…") { state.renamingSessionID = session.id }
            Divider()
            Button("Close Connection", role: .destructive) {
              model.removeSession(session.id)
            }
          }
        }
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
          .contextMenu { DatabaseConnectionActions(connection: connection) { state.beginRenameDatabase($0) } }
      }
    }
  }

  private var hostRow: some View {
    SSHConfigRow(config: config)
      .sidebarReorderable(reorder)
    #if os(macOS)
      // A file dropped on the saved connection — no terminal cwd to follow,
      // so it uploads to the server's home directory (~), once confirmed.
      .sidebarFileDrop { files in model.requestFileDrop(files, on: .host(config)) }
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
          Menu {
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
          } label: {
            Label("New Session for This Host", systemImage: "plus")
          }
          .menuStyle(.button)
          .buttonStyle(.kitIcon)
          .menuIndicator(.hidden)
          .help("New session for this host")
          .transition(.scale.combined(with: .opacity))
        }
      }
    }
    .animation(.kit, value: isConnected)
  }
}
