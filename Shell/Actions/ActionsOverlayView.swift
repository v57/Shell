import SwiftUI
import Terminal

/// The actions list: a non-modal overlay panel over the main window
/// (NOT a sheet) so it appears/closes instantly. A search bar at the top
/// is always focused; Enter runs the first matching action (even with an
/// empty query — it runs the first applicable one). Actions are grouped
/// by category into sections; each section is a horizontal ScrollView of
/// chips. With a terminal selected, only actions applicable to that
/// environment are shown; with none selected everything is listed and
/// still runnable — `runAction` defaults to the local machine (macOS;
/// on iOS there is no local pty, so chips stay disabled).
struct ActionsOverlayView: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @FocusState private var searchFocused: Bool

  private struct Section: Identifiable {
    let title: String
    let actions: [Action]
    var id: String { title }
  }

  /// Applicable actions (plus everything when no session is selected),
  /// filtered by the search query in display order.
  private var filteredActions: [Action] {
    let applicable: [Action]
    if let session = model.selectedSession {
      applicable = model.actions.all.filter { $0.applies(to: model.kind(of: session)) }
    } else {
      applicable = model.actions.all
    }
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return applicable }
    return applicable.filter {
      $0.name.localizedCaseInsensitiveContains(q)
      || ($0.category ?? "").localizedCaseInsensitiveContains(q)
    }
  }

  /// Filtered actions grouped by category, both levels sorted by last
  /// usage (most recent first). Never-used items keep the default order
  /// at the bottom: sections "General" first then alphabetically, chips
  /// in store (creation) order.
  private var sections: [Section] {
    let grouped = Dictionary(grouping: filteredActions) { $0.category ?? "General" }
    let defaultTitles = grouped.keys.sorted { a, b in
      if a == "General" { return true }
      if b == "General" { return false }
      return a.localizedStandardCompare(b) == .orderedAscending
    }
    // A section's usage = its most recently used action.
    let titles = defaultTitles.sorted { a, b in
      let lastA = grouped[a]?.compactMap(\.lastUsed).max() ?? .distantPast
      let lastB = grouped[b]?.compactMap(\.lastUsed).max() ?? .distantPast
      if lastA != lastB { return lastA > lastB }
      return defaultTitles.firstIndex(of: a)! < defaultTitles.firstIndex(of: b)!
    }
    return titles.map { title in
      let actions = (grouped[title] ?? []).enumerated().sorted { lhs, rhs in
        switch (lhs.element.lastUsed, rhs.element.lastUsed) {
        case let (a?, b?): return a > b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.offset < rhs.offset  // stable: store order
        }
      }.map(\.element)
      return Section(title: title, actions: actions)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Actions").font(.headline)
        Button {
          model.createAction()
        } label: {
          Image(systemName: "plus")
        }.buttonStyle(.borderless).help("New action")
        Spacer()
        Button {
          model.showingActions = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Close (Esc)")
      }.padding(.top, 12)

      searchBar.padding(.top, 8).padding(.bottom, 10)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(sections) { section in
            VStack(alignment: .leading, spacing: 6) {
              Text(section.title)
                .font(.caption)
                .foregroundStyle(.secondary)
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                  ForEach(section.actions) { action in
                    ActionChip(action: action) { run(action) }
                  }
                }
              }
            }
          }
          if model.actions.all.isEmpty {
            Text("No actions yet — use + in the toolbar to create one.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
          } else if filteredActions.isEmpty {
            Text("No matching actions")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
          }
        }
        .padding(.vertical, 10)
      }
    }
    .frame(width: 480, height: 340)
    .safeAreaPadding(.horizontal, 12)
    .background {
      RoundedRectangle(cornerRadius: 16).fill(.background)
        .strokeBorder(.quaternary).shadow(radius: 32, y: 8)
    }
    .defaultFocus($searchFocused, true)
    .onAppear {
      Task { @MainActor in
        searchFocused = true
      }
    }
  }

  /// The always-focused search field. Enter runs the first action in the
  /// current results (even when the query is empty).
  private var searchBar: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(filteredActions.first?.name ?? "Search actions", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .onSubmit { runFirst() }
      if !query.isEmpty {
        Button {
          query = ""
          #if os(macOS)
          claimFocus()
          #endif
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }
    }
    .padding(6)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
  }

  /// Runs an action, then hands focus back to the search bar when the
  /// overlay stays open (Focus window = off), so the next query can be
  /// typed immediately.
  private func run(_ action: Action) {
    model.runAction(action)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      #if os(macOS)
      claimFocus()
      #endif
    }
  }

  /// Runs the first action in the filtered results, if any.
  private func runFirst() {
    guard let first = filteredActions.first else { return }
    run(first)
  }

  #if os(macOS)
  /// AppKit fallback for "always focused": SwiftUI's FocusState requests
  /// are dropped for transition-inserted overlay views (verified
  /// empirically — the first responder stayed on the window's hosting
  /// view), so walk the key window's view hierarchy and make the search
  /// field's NSTextField the first responder directly. No-op when the
  /// field is gone (overlay closed) or already focused.
  private func claimFocus() {
    guard let window = NSApp.keyWindow,
          let field = Self.findTextField(in: window.contentView) else { return }
    _ = window.makeFirstResponder(field)
  }

  private static func findTextField(in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField { return field }
    for subview in view.subviews {
      if let found = findTextField(in: subview) { return found }
    }
    return nil
  }
  #endif
}

/// A single action chip; clicking it runs the action in the current
/// environment. With no terminal selected it runs on the local machine
/// (macOS; disabled on iOS, where local actions need a pty that doesn't
/// exist — see AppModel.runAction).
private struct ActionChip: View {
  @Environment(AppModel.self) private var model
  let action: Action
  let onRun: () -> Void

  var body: some View {
    Button {
      onRun()
    } label: {
      Text(action.name).fontWeight(.semibold)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 4))
        .colorScheme(.dark)
    }
    .buttonStyle(.plain)
    .disabled(!canRun)
    .contextMenu {
      Button("Edit…") {
        model.editAction(action)
      }
      Button("Remove", role: .destructive) {
        model.actions.remove(action.id)
      }
    }
    .help(helpText)
  }

  /// No terminal selected: macOS runs the action locally by default, iOS
  /// has no local pty so the run would be a silent no-op — keep disabled.
  private var canRun: Bool {
    if model.selectedSession != nil { return true }
    #if os(macOS)
    return true
    #else
    return false
    #endif
  }

  private var helpText: String {
    guard let session = model.selectedSession else {
      #if os(macOS)
      return "Run locally (no terminal selected)"
      #else
      return "Select a terminal first"
      #endif
    }
    return "Run in " + environmentLabel(for: session)
  }

  private func environmentLabel(for session: TerminalSession) -> String {
    switch model.kind(of: session) {
    case .local, .screen, .action:
      return "Local"
    case .ssh(let config):
      return config.displayName
    case .web(let web):
      // An action run from a web session targets the bound SSH host when it
      // has one, else the local machine.
      if let id = web.sshConfigID,
         let config = model.connections.first(where: { $0.id == id }) {
        return config.displayName
      }
      return "Local"
    case .database(let connection):
      // An action run from a database session targets the bound SSH host when
      // it has one, else the local machine.
      if let id = connection.sshConfigID,
         let config = model.connections.first(where: { $0.id == id }) {
        return config.displayName
      }
      return "Local"
    }
  }
}
