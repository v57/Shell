import Foundation
import SwiftUI
import Terminal

/// The Remote section: saved SSH hosts, each emitting its running sessions, its
/// host-bound web pages and its tunneled database connections as indented
/// sub-rows. Hidden entirely while the ssh feature is off (this section's own
/// gate).
///
/// The Edit… sheet for a saved connection and the collapse state are local to
/// this section; the session rename and the database rename sheet are shared
/// with the Local section and passed in.
struct RemoteSectionView: View {
  @Environment(AppModel.self) private var model
  /// The session currently being renamed — SHARED with the Local section, so
  /// the state lives in `SidebarView`.
  @Binding var renamingSessionID: UUID?
  /// Opens the database rename sheet (owned by `SidebarView`).
  let onRenameDatabase: (DatabaseConnection) -> Void

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

  /// This section's rows; the gate is the section's own, and keeping it in a
  /// property leaves the List's `if → Section` shape untouched.
  @ViewBuilder
  private var sectionContent: some View {
    if flags.isEnabled(.ssh) {
      Section {
        ForEach(remoteCollapsed || !flags.isEnabled(.ssh) ? [] : model.connections) { config in
          SSHConfigGroup(
            config: config,
            renamingSessionID: renamingSessionID,
            onBeginRename: { renamingSessionID = $0 },
            onCommitRename: { commitRename($0, $1) },
            onCancelRename: { renamingSessionID = nil },
            onRenameDatabase: onRenameDatabase,
            onEdit: { editingConfig = $0 }
          )
        }
        .onMove { source, destination in
          model.moveConnection(from: source, to: destination)
        }
      } header: {
        HStack {
          SidebarCollapseChevron(collapsed: $remoteCollapsed)
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
  }

  /// Applies a session rename and exits edit mode. The binding is
  /// `SidebarView`'s (the Local section renames the same rows).
  private func commitRename(_ id: UUID, _ name: String) {
    model.renameSession(id, to: name)
    renamingSessionID = nil
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
    // Only SSH SHELL sessions get a terminal row here. A host-bound web page or
    // database connection has its own row view in the loops below; emitting one
    // here too would render its name twice (once with a terminal icon).
    ForEach(model.shellSessions(for: config)) { session in
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
