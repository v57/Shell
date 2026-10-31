import ComponentKit
import Foundation
import ShellDatabaseEngines
import SwiftUI

/// The Databases section: every saved database connection, on its own card so connections don't interleave with
/// terminals (This Mac) or hosts (Remote). One line per connection: its engine, its name, a count when several
/// saved connections share the name and the address (merged into one row), and a dot while it's open. The address,
/// the file and the SSH host it tunnels through are in the row's tooltip.
///
/// The open connections and those used in the last week show; the rest wait behind Show N More. The header's Sort
/// and Filter menu orders them by recent use or name, shows one engine, or turns the week's filter off. Searching
/// shows every match.
struct DatabasesSectionView: View {
  @Environment(AppModel.self) private var model
  /// The sidebar's shared state (SidebarChrome.swift): the filter, the database rename and delete.
  let state: SidebarState

  @AppStorage("sidebar.databases.collapsed") private var collapsed = false
  @AppStorage("sidebar.databases.sort") private var sort = DatabaseSort.recent
  @AppStorage("sidebar.databases.hidesUnused") private var hidesUnused = true
  /// The engine the section shows, or all ("").
  @AppStorage("sidebar.databases.engine") private var engineFilter = ""
  /// Show More: the connections the filters hide, until a filter changes.
  @State private var showsMore = false
  @State private var showsOptions = false

  private var flags: FeatureFlagsStore { .shared }

  private var isSearching: Bool { !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

  var body: some View {
    if flags.isEnabled(.database), showsSection {
      let groups = DatabaseGroup.groups(of: model.databaseConnections, model: model, sort: sort)
        .filter { engineFilter.isEmpty || $0.primary.engine.rawValue == engineFilter }
        .filter { state.matches($0.primary.displayName) }
      let listed = isSearching || showsMore || !hidesUnused ? groups : groups.filter { $0.isRecent(model: model) }
      let more = groups.count - groups.filter { $0.isRecent(model: model) }.count
      KitSection(
        "Databases", systemImage: "cylinder.split.1x2", hue: .indigo, isExpanded: .expanded(collapsed: $collapsed)
      ) {
        ForEach(listed) { group in
          DatabaseConnectionRow(group: group, state: state)
        }
        if hidesUnused, !isSearching, more > 0 {
          SidebarShowMoreRow(
            count: more, isShowing: $showsMore, reason: "unused",
            help: "Show \(more) connections unused for a week",
            hideHelp: "Hide the connections the filters leave out")
        }
      } meta: {
        MetaLine(meta(groups: groups, listed: listed))
      } accessory: {
        Button("Sort and Filter", systemImage: "line.3.horizontal.decrease") { showsOptions = true }
          .kitHelp("Sort and filter the connections")
          .kitMenu(isPresented: $showsOptions) { optionsMenu }
        Button("New Database Connection", systemImage: "plus") { model.newDatabaseConnection() }
          .kitHelp("New database connection")
      }
      .onChange(of: [hidesUnused ? "1" : "0", engineFilter]) { showsMore = false }
    }
  }

  /// On the Mac the section shows once there's a connection (This Mac's + menu makes the first); on iPhone and iPad,
  /// which have no This Mac, it's always there.
  private var showsSection: Bool {
    #if os(macOS) || os(Windows) || os(Linux)
    !model.databaseConnections.isEmpty
    #else
    true
    #endif
  }

  /// "2 open · 14 connections", or "PostgreSQL · 3 of 14" with an engine picked.
  private func meta(groups: [DatabaseGroup], listed: [DatabaseGroup]) -> [String] {
    let total = model.databaseConnections.count
    if total == 0 { return ["No connections"] }
    let open = groups.filter { $0.isOpen(model: model) }.count
    let count = listed.count < groups.count ? "\(listed.count) of \(groups.count)" : total == 1 ? "1 connection" : "\(total) connections"
    if let engine = DatabaseEngine(rawValue: engineFilter) { return [engine.displayName, count] }
    return [open > 0 ? "\(open) open" : "", count]
  }

  @ViewBuilder private var optionsMenu: some View {
    KitMenuSection("Sort By") {
      KitMenuOptions(
        selection: Binding(get: { sort }, set: { new in withKitAnimation { sort = new } }),
        options: DatabaseSort.allCases.map { ($0.title, $0) })
    }
    KitMenuSection("Engine") {
      let engines = DatabaseEngine.allCases.filter { engine in model.databaseConnections.contains { $0.engine == engine } }
      KitMenuOptions(
        selection: Binding(get: { engineFilter }, set: { new in withKitAnimation { engineFilter = new } }),
        options: [("All Engines", "")] + engines.map { ($0.displayName, $0.rawValue) })
    }
    KitMenuSection("Show") {
      Toggle("Hide Unused for a Week", isOn: $hidesUnused.animation(.kit))
    }
  }
}

/// How the Databases section orders its connections.
enum DatabaseSort: String, CaseIterable {
  /// Open first, then by when they were last used.
  case recent
  case name

