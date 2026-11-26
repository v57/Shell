import ComponentKit
import Foundation
import SwiftUI
import ShellKit

// What the sidebar says and offers besides its sections: the activity card above the bottom bar (what is going on
// now), the Recent section (the hosts and notes opened last) and the bar's Reconnect All. Everything here reads state
// the model already keeps: nothing is measured, polled or dialed for it.

// MARK: - Activity

extension AppModel {
  /// The activity card's lines, what needs the reader first: folder syncs waiting for Apply, hosts whose link is
  /// down or being dialed, the running actions, then the open terminals. A tap selects what the line is about.
  var sidebarActivity: [SidebarActivity] {
    let flags = FeatureFlagsStore.shared
    var lines: [SidebarActivity] = []
    let actions = flags.isEnabled(.actions) ? actionSessions : []

    // A folder sync stands still until Apply is pressed: one line each, the same words as its row in Running.
    for session in actions where session.isAwaitingApply {
      let id = session.id
      lines.append(
        SidebarActivity(
          id: "apply-\(id)", actionSpec(for: session)?.action.name ?? String(localized: "Action"),
          detail: session.applyWaitingText ?? String(localized: "Waiting for Apply"),
          systemImage: "arrow.triangle.2.circlepath", hue: .orange, status: .waiting
        ) { [weak self] in self?.selection = .session(id) })
    }

    // A host shows only while one of its terminals isn't connected: failed (with the reason), dialing again after a
    // drop, or dialing for the first time. A shell the user ended is not a problem.
    if flags.isEnabled(.ssh) {
      for config in connections {
        let sessions = shellSessions(for: config)
        guard let session = sessions.first(where: { $0.linkProblem == .failed })
          ?? sessions.first(where: { $0.linkProblem == .reconnecting })
          ?? sessions.first(where: { $0.linkProblem == .connecting })
        else { continue }
        let id = session.id
        let detail: String
        let hue: Hue
        switch session.connectionState {
        case .failed(let message):
          detail = message.isEmpty ? String(localized: "Connection failed") : message
          hue = .red
        case .reconnecting(let attempt):
          detail = attempt > 1 ? String(localized: "Reconnecting, attempt \(attempt)…") : String(localized: "Reconnecting…")
          hue = .orange
        default:
          detail = String(localized: "Connecting…")
          hue = .blue
        }
        lines.append(
          SidebarActivity(
            id: "host-\(config.id)", config.displayName, detail: detail, systemImage: "network", hue: hue,
            status: session.linkStatus
          ) { [weak self] in self?.selection = .session(id) })
      }
    }

    // The actions still running, as one line.
    let running = actions.filter { $0.isActionRunning && !$0.isAwaitingApply }
    if let first = running.first {
      let id = first.id
      let names = running.map { actionSpec(for: $0)?.action.name ?? String(localized: "Action") }
      lines.append(
        SidebarActivity(
          id: "actions", running.count == 1 ? String(localized: "Running \(names[0])") : String(localized: "\(running.count) actions running"),
          detail: running.count == 1
            ? actionSpec(for: first)?.config?.displayName ?? String(localized: "Local")
            : names.joined(separator: ", "),
          systemImage: "bolt.fill", hue: .purple, status: running.count == 1 ? first.actionRunStatus : .working
        ) { [weak self] in self?.selection = .session(id) })
    }

    // The terminals with a live shell (this computer's, persistent sessions, SSH), as one line. A tap goes to the
    // next one after the selected.
    let terminals = sessions.filter { $0.connectionState == .connected && isTerminal($0) }
    if !terminals.isEmpty {
      let ids = terminals.map(\.id)
      lines.append(
        SidebarActivity(
          id: "terminals",
          terminals.count == 1 ? String(localized: "1 terminal running") : String(localized: "\(terminals.count) terminals running"),
          detail: terminals.map { displayName(for: $0) }.joined(separator: ", "), systemImage: "terminal", hue: .green
        ) { [weak self] in
          guard let self else { return }
          var next = ids[0]
          if case .session(let selected) = selection, let index = ids.firstIndex(of: selected) {
            next = ids[(index + 1) % ids.count]
          }
          selection = .session(next)
        })
    }
    return lines
  }

  /// A session that shows a terminal: not an action's run, a web page or a database.
  private func isTerminal(_ session: TerminalSession) -> Bool {
    switch kind(of: session) {
    case .local, .screen, .ssh: true
    case .action, .web, .database: false
    }
  }

  /// The SSH terminals whose link is down: being dialed again, or failed. Reconnect All dials these now.
  var droppedSessions: [TerminalSession] {
    sessions.filter { session in
      guard session.canReconnect, case .ssh = kind(of: session) else { return false }
      return session.linkProblem == .failed || session.linkProblem == .reconnecting
    }
  }
}

extension TerminalSession {
  /// What is wrong with a session's link, if anything.
  enum LinkProblem { case connecting, reconnecting, failed }

