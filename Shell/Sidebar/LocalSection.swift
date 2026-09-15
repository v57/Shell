import Foundation
import SwiftUI
import Terminal
import TerminalIntegrations
import Monitoring

#if os(macOS)
/// The Local section: this Mac's terminals, its persistent screen/tmux
/// sessions (local AND the ones scanned from connected SSH hosts), local
/// history while history mode is on, saved web pages not bound to a host, and
/// database connections with no tunnel. Rendered while ANY of those features is
/// enabled — the gate below is this section's own.
///
/// State only this section uses lives here. The session rename (shared with the
/// Remote section), the database rename sheet and the stats monitor's lifetime
/// stay in `SidebarView` and are passed in.
struct LocalSectionView: View {
  @Environment(AppModel.self) private var model
  /// The session currently being renamed — SHARED with the Remote section, so
  /// the state lives in `SidebarView`.
  @Binding var renamingSessionID: UUID?
  /// Live CPU/GPU/wattage for the section header (the monitor itself is owned
  /// by `SidebarView`; see the note there).
  let monitor: SystemStatsMonitor
  /// Opens the stats graphs sheet (owned by `SidebarView`).
  let onShowStatsGraphs: () -> Void
  /// Opens the database rename sheet (owned by `SidebarView` — the Remote
  /// section's database rows open the same sheet).
  let onRenameDatabase: (DatabaseConnection) -> Void

  /// Collapse state for this section, persisted across launches.
  @AppStorage("sidebar.local.collapsed") private var localCollapsed = false
  /// The screen session currently being renamed (keyed by full name).
  @State private var renamingScreenName: String?

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
    sectionContent
      // A selection change cancels an in-flight rename in THIS section;
      // SidebarView's own routing clears the shared session rename.
      .onChange(of: model.selection) { _, _ in renamingScreenName = nil }
  }

  /// This section's rows; the gate is the section's own, and keeping it in a
  /// property leaves the List's `if → Section` shape untouched.
  @ViewBuilder
  private var sectionContent: some View {
    if flags.isEnabled(.sessions) || flags.isEnabled(.screen) || flags.isEnabled(.history) || flags.isEnabled(.web) || flags.isEnabled(.database) {
      Section {
        if model.historyMode {
          ForEach(localCollapsed || !flags.isEnabled(.history) ? [] : model.history.sessions) { record in
            HistorySessionRow(session: record)
              .tag(AppModel.Selection.history(record.id))
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
            .tag(AppModel.Selection.session(session.id))
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
            // Tag with the open session's selection when attached (so the row
            // shows selected while its terminal is open), else the row's own
            // stable tag id — activating that attaches.
            .tag(model.rowSelection(forScreen: info))
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
            // Same convention as the local persistent rows above.
            .tag(model.rowSelection(forScreen: info))
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
              // Tag with the open page's session when it is up (so the row
              // shows selected while its WebView is visible), else the page's
              // own id — activating that opens it.
              .tag(model.rowSelection(for: web))
          }
          .onMove { source, destination in
            model.moveLocalWebSession(from: source, to: destination)
          }
          // Local database connections (no SSH tunnel) live in the Local
          // section like local shells; remote ones group under Remote instead.
          ForEach(localCollapsed || !flags.isEnabled(.database) ? [] : localDatabaseConnections) { connection in
            DatabaseConnectionRow(connection: connection)
              .tag(model.rowSelection(for: connection))
              .contextMenu { DatabaseConnectionActions(connection: connection) { onRenameDatabase($0) } }
          }
          .onMove { source, destination in
            model.moveLocalDatabaseConnection(from: source, to: destination)
          }
          .transition(.blurReplace)
        }
      } header: {
        HStack {
          SidebarCollapseChevron(collapsed: $localCollapsed)
          Group {
            if model.historyMode {
              Text("Local History")
            } else if flags.isEnabled(.monitoring) {
              statsHeader
            } else {
              Text("Local")
            }
          }.transition(.blurReplace)
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
  }

  /// The Local section header showing live CPU/GPU usage and total
  /// wattage, e.g. "  5% 12% 13W" (percentages right-aligned to 3 chars,
  /// wattage right-aligned to 2 chars). Falls back to plain "Local" when
  /// the stats aren't available yet (first tick). Clicking it opens the
  /// stats graphs for the last minute.
  @ViewBuilder
  private var statsHeader: some View {
    let cpu = Int(monitor.cpuPercent.rounded())
    let gpu = Int(monitor.gpuPercent.rounded())
    if monitor.watts > 0 {
      Button {
        onShowStatsGraphs()
      } label: {
        Text("\(String(format: "%3d", cpu))% \(String(format: "%3d", gpu))% \(String(format: "%2d", monitor.watts))W")
          .font(.caption.weight(.medium))
          .monospaced()
      }
      .buttonStyle(.plain)
      .help("CPU · GPU · System power draw — click for graphs")
    } else {
      Text("Local")
    }
  }

  /// Applies a session rename and exits edit mode. The binding is
  /// `SidebarView`'s (the Remote section renames the same rows).
  private func commitRename(_ id: UUID, _ name: String) {
    model.renameSession(id, to: name)
    renamingSessionID = nil
  }

  /// Renames a screen session on the local machine and exits edit mode.
  private func commitScreenRename(_ info: ScreenSessionInfo, _ name: String) {
    model.screenMonitor.rename(info, to: name)
    renamingScreenName = nil
  }
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
#endif