  var title: String {
    switch self {
    case .recent: "Recently Used"
    case .name: "Name"
    }
  }
}

/// One row of the Databases section: saved connections with the same engine, name and address (a connection saved
/// twice, by two apps or a duplicate), shown as one.
struct DatabaseGroup: Identifiable {
  /// The one the row opens, edits and expands: the open one, else the selected one, else the latest used.
  let primary: DatabaseConnection
  let members: [DatabaseConnection]

  var id: UUID { primary.id }

  static func groups(of connections: [DatabaseConnection], model: AppModel, sort: DatabaseSort) -> [DatabaseGroup] {
    var order: [String] = []
    var byKey: [String: [DatabaseConnection]] = [:]
    for connection in connections {
      let key = [
        connection.engine.rawValue, connection.displayName.lowercased(), connection.host.lowercased(),
        String(connection.port),
      ].joined(separator: "\u{1F}")
      if byKey[key] == nil { order.append(key) }
      byKey[key, default: []].append(connection)
    }
    let groups = order.compactMap { key -> DatabaseGroup? in
      guard let members = byKey[key] else { return nil }
      let primary =
        members.first { model.isOpen($0) } ?? members.first { model.rowSelection(for: $0) == model.selection }
        ?? members.max { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) } ?? members[0]
      return DatabaseGroup(primary: primary, members: members)
    }
    switch sort {
    case .name:
      return groups.sorted { $0.primary.displayName.localizedStandardCompare($1.primary.displayName) == .orderedAscending }
    case .recent:
      return groups.enumerated().sorted { lhs, rhs in
        let (a, b) = (lhs.element, rhs.element)
        if a.isOpen(model: model) != b.isOpen(model: model) { return a.isOpen(model: model) }
        if a.lastUsed != b.lastUsed { return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast) }
        return lhs.offset < rhs.offset
      }.map(\.element)
    }
  }

  var lastUsed: Date? { members.compactMap(\.lastUsed).max() }

  func isOpen(model: AppModel) -> Bool { members.contains { model.isOpen($0) } }

  /// Open, selected, or used in the last week: shown while unused ones wait behind Show More.
  func isRecent(model: AppModel) -> Bool {
    if isOpen(model: model) { return true }
    if members.contains(where: { model.rowSelection(for: $0) == model.selection }) { return true }
    if case .databaseItem(let item) = model.selection, members.contains(where: { $0.id == item.connectionID }) {
      return true
    }
    guard let lastUsed else { return false }
    return lastUsed > Date().addingTimeInterval(-7 * 24 * 3600)
  }
}

extension AppModel {
  /// Whether a saved connection is open: its page or its tree in the sidebar.
  func isOpen(_ connection: DatabaseConnection) -> Bool {
    liveDatabaseSession(for: connection) != nil || databases.live[connection.id] != nil
  }
}
