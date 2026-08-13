import AppKit
import Crypto
import Foundation
import SwiftUI
import Terminal

/// Application-wide state: the list of terminal sessions, the sidebar
/// selection, and the persisted SSH connection store.
@MainActor
@Observable
final class AppModel {
  static let shared = AppModel()
  
  var sessions: [TerminalSession] = []
  var selection: UUID?
  var showingNewConnection = false
  var publicKeyError: String?
  
  /// Polls `screen -ls` for the sidebar's Screen section.
  var screenMonitor = ScreenSessionsMonitor()

  /// The sidebar's encrypted Notes list (one sealed file per note, 5s debounced save).
  var notes = NotesStore()

  /// The sidebar's saved Actions (UserDefaults-backed).
  var actions = ActionsStore()
  /// Encrypted local-session history. Active captures remain in memory until
  /// their terminal closes or the app terminates.
  var history = HistoryStore()
  var historyMode = false
  /// The actions overlay (⌘R) and the New Action sheet.
  var showingActions = false
  var showingNewAction = false
  /// The action being edited in the sheet (nil = creating a new one).
  var editingAction: Action?
  var newActionCommands = ""
  var newActionTargetSSHConnectionID: UUID?

  /// App-side kind per session id (the library session is transport-based
  /// and kind-agnostic). Written when a session is created, removed on
  /// removal — every session in `sessions` has an entry.
  private var sessionKinds: [UUID: ConnectionKind] = [:]
  private var sessionCommands: [UUID: [SubmittedCommand]] = [:]
  private var localHistoryDrafts: [UUID: LocalHistoryDraft] = [:]
  private var selectionBeforeHistory: UUID?

  private struct LocalHistoryDraft {
    var commands: [SubmittedCommand] = []
    var output = ""
  }

  /// Opens the create-action sheet (fresh form).
  func createAction(commands: String = "", from targetSession: TerminalSession? = nil) {
    editingAction = nil
    newActionCommands = commands
    let session = targetSession ?? selectedSession
    if let session {
      switch kind(of: session) {
      case .ssh(let config):
        newActionTargetSSHConnectionID = config.id
      case .action(let spec):
        newActionTargetSSHConnectionID = spec.config?.id
      case .local, .screen:
        newActionTargetSSHConnectionID = nil
      }
    } else {
      newActionTargetSSHConnectionID = nil
    }
    showingNewAction = true
  }

  /// Opens the create-action sheet pre-filled with `action`.
  func editAction(_ action: Action) {
    editingAction = action
    newActionCommands = ""
    newActionTargetSSHConnectionID = nil
    showingNewAction = true
  }
  
  private let connectionStore = SSHConnectionStore()
  /// Observable source of truth for saved SSH rows. `connectionStore` is
  /// persistence only; reading UserDefaults through a computed property does
  /// not register an Observation dependency with SwiftUI.
  private(set) var connections: [SSHConfig] = []
  
  private init() {
    connections = connectionStore.all
    // Start with a local terminal so the window is never empty.
    _ = addLocalTerminal()
  }
  
  var selectedSession: TerminalSession? {
    sessions.first { $0.id == selection }
  }

  /// The note currently focused in the main view, if any. Shares the
  /// sidebar selection with sessions (note ids are distinct UUIDs, so
  /// row tags never collide).
  var selectedNote: NotesStore.Note? {
    notes.notes.first { $0.id == selection }
  }

  var selectedHistorySession: HistorySession? {
    guard historyMode else { return nil }
    return history.sessions.first { $0.id == selection }
  }
  
  /// The app-side kind of a session. Registered at creation, dropped on
  /// removal — never nil for a live session (fallback .local keeps the
  /// switches exhaustive).
  func kind(of session: TerminalSession) -> ConnectionKind {
    sessionKinds[session.id] ?? .local
  }

  /// The action spec behind an action session, nil for other kinds.
  func actionSpec(for session: TerminalSession) -> ActionSpec? {
    if case .action(let spec) = kind(of: session) { return spec }
    return nil
  }
  
  /// The name shown in the window title and sidebar: the user-given name
  /// if set, else a kind-based default (numbered for multiple SSH
  /// connections to the same server).
  func displayName(for session: TerminalSession) -> String {
    if let customName = session.customName {
      return customName
    }
    switch kind(of: session) {
    case .local:
      return "Local"
    case .screen(let info):
      return info.name
    case .action(let spec):
      return spec.action.name
    case .ssh(let config):
      let number = (sessions(for: config).firstIndex { $0.id == session.id } ?? 0) + 1
      return "\(config.displayName) #\(number)"
    }
  }
  
  // MARK: - Sessions
  
