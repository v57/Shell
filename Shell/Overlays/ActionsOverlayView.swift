import ComponentKit
import SwiftUI
import ShellKit
import ShellIntegrations

/// The quick actions (⌘R): ComponentKit's command palette, a non-modal overlay
/// over the main window (NOT a sheet) so it appears/closes instantly. The search
/// line is always focused; ↑↓ move through the results and Return runs the
/// selected one (the first by default, even with an empty query).
///
/// Results are group cards: the smart actions of the active local directory's
/// schemes (Code's CodeActions: run, build, test, lint, clean and distribute,
/// live while one runs; a group's + adds one to your actions), your own
/// actions, and the apps that open the directory. With a terminal selected only the actions applicable to its
/// environment are shown; with none selected everything is listed and still
/// runnable — `runAction` defaults to the local machine (macOS; on iOS there
/// is no local pty, so they stay disabled). The scope pop-up picks the
/// terminal they run in.
struct ActionsOverlayView: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""

  /// Applicable actions (plus everything when no session is selected),
  /// filtered by the search query, most recently used first (never-used ones
  /// keep their store order at the bottom).
  private var filteredActions: [Action] {
    let applicable: [Action]
    if let session = model.selectedSession {
      applicable = model.actions.all.filter { $0.applies(to: model.kind(of: session)) }
    } else {
      applicable = model.actions.all
    }
    let matching = applicable.filter {
      matches($0.name) || matches($0.category ?? "") || matches($0.commands)
    }
    return matching.enumerated().sorted { lhs, rhs in
      switch (lhs.element.lastUsed, rhs.element.lastUsed) {
      case let (a?, b?): return a > b
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): return lhs.offset < rhs.offset  // stable: store order
      }
    }.map(\.element)
  }

  private func matches(_ text: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || text.localizedCaseInsensitiveContains(q)
  }

  var body: some View {
    KitPalette(
      query: $query, prompt: "Run an action or search",
      hints: [PaletteHint(["↑", "↓"], "Move"), PaletteHint(["↩"], "Run"), PaletteHint(["esc"], "Close")],
      dismiss: { model.showingActions = false }
    ) {
      scope
    } content: {
      #if os(macOS) || os(Windows) || os(Linux)
      smartActions
      #endif
      yourActions
      #if os(macOS)
      openWith
      #endif
    }
    .frame(width: 560)
    // Under the toolbar, like the board's palette, rather than mid-window.
    .frame(maxHeight: .infinity, alignment: .top)
    .padding(.top, 56)
    .onAppear {
      #if os(macOS)
      Task { @MainActor in claimFocus() }
      #endif
    }
  }

  // MARK: Scope

  /// The terminal the actions run in: the selected one, or Local when none is.
  @ViewBuilder
  private var scope: some View {
    let terminals = model.sessions.filter { session in
      switch model.kind(of: session) {
      case .local, .ssh, .screen: true
      default: false
      }
    }
    if !terminals.isEmpty {
      PaletteMenu(model.selectedSession.map { model.displayName(for: $0) } ?? "Local", systemImage: "terminal") {
        ForEach(terminals) { session in
          Button(model.displayName(for: session)) { model.selection = .session(session.id) }
        }
      }
    }
  }

  // MARK: Your actions

  @ViewBuilder
  private var yourActions: some View {
    let actions = filteredActions
    let categories = Set(model.actions.all.map { $0.category ?? "General" }).sorted()
    if !actions.isEmpty || query.isEmpty {
      PaletteGroup(
        "Your actions",
        meta: [model.actions.all.count == 1 ? "1 action" : "\(model.actions.all.count) actions",
               categories.joined(separator: ", ")],
        systemImage: "bolt.fill", hue: .indigo
      ) {
        Button("New Action", systemImage: "plus") { model.createAction() }
          .help("New action")
      } items: {
        ForEach(actions) { action in
          PaletteItem(
            action.name, id: action.id.uuidString, systemImage: "terminal", hue: .indigo,
            detail: action.commands.split(separator: "\n").first.map(String.init),
            note: runningActionIDs.contains(action.id) ? "Running" : nil,
            isEnabled: canRun
          ) {
            run(action)
          }
          .help(helpText)
          .kitContextMenu {
            Button("Edit…") { model.editAction(action) }
            Button("Remove", role: .destructive) { model.actions.remove(action.id) }
          }
        }
        if model.actions.all.isEmpty {
          Text("No actions yet — use + to create one.")
            .kitFont(.caption)
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
        }
      }
    }
  }

  /// The actions with a live run, for their "Running" note.
  private var runningActionIDs: Set<UUID> {
    Set(model.actionSessions.filter(\.isActionRunning).compactMap { model.actionSpec(for: $0)?.action.id })
  }

  /// No terminal selected: macOS runs the action locally by default, iOS
  /// has no local pty so the run would be a silent no-op — keep disabled.
  private var canRun: Bool {
    if model.selectedSession != nil { return true }
    #if os(macOS) || os(Windows) || os(Linux)
    return true
    #else
    return false
    #endif
  }

  private var helpText: String {
    guard let session = model.selectedSession else {
      #if os(macOS) || os(Windows) || os(Linux)
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
      return web.sshConfigID.flatMap { id in model.connections.first { $0.id == id }?.displayName } ?? "Local"
    case .database(let connection):
      return connection.sshConfigID.flatMap { id in model.connections.first { $0.id == id }?.displayName } ?? "Local"
    }
  }

  /// Runs an action, then hands focus back to the search line (the palette
  /// stays open), so the next query can be typed immediately.
  private func run(_ action: Action) {
    model.runAction(action)
    #if os(macOS)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { claimFocus() }
    #endif
  }

  #if os(macOS) || os(Windows) || os(Linux)
  // MARK: Smart actions

  /// A group per scheme of the active local directory: its run, build, test,
  /// lint and clean commands, then its distribute actions. A running one turns
  /// its live icon and Return stops it.
  @ViewBuilder
  private var smartActions: some View {
    if let directory = model.smartActionDirectory {
      ForEach(model.smartActionSchemes) { scheme in
        let kinds = ActionKind.allCases.filter {
          scheme.terminalCommand(for: $0) != nil && ($0.isDistribution ? $0.isOfferedHere && scheme.supports($0) : true)
            && (matches($0.title) || matches(scheme.name))
        }
        if !kinds.isEmpty {
          PaletteGroup(
            scheme.name, meta: [scheme.toolchain.displayName, scheme.directory.lastPathComponent],
            systemImage: scheme.toolchain.symbolName, hue: .blue
          ) {
            AddToActionsMenu(scheme: scheme) { addToActions($0, scheme: scheme) }
          } items: {
            ForEach(kinds, id: \.self) { kind in
              smartActionItem(kind, scheme: scheme, directory: directory)
            }
            if kinds.contains(where: \.needsNotarization) {
              Button("Notarization Settings…") {
                model.notarizationSetup = NotarizationSetupRequest()
              }
              .buttonStyle(.kitPlain)
              .controlSize(.small)
              .padding(.leading, 4)
            }
          }
        }
      }
    }
  }

  /// Opens the New Action sheet for `kind` of `scheme`, or the action it
  /// already became.
  private func addToActions(_ kind: ActionKind, scheme: ActionScheme) {
    if let saved = model.savedAction(for: kind, scheme: scheme) {
      model.editAction(saved)
    } else {
      model.addSmartActionToActions(kind, scheme: scheme)
    }
  }

  private func smartActionItem(_ kind: ActionKind, scheme: ActionScheme, directory: URL) -> some View {
    let running = model.isSmartActionRunning(kind, scheme: scheme, in: directory)
    let style = SmartActionStyle(kind)
    return PaletteItem(
      kind.title, id: "\(scheme.id).\(kind.rawValue)", systemImage: style.systemImage, hue: style.hue,
      detail: scheme.terminalCommand(for: kind), status: running ? .working : .idle,
      returnLabel: running ? "Stop" : nil
    ) {
      if running {
        model.stopSmartAction(in: directory)
      } else {
        model.runSmartAction(kind, scheme: scheme, in: directory)
      }
    }
    .help(running ? "Stop" : "\(kind.title) \(scheme.name)")
    .kitContextMenu {
      if model.savedAction(for: kind, scheme: scheme) != nil {
        Button("Edit Action…") { addToActions(kind, scheme: scheme) }
      } else if model.smartActionCommand(kind, scheme: scheme) != nil {
        Button("Add to Your Actions…") { addToActions(kind, scheme: scheme) }
      }
    }
  }
  #endif

  #if os(macOS)
  // MARK: Open with

  /// The apps that open the active local directory, as their real icons.
  @ViewBuilder
  private var openWith: some View {
    let kinds = model.openWithKinds.filter { ProjectOpener.isInstalled($0) }
    if let directory = model.smartActionDirectory, !kinds.isEmpty, query.isEmpty {
      PaletteGroup(
        "Open \(directory.lastPathComponent) in", meta: [kinds.count == 1 ? "1 app" : "\(kinds.count) apps"],
        systemImage: "folder", hue: .gray
      ) {
        ForEach(kinds, id: \.self) { kind in
          Button {
            ProjectOpener.open(kind, in: directory)
            model.showingActions = false
          } label: {
            Label {
              Text(ProjectOpener.displayName(for: kind))
            } icon: {
              Image(nsImage: ProjectOpener.icon(for: kind))
                .resizable()
                .frame(width: 20, height: 20)
            }
          }
          .help("Open in \(ProjectOpener.displayName(for: kind))")
        }
      } items: {
        EmptyView()
      }
    }
  }

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

