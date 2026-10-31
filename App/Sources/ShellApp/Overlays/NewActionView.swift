import ComponentKit
import SwiftUI
import ShellKit
import ShellIntegrations

/// Sheet for creating a new action: name, optional category, where to
/// display (local / specific SSH connections / future SSH connections),
/// focus and completion behavior, and
/// the commands to run.
struct NewActionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.kitDismiss) private var dismiss

  /// The action being edited, nil when creating a new one.
  private let editing: Action?

  @State private var name = ""
  @State private var category = ""
  @State private var appliesToLocal = true
  @State private var sshConnectionIDs = Set<UUID>()
  @State private var appliesToFutureSSHConnections = false
  @State private var commands = ""
  @State private var webAddress = ""
  @State private var dependencies = Set<UUID>()
  @State private var focusWindow = false
  @State private var keepAfterCompletion = false
  @State private var seededImplicitConnections = false

  /// `draft` fills a new action's form (a smart action added to Your actions).
  init(action: Action? = nil, draft: Action? = nil, commands: String = "", targetSSHConnectionID: UUID? = nil) {
    self.editing = action
    let action = action ?? draft
    _name = State(initialValue: action?.name ?? "")
    _category = State(initialValue: action?.category ?? "")
    _appliesToLocal = State(initialValue: action?.appliesToLocal ?? (targetSSHConnectionID == nil))
    _sshConnectionIDs = State(initialValue: Set(action?.sshConnectionIDs ?? targetSSHConnectionID.map { [$0] } ?? []))
    _appliesToFutureSSHConnections = State(initialValue: action?.appliesToFutureSSHConnections ?? false)
    _commands = State(initialValue: action?.commands ?? commands)
    _webAddress = State(initialValue: action?.webAddress ?? "")
    _dependencies = State(initialValue: Set(action?.dependencies ?? []))
    _focusWindow = State(initialValue: action?.focusWindow ?? false)
    _keepAfterCompletion = State(initialValue: action?.keepAfterCompletion ?? false)
  }

  private var canCreate: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
    && !commands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && (appliesToLocal || !sshConnectionIDs.isEmpty || appliesToFutureSSHConnections)
  }

  /// The smart-resolved absolute URL shown as a live preview of the web field
  /// (empty input -> empty output, so the footer switches to the hint text).
  private var resolvedWebAddress: String {
    SmartAddress.resolve(webAddress)
  }

  /// Actions currently selected as dependencies, in store order.
  private var selectedDependencyActions: [Action] {
    model.actions.all.filter { dependencies.contains($0.id) }
  }

  /// The picker's candidate list: every action except this one, minus the
  /// whole transitive closure (its dependencies AND its dependents) of each
  /// already-selected dependency — so a cycle is impossible.
  private var availableDependencies: [Action] {
    var excluded = Set<UUID>()
    if let selfID = editing?.id { excluded.insert(selfID) }
    for depID in dependencies {
      excluded.formUnion(dependencyClosure(of: depID))
    }
    return model.actions.all.filter { !excluded.contains($0.id) }
  }

  /// The transitive closure of `id` including itself: every action reachable
  /// by following dependencies downward, or dependents upward. Down and up
  /// use SEPARATE traversed-sets so both directions scan from the root (a
  /// shared set would make the second direction bail on the root and miss
  /// the other side, breaking the cycle guard).
  private func dependencyClosure(of id: UUID) -> Set<UUID> {
    var result = Set<UUID>()
    var downSeen = Set<UUID>()
    var upSeen = Set<UUID>()
    func down(_ a: Action) {
      guard downSeen.insert(a.id).inserted else { return }
      result.insert(a.id)
      for depID in a.dependencies {
        if let dep = model.actions.all.first(where: { $0.id == depID }) { down(dep) }
      }
    }
    func up(_ a: Action) {
      guard upSeen.insert(a.id).inserted else { return }
      result.insert(a.id)
      for depend in model.actions.all where depend.dependencies.contains(a.id) {
        up(depend)
      }
    }
    if let a = model.actions.all.first(where: { $0.id == id }) {
      down(a); up(a)
    }
    return result
  }

  var body: some View {
    KitSheet(
      title: editing == nil ? "New Action" : "Edit Action", meta: editing?.name,
      systemImage: "bolt", hue: .purple, width: 480
    ) {
      FormCard("Action") {
        FormRow("Name", systemImage: "character.cursor.ibeam", hue: .purple, field: TextField("Name", text: $name))
        FormRow(
          "Category", help: "Optional", systemImage: "folder", hue: .purple,
          field: TextField("Category (optional)", text: $category))
      }

      FormCard("Where to display", footer: "Future sessions applies to SSH connections you save after this action.") {
        FormRow("Local", systemImage: "terminal", hue: .green) {
          toggle("Local", isOn: $appliesToLocal)
        }
        ForEach(model.connections) { config in
          FormRow(config.displayName, systemImage: "network", hue: .blue) {
            toggle(config.displayName, isOn: binding(for: config.id))
          }
        }
        FormRow("Apply to future sessions", systemImage: "clock.arrow.circlepath", hue: .blue) {
          toggle("Apply to future sessions", isOn: $appliesToFutureSSHConnections)
        }
      }

      FormCard(
        "Behavior", footer: "Off: the action runs in the background — watch it in the sidebar's Running section."
      ) {
        FormRow("Focus window when run", systemImage: "macwindow", hue: .gray) {
          toggle("Focus window when run", isOn: $focusWindow)
        }
        FormRow("Keep after completion", systemImage: "pin", hue: .gray) {
          toggle("Keep after completion", isOn: $keepAfterCompletion)
        }
      }

      FormCard("Commands", footer: "Runs in a new terminal with zsh locally, or your shell on the remote host.") {
        TextEditor(text: $commands)
          .kitFont(.mono)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 140)
          .padding(6)
          .kitSurface(.field)
          .padding(6)
      }

      FormCard(
        "Web",
        footer: webAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "Optional: the command starts a web server; this opens it in a focused web view."
          : "Opens \(resolvedWebAddress) when the action runs."
      ) {
        FormRow(
          "Address", help: "Optional", systemImage: "globe", hue: .teal,
          field: TextField("Address (optional)", text: $webAddress).textContentType(.URL))
      }

      FormCard(
        "Dependencies",
        footer: availableDependencies.isEmpty
          ? (selectedDependencyActions.isEmpty
            ? "No other actions yet — create one first."
            : "No more actions can be added (all remaining would recurse).")
          : "All of this action's dependencies start at once, and this action starts 1 second after its dependencies have started — so it is running, not necessarily finished."
      ) {
        ForEach(selectedDependencyActions) { dep in
          FormRow(dep.name, systemImage: "checkmark", hue: .blue) {
            Button("Remove dependency", systemImage: "xmark") { dependencies.remove(dep.id) }
              .buttonStyle(.kitIcon)
              .labelStyle(.iconOnly)
              .help("Remove dependency")
          }
        }
        ForEach(availableDependencies) { dep in
          FormRow(
            dep.name,
            help: dep.dependencies.isEmpty
              ? nil : "\(dep.dependencies.count) dep.\(dep.dependencies.count == 1 ? "" : "s")",
            systemImage: "bolt", hue: .gray
          ) {
            Button("Add as a dependency", systemImage: "plus") { dependencies.insert(dep.id) }
              .buttonStyle(.kitIcon)
              .labelStyle(.iconOnly)
              .help("Add as a dependency")
          }
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(editing == nil ? "Create" : "Save") { save() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!canCreate)
    }
    .onAppear {
      // Connections created after a future-enabled action was saved apply
      // implicitly; show their toggles as selected when editing.
      if let editing, !seededImplicitConnections {
        for config in model.connections where editing.applies(to: .ssh(config)) {
          sshConnectionIDs.insert(config.id)
        }
        seededImplicitConnections = true
      }
    }
    // The commands TextEditor dies with this sheet; drop the edits it left on
    // the window's undo stack so a later ⌘Z cannot message the freed editor.
    .onDisappear { UndoHygiene.discardStaleTextUndo() }
  }

  /// A form row's switch (its label is the row's).
  private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn)
      .toggleStyle(.kitSwitch)
      .kitLabelsHidden()
  }

  private func binding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { sshConnectionIDs.contains(id) },
      set: { isOn in
        if isOn {
          sshConnectionIDs.insert(id)
        } else {
          sshConnectionIDs.remove(id)
        }
      }
    )
  }

  private func save() {
    let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
    let excludedConnections = appliesToFutureSSHConnections
      ? model.connections.map(\.id).filter { !sshConnectionIDs.contains($0) }
      : []
    // Prune any dependency ids that no longer resolve (action deleted) so the
    // saved action never references a missing action.
    let dependencyIDs = model.actions.all.filter { dependencies.contains($0.id) }.map(\.id)
    let action = Action(
      id: editing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      category: trimmedCategory.isEmpty ? nil : trimmedCategory,
      appliesToLocal: appliesToLocal,
      sshConnectionIDs: Array(sshConnectionIDs),
      appliesToFutureSSHConnections: appliesToFutureSSHConnections,
      excludedSSHConnectionIDs: excludedConnections,
      commands: commands,
      webAddress: webAddress.trimmingCharacters(in: .whitespacesAndNewlines),
      dependencies: dependencyIDs,
      focusWindow: focusWindow,
      keepAfterCompletion: keepAfterCompletion,
      lastUsed: editing?.lastUsed
    )
    model.actions.save(action)
    dismiss()
  }
}