  @discardableResult
  func addLocalTerminal() -> TerminalSession {
    if historyMode {
      historyMode = false
      selectionBeforeHistory = nil
    }
    let session = TerminalSession(session: .zsh)
    sessionKinds[session.id] = .local
    registerCapture(for: session, archiveLocally: true)
    sessions.append(session)
    selection = session.id
    return session
  }
  
  @discardableResult
  func connect(to config: SSHConfig) -> TerminalSession {
    connectionStore.save(config)
    if let index = connections.firstIndex(where: { $0.id == config.id }) {
      connections[index] = config
    } else {
      connections.append(config)
    }
    let session = TerminalSession(
      transport: SSHSession(config: config),
      startupMessage: "Connecting to \(config.host)…"
    )
    sessionKinds[session.id] = .ssh(config)
    registerCapture(for: session, archiveLocally: false)
    sessions.append(session)
    selection = session.id
    return session
  }
  
  /// Opens a local terminal attached to an existing persistent session
  /// (`screen -x` for screen, `tmux attach` for tmux).
  @discardableResult
  func attach(toScreen info: ScreenSessionInfo) -> TerminalSession {
    // tmux attach when tmux is installed; otherwise screen -x (screen
    // ships with macOS). LocalPTYTransport.tmux is nil without tmux.
    let session: TerminalSession
    if info.kind == .tmux, let transport = LocalPTYTransport.tmux(info.name) {
      session = TerminalSession(session: transport)
    } else {
      session = TerminalSession(session: .screen(info.name))
    }
    session.exitHandler = { [weak self, weak session] _ in
      guard let id = session?.id else { return }
      // The client can exit because the shell ended (`exit`) or because it
      // detached. In both cases the app-side attachment is finished; the
      // monitor refresh decides whether the persistent backend row remains.
      self?.removeSession(id)
      self?.screenMonitor.refresh()
    }
    sessionKinds[session.id] = .screen(info)
    registerCapture(for: session, archiveLocally: false)
    sessions.append(session)
    selection = session.id
    screenMonitor.refresh()  // the session just flipped to Attached
    return session
  }
  
  /// All running sessions for a connection, in creation order.
  func sessions(for config: SSHConfig) -> [TerminalSession] {
    sessions.filter { kind(of: $0).sshConfigID == config.id }
  }
  
