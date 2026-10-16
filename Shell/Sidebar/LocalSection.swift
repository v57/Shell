import ComponentKit
import Foundation
import SwiftUI
import ShellKit
import ShellIntegrations
import ShellMonitoring

#if os(macOS)
/// The Local section ("This Mac"): this Mac's terminals, its persistent
/// screen/tmux sessions (local AND the ones scanned from connected SSH hosts),
/// local history while history mode is on, saved web pages not bound to a
/// tunnel, and database connections with no tunnel. Rendered while ANY of those
/// features is enabled — the gate below is this section's own.
///
/// State only this section uses lives here. The session rename, the database
/// rename sheet, the filter and the stats monitor stay with the sidebar
/// (`SidebarState` in SidebarChrome.swift, shared with the Remote section) and
/// are handed in as `state`.
struct LocalSectionView: View {
  @Environment(AppModel.self) private var model
  /// The sidebar's shared state (SidebarChrome.swift): the session rename, the
  /// database rename sheet, the filter and the live-stats monitor.
  let state: SidebarState

  /// Collapse state for this section, persisted across launches.
  @AppStorage("sidebar.local.collapsed") private var localCollapsed = false
  /// The screen session currently being renamed (keyed by full name).
  @State private var renamingScreenName: String?

  private var flags: FeatureFlagsStore { .shared }

  /// Live CPU/GPU/wattage for the section header (the monitor itself is owned by
  /// the sidebar — see `SidebarState.statsMonitor`).
  private var monitor: SystemStatsMonitor { state.statsMonitor }

  /// The local shells reorder with Shell's own drag (they also take file drops,
  /// SidebarReorder.swift); the web pages and databases with the kit's.
  private var sessionReorder: SidebarReorderGroup {
    SidebarReorderGroup(.localSessions) { model.moveLocalSession(from: $0, to: $1) }
  }

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

