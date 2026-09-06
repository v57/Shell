#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreData
import CryptoKit
import Foundation
import Observation
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
  
  /// The feature-flag source of truth. Background surfaces and probes read
  /// `isEnabled(_:)` from here so a disabled feature never spawns work.
  private var features: FeatureFlagsStore { .shared }
  
  var sessions: [TerminalSession] = []
  var selection: UUID?
  /// The directory browser (Files panel) model, driven by the selected
  /// session. Shared so both ContentView and ShellCommands can drive it.
  let directoryBrowser = DirectoryBrowserModel()
  var showingNewConnection = false
  /// The New Web Session sheet (Local/Remote header "+").
  var showingNewWebSession = false
  /// The web session being edited in the sheet (nil = creating a new one).
  var editingWebSession: WebSession?
  /// The New Database Connection sheet (Database section header "+").
  var showingNewDatabaseConnection = false
  /// The database connection being edited in the sheet (nil = creating).
  var editingDatabaseConnection: DatabaseConnection?
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

  #if os(macOS)
  /// Transient, scratch opened-file documents (the sidebar "Text Files"
  /// section), edited in the content area. NOT persisted — cleared on app
  /// restart and when a file is closed via ⌘W. Kept entirely separate from
  /// `NotesStore` (an opened file is a scratch view, not a Notes item). See
  /// `OpenFilePane.swift`.
  private(set) var openedFiles: [OpenedFile] = []
  /// Monotonic guard so a stale off-main load can never overwrite newer
  /// content (bumped on every `openFile` call, including clears).
  private var openFileGeneration = 0
  /// A dirty file awaiting a Save / Don't-Save decision on close (⌘W). The
  /// selected dirty `OpenFilePane` surfaces it as a confirmation dialog.
  var pendingCloseOpenedFile: UUID?
  #endif

  /// The sidebar's saved Actions (UserDefaults-backed).
  var actions = ActionsStore()
  /// The sidebar's saved web sessions (UserDefaults-backed).
  var webSessions = WebSessionStore()
  /// The live SSH-tunnel runtimes for OPEN ssh-owned web sessions, keyed by
  /// web session id. Created on connect (openWebSession), stopped and removed
  /// on teardown (removeSession). Plain web sessions have no entry.
  private(set) var webSessionRuntimes: [UUID: WebSessionRuntime] = [:]
  /// Encrypted local-session history. Active captures remain in memory until
  /// their terminal closes or the app terminates.
  var history = HistoryStore()
  var historyMode = false
  /// The actions overlay (⌘R) and the New Action sheet.
  var showingActions = false
  var showingNewAction = false
  /// The Settings overlay (opened like the Actions overlay, not a separate
  /// window or sheet — see SettingsOverlayView).
  var showingSettings = false
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

  /// Ids of sessions and notes currently presented in their own detached
  /// window/scene (macOS `WindowGroup` id "detach", or a separate iPad scene).
  /// Mutated by detach/reattach and published via @Observable, so
  /// ContentView/SidebarView re-render when an item is detached or returned.
  var detachedIDs: Set<UUID> = []

  #if os(macOS)
  /// The app's primary window (the one hosting ContentView). The ⌘W key
  /// monitor uses it to route Window-close to session-close on the main window
  /// while letting detached-item windows close normally. Captured in
  /// ContentView.onAppear; nil until the main window has appeared.
  weak var mainWindow: NSWindow?
  #endif

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
  /// Whether the Notes store is currently backed by the CloudKit container
  /// (`.notes` on) versus a local-only store (`.notes` off). Used to detect
  /// the ON↔OFF transition in the feature-flag reactivity so the store and
  /// its observer are only swapped when the flag actually flips (reactivity
  /// re-arms on every observed flag change).
  private var notesFeatureEnabled = false
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
  /// Whether `probeEnvironment()` has already run. Guards the one-time probe
  /// so it runs only while the Smart Actions feature is enabled (and re-runs
  /// on the OFF→ON transition, never repeatedly).
  private var smartActionsProbed = false
  /// The Smart Actions flag value at the last reactivity pass. Tracks the
  /// ON↔OFF transition so a flip re-runs `refreshSmartActions` — clearing the
  /// toolbar instantly on OFF and repopulating it on ON, without requiring a
  /// session switch.
  private var smartActionsEnabled = false
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
      case .web(let web):
        newActionTargetSSHConnectionID = web.sshConfigID
      case .database(let connection):
        // A database session has no shell/SSH to run an action in.
        newActionTargetSSHConnectionID = connection.sshConfigID
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

  /// Persists the sidebar's saved database connections (SwiftData, shared
  /// container, encrypted — mirrors SSHConfigStore). Cheap `@Observable`
  /// accessor so SidebarView re-renders on save/reload.
  private let databaseStore: DatabaseConnectionStore
  var databaseConnections: [DatabaseConnection] { databaseStore.all }
  /// Live engine sessions keyed by database-connection id. Created on open,
  /// torn down on close/delete. Backs the DatabaseBrowserView.
  private(set) var databaseSessions: [UUID: DatabaseSession] = [:]

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
        for: SSHConfigRecord.self, DeviceKeyRecord.self, DatabaseConnectionRecord.self,
        configurations: ModelConfiguration("SSHConfigs", cloudKitDatabase: .none)
      )
    }()
  }()

  /// The notes' two containers (local + CloudKit cloud), built in a
  /// `static let` closure — NOT inside an init: containers created inside an
  /// @Observable init trap on their first insert (silent SIGTRAP at
  /// `localContext.insert`; probe-verified — the old `NotesStore()` factory
  /// path crashed while the injected `NotesStore(stores:)` path always
  /// worked). Used when the Notes feature is enabled.
  private static let notesStoresWithCloud: NoteStores = {
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

  /// Local-only notes container, used when the Notes feature is disabled so
  /// NO CloudKit container is loaded (a disabled feature must not run
  /// CloudKit background sync) and the notes store is not observed. Built in
  /// a `static let` closure for the same trap-avoidance reason as above.
  /// Safe: while Notes is off no note-insert path is reachable (the Notes
  /// sidebar and the new-note command are gated), and a NotesStore with a nil
  /// cloud context only SIGTRAPs on its first local *insert* — reload()/fetch
  /// on an empty store does not. The on-disk files are reused unchanged, so
  /// re-enabling restores the prior notes from disk.
  private static let notesStoresLocalOnly: NoteStores = {
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
    return NoteStores(local: local, cloud: nil)
  }()

  private init() {
    appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.appearanceModeKey) ?? "") ?? .system
    disableTerminalBackgrounds = UserDefaults.standard.bool(forKey: Self.disableTerminalBackgroundsKey)
    connectionStore = SSHConfigStore(container: Self.sharedSSHContainer)
    deviceKeys = DeviceKeyStore(container: Self.sharedSSHContainer)
    databaseStore = DatabaseConnectionStore(container: Self.sharedSSHContainer)
    // Notes gating must not read `self` here (stored properties are still
    // being initialized); read the flag first, wire `notes`, then publish it.
    let notesFlag = FeatureFlagsStore.shared.isEnabled(.notes)
    if notesFlag {
      // Notes enabled: load the CloudKit-topped store and observe its
      // remote-change notifications so cross-device edits surface at runtime.
      notes = NotesStore(stores: Self.notesStoresWithCloud)
      observeCloudKitRemoteChanges()
    } else {
      // Notes disabled: build a local-only store so NO CloudKit container is
      // loaded and nothing is observed — a disabled feature must not run
      // CloudKit background sync. The on-disk notes files are reused
      // unchanged, so re-enabling restores the prior notes from disk.
      notes = NotesStore(stores: Self.notesStoresLocalOnly)
    }
    notesFeatureEnabled = notesFlag
    // Publish this device's identity key to iCloud (no-op when the Secure
    // Enclave key is unreachable, e.g. locked screen — retried when the
    // authorized-keys panel opens).
    deviceKeys.publishThisDevice()
    #if os(macOS)
    // Probe toolchains (xcodebuild/swift) only when Smart Actions is enabled
    // — the probe is background work and must not run when the feature is off.
    if features.isEnabled(.smartActions) {
      smartActions.probeEnvironment()
      smartActionsProbed = true
      smartActionsEnabled = true
    }
    // Start (or leave stopped) the Screen feature's pollers to match the flag.
    configureGatedBackgroundWork()
    // React to runtime feature-flag flips (start/stop pollers, re-probe).
    startFeatureFlagReactivity()
    // Start with a local terminal so the window is never empty. iOS has no
    // local terminals — it starts with just the sidebar (SSH + notes).
    _ = addLocalTerminal()
    #endif
  }

  #if os(macOS)
  /// Starts or stops the Screen feature's background pollers to match the
  /// current feature flag. Idempotent; safe to call at any time.
  private func configureGatedBackgroundWork() {
    if features.isEnabled(.screen) {
      screenMonitor.start()
    } else {
      screenMonitor.stop()
    }
  }

  /// Re-applies the gated background configuration whenever any flag we gate
  /// on flips, and re-probes Smart Actions on the OFF→ON transition. Uses
  /// `withObservationTracking` so we do not touch the store's persistence
  /// layer (a dependency); each observed flip re-arms the observation.
  private func startFeatureFlagReactivity() {
    withObservationTracking {
      // Read the flags we gate on so any flip re-arms the observation.
      // `screen` is consumed via configureGatedBackgroundWork().
      _ = features.isEnabled(.screen)
      let smart = features.isEnabled(.smartActions)
      let notes = features.isEnabled(.notes)
      configureGatedBackgroundWork()
      if smart && !smartActionsProbed {
        smartActions.probeEnvironment()
        smartActionsProbed = true
      }
      // Smart Actions ON↔OFF flip: re-run the refresh so the toolbar clears
      // instantly on OFF and repopulates on ON, without a session switch.
      // (refreshSmartActions itself short-circuits to empty when disabled and
      // republishes the memo when enabled.)
      if smart != smartActionsEnabled {
        smartActionsEnabled = smart
        refreshSmartActions(for: smartActionDirectory)
      }
      configureNotesGating(notesEnabled: notes)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.startFeatureFlagReactivity()
      }
    }
  }

  /// Swaps the Notes store to match the `.notes` flag: on loads the
  /// CloudKit-topped store and observes remote changes; off swaps to a
  /// local-only store and stops observing. No-op unless the flag actually
  /// flipped (reactivity re-arms on every observed flag change, so the store
  /// must not be rebuilt every time). Persisted notes files are reused
  /// untouched, so re-enabling restores the prior set from disk.
  private func configureNotesGating(notesEnabled: Bool) {
    guard notesEnabled != notesFeatureEnabled else { return }
    notesFeatureEnabled = notesEnabled
    if notesEnabled {
      notes = NotesStore(stores: Self.notesStoresWithCloud)
      observeCloudKitRemoteChanges()
    } else {
      notes = NotesStore(stores: Self.notesStoresLocalOnly)
      stopObservingCloudKitRemoteChanges()
    }
  }
  #endif

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

  /// The selected session as shown in the MAIN window. A session currently
  /// presented in its own detached window is not shown again in the main
  /// detail (its window owns it); re-attaching (`markAttached`) restores it.
  var mainSelectedSession: TerminalSession? {
    guard let session = selectedSession, !detachedIDs.contains(session.id) else { return nil }
    return session
  }

  /// The selected note as shown in the MAIN window (nil if it is detached).
  var mainSelectedNote: NotesStore.NoteSummary? {
    guard let note = selectedNote, !detachedIDs.contains(note.id) else { return nil }
    return note
  }

  /// The selected history session as shown in the MAIN window (nil if detached).
  var mainSelectedHistorySession: HistorySession? {
    guard let history = selectedHistorySession, !detachedIDs.contains(history.id) else { return nil }
    return history
  }

  #if os(macOS)
  /// The opened-file document currently focused in the main view, if any.
  /// Shares the sidebar selection with sessions and notes (file ids are
  /// distinct UUIDs, so row tags never collide with session/note ids).
  var selectedOpenedFile: OpenedFile? {
    openedFiles.first { $0.id == selection }
  }

  /// The selected opened file as shown in the MAIN window (nil if detached).
  var mainSelectedOpenedFile: OpenedFile? {
    guard let file = selectedOpenedFile, !detachedIDs.contains(file.id) else { return nil }
    return file
  }
  #endif

  // MARK: - Detached windows (macOS + iPad)

  /// Whether `id` is currently presented in its own detached window/scene.
  func isDetached(_ id: UUID) -> Bool { detachedIDs.contains(id) }

  /// Marks `id` as detached (presented in its own window/scene) and republishes.
  func markDetached(_ id: UUID) { detachedIDs.insert(id) }

  /// Returns `id` to the main window (removes it from the detached set).
  func markAttached(_ id: UUID) { detachedIDs.remove(id) }

  /// Flips the detached state for `id`.
  func toggleDetached(_ id: UUID) {
    if detachedIDs.contains(id) { detachedIDs.remove(id) } else { detachedIDs.insert(id) }
  }

  /// Called when a detached window/scene is closed via its own close button
  /// (not the ⌘⇧D toggle or the sidebar return badge). Closing the window
  /// destroys the scene but previously left the id in `detachedIDs`, so the
  /// main window treated the item as still detached while it had no window —
  /// `mainSelectedSession`/`mainSelectedNote` returned nil and the item was
  /// stuck. This returns it to the main window: remove from `detachedIDs` and
  /// select it so it reappears and is focusable. An empty note is deleted
  /// (mirrors the ⌘W close behavior).
  func handleDetachedWindowClosed(_ id: UUID) {
    guard detachedIDs.contains(id) else { return }
    markAttached(id)
    // A detached empty note is deleted just like an empty note closed with
    // ⌘W — look it up by id (not by the current selection, which may have
    // moved on while the detached window was up).
    if let note = notes.notes.first(where: { $0.id == id }), notes.isEmptyNote(id) {
      deleteNote(id)
      return
    }
    selection = id
  }

  /// The id of the currently selected item that can be detached (a session
  /// or a note), nil when nothing detachable is selected. Drives the
  /// "Detach Session/Note" menu command: its enabled state and which item
  /// the ⌘⇧D toggle acts on. A session is detachable even while detached
  /// (so pressing ⌘⇧D again returns it to the main window).
  var selectedDetachableID: UUID? {
    if let session = selectedSession { return session.id }
    if let note = selectedNote { return note.id }
    return nil
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
    case .web(let web):
      return web.name
    case .database(let connection):
      return connection.displayName
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

  /// Opens a saved web session: a live TerminalSession whose CONTENT is a
  /// SwiftUI WebView (ContentView branches on the `.web` kind). The transport
  /// is inert — it only reports `.connected` so the sidebar/toolbar treat the
  /// session as live — and the WebView loads the stored URL. For an ssh-owned
  /// session the port-forward utility (a sibling task) later redirects the
  /// WebView at the host's localhost via a local tunnel. Web sessions never
  /// register a terminal capture, so they don't land in local history.
  @discardableResult
  func openWebSession(_ web: WebSession) -> TerminalSession {
    if historyMode {
      historyMode = false
      selectionBeforeHistory = nil
    }
    // An ssh-owned web page is reachable only through a local port-forward to
    // the SSH host's localhost. Create + start the runtime here (the connect
    // path) so the tunnel lifecycle is tied to the session's connect/disconnect
    // behavior; removeSession stops it. A plain web page needs no runtime.
    if web.sshConfigID != nil {
      let config = connections.first { $0.id == web.sshConfigID }
      let runtime = WebSessionRuntime(web: web, config: config)
      webSessionRuntimes[web.id] = runtime
      runtime.start()
    }
    let session = TerminalSession(transport: WebSessionTransport())
    sessionKinds[session.id] = .web(web)
    sessions.append(session)
    selection = session.id
    return session
  }

  /// Opens a blank web session with no URL configured: creates an empty
  /// `WebSession`, opens it like any saved page (so it lands in the sidebar
  /// and is selected), and leaves the address bar focused so the user can
  /// type a URL immediately. Unlike the New-Web sheet this does NOT persist
  /// a saved session up front — the user types a URL and presses Return to
  /// navigate, and `updateWebSessionURL` persists on the first commit. Used
  /// by the Web menu item to open an empty page with the address bar focused
  /// instead of showing the New-Web sheet.
  @discardableResult
  func openEmptyWebSession() -> TerminalSession {
    openWebSession(WebSession())
  }

  /// The live SSH-tunnel runtime for `web`, if the page is open and ssh-owned.
  /// Feeds the WebSessionDetailView's tunneled URL / error state.
  func webSessionRuntime(for web: WebSession) -> WebSessionRuntime? {
    webSessionRuntimes[web.id]
  }

  /// The live terminal session currently rendering `web`, if any — lets the
  /// sidebar row show an open dot and makes Open focus the existing page
  /// instead of launching a duplicate (same convention as the screen rows).
  func liveWebSession(for web: WebSession) -> TerminalSession? {
    sessions.first { session in
      if case .web(let open) = kind(of: session) { return open.id == web.id }
      return false
    }
  }

  /// Opens a saved web session, or focuses the one already open.
  func openOrFocusWebSession(_ web: WebSession) {
    if let live = liveWebSession(for: web) {
      selection = live.id
    } else {
      openWebSession(web)
    }
  }

  /// Reopens a web session: closes any open page and starts a fresh one.
  /// The WebView cannot be reloaded in place from here, so the open session
  /// is dropped and a new one opened at the same URL.
  func reconnectWebSession(_ web: WebSession) {
    if let live = liveWebSession(for: web) { removeSession(live.id) }
    openWebSession(web)
  }

  /// Changes which SSH host an open (or saved) web session is tunnelled
  /// through, or clears the tunnel entirely ("None (open directly)"). Persists
  /// the new `sshConfigID` via `webSessions.save`, and if the page is currently
  /// open tears the live runtime down and reopens it so the local port-forward
  /// targets the newly selected host (or the plain no-ssh path when nil).
  func updateWebSessionSSH(_ web: WebSession, to sshConfigID: UUID?) {
    guard web.sshConfigID != sshConfigID else { return }
    var updated = web
    updated.sshConfigID = sshConfigID
    webSessions.save(updated)
    // Reconnect only if the page is open; a saved-but-closed session just
    // persists the new binding for the next open (openWebSession reads it).
    if liveWebSession(for: web) != nil {
      reconnectWebSession(updated)
    }
  }

  /// Updates a web session's URL in place and, if the page is open, reloads
  /// it at the new address. A reconnect rebuilds the WebView (and, for an
  /// ssh-owned session, retargets the local port-forward at the new host URL)
  /// so the loaded page matches the address bar. A saved-but-closed session
  /// only persists the new URL for the next open.
  func updateWebSessionURL(_ web: WebSession, to newURL: String) {
    let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, web.url != trimmed else { return }
    var updated = web
    updated.url = trimmed
    webSessions.save(updated)
    if liveWebSession(for: web) != nil {
      reconnectWebSession(updated)
    }
  }

  /// Deletes a saved web session and closes any open page bound to it.
  func deleteWebSession(_ web: WebSession) {
    if let live = liveWebSession(for: web) { removeSession(live.id) }
    webSessions.remove(web.id)
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
    // A disabled Screen feature never scans, so publish an empty list.
    guard features.isEnabled(.screen) else { return [] }
    return remoteScreenScanner.sessions
  }

  /// Re-scans the connected SSH hosts for screen/tmux sessions. Called when a
  /// connection opens and by the sidebar's remote-refresh control. Safe on the
  /// main thread — each remote exec is scheduled on its connection's NIO
  /// event loop, so the main thread is never blocked.
  func refreshRemoteScreenSessions() {
    // A remote scan dials every connected SSH host — background work that
    // must not run while the Screen feature is disabled.
    guard features.isEnabled(.screen) else { return }
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

  /// Opens a terminal attached to a persistent screen/tmux session running on
  /// a connected SSH host. The transport is a NEW `SSHSession` whose exec
  /// command is the remote attach (`screen -x <name>` / `tmux attach -t
  /// <name>`), exactly like a remote action session — PTY + exec over the
  /// authenticated connection. Mirrors local `attach(toScreen:)`: the kind is
  /// `.screen` (carrying the remote origin) and the exit handler reconciles by
  /// removing the app-side client and re-scanning the remote persistent list.
  @discardableResult
  func attach(toRemoteScreen info: ScreenSessionInfo, on config: SSHConfig) -> TerminalSession {
    let exec: String
    if info.kind == .tmux {
      exec = "tmux attach -t \(info.name)"
    } else {
      exec = "screen -x \(info.name)"
    }
    let session = TerminalSession(
      transport: SSHSession(config: config, execCommand: exec),
      startupMessage: "Attaching to \(config.displayName)…"
    )
    session.exitHandler = { [weak self, weak session] _ in
      guard let id = session?.id else { return }
      // The client detached or its shell ended; the app-side attachment is
      // finished. The remote scan decides whether the persistent backend row
      // remains (it does — the session keeps running on the host).
      self?.removeSession(id)
      self?.refreshRemoteScreenSessions()
    }
    sessionKinds[session.id] = .screen(info)
    registerCapture(for: session, archiveLocally: false)
    sessions.append(session)
    selection = session.id
    refreshRemoteScreenSessions()  // the session just flipped to Attached
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
    // Tear down an ssh-owned web session's tunnel on disconnect/teardown.
    if let session = sessions.first(where: { $0.id == id }),
       case .web(let web) = kind(of: session) {
      webSessionRuntimes.removeValue(forKey: web.id)?.stop()
    }
    // Tear down a database session's engine lifecycle on close.
    if let session = sessions.first(where: { $0.id == id }),
       case .database(let connection) = kind(of: session) {
      disconnectDatabaseSession(connection)
    }
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
      // Local persistent attachments plus remote (SSH) persistent
      // attachments, in sidebar order — Cmd+W/Cmd+N navigate all of them.
      let local = screenMonitor.sessions.compactMap { attachedSession(toScreen: $0) }
      let remote = remoteScreenSessions.compactMap { attachedSession(toScreen: $0) }
      return local + remote
      #else
      return []
      #endif
    case .ssh:
      return connections.flatMap { sessions(for: $0) }
    case .action:
      return sessions.filter { if case .action = kind(of: $0) { return true }; return false }
    case .web(let web):
      // Group web sessions with everything sharing their SSH host (or, for a
      // plain web session, with the local-nil set) so ⌘W/⌘N navigates them
      // alongside the connections they belong to.
      return sessions.filter { kind(of: $0).sshConfigID == web.sshConfigID }
    case .database:
      // Database sessions share their connection's section: all DB rows group
      // together for ⌘W/⌘N, mirroring the Remote section.
      return sessions.filter { if case .database = kind(of: $0) { return true }; return false }
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
    case .web(let web):
      return openWebSession(web)
    case .database(let connection):
      return openOrFocusDatabaseConnection(connection)
    }
  }
  #else
  @discardableResult
  func newSession(inSameSectionAs session: TerminalSession) -> TerminalSession? {
    // iOS: no local terminals — SSH sessions duplicate their connection,
    // web sessions reopen the page, database rows reopen their browser,
    // anything else opens the New Connection sheet.
    switch kind(of: session) {
    case .ssh(let config):
      return connect(to: config)
    case .web(let web):
      return openWebSession(web)
    case .database(let connection):
      return openOrFocusDatabaseConnection(connection)
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

  #if os(macOS)
  // MARK: - Opened files (sidebar "Text Files")

  /// Opens `url` as a read-write scratch document. If the file is already
  /// open it is merely selected (existing edits are preserved). The content
  /// is loaded off the main thread and published back on the main actor, with
  /// a monotonic generation guard so a stale load can never clobber newer
  /// content. Non-UTF8 and oversized files are surfaced as a read-only notice.
  /// This is the entry point for `.textFile(url:)` from
  /// `application(_:openFiles:)`.
  func openFile(_ url: URL) {
    if let existing = openedFiles.first(where: { $0.url == url }) {
      selection = existing.id
      return
    }
    openFileGeneration += 1
    let generation = openFileGeneration
    var opened = OpenedFile(url: url, loadGeneration: generation)
    openedFiles.append(opened)
    selection = opened.id
    Task.detached(priority: .userInitiated) {
      let content = Self.loadContent(of: url)
      Task { @MainActor in
        self.applyLoadedContent(id: opened.id, generation: generation, content: content)
      }
    }
  }

  private nonisolated static func loadContent(of url: URL) -> (text: String?, notice: String?) {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if size > Self.maxEditableFileBytes {
      return (nil, "This file is too large to edit safely (\(Self.maxEditableFileBytes / 1024 / 1024) MB). Shown read-only.")
    }
    guard let data = try? Data(contentsOf: url) else {
      return (nil, "The file could not be read.")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      return (nil, "The file is not UTF-8 text and can't be edited.")
    }
    return (text, nil)
  }

  private static let maxEditableFileBytes = 2 * 1024 * 1024

  private func applyLoadedContent(
    id: UUID,
    generation: Int,
    content: (text: String?, notice: String?)
  ) {
    guard let idx = openedFiles.firstIndex(where: { $0.id == id }),
          openedFiles[idx].loadGeneration == generation else { return }
    openedFiles[idx].isLoaded = true
    if let notice = content.notice {
      openedFiles[idx].loadNotice = notice
      openedFiles[idx].text = ""
    } else if let text = content.text {
      openedFiles[idx].text = text
    }
  }

  func updateOpenedFileText(_ text: String, for id: UUID) {
    guard let idx = openedFiles.firstIndex(where: { $0.id == id }) else { return }
    guard openedFiles[idx].text != text else { return }
    openedFiles[idx].text = text
    openedFiles[idx].isDirty = true
  }

  func saveOpenedFile(_ id: UUID) {
    guard let idx = openedFiles.firstIndex(where: { $0.id == id }) else { return }
    let file = openedFiles[idx]
    guard file.canEdit else { return }
    do {
      try file.text.write(to: file.url, atomically: true, encoding: .utf8)
      openedFiles[idx].isDirty = false
    } catch {
      openedFiles[idx].loadNotice = "Could not save: \(error.localizedDescription)"
    }
  }

  func closeOpenedFile(_ id: UUID) {
    guard let idx = openedFiles.firstIndex(where: { $0.id == id }) else { return }
    openedFiles.remove(at: idx)
    if openedFiles.isEmpty {
      selection = nil
    } else {
      selection = openedFiles.indices.contains(idx) ? openedFiles[idx].id : openedFiles.last?.id
    }
  }

  func commitCloseOpenedFile(_ id: UUID) {
    saveOpenedFile(id)
    closeOpenedFile(id)
    pendingCloseOpenedFile = nil
  }

  func discardCloseOpenedFile(_ id: UUID) {
    closeOpenedFile(id)
    pendingCloseOpenedFile = nil
  }

  func clearPendingClose() {
    pendingCloseOpenedFile = nil
  }
  #endif

/// ⌘W: closes the selected session (quitting persistent sessions like
  /// the toolbar does), then selects the previous session in the same
  /// section — the next one when it was the first, a fresh session in
  /// that section when it was the only one.
  func closeSelectedSessionAndSelectNeighbor() {
    // ⌘W with a note focused closes the note editor — and, if the note is
    // empty (never typed into), deletes it so it doesn't linger as
    // "Untitled". A note with content is left intact (non-destructive).
    if let note = selectedNote {
      if notes.isEmptyNote(note.id) {
        deleteNote(note.id)
        return
      }
      selection = nil
      return
    }
    #if os(macOS)
    // ⌘W with an opened file focused closes it. A dirty, editable file asks
    // (Save / Don't Save / Cancel) instead of silently discarding edits.
    if let file = selectedOpenedFile {
      if file.isDirty && file.canEdit {
        pendingCloseOpenedFile = file.id
      } else {
        closeOpenedFile(file.id)
      }
      return
    }
    #endif
    guard let session = selectedSession else { return }
    let section = sectionSessions(containing: session)
    let index = section.firstIndex { $0.id == session.id } ?? 0
    let wasOnly = section.count == 1
    
    if case .screen(let info) = kind(of: session) {
      #if os(macOS)
      if info.isRemote {
        // Remote sessions live on the SSH host; closing the attached terminal
        // detaches our client (and closes the session on the host via SSH).
        closeRemoteScreenSession(info)
      } else {
        closeScreenSession(info)
      }
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
  /// sessions are identified by name AND origin: local sessions match on
  /// "pid.name"; remote sessions additionally match on the SSH config id,
  /// so two hosts that each run a session named the same don't collide.
  func attachedSession(toScreen info: ScreenSessionInfo) -> TerminalSession? {
    sessions.first { session in
      guard case .screen(let attached) = kind(of: session) else { return false }
      guard attached.name == info.name else { return false }
      // Local rows match local attachments; remote rows match attachments on
      // the same host (same origin config id).
      switch (attached.remoteOrigin, info.remoteOrigin) {
      case (nil, nil):
        return true
      case let (a?, b?):
        return a.sshConfigID == b.sshConfigID
      default:
        return false
      }
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

  /// Closes a persistent session running on a connected SSH host: quits it on
  /// the host via the connection's live SSH exec channel (`screen -S <name> -X
  /// quit` / `tmux kill-session -t <name>`), then removes the app-side
  /// terminals attached to it. If the connection dropped or the session is
  /// already gone, the exec is a no-op and we only remove our own attachment.
  func closeRemoteScreenSession(_ info: ScreenSessionInfo) {
    if let origin = info.remoteOrigin,
       let transport = connectedSSHSessions
         .first(where: { $0.sshTransport?.config.id == origin.sshConfigID })?
         .sshTransport {
      let command: String
      if info.kind == .tmux {
        command = "tmux kill-session -t \(info.name)"
      } else {
        command = "screen -S \(info.name) -X quit"
      }
      // One-shot exec on the already-connected channel; the result is not
      // surfaced (a missing session is the normal outcome here).
      transport.runCommand(command) { _ in }
    }
    let attached = sessions.filter { session in
      if case .screen(let attached) = kind(of: session) {
        return attached.id == info.id
      }
      return false
    }
    for session in attached {
      removeSession(session.id)
    }
    refreshRemoteScreenSessions()
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

  // MARK: - Database connections

  /// Persists a database connection (creating or updating the record) and,
  /// when a non-nil `password` is passed, writes the credential to the
  /// Keychain. Does not open a session.
  func saveDatabaseConnection(_ connection: DatabaseConnection, password: String? = nil) {
    databaseStore.save(connection, password: password)
  }

  /// Deletes a saved database connection: closes any open browser session,
  /// removes the Keychain credential, then removes the record.
  func deleteDatabaseConnection(_ connection: DatabaseConnection) {
    disconnectDatabaseSession(connection)
    if let session = liveDatabaseSession(for: connection) {
      removeSession(session.id)
    }
    databaseStore.remove(connection.id)
  }

  /// Persists a database connection edit in place (same id) and, when a
  /// browser is currently open for it, reconnects so the live view reflects
  /// the new settings.
  func updateDatabaseConnection(_ connection: DatabaseConnection, password: String? = nil) {
    databaseStore.save(connection, password: password)
    if let dbSession = databaseSessions[connection.id] {
      // The old connection reference is stale; swap it and reconnect.
      databaseSessions.removeValue(forKey: connection.id)
      Task { @MainActor in
        await dbSession.disconnect()
        let fresh = DatabaseSession(connection: connection, sshConfigStore: connectionStore)
        databaseSessions[connection.id] = fresh
        await fresh.connect(password: databaseStore.password(for: connection))
      }
    }
  }

  /// Renames a saved database connection in place (same id, so the sidebar row
  /// and any open browser session keep referring to the same connection), then
  /// persists via `databaseStore.save`. Empty/whitespace-only input resets the
  /// name to the engine display name, matching the displayName fallback.
  func renameDatabaseConnection(_ connection: DatabaseConnection, to name: String) {
    var updated = connection
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.name = trimmed.isEmpty ? updated.engine.displayName : trimmed
    databaseStore.save(updated)
  }

  /// Opens a saved database connection (or focuses its already-open browser).
  /// Mirrors `openOrFocusWebSession`: create a live session backed by the
  /// inert transport, then connect the engine.
  @discardableResult
  func openOrFocusDatabaseConnection(_ connection: DatabaseConnection, password: String? = nil)
    -> TerminalSession
  {
    if let live = liveDatabaseSession(for: connection) {
      selection = live.id
      return live
    }
    // Load the persisted credential when the caller didn't supply one.
    let password = password ?? databaseStore.password(for: connection)
    let dbSession = DatabaseSession(connection: connection, sshConfigStore: connectionStore)
    let session = TerminalSession(transport: DatabaseTransport())
    sessionKinds[session.id] = .database(connection)
    sessions.append(session)
    selection = session.id
    databaseSessions[connection.id] = dbSession
    Task { @MainActor in
      await dbSession.connect(password: password)
    }
    return session
  }

  /// The live terminal session currently rendering `connection`, if any —
  /// lets the sidebar row show an open dot and makes Open focus the existing
  /// browser instead of launching a duplicate (same convention as web rows).
  func liveDatabaseSession(for connection: DatabaseConnection) -> TerminalSession? {
    sessions.first { session in
      if case .database(let open) = kind(of: session) { return open.id == connection.id }
      return false
    }
  }

  /// The engine session backing `connection`, if it is open.
  func databaseSession(for connection: DatabaseConnection) -> DatabaseSession? {
    databaseSessions[connection.id]
  }

  /// The saved Keychain password for a connection (nil when unset), for
  /// pre-filling the edit form.
  func passwordForDatabase(_ connection: DatabaseConnection) -> String? {
    databaseStore.password(for: connection)
  }

  /// Disconnects the engine lifecycle for `connection` (if open), keeping the
  /// saved row and any terminal session so the browser shows a disconnected
  /// state rather than vanishing.
  func disconnectDatabase(_ connection: DatabaseConnection) {
    disconnectDatabaseSession(connection)
  }

  /// Closes + removes a database session (used by delete and by the sidebar
  /// close affordance). Keeps the saved row intact.
  func closeDatabaseSession(_ connection: DatabaseConnection) {
    disconnectDatabaseSession(connection)
    if let session = liveDatabaseSession(for: connection) {
      removeSession(session.id)
    }
  }

  /// Tears down the engine connection and its runtime entry.
  private func disconnectDatabaseSession(_ connection: DatabaseConnection) {
    guard let session = databaseSessions.removeValue(forKey: connection.id) else { return }
    Task { @MainActor in await session.disconnect() }
  }

  /// Reorders the sidebar's database section (drag-to-reorder).
  func moveDatabaseConnection(from source: IndexSet, to destination: Int) {
    var reordered = databaseStore.all
    reordered.move(fromOffsets: source, toOffset: destination)
    databaseStore.reorder(reordered)
  }

  /// Duplicates a database connection: a brand-new record (fresh id) copying
  /// every field plus the Keychain credential from the source, so the copy is
  /// independently usable. The displayed name gets a " copy" suffix (only when
  /// a name was set) so the two rows are distinguishable in the sidebar.
  func duplicateDatabaseConnection(_ source: DatabaseConnection) {
    var copy = source
    copy.id = UUID()
    if !source.name.isEmpty { copy.name = "\(source.name) copy" }
    let password = databaseStore.password(for: source)
    databaseStore.save(copy, password: password)
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
        // Glue across the scrollback/grid seam: a grid row 0 that is a
        // soft-wrap continuation of the last scrollback row does not start
        // a new captured line (otherwise a long wrapped line gets a spurious
        // newline when it scrolls off the bottom).
        if !output.isEmpty && !snapshot.isLineWrapped(snapshot.scrollback.count) {
          output += "\n"
        }
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

  /// Where an action runs: locally (a local pty) or over an SSH exec
  /// channel. `sshConfig` is nil for local.
  private enum ActionEnvironment {
    case local
    case ssh(SSHConfig)

    var sshConfig: SSHConfig? {
      if case .ssh(let config) = self { return config }
      return nil
    }
  }

  /// Runs `action` by opening a separate terminal session in the selected
  /// session's environment (the local machine, or the same SSH host). With
  /// NO session selected (e.g. nothing is open), defaults to the local
  /// machine so ⌘R stays usable from a fresh start.
  ///
  /// Dependencies: when `action` lists dependencies, every unresolved
  /// dependency — recursively following its OWN dependencies — is started in
  /// a batch: all leaves launch at once, and each action starts 1 second
  /// AFTER ALL of its dependencies have started. A dependency is guaranteed
  /// to be *running* (never waited on to completion) when the depending
  /// action launches. Everything starts in the same target environment; a
  /// dependency is never focused and never MRU-touched.
  func runAction(_ action: Action) {
    actions.touch(action.id)
    guard let environment = currentActionEnvironment else { return }
    let order = dependencyStartupOrder(for: action)
    // Group actions into dependency "levels": every action with no
    // dependency-that-needs-starting (a leaf, or a dep already running)
    // launches at level 0; each dependent launches one level deeper than the
    // deepest dependency it waits on. All actions at a level start together,
    // then we advance one level per second — so an action starts 1 second
    // AFTER ALL of its (unresolved) dependencies have started, not one by one.
    var levelByID: [UUID: Int] = [:]
    for a in order {
      let depLevels = a.dependencies.compactMap { levelByID[$0] }
      levelByID[a.id] = (depLevels.max() ?? -1) + 1
    }
    let maxLevel = levelByID.values.max() ?? 0
    Task { @MainActor [weak self] in
      guard let self else { return }
      for level in 0...maxLevel {
        for a in order where levelByID[a.id] == level {
          // Only the action the user actually triggered may retake focus.
          let isTopLevel = a.id == action.id
          self.spawnActionSession(a, in: environment, isTopLevel: isTopLevel, focus: isTopLevel && a.focusWindow)
        }
        if level != maxLevel {
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
  }

  /// The environment an action runs in, resolved once at trigger time from
  /// the currently selected session. `nil` when there is nothing runnable
  /// (iOS with no terminal selected — there is no local pty).
  private var currentActionEnvironment: ActionEnvironment? {
    if let session = selectedSession {
      switch kind(of: session) {
      case .local, .screen, .action:
        // Action sessions run in the environment of their target; without
        // one they fall back to the local machine.
        return .local
      case .ssh(let config):
        return .ssh(config)
      case .database(let connection):
        // A database session has no shell to run actions in; honor the
        // bound SSH host when it has one, else run locally.
        if let id = connection.sshConfigID,
           let config = connections.first(where: { $0.id == id }) {
          return .ssh(config)
        }
        return .local
      case .web(let web):
        // An action run from a web session executes in that session's
        // environment: the bound SSH host when it has one, else locally.
        if let id = web.sshConfigID,
           let config = connections.first(where: { $0.id == id }) {
          return .ssh(config)
        }
        return .local
      }
    } else {
      #if os(macOS)
      // Nothing selected (fresh start / nothing open): run locally.
      return .local
      #else
      // Local actions need a local pty, which iOS doesn't have; the
      // overlay's applicability filter never offers one there anyway.
      return nil
      #endif
    }
  }

  /// Launches one action session (local zsh or an SSH exec channel) and
  /// wires it to archive to history on completion. `focus` is honored only
  /// for the action the user actually triggered, never for a dependency.
  private func spawnActionSession(_ action: Action, in environment: ActionEnvironment, isTopLevel: Bool, focus: Bool) {
    let spec = ActionSpec(action: action, config: environment.sshConfig)
    let transport: any TerminalTransport
    let startupMessage: String?
    if let config = spec.config {
      transport = SSHSession(config: config, execCommand: spec.action.commands)
      startupMessage = "Connecting to \(config.host)…"
    } else {
      #if os(macOS)
      // -lic (login + interactive + command) sources ~/.zshrc so the
      // user's environment (e.g. bun's PATH in ~/.zshrc) is present when
      // the action runs. Plain -lc is non-interactive and skips .zshrc.
      transport = LocalPTYTransport(executable: "/bin/zsh", argv: ["zsh", "-lic", spec.action.commands])
      startupMessage = nil
      #else
      // Local actions need a local pty, which iOS doesn't have. This
      // branch is unreachable on iOS: dependencies resolve to .local only
      // where a pty exists.
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
    // A web-field action is a "run the server AND open it" action: the
    // command session above is the web server (it stays in the Running
    // section), and we open a web view at the smart-resolved address. The web
    // view — not the server terminal — is what the user looks at, so it takes
    // focus when the action runs. Only the user-triggered (top-level) action
    // opens a web view; dependencies just run their commands.
    if isTopLevel, !spec.action.webAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let web = WebSession(
        name: spec.action.name,
        url: SmartAddress.resolve(spec.action.webAddress),
        sshConfigID: environment.sshConfig?.id
      )
      openWebSession(web)
      showingActions = false
    } else if focus {
      selection = newSession.id
      showingActions = false   // you're looking at the run now
    }
    // focusWindow == false and no web field: the overlay stays open for queuing more runs.
  }

  /// Post-order startup sequence for `action` and its transitive
  /// dependencies: every leaf dependency first, `action` itself last. The
  /// visited set bounds the recursion so a malformed dependency cycle can't
  /// loop forever (the picker already prevents cycles).
  private func dependencyStartupOrder(for action: Action) -> [Action] {
    var visited = Set<UUID>()
    var order: [Action] = []
    func visit(_ a: Action) {
      guard visited.insert(a.id).inserted else { return }
      // If a dependency is already running, its prerequisites are satisfied —
      // don't start it (or its subtree) again; just proceed to the dependent.
      if a.id != action.id && isActionRunning(a.id) { return }
      for depID in a.dependencies {
        if let dep = actions.all.first(where: { $0.id == depID }) {
          visit(dep)
        }
      }
      order.append(a)
    }
    visit(action)
    return order
  }

  /// Whether a live action session for `id` is currently running (starting,
  /// connecting, or connected). Failed/closed sessions don't count.
  private func isActionRunning(_ id: UUID) -> Bool {
    sessions.contains { session in
      guard case .action(let spec) = kind(of: session), spec.action.id == id else { return false }
      switch session.connectionState {
      case .starting, .connecting, .connected: return true
      case .failed, .closed: return false
      }
    }
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
    // Smart Actions disabled → the directory listing + integration scan is
    // background work that must not run; publish nothing.
    guard features.isEnabled(.smartActions) else {
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
    // -lic sources ~/.zshrc (same reasoning as runAction): a bun or other
    // tool added to PATH in .zshrc must be visible for the smart action.
    let transport = LocalPTYTransport(executable: "/bin/zsh", argv: ["zsh", "-lic", command])
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
  /// new order (drag-to-reorder of the server rows).
  func moveConnection(from source: IndexSet, to destination: Int) {
    var reordered = connections
    reordered.move(fromOffsets: source, toOffset: destination)
    connectionStore.reorder(reordered)
  }

  /// Shared subset reorder: `items` is a computed slice of `sessions`
  /// (e.g. all local, or all sessions under one SSH config). `.onMove`
  /// reports indices into that SLICE, but the order lives in the flat
  /// `sessions` array interleaved with other kinds, so we reorder only
  /// the matching entries while leaving every other entry in its slot.
  private func moveSessionSubset(
    matching predicate: (TerminalSession) -> Bool,
    from source: IndexSet,
    to destination: Int
  ) {
    guard !source.isEmpty else { return }
    let indexes = sessions.indices.filter { predicate(sessions[$0]) }
    var items = indexes.map { sessions[$0] }
    items.move(fromOffsets: source, toOffset: destination)
    for (j, item) in items.enumerated() {
      sessions[indexes[j]] = item
    }
  }

  /// Reorders the Local section's shell rows. The displayed `localSessions`
  /// is a filtered slice of the flat `sessions` array, so the move is
  /// applied to the slice and written back into the global slots.
  func moveLocalSession(from source: IndexSet, to destination: Int) {
    moveSessionSubset(matching: { kind(of: $0) == .local }, from: source, to: destination)
  }

  /// Reorders the running sessions under one SSH server (the rows inside an
  /// SSHConfigGroup). Keeps the server's own ordering untouched — the server
  /// row is reordered separately via `moveConnection`.
  func moveSSHSession(for config: SSHConfig, from source: IndexSet, to destination: Int) {
    let configID = config.id
    moveSessionSubset(
      matching: { kind(of: $0).sshConfigID == configID },
      from: source,
      to: destination
    )
  }

  /// Reorders the Local section's saved web-page rows (pages not bound to an
  /// SSH tunnel). Web sessions live in `WebSessionStore`, not `sessions`, so
  /// the move is delegated to the store's local-subset reorder.
  func moveLocalWebSession(from source: IndexSet, to destination: Int) {
    webSessions.moveLocalSubset(from: source, to: destination)
  }

  /// Reorders the Local section's database-connection rows (connections not
  /// reached through an SSH tunnel). Delegated to the store's local-subset
  /// reorder, which reassigns `order` for the whole list.
  func moveLocalDatabaseConnection(from source: IndexSet, to destination: Int) {
    databaseStore.moveLocalSubset(from: source, to: destination)
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

  /// Tears down the CloudKit remote-change observation. Called when the Notes
  /// feature is disabled so a disabled feature never holds a live observer or
  /// a pending coalesced refresh.
  private func stopObservingCloudKitRemoteChanges() {
    if let observer = cloudKitChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      cloudKitChangeObserver = nil
    }
    cloudKitRefreshTask?.cancel()
    cloudKitRefreshTask = nil
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
    // Notes CloudKit is gated behind its feature: when off, don't observe or
    // refresh the notes stores (persisted data is left untouched, so
    // re-enabling restores it). SSH configs and device keys always refresh.
    if features.isEnabled(.notes) { notes.refreshOnActivation() }
    connectionStore.refreshOnActivation()
    deviceKeys.refreshOnActivation()
    databaseStore.refreshOnActivation()
  }
}