  /// Sets a session's sidebar name; empty input restores the default.
  func renameSession(_ id: UUID, to name: String) {
    guard let session = sessions.first(where: { $0.id == id }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    session.customName = trimmed.isEmpty ? nil : trimmed
  }
  
  func removeSession(_ id: UUID) {
    archiveLocalSession(id)
    sessions.first(where: { $0.id == id })?.close()
    sessions.removeAll { $0.id == id }
    sessionKinds.removeValue(forKey: id)
    sessionCommands.removeValue(forKey: id)
    if selection == id {
      selection = sessions.last?.id
    }
  }
  
  // MARK: - Section navigation (⌘W / ⌘N)
  
  /// The sessions shown in the same sidebar section as `session`, in
  /// sidebar display order. Local terminals list in creation order; the
  /// Persistent section lists attached sessions in monitor order; the
  /// Remote section lists each connection's running sessions in the
  /// connection store's order.
  func sectionSessions(containing session: TerminalSession) -> [TerminalSession] {
    switch kind(of: session) {
    case .local:
      return sessions.filter { kind(of: $0) == .local }
    case .screen:
      return screenMonitor.sessions.compactMap { attachedSession(toScreen: $0) }
    case .ssh:
      return connections.flatMap { sessions(for: $0) }
    case .action:
      return sessions.filter { if case .action = kind(of: $0) { return true }; return false }
    }
  }
  
  /// Creates a new session in the same section as `session`: a local
  /// terminal for local, a duplicate connection for SSH, a brand-new
  /// persistent session for screen.
  @discardableResult
  func newSession(inSameSectionAs session: TerminalSession) -> TerminalSession {
    switch kind(of: session) {
    case .local:
      return addLocalTerminal()
    case .screen:
      createScreenSession()
      return sessions.last ?? session
    case .ssh(let config):
      return connect(to: config)
    case .action:
      return addLocalTerminal()
    }
  }
  
  /// ⌘N: new session in the same section as the current selection
  /// (new local terminal when nothing is selected).
  @discardableResult
  func newSessionInSameSection() -> TerminalSession {
    if let session = selectedSession {
      return newSession(inSameSectionAs: session)
    }
    return addLocalTerminal()
  }
  
  /// ⌘W: closes the selected session (quitting persistent sessions like
  /// the toolbar does), then selects the previous session in the same
  /// section — the next one when it was the first, a fresh session in
  /// that section when it was the only one.
  func closeSelectedSessionAndSelectNeighbor() {
    // ⌘W with a note focused just closes the note editor (non-destructive).
    if selectedNote != nil {
      selection = nil
      return
    }
    guard let session = selectedSession else { return }
    let section = sectionSessions(containing: session)
    let index = section.firstIndex { $0.id == session.id } ?? 0
    let wasOnly = section.count == 1
    
    if case .screen(let info) = kind(of: session) {
      closeScreenSession(info)
    } else {
      removeSession(session.id)
    }
    
    let remaining = sectionSessions(containing: session)
    if wasOnly || remaining.isEmpty {
      newSession(inSameSectionAs: session)
    } else if index > 0 {
      selection = remaining[index - 1].id
    } else {
      selection = remaining[0].id
    }
  }
  
  /// The id of the running session for a connection, if any.
  func sessionID(for config: SSHConfig) -> UUID? {
    sessions.first { kind(of: $0).sshConfigID == config.id }?.id
  }
  
  /// The open terminal attached to a screen session, if any. Screen
  /// sessions are identified by their "pid.name" spec.
  func attachedSession(toScreen info: ScreenSessionInfo) -> TerminalSession? {
    sessions.first { session in
      if case .screen(let attached) = kind(of: session) {
        return attached.name == info.name
      }
      return false
    }
  }
  
  /// Creates a new persistent session (tmux when installed, else screen)
  /// and immediately opens a terminal attached to it, so the new session
  /// is usable at once.
  func createScreenSession() {
    screenMonitor.createSession { [weak self] info in
      self?.attach(toScreen: info)
    }
  }

  /// Closes a persistent session for good: quits it on the machine via
  /// `screen -S <name> -X quit` / `tmux kill-session -t <name>` (which
  /// kills every attached client, including our own), then removes the
  /// app-side terminals attached to it.
  func closeScreenSession(_ info: ScreenSessionInfo) {
    screenMonitor.quit(info)
    let attached = sessions.filter { session in
      if case .screen(let attached) = kind(of: session) {
        return attached.name == info.name
      }
      return false
    }
    for session in attached {
      removeSession(session.id)
    }
  }
  
  func deleteConnection(_ config: SSHConfig) {
    connectionStore.remove(config.id)
    connections.removeAll { $0.id == config.id }
    let toRemove = sessions.filter { kind(of: $0).sshConfigID == config.id }
    for session in toRemove {
      removeSession(session.id)
    }
    if selection == config.id {
      selection = sessions.last?.id
    }
    SSHKeychain.deletePassword(account: config.passwordAccount)
  }
  
  // MARK: - Public keys
  
  /// The Secure Enclave key for an identity (creates it on first use).
  private func key(for identity: SSHKeychain.Identity) throws -> SecureEnclave.P256.Signing.PrivateKey {
    switch identity {
    case .default:
      return try SSHKeychain.loadOrCreateDefaultKey()
    case .sensitive:
      return try SSHKeychain.loadOrCreateSensitiveKey()
    }
  }
  
  /// Copies a Secure Enclave key's public key (OpenSSH authorized_keys
  /// line) to the pasteboard. Generates the key on first use.
  func copyPublicKey(_ identity: SSHKeychain.Identity = .default) {
    do {
      let key = try key(for: identity)
      let host = Host.current().localizedName ?? "Mac"
      let comment = "Shell (\(NSUserName())@\(host))"
      let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: comment)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(line, forType: .string)
    } catch {
      publicKeyError = error.localizedDescription
    }
  }
  
  func publicKeyFingerprint(for identity: SSHKeychain.Identity = .default) -> String? {
    guard let key = try? key(for: identity) else { return nil }
    return SSHKeychain.publicKeyFingerprint(for: key)
  }
  
  // MARK: - Notes
  
  /// Creates a new note and focuses it in the main view.
  @discardableResult
  func newNote() -> NotesStore.Note {
    let note = notes.addNote()
    selection = note.id
    return note
  }

  /// Deletes a note (and its file); selects the previous note when the
  /// deleted one was focused.
  func deleteNote(_ id: UUID) {
    notes.deleteNote(id)
    if selection == id {
      selection = notes.notes.last?.id
    }
  }

  // MARK: - Local history and command transcripts

  func toggleHistoryMode() {
    if historyMode {
      historyMode = false
      if let previous = selectionBeforeHistory,
         sessions.contains(where: { $0.id == previous }) {
        selection = previous
      } else {
        selection = sessions.first { kind(of: $0) == .local }?.id ?? sessions.last?.id
      }
      selectionBeforeHistory = nil
    } else {
      if selectedSession != nil { selectionBeforeHistory = selection }
      historyMode = true
      selection = history.sessions.first?.id
    }
  }

  func deleteHistorySession(_ id: UUID) {
    history.remove(id)
    if selection == id { selection = history.sessions.first?.id }
  }

  func deleteAllHistory() {
    history.removeAll()
    if historyMode { selection = nil }
  }

