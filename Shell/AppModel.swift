#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Crypto
import Foundation
import SwiftData
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
  
  #if os(macOS)
  /// Polls `screen -ls` for the sidebar's Screen section.
  var screenMonitor = ScreenSessionsMonitor()
  #endif

  /// The sidebar's encrypted Notes list (SwiftData-backed, lazy decryption).
  var notes: NotesStore

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
  
  private let connectionStore: SSHConfigStore
  /// Observable source of truth for saved SSH rows. Computed from the
  /// store so saves/reloads (including iCloud sync refreshes) flow through
  /// Observation automatically.
  var connections: [SSHConfig] { connectionStore.all }

  /// The iCloud registry of every device's public key (this device
  /// publishes on launch; other devices' keys power the authorized-keys
  /// panel).
  var deviceKeys: DeviceKeyStore
  /// The authorized-keys panel (key.2.on.ring button in the sidebar).
  var showingAuthorizedKeys = false
  var authorizedKeysTarget: AuthorizedKeysManager.Target?
  /// Message when the panel can't be opened (e.g. no SSH connections).
  var authorizedKeysError: String?

  /// ONE container for both the SSH-config and device-key stores (the
  /// SwiftData hosted-runner instability scales with container churn, so
  /// the app deliberately keeps the container count low). Falls back to a
  /// plain local store when CloudKit setup fails.
  private static let sharedSSHContainer: ModelContainer = {
    (try? SSHConfigStore.makeContainer()) ?? {
      // swiftlint:disable:next force_try
      try! ModelContainer(
        for: SSHConfigRecord.self, DeviceKeyRecord.self,
        configurations: ModelConfiguration("SSHConfigs", cloudKitDatabase: .none)
      )
    }()
  }()

  /// The notes' two containers. Built in a `static let` closure — NOT
  /// inside an init: containers created inside an @Observable init trap
  /// on their first insert (silent SIGTRAP at `localContext.insert`;
  /// probe-verified — the old `NotesStore()` factory path crashed while
  /// the injected `NotesStore(stores:)` path always worked).
  private static let notesStores: NoteStores = {
    if let made = try? NoteStores.make() { return made }
    // Store setup failed — degrade to two plain local stores rather than
    // crash. Plain SQLite stores are effectively infallible.
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Shell", isDirectory: true)
    // swiftlint:disable:next force_try
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let local = try! ModelContainer(
      for: NoteRecord.self,
      configurations: ModelConfiguration(
        "LocalNotes",
        url: dir.appendingPathComponent("LocalNotes.store"),
        cloudKitDatabase: .none
      )
    )
    let cloud = try! ModelContainer(
      for: NoteRecord.self,
      configurations: ModelConfiguration(
        "CloudNotes",
        url: dir.appendingPathComponent("CloudNotes.store"),
        cloudKitDatabase: .none
      )
    )
    return NoteStores(local: local, cloud: cloud)
  }()

  private init() {
    connectionStore = SSHConfigStore(container: Self.sharedSSHContainer)
    deviceKeys = DeviceKeyStore(container: Self.sharedSSHContainer)
    notes = NotesStore(stores: Self.notesStores)
    // Publish this device's identity key to iCloud (no-op when the Secure
    // Enclave key is unreachable, e.g. locked screen — retried when the
    // authorized-keys panel opens).
    deviceKeys.publishThisDevice()
    #if os(macOS)
    // Start with a local terminal so the window is never empty. iOS has no
    // local terminals — it starts with just the sidebar (SSH + notes).
    _ = addLocalTerminal()
    #endif
  }
  
  var selectedSession: TerminalSession? {
    sessions.first { $0.id == selection }
  }

  /// The note currently focused in the main view, if any. Shares the
  /// sidebar selection with sessions (note ids are distinct UUIDs, so
  /// row tags never collide).
  var selectedNote: NotesStore.NoteSummary? {
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
  
  #if os(macOS)
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
  #endif
  
  @discardableResult
  func connect(to config: SSHConfig) -> TerminalSession {
    connectionStore.save(config)
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
  
  #if os(macOS)
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
  #endif
  
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
      #if os(macOS)
      return screenMonitor.sessions.compactMap { attachedSession(toScreen: $0) }
      #else
      return []
      #endif
    case .ssh:
      return connections.flatMap { sessions(for: $0) }
    case .action:
      return sessions.filter { if case .action = kind(of: $0) { return true }; return false }
    }
  }
  
  /// Creates a new session in the same section as `session`: a local
  /// terminal for local, a duplicate connection for SSH, a brand-new
  /// persistent session for screen.
  #if os(macOS)
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
  #else
  @discardableResult
  func newSession(inSameSectionAs session: TerminalSession) -> TerminalSession? {
    // iOS: no local terminals — SSH sessions duplicate their connection,
    // anything else opens the New Connection sheet.
    switch kind(of: session) {
    case .ssh(let config):
      return connect(to: config)
    default:
      showingNewConnection = true
      return selectedSession
    }
  }
  #endif

  /// ⌘N: new session in the same section as the current selection
  /// (new local terminal when nothing is selected).
  #if os(macOS)
  @discardableResult
  func newSessionInSameSection() -> TerminalSession {
    if let session = selectedSession {
      return newSession(inSameSectionAs: session)
    }
    return addLocalTerminal()
  }
  #else
  @discardableResult
  func newSessionInSameSection() -> TerminalSession? {
    if let session = selectedSession {
      return newSession(inSameSectionAs: session)
    }
    showingNewConnection = true
    return nil
  }
  #endif
  
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
      #if os(macOS)
      closeScreenSession(info)
      #else
      removeSession(session.id)
      #endif
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
  
  #if os(macOS)
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
  #endif
  
  func deleteConnection(_ config: SSHConfig) {
    connectionStore.remove(config.id)
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
  
  /// Copies the Secure Enclave key's public key (OpenSSH authorized_keys
  /// line) to the pasteboard. Generates the key on first use.
  func copyPublicKey() {
    do {
      let key = try SSHKeychain.loadOrCreateDefaultKey()
      #if os(macOS)
      let host = Host.current().localizedName ?? "Mac"
      #else
      let host = UIDevice.current.name
      #endif
      let comment = "Shell (\(NSUserName())@\(host))"
      let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: comment)
      #if os(macOS)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(line, forType: .string)
      #else
      UIPasteboard.general.string = line
      #endif
    } catch {
      publicKeyError = error.localizedDescription
    }
  }
  
  func publicKeyFingerprint() -> String? {
    guard let key = try? SSHKeychain.loadOrCreateDefaultKey() else { return nil }
    return SSHKeychain.publicKeyFingerprint(for: key)
  }
  
  // MARK: - Notes
  
  /// Creates a new note and focuses it in the main view.
  @discardableResult
  func newNote() -> NotesStore.NoteSummary {
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
    // Deleting the last record while viewing history would leave an empty
    // list with no way back (the history button hides when empty).
    if historyMode && history.sessions.isEmpty { toggleHistoryMode() }
  }

  func deleteAllHistory() {
    history.removeAll()
    if historyMode { toggleHistoryMode() }
  }

  func replayHistorySession(_ record: HistorySession) {
    if historyMode { toggleHistoryMode() }
    #if os(macOS)
    let session = addLocalTerminal()
    DispatchQueue.main.async {
      for command in record.commands {
        session.submitCommand(command.text)
      }
    }
    #else
    // Replay needs a local pty (macOS only); iOS just drops back to the
    // session list. The history row's replay button is hidden on iOS.
    #endif
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
      #if os(macOS)
      transport = LocalPTYTransport(executable: "/bin/zsh", argv: ["zsh", "-lc", spec.action.commands])
      startupMessage = nil
      #else
      // Local actions need a local pty, which iOS doesn't have. This
      // branch is unreachable on iOS: the actions overlay's applicability
      // filter never offers a local action (no local/screen sessions).
      preconditionFailure("Local actions require a local pty (macOS only)")
      #endif
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
    var reordered = connections
    reordered.move(fromOffsets: source, toOffset: destination)
    connectionStore.reorder(reordered)
  }

  // MARK: - Authorized keys

  /// Opens the authorized-keys panel for a target machine.
  func showAuthorizedKeys(for target: AuthorizedKeysManager.Target) {
    authorizedKeysTarget = target
    showingAuthorizedKeys = true
  }

  /// The Local section's key-ring button: this Mac's authorized_keys.
  func openLocalAuthorizedKeys() {
    showAuthorizedKeys(for: .local)
  }

  /// The Remote section's key-ring button: the selected SSH connection's
  /// authorized_keys (falls back to the first saved connection).
  func openRemoteAuthorizedKeys() {
    guard let config = connections.first(where: { $0.id == selection }) ?? connections.first else {
      authorizedKeysError = "Add an SSH connection first, then manage its authorized keys."
      return
    }
    showAuthorizedKeys(for: .ssh(config))
  }

  /// Sync trigger for the no-push stores (notes + SSH configs): re-fetch
  /// whatever CloudKit pulled while the app ran. Called when the scene
  /// becomes active; the launch-time activation is skipped in ContentView.
  func refreshOnActivation() {
    notes.refreshOnActivation()
    connectionStore.refreshOnActivation()
    deviceKeys.refreshOnActivation()
  }
}
