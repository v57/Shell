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
  /// Folder sync: on, the local folder, the folder on the host, deleting, the exclude patterns (comma-separated).
  @State private var syncsFolder = false
  @State private var syncLocalPath = ""
  @State private var syncRemotePath = ""
  @State private var syncDeletes = true
  @State private var syncAsks = true
  @State private var syncExcludes = FolderSyncSettings.defaultExcludes.joined(separator: ", ")

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
    if let sync = action?.folderSync {
      _syncsFolder = State(initialValue: true)
      _syncLocalPath = State(initialValue: sync.localPath)
      _syncRemotePath = State(initialValue: sync.remotePath)
      _syncDeletes = State(initialValue: sync.deletesRemovedFiles)
      _syncAsks = State(initialValue: sync.asksBeforeApplying)
      _syncExcludes = State(initialValue: sync.excludes.joined(separator: ", "))
    }
  }

  private var canCreate: Bool {
    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    if syncsFolder {
      // A sync needs both folders and a host; its commands are optional (they run on the host after it).
      return syncError == nil && !syncLocalPath.trimmingCharacters(in: .whitespaces).isEmpty
        && !syncRemotePath.trimmingCharacters(in: .whitespaces).isEmpty
        && (!sshConnectionIDs.isEmpty || appliesToFutureSSHConnections)
    }
    return !commands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (appliesToLocal || !sshConnectionIDs.isEmpty || appliesToFutureSSHConnections)
  }

  /// What's wrong with the folder on the host, checked as it's typed (the run checks it again on the host).
  private var syncError: String? {
    do {
      _ = try FolderSyncPath.checkedRemoteRoot(syncRemotePath, deletes: syncDeletes)
      return nil
    } catch {
      return syncRemotePath.isEmpty ? nil : (error as? LocalizedError)?.errorDescription
    }
  }

  private var syncExcludePatterns: [String] {
    syncExcludes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
      title: editing == nil ? "New Action" : "Edit Action", meta: editing.map { "\($0.name)" },
      systemImage: "bolt", hue: .purple, width: 480
    ) {
      FormCard("Action") {
        FormRow("Name", systemImage: "character.cursor.ibeam", hue: .purple, field: TextField("Name", text: $name))
        FormRow(
          "Category", help: "Optional", systemImage: "folder", hue: .purple,
          field: TextField("Category (optional)", text: $category))
      }

      #if os(macOS) || os(Windows) || os(Linux)
      folderSyncCard
      #endif

      FormCard(
        "Where to display",
        footer: syncsFolder
          ? "A folder sync runs on SSH connections only. Future sessions applies to SSH connections you save after this action."
          : "Future sessions applies to SSH connections you save after this action."
      ) {
        if !syncsFolder {
          FormRow("Local", systemImage: "terminal", hue: .green) {
            toggle("Local", isOn: $appliesToLocal)
          }
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

      FormCard(
        "Commands",
        footer: syncsFolder
          ? "Optional: runs on the host with your shell after the folder sync applied without errors."
          : "Runs in a new terminal with zsh locally, or your shell on the remote host."
      ) {
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
            "\(dep.name)",
            help: dep.dependencies.isEmpty
              ? nil : "\(dep.dependencies.count) deps.",
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

  #if os(macOS) || os(Windows) || os(Linux)
  /// Sync a local folder to a folder on the host, over Shell's own SSH login.
  private var folderSyncCard: some View {
    FormCard(
      "Folder sync",
      footer: syncsFolder
        ? (syncAsks
          ? "Each run lists both folders and shows what would change, then waits for Apply. Files of the same size are compared by SHA-256 when the host has sha256sum or shasum, else by modification time. The host's login stays in Shell."
          : "Each run lists both folders and makes the changes at once, without asking. Files of the same size are compared by SHA-256 when the host has sha256sum or shasum, else by modification time. The host's login stays in Shell.")
        : "Optional: upload a local folder to the host, like rsync, without handing the host's login to another app."
    ) {
      FormRow("Sync a folder", systemImage: "arrow.triangle.2.circlepath", hue: .orange) {
        toggle("Sync a folder", isOn: $syncsFolder.animation(.kit))
      }
      if syncsFolder {
        FormRow(
          "Local folder", systemImage: "folder", hue: .orange,
          field: TextField("Local folder", text: $syncLocalPath)
        ) {
          Button("Choose…") { chooseLocalFolder() }
            .buttonStyle(.kit)
            .controlSize(.small)
            .kitHelp("Pick the folder to upload")
        }
        FormRow(
          "Folder on the host", help: "Absolute, or relative to the login folder", systemImage: "externaldrive.connected.to.line.below",
          hue: .orange, error: syncError, field: TextField("/var/www/site", text: $syncRemotePath))
        FormRow(
          "Delete removed files", help: "Files on the host the local folder doesn't have", systemImage: "trash",
          hue: .red
        ) {
          toggle("Delete removed files", isOn: $syncDeletes)
        }
        FormRow(
          "Ask before applying", help: "Show what would change and wait for Apply", systemImage: "hand.raised",
          hue: .orange
        ) {
          toggle("Ask before applying", isOn: $syncAsks)
        }
        FormRow(
          "Exclude", help: "Neither uploaded nor deleted. Comma-separated: .* (dotfiles), node_modules, /drafts",
          systemImage: "eye.slash", hue: .gray, field: TextField("Exclude", text: $syncExcludes))
      }
    }
  }

  private func chooseLocalFolder() {
    Task {
      let start = syncLocalPath.isEmpty ? nil : URL(fileURLWithPath: (syncLocalPath as NSString).expandingTildeInPath)
      if let folder = await KitDesktop.chooseFolders(prompt: String(localized: "Choose"), directory: start).first {
        syncLocalPath = folder.path
      }
    }
  }
  #endif

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
      appliesToLocal: appliesToLocal && !syncsFolder,
      sshConnectionIDs: Array(sshConnectionIDs),
      appliesToFutureSSHConnections: appliesToFutureSSHConnections,
      excludedSSHConnectionIDs: excludedConnections,
      commands: commands,
      webAddress: webAddress.trimmingCharacters(in: .whitespacesAndNewlines),
      dependencies: dependencyIDs,
      focusWindow: focusWindow,
      keepAfterCompletion: keepAfterCompletion,
      lastUsed: editing?.lastUsed,
      folderSync: syncsFolder
        ? FolderSyncSettings(
          localPath: syncLocalPath.trimmingCharacters(in: .whitespacesAndNewlines),
          remotePath: syncRemotePath.trimmingCharacters(in: .whitespacesAndNewlines),
          deletesRemovedFiles: syncDeletes, excludes: syncExcludePatterns, asksBeforeApplying: syncAsks)
        : nil
    )
    model.actions.save(action)
    dismiss()
  }
}
