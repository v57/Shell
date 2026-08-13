import SwiftUI
import Terminal

/// Sheet for creating a new action: name, optional category, where to
/// display (local / specific SSH connections / future SSH connections),
/// focus and completion behavior, and
/// the commands to run.
struct NewActionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  /// The action being edited, nil when creating a new one.
  private let editing: Action?

  @State private var name = ""
  @State private var category = ""
  @State private var appliesToLocal = true
  @State private var sshConnectionIDs = Set<UUID>()
  @State private var appliesToFutureSSHConnections = false
  @State private var commands = ""
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
    _focusWindow = State(initialValue: action?.focusWindow ?? false)
    _keepAfterCompletion = State(initialValue: action?.keepAfterCompletion ?? false)
  }

  private var canCreate: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
    && !commands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && (appliesToLocal || !sshConnectionIDs.isEmpty || appliesToFutureSSHConnections)
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
    let action = Action(
      id: editing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      category: trimmedCategory.isEmpty ? nil : trimmedCategory,
      appliesToLocal: appliesToLocal,
      sshConnectionIDs: Array(sshConnectionIDs),
      appliesToFutureSSHConnections: appliesToFutureSSHConnections,
      excludedSSHConnectionIDs: excludedConnections,
      commands: commands,
      focusWindow: focusWindow,
      keepAfterCompletion: keepAfterCompletion,
      lastUsed: editing?.lastUsed
    )
    model.actions.save(action)
    dismiss()
  }
}
