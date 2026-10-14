import Foundation
import SwiftUI
import ShellKit

/// The Remote section: saved SSH hosts, each emitting its running sessions, its
/// host-bound web pages and its tunneled database connections as indented
/// sub-rows. Hidden entirely while the ssh feature is off (this section's own
/// gate).
///
/// The Edit… sheet for a saved connection and the collapse state are local to
/// this section; the session rename and the database rename sheet stay with the
/// CONTAINER (`SidebarState` in SidebarChrome.swift — the Local section and the
/// other sidebar container share them) and are handed in as `state`.
struct RemoteSectionView: View {
  @Environment(AppModel.self) private var model
  /// The sidebar state the CONTAINER owns (SidebarChrome.swift): the session
  /// rename and the database rename sheet, both shared with the Local section.
  let state: SidebarState
  /// Collapse state for this section, persisted across launches.
  @AppStorage("sidebar.remote.collapsed") private var remoteCollapsed = false
  /// The saved SSH connection currently being edited (opens the edit sheet).
  @State private var editingConfig: SSHConfig?

  private var flags: FeatureFlagsStore { .shared }

  /// The saved SSH hosts' drag-reorder descriptor: ONE descriptor feeds both the
  /// `ForEach`'s `.onMove` (the `List` sidebar) and each host row's drag (the
  /// `LazyVStack` one), so either container reorders through the same model call.
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

  /// This section's rows; the gate is the section's own, and keeping it in a
  /// property leaves the section's shape untouched.
  @ViewBuilder
  private var sectionContent: some View {
    if flags.isEnabled(.ssh) {
      SidebarSection {
        ForEach(Array((remoteCollapsed || !flags.isEnabled(.ssh) ? [] : model.connections).enumerated()), id: \.element.id) { index, config in
          SSHConfigGroup(
            config: config,
            state: state,
            reorder: connectionReorder.row(at: index),
            onEdit: { editingConfig = $0 }
          )
        }
        .onMove(perform: connectionReorder.move)
      } header: {
        SidebarSectionHeader(collapsed: $remoteCollapsed) {
          Text("Remote")
        } trailing: {
          if flags.isEnabled(.ssh) {
            Button {
              model.showingNewConnection = true
            } label: {
              Image(systemName: "plus")
            }.buttonStyle(.borderless).help("New SSH connection")
          }
        }
      }
    } // end if (ssh section gate)
  }

  /// Applies a session rename and exits edit mode. The state is the container's
  /// (the Local section renames the same rows).
  private func commitRename(_ id: UUID, _ name: String) {
    model.renameSession(id, to: name)
    state.renamingSessionID = nil
  }
}

/// A saved SSH connection (server) plus its running connections. Emits
/// one sidebar row per running session, so the sidebar shows them all.
private struct SSHConfigGroup: View {
  @Environment(AppModel.self) private var model
  let config: SSHConfig
  /// The sidebar state the CONTAINER owns (SidebarChrome.swift): the session
  /// rename and the database rename sheet, both shared with the Local section.
  let state: SidebarState
  /// This host's row in the sidebar's host list: the `List` reorders hosts
  /// through `.onMove`, the `LazyVStack` by dragging the row.
  let reorder: SidebarReorder
  let onEdit: (SSHConfig) -> Void
  private var flags: FeatureFlagsStore { .shared }

  /// This host's running shell rows — a reorderable list of their OWN, so
  /// dragging a session row never moves the host row (and vice versa).
  private var sessionReorder: SidebarReorderGroup {
    SidebarReorderGroup(.sshSessions(config.id)) { model.moveSSHSession(for: config, from: $0, to: $1) }
  }
  
  var body: some View {
    SSHConfigRow(config: config)
      .sidebarRow(.ssh(config.id), reorder: reorder)
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
        if flags.isEnabled(.authorizedKeys) {
          Button("Authorized Keys", systemImage: "key.2.on.ring") {
            model.showAuthorizedKeys(for: .ssh(config))
          }.buttonStyle(.borderless).help("Manage the selected connection's authorized keys")
            .accessibilityIdentifier("ssh-cell-\(config.host)")
        }
        Divider()
        Button("Delete Connection", role: .destructive) {
          model.deleteConnection(config)
        }
      }
    // Only SSH SHELL sessions get a terminal row here. A host-bound web page or
    // database connection has its own row view in the loops below; emitting one
    // here too would render its name twice (once with a terminal icon).
    ForEach(Array(model.shellSessions(for: config).enumerated()), id: \.element.id) { index, session in
      SessionRow(
        session: session,
        defaultLabel: model.displayName(for: session),
        subtitle: "\(config.user)@\(config.host):\(config.port)",
        isRenaming: state.renamingSessionID == session.id,
        onCommitRename: { commitRename(session.id, $0) },
        onCancelRename: { state.renamingSessionID = nil }
      )
      .padding(.leading, 14)
      .sidebarRow(.session(session.id), reorder: sessionReorder.row(at: index))
#if os(macOS)
      // A file dropped on a running SSH session's row: ask whether to upload it
      // to the session's remote cwd or, for a file on this same host, to type
      // its path or go to its folder (FileDropActions.swift).
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
    .onMove(perform: sessionReorder.move)
    // Saved web pages bound to this host render as SSH-section rows, in the
    // same indented sub-row layout as the connection's terminals. Hidden when
    // the web feature is disabled.
    if FeatureFlagsStore.shared.isEnabled(.web) {
    ForEach(model.webSessions.all.filter { $0.sshConfigID == config.id }) { web in
      WebSessionRow(web: web, environmentName: config.displayName)
        .padding(.leading, 14)
        .sidebarRow(model.rowSelection(for: web))
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
        .sidebarRow(model.rowSelection(for: connection))
        .contextMenu { DatabaseConnectionActions(connection: connection) { state.beginRenameDatabase($0) } }
    }
    }
  }

  /// Applies a session rename and exits edit mode. The state is the container's
  /// (the Local section renames the same rows).
  private func commitRename(_ id: UUID, _ name: String) {
    model.renameSession(id, to: name)
    state.renamingSessionID = nil
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
          .transition(SidebarMotion.iconTransition)
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
          .transition(SidebarMotion.iconTransition)
        }
      }
    }
    .sidebarAnimation(value: model.sessionID(for: config) != nil)
    .contentShape(Rectangle())
  }
}