  /// Whether the filter is on: reordering a filtered list would move rows by
  /// the wrong indices, so the lists don't reorder while it is.
  private var isFiltering: Bool { !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

  var body: some View {
    sectionContent
      // A selection change cancels an in-flight rename in THIS section;
      // SidebarChrome's own routing clears the shared session rename.
      .onChange(of: model.selection) { _, _ in renamingScreenName = nil }
  }

  /// This section's card; the gate is the section's own.
  @ViewBuilder
  private var sectionContent: some View {
    if flags.isEnabled(.sessions) || flags.isEnabled(.screen) || flags.isEnabled(.history) || flags.isEnabled(.web) || flags.isEnabled(.database) {
      KitSection(
        model.historyMode ? "Local History" : "This Mac", systemImage: model.historyMode ? "clock" : "laptopcomputer",
        hue: model.historyMode ? .orange : .green, isExpanded: .expanded(collapsed: $localCollapsed)
      ) {
        if model.historyMode {
          ForEach(flags.isEnabled(.history) ? model.history.sessions.filter { state.matches($0.title) } : []) { record in
            SidebarRow(value: AppModel.Selection.history(record.id), record.title, systemImage: "clock") {
              Text(record.activityDate, style: .relative)
            }
          }
          .transition(.blurReplace)
        } else {
          rows
            .transition(.blurReplace)
        }
      } meta: {
        meta
      } accessory: {
        accessory
      }
    } // end if (local section gate)
  }

  /// The terminals, persistent sessions, web pages and databases.
  @ViewBuilder
  private var rows: some View {
    let sessions = flags.isEnabled(.sessions) ? localSessions : []
    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
      if state.matches(model.displayName(for: session)) {
        SessionRow(
          session: session,
          defaultLabel: model.displayName(for: session),
          isRenaming: state.isRenamingSession(session.id),
          onRename: { model.renameSession(session.id, to: $0) }
        )
        .sidebarReorderable(sessionReorder.row(at: index))
        // Files from Finder or the Files panel: ask whether to copy them in,
        // type their paths or go to their folder (FileDropActions.swift). Outside
        // the reorder, whose drop target reads its handler (SidebarReorder.swift).
        .sidebarFileDrop { files in model.requestFileDrop(files, on: .session(session.id)) }
        .contextMenu {
          Button("Rename…") { state.renamingSessionID = session.id }
          if flags.isEnabled(.authorizedKeys) {
            Button("Authorized Keys", systemImage: "key.2.on.ring.fill") {
              model.openLocalAuthorizedKeys()
            }.help("Manage this Mac's authorized keys")
          }
          Divider()
          Button("Close Terminal", role: .destructive) {
            model.removeSession(session.id)
          }
        }
      }
    }
    ForEach(flags.isEnabled(.screen) ? model.screenMonitor.sessions.filter { state.matches($0.shortName) } : []) { info in
      ScreenSessionRow(
        info: info,
        isRenaming: Binding(
          get: { renamingScreenName == info.name },
          set: { if !$0, renamingScreenName == info.name { renamingScreenName = nil } }),
        onRename: { model.screenMonitor.rename(info, to: $0) }
      )
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
    ForEach(flags.isEnabled(.screen) ? model.remoteScreenSessions.filter { state.matches($0.shortName) } : []) { info in
      // Remote persistent sessions are identified by their SSH origin;
      // renaming runs on the host, which is out of scope here.
      ScreenSessionRow(info: info, isRenaming: .constant(false), onRename: { _ in })
        .contextMenu {
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
    if flags.isEnabled(.web) {
      if isFiltering {
        ForEach(localWebSessions.filter { state.matches($0.sidebarTitle) }) { web in WebSessionRow(web: web) }
      } else {
        ReorderableSection(localWebSessions, move: { model.moveLocalWebSession(from: $0, to: $1) }) { web in
          WebSessionRow(web: web)
        }
      }
    }
    // Local database connections (no SSH tunnel) live in the Local section like
    // local shells; remote ones group under Remote instead.
    if flags.isEnabled(.database) {
      if isFiltering {
        ForEach(localDatabaseConnections.filter { state.matches($0.displayName) }) { connection in
          localDatabaseRow(connection)
        }
      } else {
        ReorderableSection(localDatabaseConnections, move: { model.moveLocalDatabaseConnection(from: $0, to: $1) }) {
          localDatabaseRow($0)
        }
      }
    }
  }

  private func localDatabaseRow(_ connection: DatabaseConnection) -> some View {
    DatabaseConnectionRow(connection: connection)
      .contextMenu { DatabaseConnectionActions(connection: connection) { state.beginRenameDatabase($0) } }
  }

  /// The header's line: the live CPU, GPU and power draw while Monitoring is on
  /// (clicking it opens the graphs for the last minute), else what it holds.
  @ViewBuilder
  private var meta: some View {
    if model.historyMode {
      MetaLine(model.history.sessions.count == 1 ? "1 session" : "\(model.history.sessions.count) sessions")
    } else if flags.isEnabled(.monitoring), monitor.watts > 0 {
      Button {
        state.showingStatsGraphs = true
      } label: {
        // Never animated: the stats tick every second, and digit-roll motion
        // on every tick is pure distraction.
        // The meters while they fit, the bare figures in a narrow sidebar.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 6) {
            StatsMeter(label: "CPU", percent: monitor.cpuPercent, hue: .blue)
            StatsMeter(label: "GPU", percent: monitor.gpuPercent, hue: .purple)
            Text("\(monitor.watts) W")
          }
          .fixedSize()
          MetaLine(
            "\(Int(monitor.cpuPercent.rounded()))%", "\(Int(monitor.gpuPercent.rounded()))%", "\(monitor.watts) W")
        }
        .monospacedDigit()
        .transaction { $0.animation = nil }
      }
      .buttonStyle(.plain)
      .help("CPU · GPU · System power draw — click for graphs")
    } else {
      let count = localSessions.count
      let active = localSessions.filter(\.hasActivity).count
      MetaLine([count == 1 ? "1 session" : "\(count) sessions", active > 0 ? "\(active) running" : ""])
    }
  }

  /// The header's controls: the history toggle (and, in history, delete all),
  /// and the + menu.
  @ViewBuilder
  private var accessory: some View {
    if model.historyMode, flags.isEnabled(.history) {
      Button("Delete All History", systemImage: "trash", role: .destructive) {
        model.deleteAllHistory()
      }
      .help("Delete all local history")
      .transition(.blurReplace)
    }
    // Only meaningful when there is something to show; hidden while the list is
    // empty (the trash button still serves as the exit when viewing history).
    if flags.isEnabled(.history), !model.history.sessions.isEmpty {
      Button {
        model.toggleHistoryMode()
      } label: {
        Label {
          Text(model.historyMode ? "Show Local Terminals" : "Show Local History")
        } icon: {
          Image(systemName: "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted")
            .foregroundStyle(model.historyMode ? AnyShapeStyle(Hue.accent.text) : AnyShapeStyle(.kitSecondary))
        }
      }
      .help(model.historyMode ? "Show local terminals" : "Show local history")
      .transition(.blurReplace)
    }
    if flags.isEnabled(.sessions) || flags.isEnabled(.web) || flags.isEnabled(.database) {
      Menu {
        if flags.isEnabled(.sessions) {
          Button("New Session", systemImage: "terminal") {
            model.addLocalTerminal()
          }
        }
        if flags.isEnabled(.web) {
          Button("Web Session", systemImage: "globe") {
            model.openEmptyWebSession()
          }
        }
        if flags.isEnabled(.database) {
          Button("Database", systemImage: "cylinder.split.1x2") {
            model.editingDatabaseConnection = nil
            model.showingNewDatabaseConnection = true
          }
        }
      } label: {
        Label("New", systemImage: "plus")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .help("New session")
    }
  }
}

/// One reading of the Local header: its name, a small meter and the percentage.
private struct StatsMeter: View {
  let label: String
  let percent: Double
  let hue: Hue

  var body: some View {
    HStack(spacing: 3) {
      Text(label)
      MeterBar(segments: [MeterSegment(label, value: min(max(percent, 0), 100), hue: hue)], total: 100, height: 4)
        .frame(width: 22)
      Text("\(Int(percent.rounded()))%")
    }
  }
}

/// A GNU screen or tmux persistent session in the sidebar. Clicking it
/// attaches a new local terminal to that session. Rename… edits the name in
/// place (prefilled without the "pid." prefix — the pid is screen's identity).
private struct ScreenSessionRow: View {
  @Environment(AppModel.self) private var model
  let info: ScreenSessionInfo
  @Binding var isRenaming: Bool
  let onRename: (String) -> Void

  /// The open terminal attached to this screen session, if any. Its
  /// status line is shown under the row.
  private var attachedSession: TerminalSession? {
    model.attachedSession(toScreen: info)
  }

  private var helpText: String {
    switch info.kind {
    case .tmux: "tmux session"
    case .screen: "GNU screen session"
    case .session: info.isProtected ? "Password-protected session" : "session"
    }
  }

  var body: some View {
    // The sidebar shows the short name (no "pid." prefix); the full "pid.name"
    // spec stays in the window title (navigationTitle).
    SidebarRow(
      value: model.rowSelection(forScreen: info), info.shortName,
      systemImage: info.isProtected ? "lock.fill" : "shield.fill"
    ) {
      StatusDot(hue: info.isAttached ? .green : .gray, isHollow: !info.isAttached)
        .accessibilityLabel(info.state)
        .help(helpText)
    }
    // The second line: a remote row's SSH origin (so it is distinguishable from
    // local rows in the same section), then the attached terminal's status.
    .subtitle {
      if let session = attachedSession {
        SessionStatusLine(session: session, prefix: info.remoteOrigin?.displayName)
      } else if let origin = info.remoteOrigin?.displayName {
        Text(origin)
      }
    }
    .kitRename(isRenaming: $isRenaming) { onRename($0) }
  }
}
#endif
