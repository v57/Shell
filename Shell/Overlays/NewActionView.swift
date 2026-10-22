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

  init(action: Action? = nil, commands: String = "", targetSSHConnectionID: UUID? = nil) {
    self.editing = action
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
    VStack(spacing: 0) {
      Text(editing == nil ? "New Action" : "Edit Action")
        .font(.headline)
        .padding(.top, 16)
        .padding(.bottom, 8)

      Form {
        Section("Action") {
          TextField("Name", text: $name)
          TextField("Category (optional)", text: $category)
        }

        Section {
          Toggle("Local", isOn: $appliesToLocal)
          ForEach(model.connections) { config in
            Toggle(config.displayName, isOn: binding(for: config.id))
          }
          Toggle("Apply to future sessions", isOn: $appliesToFutureSSHConnections)
        } header: {
          Text("Where to display")
        } footer: {
          Text("Future sessions applies to SSH connections you save after this action.")
        }

        Section {
          Toggle("Focus window when run", isOn: $focusWindow)
          Toggle("Keep after completion", isOn: $keepAfterCompletion)
        } header: {
          Text("Behavior")
        } footer: {
          Text("Off: the action runs in the background — watch it in the sidebar's Running section.")
        }

        Section {
          TextEditor(text: $commands)
            .font(.body.monospaced())
            .frame(minHeight: 140)
        } header: {
          Text("Commands")
        } footer: {
          Text("Runs in a new terminal with zsh locally, or your shell on the remote host.")
        }

        Section {
          TextField("Address (optional)", text: $webAddress)
            .textContentType(.URL)
        } header: {
          Text("Web")
        } footer: {
          if webAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Optional: the command starts a web server; this opens it in a focused web view.")
          } else {
            Text("Opens \(resolvedWebAddress) when the action runs.")
          }
        }

        Section {
          if !selectedDependencyActions.isEmpty {
            ForEach(selectedDependencyActions) { dep in
              HStack {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.blue)
                Text(dep.name)
                Spacer()
                Button {
                  dependencies.remove(dep.id)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove dependency")
              }
            }
          }
          if availableDependencies.isEmpty {
            Text(selectedDependencyActions.isEmpty
                 ? "No other actions yet — create one first."
                 : "No more actions can be added (all remaining would recurse).")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            ForEach(availableDependencies) { dep in
              HStack {
                Button {
                  dependencies.insert(dep.id)
                } label: {
                  Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add as a dependency")
                Text(dep.name)
                Spacer()
                if !dep.dependencies.isEmpty {
                  Text("\(dep.dependencies.count) dep.\(dep.dependencies.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        } header: {
          Text("Dependencies")
        } footer: {
          Text("All of this action's dependencies start at once, and this action starts 1 second after its dependencies have started — so it is running, not necessarily finished.")
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(editing == nil ? "Create" : "Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
      }
      .padding()
    }
    .frame(width: 440, height: 560)
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
