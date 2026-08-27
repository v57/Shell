import Foundation
import SwiftUI
import Terminal
import Monitoring

/// Sidebar: lists local terminals and saved SSH connections.
struct SidebarView: View {
  @Environment(AppModel.self) private var model
  /// The session currently being renamed (shows an inline text field).
  @State private var renamingSessionID: UUID?
  /// The saved SSH connection currently being edited (opens the edit sheet).
  @State private var editingConfig: SSHConfig?
  #if os(macOS)
  /// The screen session currently being renamed (keyed by full name).
  @State private var renamingScreenName: String?
  /// Live CPU/GPU/wattage for the Local section header (macOS only —
  /// the reads need IOKit's AppleSMC / IOAccelerator).
  @State private var statsMonitor = SystemStatsMonitor()
  /// The stats graphs sheet, opened by clicking the Local section header.
  @State private var showingStatsGraphs = false
  #endif
  
  private var localSessions: [TerminalSession] {
    model.sessions.filter { model.kind(of: $0) == .local }
  }
  
  var body: some View {
    @Bindable var model = model
    List(selection: $model.selection) {
      if !model.actionSessions.isEmpty {
        Section("Running") {
          ForEach(model.actionSessions) { session in
            ActionRunRow(session: session, spec: model.actionSpec(for: session))
              .tag(session.id)   // mandatory: untagged rows write nil into selection
              .contextMenu {
                if isRunning(session) {
                  Button("Cancel (Ctrl+C)") { session.send(Data([0x03])) }
                }
                Button("Remove", role: .destructive) {
                  model.removeSession(session.id)
                }
              }
          }
        }
      }

      #if os(macOS)
      Section {
        if model.historyMode {
          ForEach(model.history.sessions) { record in
            HistorySessionRow(session: record)
              .tag(record.id)
          }
        } else {
          ForEach(localSessions) { session in
            SessionRow(
              session: session,
              defaultLabel: model.displayName(for: session),
              subtitle: nil,
              isRenaming: renamingSessionID == session.id,
              onCommitRename: { commitRename(session.id, $0) },
              onCancelRename: { renamingSessionID = nil }
            )
            .tag(session.id)
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
          ForEach(model.screenMonitor.sessions) { info in
            ScreenSessionRow(
              info: info,
              isRenaming: renamingScreenName == info.name,
              onCommitRename: { commitScreenRename(info, $0) },
              onCancelRename: { renamingScreenName = nil }
            )
            // Tag with the open session's id when attached (so the row shows
            // selected while its terminal is open), else the stable tagID.
            .tag(model.attachedSession(toScreen: info)?.id ?? info.tagID)
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
        }
      } header: {
        HStack {
          #if os(macOS)
          if model.historyMode {
            Text("Local History")
          } else {
            statsHeader
          }
          #else
          Text(model.historyMode ? "Local History" : "Local")
          #endif
          if model.historyMode {
            Button(role: .destructive) {
              model.deleteAllHistory()
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete all local history")
          }
          Spacer()
          // Only meaningful when there is something to show; hidden while
          // the list is empty (the trash button still serves as the exit
          // when viewing history).
          if !model.history.sessions.isEmpty {
            Button {
              model.toggleHistoryMode()
            } label: {
              Image(systemName: "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted")
                .foregroundStyle(model.historyMode ? Color.blue : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.historyMode ? "Show local terminals" : "Show local history")
          }
          Button {
            model.addLocalTerminal()
          } label: {
            Image(systemName: "plus")
          }.buttonStyle(.borderless).help("New local terminal")
          Button {
            model.screenMonitor.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }.buttonStyle(.borderless).help("Refresh persistent sessions")
          Button {
            model.createScreenSession()
          } label: {
            Image(systemName: "plus")
          }.buttonStyle(.borderless).help("New persistent zsh session")
        }.padding(.trailing, 4)
      }
      
      #endif // os(macOS) — Local section (no local terminals on iOS)

      Section {
        ForEach(model.connections) { config in
          SSHConfigGroup(
            config: config,
            renamingSessionID: renamingSessionID,
            onBeginRename: { renamingSessionID = $0 },
            onCommitRename: commitRename,
            onCancelRename: { renamingSessionID = nil },
            onEdit: { editingConfig = $0 }
          )
        }
        .onMove { source, destination in
          model.moveConnection(from: source, to: destination)
        }
      } header: {
        HStack {
          Text("Remote")
          Spacer()
          Button {
            model.showingNewConnection = true
          } label: {
            Image(systemName: "plus")
          }.buttonStyle(.borderless).help("New SSH connection")
        }.padding(.trailing, 4)
      }

      Section {
        ForEach(model.notes.notes) { note in
          NoteRow(note: note)
            .tag(note.id)
            .contextMenu {
              Button("Delete Note", role: .destructive) {
                model.deleteNote(note.id)
              }
            }
        }
      } header: {
        HStack {
          Text("Notes")
          Spacer()
          Button {
            model.newNote()
          } label: {
            Image(systemName: "plus")
          }.buttonStyle(.borderless).help("New note")
        }.padding(.trailing, 4)
      }
    }
    // Clicking an SSH row selects its config id; turn that into an
    // actual connection (select the existing session or create one).
    // Screen rows select a deterministic tagID; attach a local terminal
    // to that screen session.
    .onChange(of: model.selection) { _, newValue in
      if renamingSessionID != nil { renamingSessionID = nil }
      #if os(macOS)
      renamingScreenName = nil
      #endif
      guard let id = newValue else { return }
      if let config = model.connections.first(where: { $0.id == id }) {
        model.connect(to: config)
        return
      }
      #if os(macOS)
      if let info = model.screenMonitor.sessions.first(where: { $0.tagID == id }) {
        if let existing = model.attachedSession(toScreen: info) {
          // Already attached: just focus the open terminal instead of
          // spawning a second client (multi-attach would leave the
          // session "Attached" even after one terminal closes).
          model.selection = existing.id
        } else {
          model.attach(toScreen: info)
        }
      }
      #endif
    }
    .navigationTitle("Terminals")
    #if os(macOS)
    .alert(item: $model.screenMonitor.actionError) { error in
      Alert(
        title: Text(error.title),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    #endif
    // The authorized-keys panel (key.2.on.ring in the Local/Remote
    // headers); opens for this Mac or the selected SSH connection.
    .sheet(isPresented: $model.showingAuthorizedKeys) {
      if let target = model.authorizedKeysTarget {
        AuthorizedKeysView(target: target)
          .environment(model)
      }
    }
    // The Edit… action on a saved SSH connection: the same form as new
    // connections, prefilled, saving in place (same id).
    .sheet(item: $editingConfig) { config in
      NewConnectionView(config: config)
    }
    .alert("Authorized Keys", isPresented: Binding(
      get: { model.authorizedKeysError != nil },
      set: { if !$0 { model.authorizedKeysError = nil } }
    )) {
      Button("OK", role: .cancel) { model.authorizedKeysError = nil }
    } message: {
      Text(model.authorizedKeysError ?? "")
    }
    #if os(macOS)
    .background(WindowStatsObserver(monitor: statsMonitor))
    .onAppear { statsMonitor.start() }
    .onDisappear { statsMonitor.stop() }
    // Stats graphs for the last minute, opened from the Local header.
    .sheet(isPresented: $showingStatsGraphs) {
      StatsGraphView(monitor: statsMonitor)
    }
    #endif
  }

  #if os(macOS)
  /// The Local section header showing live CPU/GPU usage and total
  /// wattage, e.g. "  5% 12% 13W" (percentages right-aligned to 3 chars,
  /// wattage right-aligned to 2 chars). Falls back to plain "Local" when
  /// the stats aren't available yet (first tick). Clicking it opens the
  /// stats graphs for the last minute.
  @ViewBuilder
  private var statsHeader: some View {
    let cpu = Int(statsMonitor.cpuPercent.rounded())
    let gpu = Int(statsMonitor.gpuPercent.rounded())
    if statsMonitor.watts > 0 {
      Button {
        showingStatsGraphs = true
      } label: {
        Text("\(String(format: "%3d", cpu))% \(String(format: "%3d", gpu))% \(String(format: "%2d", statsMonitor.watts))W")
          .font(.caption.weight(.medium))
          .monospaced()
      }
      .buttonStyle(.plain)
      .help("CPU · GPU · System power draw — click for graphs")
    } else {
      Text("Local")
    }
  }
  #endif

  /// True while an action session can still be interrupted (its process
  /// or remote exec is alive); Cancel sends Ctrl+C in that state.
  private func isRunning(_ session: TerminalSession) -> Bool {
    switch session.connectionState {
    case .starting, .connecting, .connected:
      return true
    case .failed, .closed:
      return false
    }
  }

  /// Applies a rename and exits edit mode.
  private func commitRename(_ id: UUID, _ name: String) {
    model.renameSession(id, to: name)
    renamingSessionID = nil
  }
  
  #if os(macOS)
  /// Renames a screen session on the local machine and exits edit mode.
  private func commitScreenRename(_ info: ScreenSessionInfo, _ name: String) {
    model.screenMonitor.rename(info, to: name)
    renamingScreenName = nil
  }
  #endif
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

/// A running or finished action session in the sidebar's Running section:
/// spinner while alive, green ✓ in the ~2s grace before a clean run
/// disappears, red ✗ + exit code/error for failures (which persist until
/// dismissed). Shows the action's live last output line like other rows.
private struct ActionRunRow: View {
  var session: TerminalSession
  let spec: ActionSpec?

  @Environment(\.terminalBackgroundsDisabled) private var disableBackgrounds
  @Environment(\.colorScheme) private var colorScheme

  private var environmentLabel: String {
    spec?.config?.displayName ?? "Local"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        stateIcon
        Text(spec?.action.name ?? "Action")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Text(environmentLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      statusLine
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var stateIcon: some View {
    switch session.connectionState {
    case .starting, .connecting, .connected:
      Image(systemName: "play.fill")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Running")
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .closed:
      if session.actionExitCode == 0 {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      } else {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    switch session.connectionState {
    case .failed(let message):
      Text(message)
        .font(.caption2)
        .foregroundStyle(.red)
        .lineLimit(1)
    case .closed:
      if let code = session.actionExitCode, code != 0 {
        Text("exit " + String(code))
          .font(.caption2.monospaced())
          .foregroundStyle(.red)
          .lineLimit(1)
      } else if !session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme).characters.isEmpty {
        Text(session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme))
          .font(.caption2.monospaced())
          .lineLimit(1)
          .truncationMode(.tail)
      }
    default:
      if !session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme).characters.isEmpty {
        Text(session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme))
          .font(.caption2.monospaced())
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
  }
}

/// A saved SSH connection (server) plus its running connections. Emits
/// one sidebar row per running session, so the List shows them all.
private struct SSHConfigGroup: View {
  @Environment(AppModel.self) private var model
  let config: SSHConfig
  let renamingSessionID: UUID?
  let onBeginRename: (UUID) -> Void
  let onCommitRename: (UUID, String) -> Void
  let onCancelRename: () -> Void
  let onEdit: (SSHConfig) -> Void
  
  var body: some View {
    SSHConfigRow(config: config)
      .tag(config.id)
      .contextMenu {
        Button("Connect") { model.connect(to: config) }
        Button("Edit…") { onEdit(config) }
        Button("Copy Public Key") { model.copyPublicKey() }
        Button("Authorized Keys", systemImage: "key.2.on.ring") {
          model.showAuthorizedKeys(for: .ssh(config))
        }.buttonStyle(.borderless).help("Manage the selected connection's authorized keys")
        Divider()
        Button("Delete Connection", role: .destructive) {
          model.deleteConnection(config)
        }
      }
    ForEach(model.sessions(for: config)) { session in
      SessionRow(
        session: session,
        defaultLabel: model.displayName(for: session),
        subtitle: "\(config.user)@\(config.host):\(config.port)",
        isRenaming: renamingSessionID == session.id,
        onCommitRename: { onCommitRename(session.id, $0) },
        onCancelRename: onCancelRename
      )
      .padding(.leading, 14)
      .tag(session.id)
      .contextMenu {
        Button("Rename…") { onBeginRename(session.id) }
        Divider()
        Button("Close Connection", role: .destructive) {
          model.removeSession(session.id)
        }
      }
    }
  }
}

/// A saved SSH connection (server) in the sidebar. Clicking it opens a
/// new connection to that server.
private struct SSHConfigRow: View {
  @Environment(AppModel.self) private var model
  let config: SSHConfig
  
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "network")
        .foregroundStyle(.secondary)
      Text(config.displayName)
      Spacer()
      if model.sessionID(for: config) != nil {
        Circle()
          .fill(.green)
          .frame(width: 7, height: 7)
          .accessibilityLabel("Connected")
      }
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

/// A session row in the sidebar. While renaming, shows a focused text
/// field instead of the label; Enter applies, Escape cancels.
private struct SessionRow: View {
  var session: TerminalSession
  let defaultLabel: String
  let subtitle: String?
  let isRenaming: Bool
  let onCommitRename: (String) -> Void
  let onCancelRename: () -> Void

  @Environment(\.terminalBackgroundsDisabled) private var disableBackgrounds
  @Environment(\.colorScheme) private var colorScheme
  
  @State private var draft = ""
  @FocusState private var fieldFocused: Bool
  
  private var currentLabel: String {
    session.customName ?? defaultLabel
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: "terminal")
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
          Text(currentLabel)
        }
        Spacer()
        stateDot
      }
      // Second line: the session's status (n-th non-empty terminal line
      // from the bottom, or the line pinned by clicking its last
      // character), rendered in the terminal's own colors.
      if !session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme).characters.isEmpty {
        Text(session.statusAttributedString(disableBackgrounds: disableBackgrounds, scheme: colorScheme)).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
          .clipShape(.capsule)
      }
    }
    .onChange(of: isRenaming) { _, newValue in
      if newValue {
        draft = currentLabel
        fieldFocused = true
      }
    }
    .contentShape(Rectangle())
  }
  
  @ViewBuilder
  private var stateDot: some View {
    switch session.connectionState {
    case .connected:
      // Green only while the session produced output recently; after
      // `TerminalSession.inactivityTimeout` of quiet the session is idle
      // and the dot hides. Read via @Observable so the row re-renders when
      // `hasActivity` flips.
      if session.hasActivity {
        Circle().fill(.green).frame(width: 7, height: 7)
      }
    case .failed:
      Circle().fill(.red).frame(width: 7, height: 7)
    case .starting, .connecting, .closed:
      Circle().fill(.secondary).frame(width: 7, height: 7)
    }
  }
}

/// Sheet for creating a NEW SSH connection, or EDITING a saved one (when
/// initialized with a `config`): fields prefill and the toolbar button
/// saves in place (same id) instead of connecting.
struct NewConnectionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  
  /// Non-nil when editing a saved connection.
  private let editing: SSHConfig?
  
  @State private var name: String
  @State private var host: String
  @State private var user: String
  @State private var port: Int
  @State private var authMethod: SSHConfig.AuthMethod
  @State private var password: String
  @State private var savePassword: Bool
  @State private var keyError: String?
  
  init(config: SSHConfig? = nil) {
    editing = config
    _name = State(initialValue: config?.name ?? "")
    _host = State(initialValue: config?.host ?? "")
    _user = State(initialValue: config?.user ?? NSUserName())
    _port = State(initialValue: config?.port ?? 22)
    _authMethod = State(initialValue: config?.authMethod ?? .keychainKey)
    _password = State(initialValue: "")
    _savePassword = State(initialValue: config?.savePassword ?? true)
    _keyError = State(initialValue: nil)
  }
  
  private var canConnect: Bool {
    !host.trimmingCharacters(in: .whitespaces).isEmpty
    && !user.trimmingCharacters(in: .whitespaces).isEmpty
    && port > 0 && port < 65536
    && (authMethod == .keychainKey
        || !password.isEmpty
        || editing?.authMethod == .password)  // stored password still applies
  }
  
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Form {
          Section {
            TextField("Host", text: $host).textContentType(.URL)
            TextField("User", text: $user).textContentType(.username)
            TextField("Name \(host)", text: $name)
            TextField("Port", value: $port, format: .number)
          }
          
          Section("Authentication") {
            Picker("Method", selection: $authMethod) {
              ForEach(SSHConfig.AuthMethod.allCases) { method in
                Text(method.label).tag(method)
              }
            }
            if authMethod == .password {
              SecureField("Password", text: $password)
                .textContentType(.password)
              Toggle("Save in Keychain", isOn: $savePassword)
            }
          }
          
          if authMethod == .keychainKey {
            Section {
              KeyRow(
                label: "Default key",
                fingerprint: model.publicKeyFingerprint(),
                onCopy: {
                  model.copyPublicKey()
                  keyError = model.publicKeyError
                }
              )
            } header: {
              Text("SSH key")
            } footer: {
              Text("Add this key to the server's ~/.ssh/authorized_keys to use key authentication.")
            }
          }
        }.formStyle(.grouped)
      }.toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(editing == nil ? "Connect" : "Save", systemImage: "checkmark") {
            submit()
          }.keyboardShortcut(.defaultAction).disabled(!canConnect)
        }
      }.alert("Could not copy public key", isPresented: Binding(
        get: { keyError != nil },
        set: { if !$0 { keyError = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(keyError ?? "")
      }.navigationTitle(editing == nil ? "New Connection" : "Edit Connection")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
  }
  
  private func submit() {
    let config = SSHConfig(
      id: editing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      host: host.trimmingCharacters(in: .whitespaces),
      user: user.trimmingCharacters(in: .whitespaces),
      port: port,
      authMethod: authMethod,
      savePassword: savePassword
    )
    // Password lifecycle: a typed password saves or clears per the toggle;
    // editing without retyping leaves the stored password untouched; the
    // toggle turned off without a new password deletes it.
    if authMethod == .password {
      if !password.isEmpty {
        if savePassword {
          try? SSHKeychain.savePassword(password, account: config.passwordAccount)
        } else {
          SSHKeychain.deletePassword(account: config.passwordAccount)
        }
      } else if !savePassword {
        SSHKeychain.deletePassword(account: config.passwordAccount)
      }
    }
    if editing != nil {
      model.updateConnection(config)
    } else {
      model.connect(to: config)
    }
    dismiss()
  }
}

/// One row in the SSH key section: label + fingerprint + copy button.
private struct KeyRow: View {
  let label: String
  let fingerprint: String?
  let onCopy: () -> Void
  
  var body: some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      if let fingerprint {
        Text(fingerprint)
          .font(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Button {
        onCopy()
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .help("Copy \(label.lowercased()) public key")
    }
  }
}

/// A note row in the sidebar. The title is the first non-empty line of the
/// note (editing it renames it); the preview is the next non-empty line.
/// Both are DECRYPTED IN THE VIEW via `decryptedNote(id:)` — SwiftUI's List
/// materializes visible rows only, so only visible cells decrypt (results
/// cached by the store).
private struct NoteRow: View {
  @Environment(AppModel.self) private var model
  let note: NotesStore.NoteSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: "note.text")
          .foregroundStyle(.secondary)
        Text(model.notes.title(for: note.id))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        if note.storedInICloud {
          Image(systemName: "icloud.fill")
            .font(.caption2)
            .foregroundStyle(Color.blue)
            .help("Stored in iCloud (encrypted)")
        }
      }
      if let subtitle = model.notes.subtitle(for: note.id) {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .contentShape(Rectangle())
  }
}

// MARK: - Sidebar status rendering (moved from the old app-side TerminalView.swift)

extension TerminalColor {
  /// SwiftUI color for explicit terminal colors (ANSI/rgb); nil for
  /// default/clear so the sidebar's own text style shows through.
  var sidebarColor: Color? {
    switch self {
    case .clear, .default:
      return nil
    case .rgb(let red, let green, let blue):
      return Color(red: red, green: green, blue: blue)
    case .ansi(let index):
      return TerminalColor.color(forAnsiIndex: index)
    }
  }
}

extension TerminalSession {
  /// The status line rendered with the terminal's own per-cell colors
  /// and styles (prompts, git status, vim bars, ...). Runs without an
  /// explicit color keep the sidebar's secondary style; bold cells use
  /// a semibold monospaced face.
  ///
  /// `disableBackgrounds: true` mirrors the canvas's background-suppression
  /// theme (the "Disable Background Colors" option): no character
  /// backgrounds, and explicit low-contrast colors replaced with `.primary`
  /// per `TerminalContrast`. `scheme` is the EFFECTIVE color scheme (after
  /// any preferredColorScheme override), matching the canvas's contrast keys.
  func statusAttributedString(disableBackgrounds: Bool, scheme: ColorScheme) -> AttributedString {
    if let message = snapshot.message {
      return AttributedString(message)
    }
    guard let line = snapshot.nonEmptyLineIndexFromBottom(statusRank) else {
      return AttributedString()
    }
    let lastColumn = snapshot.lastNonBlankColumn(ofLine: line)
    guard lastColumn >= 0 else { return AttributedString() }
    // Start-character mode shows the line FROM the clicked character
    // (skipping the prefix before it); full-line mode shows the whole
    // line. Clamp to the line's content so a click past its end doesn't
    // produce an empty range.
    let startColumn = statusStartMarked ? min(max(0, statusStartColumn), lastColumn) : 0
    
    let baseFont = Font.caption2.monospaced()
    let boldFont = Font.caption2.monospaced().weight(.semibold)
    var result = AttributedString()
    for column in startColumn...lastColumn {
      let cell = snapshot.cell(atLine: line, column: column)
      // Blank cells (including \0) render as spaces — internal spacing
      // must survive; lastColumn already bounds trailing blanks.
      let character = cell.isBlank ? " " : String(cell.character)
      var attrs = AttributeContainer()
      attrs.font = cell.bold ? boldFont : baseFont
      // Inverse swaps the background into the foreground (like the canvas).
      if disableBackgrounds {
        // Apple theme: no character backgrounds; the cell's own color
        // (the background color for inverse cells) unless low-contrast,
        // then primary. Exactly the canvas's suppression contract.
        attrs.foregroundColor = TerminalContrast.suppressedBackgroundForeground(
          for: cell.inverse ? cell.background : cell.foreground,
          scheme: scheme
        )
      } else {
        if cell.inverse {
          if let color = cell.background.sidebarColor {
            attrs.foregroundColor = color
          }
        } else if let color = cell.foreground.sidebarColor {
          attrs.foregroundColor = color
        }
        if !cell.inverse, let background = cell.background.sidebarColor {
          attrs.backgroundColor = background
        }
      }
      result.append(AttributedString(character, attributes: attrs))
    }
    return result
  }
}