  func replayHistorySession(_ record: HistorySession) {
    if historyMode { toggleHistoryMode() }
    let session = addLocalTerminal()
    DispatchQueue.main.async {
      for command in record.commands {
        session.submitCommand(command.text)
      }
    }
  }

  func createAction(from record: HistorySession) {
    createAction(commands: record.commands.map(\.text).joined(separator: "\n"))
  }

  func createActionFromCurrentSession() {
    guard let session = selectedSession,
          let commands = sessionCommands[session.id],
          !commands.isEmpty
    else { return }
    createAction(commands: commands.map(\.text).joined(separator: "\n"), from: session)
  }

  var canCreateActionFromCurrentSession: Bool {
    guard let session = selectedSession else { return false }
    return sessionCommands[session.id]?.isEmpty == false
  }

  func flushForTermination() {
    notes.flush()
    let localIDs = sessions.filter { kind(of: $0) == .local }.map(\.id)
    for id in localIDs { archiveLocalSession(id) }
    history.flush()
  }

  private func registerCapture(for session: TerminalSession, archiveLocally: Bool) {
    sessionCommands[session.id] = []
    if archiveLocally {
      localHistoryDrafts[session.id] = LocalHistoryDraft(output: session.snapshot.fullPlainText)
    }

    session.commandSubmittedHandler = { [weak self] text in
      guard let self else { return }
      let command = SubmittedCommand(text: text)
      self.sessionCommands[session.id, default: []].append(command)
      if archiveLocally {
        self.localHistoryDrafts[session.id]?.commands.append(command)
      }
    }
    session.snapshotUpdateHandler = { [weak self] snapshot in
      guard archiveLocally else { return }
      self?.localHistoryDrafts[session.id]?.output = snapshot.fullPlainText
    }
  }

  private func archiveLocalSession(_ id: UUID) {
    guard let draft = localHistoryDrafts.removeValue(forKey: id),
          !draft.commands.isEmpty
    else { return }
    history.archive(HistorySession(
      id: id,
      commands: draft.commands,
      output: draft.output,
      archivedAt: Date()
    ))
  }
  
  // MARK: - Actions
  
  /// Runs `action` by opening a separate terminal session in the selected
  /// session's environment (the local machine, or the same SSH host).
  func runAction(_ action: Action) {
    guard let session = selectedSession else { return }
    actions.touch(action.id)
    let spec: ActionSpec
    switch kind(of: session) {
    case .local, .screen:
      spec = ActionSpec(action: action, config: nil)
    case .ssh(let config):
      spec = ActionSpec(action: action, config: config)
    case .action:
      // Running an action from an action session falls back to local.
      spec = ActionSpec(action: action, config: nil)
    }
    // The transport picks the environment: a fresh SSH exec channel for
    // remote actions, a local zsh -lc pty for local ones.
    let transport: any TerminalTransport
    let startupMessage: String?
    if let config = spec.config {
      transport = SSHSession(config: config, execCommand: spec.action.commands)
      startupMessage = "Connecting to \(config.host)…"
    } else {
      transport = LocalPTYTransport(executable: "/bin/zsh", argv: ["zsh", "-lc", spec.action.commands])
      startupMessage = nil
    }
    let newSession = TerminalSession(transport: transport, startupMessage: startupMessage)
    sessionKinds[newSession.id] = .action(spec)
    registerCapture(for: newSession, archiveLocally: false)
    newSession.actionCompletionHandler = { [weak self] in
      self?.actionSessionCompleted(newSession)
    }
    sessions.append(newSession)
    if action.focusWindow {
      selection = newSession.id
      showingActions = false   // you're looking at the run now
    }
    // focusWindow == false: the overlay stays open for queuing more runs.
  }

  /// Clean exit (0): let the ✓ read for ~2s, then close + remove the row
  /// ("disappear on completion"). Non-zero / no status / connection
  /// failure: the row stays until the user dismisses it.
  func actionSessionCompleted(_ session: TerminalSession) {
    guard session.actionExitCode == 0 else { return }
    guard modelAction(for: session)?.keepAfterCompletion != true else { return }
    let id = session.id
    Task { try? await Task.sleep(for: .seconds(2)); removeSession(id) }
  }

  private func modelAction(for session: TerminalSession) -> Action? {
    actionSpec(for: session)?.action
  }

  /// The action sessions shown in the sidebar's Running section.
  var actionSessions: [TerminalSession] {
    sessions.filter { if case .action = kind(of: $0) { return true }; return false }
  }
  
  // MARK: - Reordering
  
  /// Moves an SSH connection within the sidebar list and persists the
  /// new order (drag-to-reorder).
  func moveConnection(from source: IndexSet, to destination: Int) {
    connections.move(fromOffsets: source, toOffset: destination)
    connectionStore.reorder(connections)
  }
}
