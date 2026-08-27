#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreData
import Crypto
import Foundation
import SwiftData
import SwiftUI
import Terminal
import TerminalIntegrations

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
  /// Scans GNU screen/tmux sessions on the currently-connected SSH hosts and
  /// publishes them (tagged with their remote origin) so the sidebar can show
  /// remote persistent rows alongside the local ones.
  var remoteScreenScanner = RemoteScreenSessionsScanner()
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
  /// The ⌘E "insert into terminal" overlay.
  var showingCommandInsert = false
  /// The action being edited in the sheet (nil = creating a new one).
  var editingAction: Action?
  var newActionCommands = ""
  var newActionTargetSSHConnectionID: UUID?

  // MARK: - Theme settings (persisted)

  /// UserDefaults keys for the theme settings (non-sensitive UI prefs).
  private static let appearanceModeKey = "appearanceMode"
  private static let disableTerminalBackgroundsKey = "disableTerminalBackgrounds"

  /// Forced color scheme for the whole window (see `appearanceMode.colorScheme`).
  var appearanceMode: AppearanceMode {
    didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey) }
  }

  /// When true, terminals stop drawing character backgrounds and replace
  /// low-contrast foreground colors with the default text color.
  var disableTerminalBackgrounds: Bool {
    didSet { UserDefaults.standard.set(disableTerminalBackgrounds, forKey: Self.disableTerminalBackgroundsKey) }
  }

  /// The Themes sheet (Shell menu: Themes… ⌘⇧H).
  var showingThemes = false

  /// App-side kind per session id (the library session is transport-based
  /// and kind-agnostic). Written when a session is created, removed on
  /// removal — every session in `sessions` has an entry.
  private var sessionKinds: [UUID: ConnectionKind] = [:]
  private var sessionCommands: [UUID: [SubmittedCommand]] = [:]
  private var localHistoryDrafts: [UUID: LocalHistoryDraft] = [:]
  private var selectionBeforeHistory: UUID?
  /// Observation token for CloudKit remote-change notifications (kept so
  /// the observer can be torn down; AppModel is a singleton, so it lives
  /// for the process).
  private var cloudKitChangeObserver: NSObjectProtocol?
  /// Coalesces CloudKit remote-change bursts into a single store refresh.
  /// Remote-change notifications fire in tight bursts while the CloudKit
  /// mirror is working (each import polls our stores), and also on every
  /// local write — refreshing once per notification is redundant main-thread
  /// re-fetch work on top of the framework's own export loop.
  private var cloudKitRefreshTask: Task<Void, Never>?
  /// How long a remote-change burst is coalesced before one refresh runs.
  private static let cloudKitRefreshCoalesceDelay: Duration = .milliseconds(400)

  #if os(macOS)
  /// Project detection over the active directory (Swift/Xcode integrations),
  /// driving the toolbar's smart-action Run/Stop controls. Availability is
  /// probed once at startup; per-directory results are encrypted-cached.
  let smartActions = SmartActionsCoordinator(
    integrations: [
      XcodeIntegration(isAvailable: false),
      SwiftIntegration(isAvailable: false),
    ],
    cacheStore: SmartActionsStore()
  )
  /// The smart actions for the active directory (refreshed on directory change).
  private(set) var smartActionActions: [IntegrationAction] = []
  /// The directory `smartActionActions` was computed for (nil = none active).
  private(set) var smartActionDirectory: URL?
  /// The "Open With" apps offered for the active directory (empty = none,
  /// e.g. no local terminal selected). Computed alongside the smart actions.
  private(set) var openWithKinds: [OpenWithKind] = []
  /// Monotonic counter bumped on every `refreshSmartActions` call (including
  /// clears) so an in-flight background scan from a previous directory is
  /// discarded as stale instead of overwriting newer results.
  private var smartActionsGeneration = 0
  /// In-memory display state per canonical directory path, published
  /// synchronously when a session switch revisits the directory — avoids
  /// waiting on the encrypted cache read (Secure Enclave round-trip) that
  /// makes the toolbar actions pop in late. Every background refresh
  /// revalidates (and replaces) the memoized result.
  private var smartActionResultMemo: [String: SmartActionResult] = [:]
  /// The currently running smart-action session per canonical directory path.
  /// One per directory — a new Run replaces it (stop first), Stop kills it.
  private var currentSmartActionByDirectory: [String: TerminalSession] = [:]
  /// Memoized smart-action display state for one directory (actions plus the
  /// matching "Open With" apps).
  private struct SmartActionResult {
    let actions: [IntegrationAction]
    let openKinds: [OpenWithKind]
  }
  #endif

  private struct LocalHistoryDraft {
    var commands: [SubmittedCommand] = []
    /// Scrollback text captured so far, followed by the last grid segment.
    /// The scrollback part is appended incrementally (`capturedScrollback`
    /// tracks how many rows are already converted); the grid part is
    /// replaced wholesale per publish (it is only one screen).
    var output = ""
    /// Number of scrollback rows already converted into `output`.
    var capturedScrollback = 0
    /// The snapshot epoch the captured text is valid against. Wholesale
    /// invalidation (alt-screen switch, full clear, RIS, Cmd+K) replaces
    /// the text with a full rebuild; ordinary output appends incrementally.
    var capturedEpoch = 0
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
    appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.appearanceModeKey) ?? "") ?? .system
    disableTerminalBackgrounds = UserDefaults.standard.bool(forKey: Self.disableTerminalBackgroundsKey)
    connectionStore = SSHConfigStore(container: Self.sharedSSHContainer)
    deviceKeys = DeviceKeyStore(container: Self.sharedSSHContainer)
    notes = NotesStore(stores: Self.notesStores)
    // Publish this device's identity key to iCloud (no-op when the Secure
    // Enclave key is unreachable, e.g. locked screen — retried when the
    // authorized-keys panel opens).
    deviceKeys.publishThisDevice()
    observeCloudKitRemoteChanges()
    #if os(macOS)
    // Probe toolchains (xcodebuild/swift) once so integrations know their
    // availability for the whole process.
    smartActions.probeEnvironment()
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
      return defaultLocalName(for: session)
    case .screen(let info):
      return info.name
    case .action(let spec):
      return spec.action.name
    case .ssh(let config):
      let number = (sessions(for: config).firstIndex { $0.id == session.id } ?? 0) + 1
      return "\(config.displayName) #\(number)"
    }
  }

  /// Default name for a local terminal: the basename of the directory the
  /// shell currently sits in (follows `cd`, like the window subtitle),
  /// so a terminal opened in a project reads as its folder. Falls back
  /// to "Local" while no child/cwd is available (starting, closed,
  /// unmounted root) — the pre-existing label.
  private func defaultLocalName(for session: TerminalSession) -> String {
    guard
      let directory = session.currentDirectory,
      directory.path != "/"
    else { return "Local" }
    return directory.lastPathComponent
  }
  
  // MARK: - Insert into terminal (⌘E)

  /// Sends `text` into `session`'s output stream (written to the child's
  /// input, echoed to stdout). With `sendAsSeparateCommands` (default
  /// true), newlines are translated to carriage returns so a multi-line
  /// paste runs each line in the shell. With it false, newlines go through
  /// as literal `\n` — the text is pasted verbatim.
  func insertCommandText(_ text: String, into session: TerminalSession, sendAsSeparateCommands: Bool = true) {
    guard !text.isEmpty else { return }
    let translated = sendAsSeparateCommands
      ? text.replacingOccurrences(of: "\n", with: "\r")
      : text
    session.send(translated)
  }

  // MARK: - Sessions
  
  #if os(macOS)
  @discardableResult
  func addLocalTerminal(in directory: String? = nil) -> TerminalSession {
    if historyMode {
      historyMode = false
      selectionBeforeHistory = nil
    }
    // `directory` (⌘T) starts the shell there instead of in the home
    // directory; nil keeps the default home-dir launch.
    let session = TerminalSession(session: directory.map { .zsh(in: $0) } ?? .zsh)
    sessionKinds[session.id] = .local
    registerCapture(for: session, archiveLocally: true)
    sessions.append(session)
    selection = session.id
    return session
  }
  #endif

  #if os(macOS)
  /// ⌘T: opens a new local terminal whose shell starts in the SAME
  /// directory as the selected session's current working directory.
  /// Falls back to a plain local terminal (home dir) when the selected
  /// session has no local cwd (SSH/action/screen, or still starting).
  @discardableResult
  func openTerminalInSameDirectoryAsSelected() -> TerminalSession {
    guard
      let session = selectedSession,
      let directory = session.currentDirectory?.path
    else {
      return addLocalTerminal()
    }
    return addLocalTerminal(in: directory)
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
    #if os(macOS)
    // Kick a remote scan on connect. The just-created session isn't
    // `.connected` yet, so it's skipped this pass; every already-connected
    // host is scanned, and the next refresh (or the connected-state refresh
    // the sidebar triggers) picks the new host up.
    refreshRemoteScreenSessions()
    #endif
    return session
  }

  #if os(macOS)
  /// The SSH sessions that are currently open (kind `.ssh` AND
  /// `connectionState == .connected`). This is the ONLY set the remote
  /// persistent-session scanner iterates — it never dials a connection from a
  /// saved (possibly disconnected) config (confirmed scope decision 3).
  var connectedSSHSessions: [TerminalSession] {
    sessions.filter { session in
      guard case .ssh = kind(of: session) else { return false }
      return session.connectionState == .connected
    }
  }

  /// The remote persistent session rows scanned from currently-connected SSH
  /// connections (empty until a scan). The sidebar renders these in the
  /// merged Local section.
  var remoteScreenSessions: [ScreenSessionInfo] {
    remoteScreenScanner.sessions
  }

  /// Re-scans the connected SSH hosts for screen/tmux sessions. Called when a
  /// connection opens and by the sidebar's remote-refresh control. Safe on the
  /// main thread — each remote exec is scheduled on its connection's NIO
  /// event loop, so the main thread is never blocked.
  func refreshRemoteScreenSessions() {
    remoteScreenScanner.scan(using: self)
  }
  #endif
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

  /// Persists an EDITED connection in place (same id, so the sidebar row
  /// and any running sessions keep referring to the same connection).
  /// Unlike `connect(to:)` it does not open a session.
  func updateConnection(_ config: SSHConfig) {
    connectionStore.save(config)
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
      selection = notes.notes.first?.id
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
      let seed = session.snapshot
      localHistoryDrafts[session.id] = LocalHistoryDraft(
        output: seed.fullPlainText,
        capturedScrollback: seed.scrollback.count,
        capturedEpoch: seed.selectionEpoch
      )
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
      guard let self, var draft = self.localHistoryDrafts[session.id] else { return }
      if snapshot.selectionEpoch != draft.capturedEpoch {
        // Wholesale invalidation (alt-screen switch, full clear, RIS,
        // Cmd+K): the scrollback indices are meaningless now — rebuild
        // the whole text. Rare (epoch bumps only on such events), so the
        // O(scrollback) cost is acceptable here.
        draft.output = snapshot.fullPlainText
        draft.capturedScrollback = snapshot.scrollback.count
        draft.capturedEpoch = snapshot.selectionEpoch
        self.localHistoryDrafts[session.id] = draft
        return
      }
      // Scrollback is append-only: convert only the rows that arrived
      // since the last capture (the O(scrollback) full-text rebuild per
      // output chunk was the CPU amplifier that made history capture cost
      // grow with session age).
      guard snapshot.scrollback.count >= draft.capturedScrollback else {
        // Scrollback was TRUNCATED at the limit: indices shifted, the
        // incremental state is stale — rebuild the whole text.
        draft.output = snapshot.fullPlainText
        draft.capturedScrollback = snapshot.scrollback.count
        self.localHistoryDrafts[session.id] = draft
        return
      }
      let newScrollback = snapshot.scrollbackText(after: draft.capturedScrollback)
      // The visible grid is one screen; replace its segment wholesale
      // (its lines are rewritten in place by cursors — line-index deltas
      // would miss live updates like ping's status line).
      let grid = snapshot.gridText
      var output = ""
      if !newScrollback.isEmpty {
        output = newScrollback
      }
      if !grid.isEmpty {
        if !output.isEmpty { output += "\n" }
        output += grid
      }
      draft.output = output
      draft.capturedScrollback = snapshot.scrollback.count
      self.localHistoryDrafts[session.id] = draft
    }
  }

  /// Action-session capture that archives to history on completion: seeds the
  /// executed command and captures output, so the run lands in History like a
  /// terminal session. Used by both normal actions and smart actions
  /// (history consistency).
  private func registerActionCapture(for session: TerminalSession, seedCommand: String) {
    registerCapture(for: session, archiveLocally: true)
    let submitted = SubmittedCommand(text: seedCommand)
    sessionCommands[session.id] = [submitted]
    localHistoryDrafts[session.id]?.commands = [submitted]
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
  /// session's environment (the local machine, or the same SSH host). With
  /// NO session selected (e.g. nothing is open), defaults to the local
  /// machine so ⌘R stays usable from a fresh start.
  func runAction(_ action: Action) {
    actions.touch(action.id)
    let spec: ActionSpec
    if let session = selectedSession {
      switch kind(of: session) {
      case .local, .screen:
        spec = ActionSpec(action: action, config: nil)
      case .ssh(let config):
        spec = ActionSpec(action: action, config: config)
      case .action:
        // Running an action from an action session falls back to local.
        spec = ActionSpec(action: action, config: nil)
      }
    } else {
      #if os(macOS)
      // Nothing selected (fresh start / nothing open): run locally.
      spec = ActionSpec(action: action, config: nil)
      #else
      // Local actions need a local pty, which iOS doesn't have; the
      // overlay's applicability filter never offers one there anyway.
      return
      #endif
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
    registerActionCapture(for: newSession, seedCommand: spec.action.commands)
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
  /// failure: the row stays until the user dismisses it. Regardless of exit
  /// status, the run is archived to history (consistency with terminals).
  func actionSessionCompleted(_ session: TerminalSession) {
    archiveLocalSession(session.id)
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

  // MARK: - Smart actions

  #if os(macOS)
  /// Recomputes the smart actions for the active local directory. Returns
  /// immediately; the blocking scan (directory listing + integration scan +
  /// cache save) runs off the main thread so a large directory never stalls
  /// the UI. The cache short-circuits unchanged directories. Passing nil
  /// clears them.
  ///
  /// A directory visited before publishes its memoized actions SYNCHRONOUSLY
  /// (the memo is keyed by canonical path and survives session switches), so
  /// switching sessions shows the toolbar controls instantly instead of
  /// waiting on the encrypted cache read. The background refresh still runs
  /// to revalidate the memo.
  func refreshSmartActions(for directory: URL?) {
    smartActionsGeneration += 1
    smartActionDirectory = directory
    guard let directory else {
      smartActionActions = []
      openWithKinds = []
      return
    }
    let canonical = directory.standardizedFileURL
    // First visit: publish nothing yet so the toolbar never shows the
    // previous directory's actions under this one. Revisit: publish the
    // memoized result immediately, then revalidate in the background.
    if let memo = smartActionResultMemo[canonical.path] {
      smartActionActions = memo.actions
      openWithKinds = memo.openKinds
    } else {
      smartActionActions = []
      openWithKinds = []
    }
    let generation = smartActionsGeneration
    let coordinator = smartActions
    Task { @MainActor [weak self] in
      // The coordinator (and the "Open With" resolution) are pure,
      // non-MainActor-bound logic — run them off the main actor, then hop
      // back to publish.
      let result = await Task.detached(priority: .userInitiated) {
        let actions = coordinator.refresh(directory: canonical)
        let entries = IntegrationFileLister.list(directory: canonical)
        let openKinds = OpenWithResolver.kinds(for: entries)
        return (actions: actions, openKinds: openKinds)
      }.value
      guard let self, self.smartActionsGeneration == generation else { return }
      let memo = SmartActionResult(actions: result.actions, openKinds: result.openKinds)
      self.smartActionResultMemo[canonical.path] = memo
      self.smartActionActions = memo.actions
      self.openWithKinds = memo.openKinds
    }
  }

  /// The currently running smart-action session for a directory, if any.
  func currentSmartAction(in directory: URL) -> TerminalSession? {
    currentSmartActionByDirectory[directory.standardizedFileURL.path]
  }

  /// Whether a specific smart action is currently running in `directory`
  /// (gates the toolbar control's stop.fill state).
  func isSmartActionRunning(_ actionID: UUID, in directory: URL) -> Bool {
    guard let session = currentSmartAction(in: directory),
          case .action(let spec) = kind(of: session) else { return false }
    return spec.action.id == actionID
  }

  /// Runs a smart action as a Running-section session in `directory` with no
  /// focus. Replaces any current run for that directory (stops it first);
  /// archives to history on completion via `actionSessionCompleted`.
  func runSmartAction(_ action: IntegrationAction, in directory: URL) {
    // Replace semantics: stop the current run for this dir before starting.
    stopSmartAction(in: directory)

    // LocalPTYTransport has no working-dir parameter, so cd into the project.
    let command = "cd \(shellQuote(directory.path)) && \(action.command)"
    let spec = ActionSpec(
      action: Action(
        id: action.id,
        name: action.title,
        appliesToLocal: true,
        commands: command,
        focusWindow: false,
        keepAfterCompletion: false
      ),
      config: nil
    )
    let transport = LocalPTYTransport(executable: "/bin/zsh", argv: ["zsh", "-lc", command])
    let newSession = TerminalSession(transport: transport)
    sessionKinds[newSession.id] = .action(spec)
    registerActionCapture(for: newSession, seedCommand: command)
    currentSmartActionByDirectory[directory.standardizedFileURL.path] = newSession
    newSession.actionCompletionHandler = { [weak self, weak newSession] in
      guard let self, let newSession else { return }
      self.currentSmartActionByDirectory[directory.standardizedFileURL.path] = nil
      self.actionSessionCompleted(newSession)
    }
    sessions.append(newSession)
    // No focus: the run stays in Running, the user's selection is unchanged.
  }

  /// Terminates the running smart-action session for a directory (no-op when
  /// none is running).
  func stopSmartAction(in directory: URL) {
    guard let session = currentSmartActionByDirectory.removeValue(
      forKey: directory.standardizedFileURL.path
    ) else { return }
    session.close()
  }

  private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
  #endif

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

  /// Re-fetches the stores whenever the CloudKit mirror imports remote
  /// changes (the CoreData `NSPersistentStoreRemoteChange` notification;
  /// SwiftData's CloudKit stores post it through their persistent store
  /// coordinator). This is what makes FIRST LAUNCH self-heal: init's
  /// reload runs before CloudKit has delivered anything, and the launch-time
  /// scene activation is deliberately skipped, so without this the sidebar
  /// stays empty until the next activation or restart. It also surfaces
  /// cross-device edits while the app runs (belt-and-braces on top of the
  /// scene-activation refresh).
  private func observeCloudKitRemoteChanges() {
    cloudKitChangeObserver = NotificationCenter.default.addObserver(
      forName: .NSPersistentStoreRemoteChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // `queue: .main` runs this on the main queue, but the closure is still
      // nonisolated to the compiler — hop to the main actor to refresh.
      Task { @MainActor [weak self] in
        self?.scheduleCloudKitRefresh()
      }
    }
  }

  /// Debounces a store refresh: cancels any pending one and schedules a
  /// single refresh shortly after the last trigger. A burst of remote-change
  /// notifications (and the app's own writes, which also fire them) becomes
  /// one re-fetch instead of N.
  private func scheduleCloudKitRefresh() {
    cloudKitRefreshTask?.cancel()
    cloudKitRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.cloudKitRefreshCoalesceDelay)
      guard !Task.isCancelled else { return }
      self?.refreshOnActivation()
    }
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