  var linkProblem: LinkProblem? {
    switch connectionState {
    case .connecting: .connecting
    case .reconnecting: .reconnecting
    case .failed: .failed
    case .starting, .connected, .closed: nil
    }
  }
}

// MARK: - Bottom bar

/// Reconnect All in the sidebar's bottom bar: dials every dropped SSH terminal now, as the toolbar's Reconnect does
/// for the selected one. There only while a link is down. A view of its own, so the link states are read here and
/// not in the sidebar's body.
struct ReconnectAllButton: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let dropped = model.droppedSessions
    if !dropped.isEmpty {
      Button("Reconnect All", systemImage: "arrow.clockwise") {
        for session in dropped { session.reconnectNow() }
      }
      .kitHelp("Reconnect dropped connections now")
    }
  }
}

// MARK: - Recent

extension SidebarState {
  /// What Recent keeps: saved hosts and notes, whose ids last between launches. A terminal session's id is new on
  /// every launch, so a session counts as its host.
  enum RecentItem: Hashable {
    case host(UUID)
    case note(UUID)

    init?(key: String) {
      let parts = key.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
      switch parts[0] {
      case "host": self = .host(id)
      case "note": self = .note(id)
      default: return nil
      }
    }

    var key: String {
      switch self {
      case .host(let id): "host:\(id.uuidString)"
      case .note(let id): "note:\(id.uuidString)"
      }
    }
  }

  /// `selection` was just opened: a host (its row, or one of its terminals) or a note leads Recent.
  func noteOpened(_ selection: AppModel.Selection, in model: AppModel) {
    switch selection {
    case .ssh(let id):
      recents.note(RecentItem.host(id).key)
    case .note(let id):
      recents.note(RecentItem.note(id).key)
    case .session(let id):
      if let session = model.sessions.first(where: { $0.id == id }), case .ssh(let config) = model.kind(of: session) {
        recents.note(RecentItem.host(config.id).key)
      }
    case .screen, .web, .database, .databaseItem, .history, .openedFile:
      break
    }
  }

  /// Drops from Recent what was in `old` and isn't in `new` (a deleted host or note).
  func forgetRecents(_ item: (UUID) -> RecentItem, removedFrom old: [UUID], now new: [UUID]) {
    guard !new.isEmpty else { return }
    let gone = Set(old.filter { !new.contains($0) }.map { item($0).key })
    guard !gone.isEmpty else { return }
    recents.keep { !gone.contains($0) }
  }
}

/// The Recent section at the top: the hosts and notes opened last, newest first. Hidden while there are none. Its
/// rows act instead of selecting: the same host or note has its own row further down, and that one carries the
/// selection.
struct RecentSectionView: View {
  @Environment(AppModel.self) private var model
  let state: SidebarState

  @KitStorage("sidebar.recent.collapsed") private var recentCollapsed = false

  private var flags: FeatureFlagsStore { .shared }

  /// A recent that still exists and passes the filter, with what its row shows.
  private struct Entry: Identifiable {
    let item: SidebarState.RecentItem
    let title: String
    var id: SidebarState.RecentItem { item }
  }

  private var entries: [Entry] {
    state.recents.ids.compactMap { key -> Entry? in
      guard let item = SidebarState.RecentItem(key: key) else { return nil }
      let title: String
      switch item {
      case .host(let id):
        guard flags.isEnabled(.ssh), let config = model.connections.first(where: { $0.id == id }) else { return nil }
        title = config.displayName
      case .note(let id):
        guard flags.isEnabled(.notes), model.notes.notes.contains(where: { $0.id == id }), !model.notes.isEmptyNote(id)
        else { return nil }
        title = model.notes.title(for: id)
      }
      return state.matches(title) ? Entry(item: item, title: title) : nil
    }
  }

  var body: some View {
    let entries = entries
    if !entries.isEmpty {
      KitSection("Recent", systemImage: "clock", hue: .gray, isExpanded: .expanded(collapsed: $recentCollapsed)) {
        ForEach(entries) { entry in
          switch entry.item {
          case .host(let id):
            let open = model.connections.first { $0.id == id }.flatMap { model.shellSessions(for: $0).first }
            SidebarRow(entry.title, systemImage: "network", hue: .blue) {
              if open != nil {
                StatusDot(hue: .green)
                  .accessibilityLabel("Connected")
              }
            }
            // Its open terminal, or a new connection as the host's own row makes.
            .action { model.selection = open.map { .session($0.id) } ?? .ssh(id) }
          case .note(let id):
            SidebarRow(entry.title, subtitle: model.notes.subtitle(for: id), systemImage: "note.text", hue: .orange)
              .action { model.selection = .note(id) }
          }
        }
      } meta: {
        MetaLine(String(localized: "Opened last"))
      } accessory: {
        EmptyView()
      }
    }
  }
}