#if os(macOS) || os(Windows) || os(Linux)
/// A smart-action group's + button: a menu of the scheme's smart actions to
/// add to Your actions (the New Action sheet, filled in). Added ones are
/// checked and open their action instead.
private struct AddToActionsMenu: View {
  @Environment(AppModel.self) private var model
  let scheme: ActionScheme
  let pick: (ActionKind) -> Void
  @State private var isOpen = false

  var body: some View {
    let kinds = ActionKind.allCases.filter {
      model.smartActionCommand($0, scheme: scheme) != nil && ($0.isDistribution ? $0.isOfferedHere && scheme.supports($0) : true)
    }
    Button("Add to Your Actions", systemImage: "plus") { isOpen = true }
      .help("Add \(scheme.name)'s smart actions to Your actions")
      .kitMenu(isPresented: $isOpen) {
        KitMenuSection("Add to Your Actions") {
          ForEach(kinds, id: \.self) { kind in
            let isSaved = model.savedAction(for: kind, scheme: scheme) != nil
            Toggle(isOn: Binding(get: { isSaved }, set: { _ in pick(kind) })) {
              Label(kind.title, systemImage: SmartActionStyle(kind).systemImage)
            }
          }
        }
      }
  }
}

/// A smart action's tile: Run green play, Build orange hammer, Test purple
/// diamond, Lint teal seal, Clean gray trash, distribution blue.
private struct SmartActionStyle {
  let systemImage: String
  let hue: Hue

  init(_ kind: ActionKind) {
    switch kind {
    case .run: (systemImage, hue) = ("play.fill", .green)
    case .build: (systemImage, hue) = ("hammer.fill", .orange)
    case .test: (systemImage, hue) = ("play.diamond.fill", .purple)
    case .lint: (systemImage, hue) = ("checkmark.seal.fill", .teal)
    case .clean: (systemImage, hue) = ("trash.fill", .gray)
    case .install, .export, .upload: (systemImage, hue) = ("square.and.arrow.up", .blue)
    }
  }
}
#endif
