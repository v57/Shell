#if os(macOS) || os(Windows)
#if os(macOS)
import AppKit
#endif
#elseif os(iOS)
import UIKit
#endif
import ComponentKit
#if canImport(CoreData)
import CoreData
#endif
import CryptoKit
import Foundation
import Observation
import SwiftData
import SwiftUI
import ShellKit
import ShellIntegrations

/// Application-wide state: the list of terminal sessions, the sidebar
/// selection, and the persisted SSH connection store.
@MainActor
@Observable
final class AppModel {
  static let shared = AppModel()

  /// What the sidebar has focused: the KIND of row plus its id.
  ///
  /// The kind is the point. A bare `UUID?` forced every accessor to search
  /// `sessions`, then `notes`, then `history`, then `openedFiles` before it
  /// could tell what was selected, and the content area could only find the
  /// view to present by chaining one getter per collection
  /// (`mainSelectedSession` → `mainSelectedNote` → …). Naming the kind makes
  /// each lookup a single pass over ONE collection and lets the content area
  /// switch straight to the pane it presents.
  ///
  /// `.ssh`, `.screen`, `.web` and `.database` are ACTIVATION selections:
  /// those rows don't back a live session yet, so `activate(_:)` turns them
  /// into the session they open (or focuses the open one) and the content
  /// area presents nothing for them. Every other case is the resting state
  /// of an open item.
  nonisolated enum Selection: Hashable, Sendable {
    /// A live terminal session — the resting state of every open item: local
    /// and SSH shells, action runs, attached persistent sessions, open web
    /// pages and open database browsers.
    case session(UUID)
    /// A saved SSH connection row: activating it connects.
    case ssh(UUID)
    /// A persistent (screen/tmux) session row, keyed by its deterministic
    /// `ScreenSessionInfo.tagID` (stable across monitor refreshes):
    /// activating it attaches a terminal, or focuses the attached one.
    case screen(UUID)
    /// A saved web page row: activating it opens the page, or focuses the
    /// already-open one.
    case web(UUID)
    /// A saved database connection row: activating it opens the browser, or
    /// focuses the already-open one.
    case database(UUID)
    /// A note in the main window's editor.
    case note(UUID)
    /// An archived history session in the history viewer.
    case history(UUID)
    /// A transient opened text file (macOS only).
    case openedFile(UUID)

    /// The id this selection carries. Every case carries exactly one, so this
    /// is the key the detached-window scene (`WindowGroup` id "detach", which
    /// presents by item id) and the detach badge work with.
    var itemID: UUID {
      switch self {
      case .session(let id), .ssh(let id), .screen(let id), .web(let id),
           .database(let id), .note(let id), .history(let id), .openedFile(let id):
        return id
      }
    }
  }
  
  /// The feature-flag source of truth. Background surfaces and probes read
  /// `isEnabled(_:)` from here so a disabled feature never spawns work.
  private var features: FeatureFlagsStore { .shared }
  
  var sessions: [TerminalSession] = []
  var selection: Selection?
  /// The directory browser (Files panel) model, driven by the selected
  /// session. Shared so both ContentView and ShellCommands can drive it.
  let directoryBrowser = DirectoryBrowserModel()
  var showingNewConnection = false
  /// The web session being edited in the sheet (nil = creating a new one).
  var editingWebSession: WebSession?
  /// The New Database Connection sheet (Database section header "+").
  var showingNewDatabaseConnection = false
  /// The database connection being edited in the sheet (nil = creating).
  var editingDatabaseConnection: DatabaseConnection?
  /// The SSH tunnel to preset in the New Database Connection sheet when it is
  /// opened from a connected Remote host's per-config + menu (nil = no tunnel).
  var databasePresetSSHConfigID: UUID?
  var publicKeyError: String?
  
  #if os(macOS) || os(Windows)
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
  /// Files dropped on a session, the terminal or Notes, waiting for the user to pick what to do with them (the
  /// drop dialog in ContentView; see FileDropActions.swift).
  var fileDropRequest: FileDropRequest?
  /// Why a drop could not be carried out (shown as an alert).
  var fileDropError: String?

  /// Transient, scratch opened-file documents (the sidebar "Text Files"
  /// section), edited in the content area. NOT persisted — cleared on app
  /// restart and when a file is closed via ⌘W — except files LINKED by a drop
  /// on Notes (`linkFile`), which reopen at launch. Kept entirely separate from
  /// `NotesStore` (an opened file is a scratch view, not a Notes item). See
  /// `OpenFilePane.swift`.
  private(set) var openedFiles: [OpenedFile] = []
  /// Monotonic guard so a stale off-main load can never overwrite newer
  /// content (bumped on every `openFile` call, including clears).
  private var openFileGeneration = 0
  /// Autosave bookkeeping: a deduped, debounced (5s, matching the Notes
  /// editor) write-through task per opened-file id. `updateOpenedFileText`
  /// schedules one; any pending write is flushed on close, scene-change, and
  /// app quit so the last keystrokes land on disk.
  private var openedFileSaveTasks: [UUID: Task<Void, Never>] = [:]
  /// The same debounce the Notes editor uses, so a file auto-saves 5s after
  /// the last keystroke (autosave, written through to the file — not a manual
  /// Save). Replaces the pane's original explicit Save (⌘S) UI.
  private static let openedFileSaveDelay: Duration = .seconds(5)
  #endif

  /// The sidebar's saved Actions (UserDefaults-backed).
  var actions = ActionsStore(defaults: ScreenshotDemo.isOn ? ScreenshotDemo.defaults : .standard)
  /// The sidebar's saved web sessions (UserDefaults-backed).
  var webSessions = WebSessionStore(defaults: ScreenshotDemo.isOn ? ScreenshotDemo.defaults : .standard)
  /// The live SSH-tunnel runtimes for OPEN ssh-owned web sessions, keyed by
  /// web session id. Created on connect (openWebSession), stopped and removed
  /// on teardown (removeSession). Plain web sessions have no entry.
  private(set) var webSessionRuntimes: [UUID: WebSessionRuntime] = [:]
  /// Encrypted local-session history. Active captures remain in memory until
  /// their terminal closes or the app terminates.
  var history = HistoryStore(fileURL: ScreenshotDemo.isOn ? ScreenshotDemo.historyFile : nil)
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
  private var selectionBeforeHistory: Selection?
  /// The `.notes` flag as last seen, to act only when it flips (reactivity
  /// re-arms on every observed flag change).
  private var notesFeatureEnabled = false

  #if os(macOS) || os(Windows)
  /// Project detection over the active directory with Code's CodeActions,
  /// driving the toolbar's smart-action Run/Stop controls. Per-directory
  /// results are encrypted-cached.
  let smartActions = SmartActionsCoordinator(cacheStore: SmartActionsStore())
  /// The schemes in the active directory, each with its actions (refreshed
  /// on directory change).
  private(set) var smartActionSchemes: [ActionScheme] = []
  /// The directory `smartActionSchemes` was computed for (nil = none active).
  private(set) var smartActionDirectory: URL?
  /// The "Open With" apps offered for the active directory (empty = none,
  /// e.g. no local terminal selected). Computed alongside the smart actions.
  private(set) var openWithKinds: [OpenWithKind] = []
  /// Monotonic counter bumped on every `refreshSmartActions` call (including
  /// clears) so an in-flight background scan from a previous directory is
  /// discarded as stale instead of overwriting newer results.
  private var smartActionsGeneration = 0
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
  /// The currently running smart action per canonical directory path.
  /// One per directory — a new Run replaces it (stop first), Stop kills it.
  private var currentSmartActionByDirectory: [String: RunningSmartAction] = [:]
  /// A smart action's session, and which scheme and action it runs.
  private struct RunningSmartAction {
    let session: TerminalSession
    let schemeID: String
    let kind: ActionKind
  }
  /// Memoized smart-action display state for one directory (schemes plus the
  /// matching "Open With" apps).
  private struct SmartActionResult {
    let schemes: [ActionScheme]
    let openKinds: [OpenWithKind]
  }
  /// The Notarization sheet: shown by the first Export (or from the
  /// Distribute menu) until a Developer ID and a working notary profile are set.
  var notarizationSetup: NotarizationSetupRequest?
  private static let notaryProfileKey = "notarization.profile"
  /// The notarytool keychain profile Export passes as `NOTARY_PROFILE`; set by
  /// the Notarization sheet once it validated it. nil = not set up yet.
  var notaryProfile: String? = UserDefaults.standard.string(forKey: notaryProfileKey) {
    didSet { UserDefaults.standard.set(notaryProfile, forKey: Self.notaryProfileKey) }
  }
  #endif

  private struct LocalHistoryDraft {
    var commands: [SubmittedCommand] = []
    var capture: TerminalHistoryCapture
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

  private init() {
    appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.appearanceModeKey) ?? "") ?? .system
    disableTerminalBackgrounds = UserDefaults.standard.bool(forKey: Self.disableTerminalBackgroundsKey)
    // SSH hosts, database connections and device keys are the ones the v57 apps share through the vault
    // (../Vault), synced through iCloud and live across apps.
    connectionStore = SSHConfigStore()
    deviceKeys = DeviceKeyStore()
    databaseStore = DatabaseConnectionStore()
    // Notes gating must not read `self` here (stored properties are still
    // being initialized); read the flag first, wire `notes`, then publish it.
    // Notes are the ones the v57 apps share (Markdown keeps them as files).
    let notesFlag = FeatureFlagsStore.shared.isEnabled(.notes)
    notes = NotesStore()
    notesFeatureEnabled = notesFlag
    // Hosts and connections saved by builds before the vault move into it once (never into the
    // screenshot demo's store).
    if !ScreenshotDemo.isOn { LegacyImport.run(configs: connectionStore, databases: databaseStore) }
    // Publish this device's identity key to iCloud (no-op when the Secure
    // Enclave key is unreachable, e.g. locked screen — retried when the
    // authorized-keys panel opens). Part of the Authorized Keys feature.
    if features.isEnabled(.authorizedKeys), !ScreenshotDemo.isOn {
      deviceKeys.publishThisDevice()
    }
    #if os(macOS) || os(Windows)
    smartActionsEnabled = features.isEnabled(.smartActions)
    // Start (or leave stopped) the Screen feature's pollers to match the flag.
    configureGatedBackgroundWork()
    // React to runtime feature-flag flips (start/stop pollers, re-probe).
    startFeatureFlagReactivity()
    // Start with a local terminal so the window is never empty, unless
    // Sessions is off (no shell may be spawned then). iOS has no local
    // terminals — it starts with just the sidebar (SSH + notes).
    if features.isEnabled(.sessions) {
      _ = addLocalTerminal()
    }
    #if os(macOS)
    // Files linked by a drop on Notes stay in the Text Files section.
    if !ScreenshotDemo.isOn { reopenLinkedFiles() }
    #endif
    #endif
  }

  #if os(macOS) || os(Windows)
  /// Starts or stops the Screen feature's background pollers to match the
  /// current feature flag. Idempotent; safe to call at any time.
  private func configureGatedBackgroundWork() {
    // The monitor lists the Mac's real screen/tmux sessions: never in the screenshot demo.
    if features.isEnabled(.screen), !ScreenshotDemo.isOn {
      screenMonitor.start()
    } else {
      screenMonitor.stop()
    }
  }

  /// Re-applies the gated background configuration whenever any flag we gate
  /// on flips, and refreshes Smart Actions when that flag flips. Uses
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

  /// Follows the `.notes` flag: the Notes section and commands are gated on it,
  /// and turning it on re-reads the notes.
  private func configureNotesGating(notesEnabled: Bool) {
    guard notesEnabled != notesFeatureEnabled else { return }
    notesFeatureEnabled = notesEnabled
    if notesEnabled { notes.refreshOnActivation() }
  }
  #endif

  /// The live session with `id`, if it is open — one pass over `sessions`
  /// (the only collection that can hold it).
  func session(_ id: UUID) -> TerminalSession? {
    sessions.first { $0.id == id }
  }

  /// The note summary with `id`, if it exists (notes are decrypted lazily, so
  /// the summary — not the text — is what the sidebar and the editor's title
  /// need).
  func note(_ id: UUID) -> NotesStore.NoteSummary? {
    notes.notes.first { $0.id == id }
  }

  /// The archived history session with `id`, if it still exists.
  func historySession(_ id: UUID) -> HistorySession? {
    history.sessions.first { $0.id == id }
  }

  #if os(macOS)
  /// The transient opened text file with `id`, if it is still open.
  func openedFile(_ id: UUID) -> OpenedFile? {
    openedFiles.first { $0.id == id }
  }
  #endif

  /// The live terminal session behind the selection, if it points at one —
  /// the ONE selection→session resolution, used by the menus, the ⌘W/⌘N
  /// navigation and the action runner. Answers from the selection's case
  /// instead of scanning every collection for the id.
  var selectedSession: TerminalSession? {
    guard case .session(let id) = selection else { return nil }
    return session(id)
  }

  /// The note currently focused in the main view, if any.
  var selectedNote: NotesStore.NoteSummary? {
    guard case .note(let id) = selection else { return nil }
    return note(id)
  }

  /// Routes a sidebar selection to the item it names. The sidebar's `List`
  /// writes the clicked row's `Selection` and nothing else: a saved SSH host
  /// connects, a persistent-session row attaches (or focuses) its terminal, a
  /// saved page or database row opens (or focuses) its browser. A selection
  /// that already names an open item is a no-op — it IS the presented pane.
  /// (This used to be the sidebar's job, and it had to look the raw id up in
  /// the connection store, the web store, the database store and the two
  /// screen lists in turn to discover which kind of row had been clicked.)
  func activate(_ selection: Selection) {
    switch selection {
    case .session, .note, .history, .openedFile:
      break
    case .ssh(let id):
      if let config = connections.first(where: { $0.id == id }) {
        connect(to: config)
      }
    case .web(let id):
      if let web = webSessions.all.first(where: { $0.id == id }) {
        openOrFocusWebSession(web)
      }
    case .database(let id):
      if let connection = databaseConnections.first(where: { $0.id == id }) {
        openOrFocusDatabaseConnection(connection)
      }
    case .screen(let tagID):
      #if os(macOS) || os(Windows)
      if let info = screenMonitor.sessions.first(where: { $0.tagID == tagID }) {
        attachOrFocus(info)
      } else if let info = remoteScreenSessions.first(where: { $0.tagID == tagID }),
                let config = connections.first(where: { $0.id == info.remoteOrigin?.sshConfigID }) {
        attachOrFocus(info, on: config)
      }
      #else
      // iOS renders no persistent-session rows (no local multiplexer, no
      // remote scanner), so a `.screen` selection can't occur there.
      _ = tagID
      #endif
    }
  }

  /// The selection a saved web page's sidebar row tags with: the OPEN page's
  /// session when there is one (so the row highlights while its WebView is
  /// up), else the page's own id — an activation selection that opens it.
  func rowSelection(for web: WebSession) -> Selection {
    if let live = liveWebSession(for: web) { return .session(live.id) }
    return .web(web.id)
  }

  /// The selection a saved database connection's sidebar row tags with: the
  /// open browser's session when there is one, else the connection's own id
  /// (activating that opens the browser). Same convention as the web rows.
  func rowSelection(for connection: DatabaseConnection) -> Selection {
    if let live = liveDatabaseSession(for: connection) { return .session(live.id) }
    return .database(connection.id)
  }

  #if os(macOS) || os(Windows)
  /// The selection a persistent (screen/tmux) session's sidebar row tags
  /// with: the attached terminal's session when one is open (so the row
  /// highlights while its terminal is up), else the row's stable `tagID` —
  /// an activation selection that attaches (or focuses) a terminal.
  func rowSelection(forScreen info: ScreenSessionInfo) -> Selection {
    if let attached = attachedSession(toScreen: info) { return .session(attached.id) }
    return .screen(info.tagID)
  }
  #endif

  #if os(macOS) || os(Windows)
  /// Focuses the open terminal attached to `info`, or attaches a new one.
  /// Focusing (rather than multi-attaching) keeps the persistent session's
  /// state honest — a second client would leave it "Attached" after either
  /// one closes. A remote row is identified by its origin host.
  private func attachOrFocus(_ info: ScreenSessionInfo, on config: SSHConfig? = nil) {
    if let existing = attachedSession(toScreen: info) {
      selection = .session(existing.id)
    } else if let config {
      attach(toRemoteScreen: info, on: config)
    } else {
      attach(toScreen: info)
    }
  }
  #endif

  /// The selection that focuses the item with `id` — its kind is not known to
  /// the caller (a detached window or the detach badge reports a bare id), so
  /// resolve it against the two detachable collections (sessions, notes).
  private func selection(forItemID id: UUID) -> Selection {
    note(id) == nil ? .session(id) : .note(id)
  }

  /// The selection that can be detached (a session or a note), nil when
  /// nothing detachable is selected. Drives the "Detach Session/Note" menu
  /// command: its enabled state and which item the ⌘⇧D toggle acts on. An
  /// item stays detachable while detached, so ⌘⇧D again returns it.
  var selectedDetachable: Selection? {
    switch selection {
    case .session, .note:
      return selection
    default:
      return nil
    }
  }

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
  /// the content area presented nothing and the item was stuck. This returns
  /// it to the main window: remove from `detachedIDs` and select it so it
  /// reappears and is focusable. An empty note is deleted (mirrors the ⌘W
  /// close behavior).
  func handleDetachedWindowClosed(_ id: UUID) {
    guard detachedIDs.contains(id) else { return }
    markAttached(id)
    // A detached empty note is deleted just like an empty note closed with
    // ⌘W — look it up by id (not by the current selection, which may have
    // moved on while the detached window was up).
    if note(id) != nil, notes.isEmptyNote(id) {
      deleteNote(id)
      return
    }
    selection = selection(forItemID: id)
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
      let number = (shellSessions(for: config).firstIndex { $0.id == session.id } ?? 0) + 1
      return "\(config.displayName) #\(number)"
    case .web(let web):
      return webDisplayName(for: web)
    case .database(let connection):
      return connection.displayName
    }
  }

  /// The name shown for a web page (window title and sidebar row): the saved
  /// name, else the page's URL, else a generic label while the address field is
  /// still empty (a page started from a host's "Web Session" item has neither
  /// until the first load). The STORE is the source of truth rather than the
  /// open session's `.web` snapshot: an auto-name derived from the page's HTML
  /// `<title>` (`autoNameWebSession`) lands in the store after load, while the
  /// snapshot was captured at open time.
  func webDisplayName(for web: WebSession) -> String {
    let saved = webSessions.all.first { $0.id == web.id } ?? web
    if !saved.name.isEmpty { return saved.name }
    return saved.url.isEmpty ? "Web Session" : saved.url
  }

  /// Names a web page from the loaded page's HTML `<title>` — the naming hook
  /// for a page that was opened with no name prompt. Only a SAVED page with a
  /// URL and no name yet is named, and a user-given name (the Edit… sheet) is
  /// never overwritten, so renaming a page stops the auto-naming for it.
  func autoNameWebSession(_ web: WebSession, pageTitle: String) {
    let title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    guard let saved = webSessions.all.first(where: { $0.id == web.id }),
          !saved.url.isEmpty, saved.name.isEmpty
    else { return }
    var updated = saved
    updated.name = title
    webSessions.save(updated)
  }

  /// Whether a saved web page is still blank — no URL and no name, i.e. it was
  /// started from a host's "Web Session" item and never used.
  func isBlankWebSession(_ web: WebSession) -> Bool {
    guard let saved = webSessions.all.first(where: { $0.id == web.id }) else { return false }
    return saved.url.isEmpty && saved.name.isEmpty
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
  
  #if os(macOS) || os(Windows)
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
    selection = .session(session.id)
    return session
  }
  #endif

  #if os(macOS) || os(Windows)
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
    // A dropped link (host rebooting, network gone) is dialed again with a
    // fresh SSHSession until the host answers; the terminal keeps its
    // scrollback. A shell the user ends (`exit`) just closes.
    let session = TerminalSession(
      transport: SSHSession(config: config),
      startupMessage: "Connecting to \(config.host)…",
      reconnect: { SSHSession(config: config) }
    )
    sessionKinds[session.id] = .ssh(config)
    registerCapture(for: session, archiveLocally: false)
    sessions.append(session)
    selection = .session(session.id)
    #if os(macOS) || os(Windows)
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
    // behavior; removeSession stops it. A plain web page needs no runtime, and
    // neither does an ssh-owned page with no URL yet — there is nothing to
    // tunnel to, so the runtime starts on the first URL commit (the reconnect
    // in `updateWebSessionURL` routes back through here).
    if web.sshConfigID != nil, !web.url.isEmpty {
      let config = connections.first { $0.id == web.sshConfigID }
      let runtime = WebSessionRuntime(web: web, config: config)
      webSessionRuntimes[web.id] = runtime
      runtime.start()
    }
    let session = TerminalSession(transport: WebSessionTransport())
    sessionKinds[session.id] = .web(web)
    sessions.append(session)
    selection = .session(session.id)
    return session
  }

  /// Opens a blank local web session with no URL configured: creates an empty
  /// `WebSession`, opens it like any saved page (so it is selected), and leaves
  /// the address bar empty for the user to type into. Unlike a host-bound page
  /// this does NOT persist a saved session up front — the user types a URL and
  /// presses Return to navigate, and `updateWebSessionURL` persists on the first
  /// commit (which is also what names the row, from the page's title). Used by
  /// the Local section's "Web Session" menu item.
  @discardableResult
  func openEmptyWebSession() -> TerminalSession {
    openWebSession(WebSession())
  }

  /// Opens a NEW ssh-owned web page immediately — no setup sheet: saves a blank
  /// `WebSession` bound to `config` (so its row appears under that host straight
  /// away) and opens it, focused, with the URL field still empty. The user types
  /// the page's address into the toolbar's URL field; committing it persists the
  /// URL and starts the SSH local port-forward, and the loaded page then names
  /// the row from its HTML `<title>` (`autoNameWebSession`). Used by the SSH
  /// config row's "Web Session" menu items.
  @discardableResult
  func openNewWebSession(on config: SSHConfig) -> TerminalSession {
    let web = WebSession(sshConfigID: config.id)
    webSessions.save(web)
    return openWebSession(web)
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
      selection = .session(live.id)
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

  #if os(macOS) || os(Windows)
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
  #if os(macOS) || os(Windows)
  /// Opens a local terminal attached to an existing persistent session
  /// (`screen -x` for screen, `tmux attach` for tmux).
  @discardableResult
  func attach(toScreen info: ScreenSessionInfo) -> TerminalSession {
    // tmux attach when tmux is installed; otherwise screen -x (screen
    // ships with macOS). LocalPTYTransport.tmux is nil without tmux.
    let session: TerminalSession
    if info.kind == .session, let transport = LocalPTYTransport.session(info.name) {
      // session-tool: `session <name>` is create-or-attach, so attaching
      // here both (re)attaches to a live session and creates a missing one.
      session = TerminalSession(session: transport)
    } else if info.kind == .tmux, let transport = LocalPTYTransport.tmux(info.name) {
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
    selection = .session(session.id)
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
    selection = .session(session.id)
    refreshRemoteScreenSessions()  // the session just flipped to Attached
    return session
  }

  /// The live SSH transport for `config`, if one of its terminals is
  /// connected. One-shot execs (remote persistent create/close) reuse this
  /// authenticated channel — the scanner never dials a throwaway connection.
  private func liveSSHTransport(for config: SSHConfig) -> SSHSession? {
    connectedSSHSessions
      .first { $0.sshTransport?.config.id == config.id }?
      .sshTransport
  }

  /// True when `config` has a live, connected SSH terminal whose exec channel
  /// can run one-shot commands. Gates the context menu's Persistent Session
  /// item (a remote create must run on an already-connected host).
  func hasLiveSSHConnection(to config: SSHConfig) -> Bool {
    liveSSHTransport(for: config) != nil
  }

  /// Manual refresh of every persistent-session list: the local multiplexers
  /// AND the connected SSH hosts' screen/tmux sessions. With the 5s auto-poll
  /// disabled this is the sidebar's "Refresh Sessions" action; attach/close
  /// events still refresh their own lists on top of this.
  func refreshPersistentSessions() {
    guard features.isEnabled(.screen) else { return }
    screenMonitor.refresh()
    refreshRemoteScreenSessions()
  }

  /// Creates a NEW persistent session on a connected SSH host and opens a
  /// terminal attached to it — the remote analogue of `createScreenSession()`.
  /// The create runs as one-shot execs over the live connection (never a
  /// throwaway dial): tmux when the host has it, falling back to screen when
  /// tmux is absent (exec exit 127). The name is auto-generated from the
  /// sessions last scanned on that host; failures surface as a screen-action
  /// alert.
  func createRemoteScreenSession(on config: SSHConfig) {
    guard features.isEnabled(.screen),
          let transport = liveSSHTransport(for: config) else { return }
    let origin = ScreenRemoteOrigin(sshConfigID: config.id, displayName: config.displayName)
    let existing = Set(
      remoteScreenSessions
        .filter { $0.remoteOrigin?.sshConfigID == config.id }
        .map(\.shortName)
    )
    let name = ScreenSessionsParser.nextSessionName(existing: existing)
    // tmux first; exit 127 = command not found -> screen fallback below.
    transport.runCommand("tmux new-session -d -s \(name)") { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch result {
        case .failure(let error):
          self.screenSessionActionError("tmux new-session failed: \(error.localizedDescription)")
        case .success(let run):
          if run.exitStatus == 0 {
            self.attachAfterRemoteCreate(name: name, kind: .tmux, config: config, origin: origin)
          } else if run.exitStatus == 127, let transport = self.liveSSHTransport(for: config) {
            transport.runCommand("screen -dmS \(name)") { [weak self] result in
              Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error):
                  self.screenSessionActionError("screen -dm failed: \(error.localizedDescription)")
                case .success(let run):
                  if run.exitStatus == 0 {
                    self.attachAfterRemoteCreate(name: name, kind: .screen, config: config, origin: origin)
                  } else {
                    self.screenSessionActionError(
                      "tmux is not installed on \(config.displayName) and screen exited \(run.exitStatus)."
                    )
                  }
                }
              }
            }
          } else {
            self.screenSessionActionError(
              "Creating a persistent session on \(config.displayName) failed: tmux exited \(run.exitStatus)."
            )
          }
        }
      }
    }
  }

  /// Refreshes the remote list and attaches to the just-created session. The
  /// scanner can lag the create by a beat (exec + re-list round-trips), so
  /// poll briefly; once the window is exhausted the attach runs against a
  /// constructed row (by then the host's screen/tmux socket is up).
  private func attachAfterRemoteCreate(
    name: String,
    kind: PersistentSessionKind,
    config: SSHConfig,
    origin: ScreenRemoteOrigin,
    attempts: Int = 6
  ) {
    refreshRemoteScreenSessions()
    if let info = remoteScreenSessions.first(where: {
      $0.remoteOrigin?.sshConfigID == config.id && $0.shortName == name && $0.kind == kind
    }) {
      attach(toRemoteScreen: info, on: config)
      return
    }
    guard attempts > 0 else {
      attach(
        toRemoteScreen: ScreenSessionInfo(name: name, pid: 0, state: "detached", kind: kind, remoteOrigin: origin),
        on: config
      )
      return
    }
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      self?.attachAfterRemoteCreate(
        name: name, kind: kind, config: config, origin: origin, attempts: attempts - 1
      )
    }
  }

  /// Surfaces a remote persistent-session failure through the monitor's alert
  /// (the sidebar already presents `screenMonitor.actionError`).
  private func screenSessionActionError(_ message: String) {
    screenMonitor.actionError = ScreenActionError(
      title: "Could not create persistent session",
      message: message
    )
  }
  #endif
  
  /// Every running session bound to a connection, in creation order — SHELL
  /// sessions AND the host-bound web pages / database connections tunnelled
  /// through it (`ConnectionKind.sshConfigID` is non-nil for all three). This is
  /// the sidebar SECTION grouping, used to pick ⌘W/⌘N neighbors. To emit the
  /// host's terminal rows use `shellSessions(for:)` instead: rendering this set
  /// as rows duplicates every web page and database connection, which have their
  /// own row views.
  func sessions(for config: SSHConfig) -> [TerminalSession] {
    sessions.filter { kind(of: $0).sshConfigID == config.id }
  }

  /// The SSH SHELL sessions for a connection, in creation order — the rows the
  /// Remote section emits under the host, and the basis for the `#N` numbering
  /// in `displayName`. Uses `shellConfigID`, not `sshConfigID`, so an open
  /// host-bound web page or database connection neither adds a duplicate row nor
  /// shifts the numbering.
  func shellSessions(for config: SSHConfig) -> [TerminalSession] {
    sessions.filter { kind(of: $0).shellConfigID == config.id }
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
    if selection == .session(id) {
      selection = sessions.last.map { .session($0.id) }
    }
  }

  /// Terminates every running action session shown in the sidebar's Running
  /// section. Iterates only over `actionSessions`, so local/ssh/screen/web/
  /// database sessions are left untouched.
  func closeAllActionSessions() {
    for id in actionSessions.map(\.id) {
      removeSession(id)
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
      #if os(macOS) || os(Windows)
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
  #if os(macOS) || os(Windows)
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
  #if os(macOS) || os(Windows)
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
  func openFile(_ url: URL, select: Bool = true) {
    if let existing = openedFiles.first(where: { $0.url == url }) {
      if select { selection = .openedFile(existing.id) }
      return
    }
    openFileGeneration += 1
    let generation = openFileGeneration
    var opened = OpenedFile(url: url, loadGeneration: generation)
    openedFiles.append(opened)
    if select { selection = .openedFile(opened.id) }
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
    scheduleOpenedFileSave(id, text: text)
  }

  /// Notes-style autosave: writes the edit buffer through to the file 5s
  /// after the last keystroke (the same debounce the Notes editor uses),
  /// cancelling any earlier pending write so rapid typing doesn't thrash
  /// the disk. The pane no longer exposes an explicit Save — the user asked
  /// for write-through autosave, not manual Save.
  private func scheduleOpenedFileSave(_ id: UUID, text: String) {
    openedFileSaveTasks[id]?.cancel()
    openedFileSaveTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: Self.openedFileSaveDelay)
      guard !Task.isCancelled else { return }
      self?.writeOpenedFile(id, text: text)
    }
  }

  private func writeOpenedFile(_ id: UUID, text: String) {
    guard let idx = openedFiles.firstIndex(where: { $0.id == id }) else { return }
    let file = openedFiles[idx]
    guard file.canEdit else { return }
    do {
      try text.write(to: file.url, atomically: true, encoding: .utf8)
      openedFiles[idx].isDirty = false
    } catch {
      openedFiles[idx].loadNotice = "Could not save: \(error.localizedDescription)"
    }
  }

  /// Flushes every pending opened-file autosave immediately (scene change,
  /// app quit). Mirrors `NotesStore.flush()`.
  func flushOpenedFiles() {
    for (id, task) in openedFileSaveTasks {
      task.cancel()
      if let file = openedFiles.first(where: { $0.id == id }) {
        writeOpenedFile(id, text: file.text)
      }
    }
    openedFileSaveTasks.removeAll()
  }

  /// Closes a file, flushing any pending autosave so the final edits land on
  /// disk before the pane goes away.
  func closeOpenedFile(_ id: UUID) {
    openedFileSaveTasks[id]?.cancel()
    openedFileSaveTasks[id] = nil
    guard let idx = openedFiles.firstIndex(where: { $0.id == id }) else { return }
    let file = openedFiles[idx]
    if file.canEdit {
      try? file.text.write(to: file.url, atomically: true, encoding: .utf8)
    }
    openedFiles.remove(at: idx)
    unlinkFile(file.url)
    let next = openedFiles.indices.contains(idx) ? openedFiles[idx].id : openedFiles.last?.id
    selection = next.map { .openedFile($0) }
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
    // ⌘W with an opened file focused closes it, flushing any pending
    // autosave first (the file is write-through, so nothing is lost).
    if case .openedFile(let fileID) = selection, let file = openedFile(fileID) {
      closeOpenedFile(file.id)
      return
    }
    #endif
    guard let session = selectedSession else { return }
    // ⌘W on a web page that never got a URL (started from an SSH host's
    // "Web Session" item and left blank) drops its saved entry too, so it
    // doesn't linger as an unnamed row. A page that got a URL is kept — by then
    // it has an auto-name from its title, or the user's own name.
    if case .web(let web) = kind(of: session), isBlankWebSession(web) {
      webSessions.remove(web.id)
    }
    let section = sectionSessions(containing: session)
    let index = section.firstIndex { $0.id == session.id } ?? 0
    let wasOnly = section.count == 1
    
    if case .screen(let info) = kind(of: session) {
      #if os(macOS) || os(Windows)
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
      selection = .session(remaining[index - 1].id)
    } else {
      selection = .session(remaining[0].id)
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
  
  #if os(macOS) || os(Windows)
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
       let config = connections.first(where: { $0.id == origin.sshConfigID }),
       let transport = liveSSHTransport(for: config) {
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
    if selection == .ssh(config.id) {
      selection = sessions.last.map { .session($0.id) }
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
      selection = .session(live.id)
      return live
    }
    // Load the persisted credential when the caller didn't supply one.
    let password = password ?? databaseStore.password(for: connection)
    let dbSession = DatabaseSession(connection: connection, sshConfigStore: connectionStore)
    let session = TerminalSession(transport: DatabaseTransport())
    sessionKinds[session.id] = .database(connection)
    sessions.append(session)
    selection = .session(session.id)
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
      #elseif os(iOS)
      let host = UIDevice.current.name
      #else
      let host = ProcessInfo.processInfo.hostName
      #endif
      let comment = "Shell (\(NSUserName())@\(host))"
      let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: comment)
      KitPasteboard.copy(line)
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
    selection = .note(note.id)
    return note
  }

  /// Deletes a note (and its file); selects the previous note when the
  /// deleted one was focused.
  func deleteNote(_ id: UUID) {
    notes.deleteNote(id)
    if selection == .note(id) {
      selection = notes.notes.first.map { .note($0.id) }
    }
  }

  // MARK: - Local history and command transcripts

  func toggleHistoryMode() {
    if historyMode {
      historyMode = false
      if case .session(let previous) = selectionBeforeHistory, session(previous) != nil {
        selection = .session(previous)
      } else {
        let fallback = sessions.first { kind(of: $0) == .local } ?? sessions.last
        selection = fallback.map { .session($0.id) }
      }
      selectionBeforeHistory = nil
    } else {
      if selectedSession != nil { selectionBeforeHistory = selection }
      historyMode = true
      selection = history.sessions.first.map { .history($0.id) }
    }
  }

  func deleteHistorySession(_ id: UUID) {
    history.remove(id)
    if selection == .history(id) {
      selection = history.sessions.first.map { .history($0.id) }
    }
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
    #if os(macOS) || os(Windows)
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
    #if os(macOS)
    flushOpenedFiles()
    #endif
    let localIDs = sessions.filter { kind(of: $0) == .local }.map(\.id)
    for id in localIDs { archiveLocalSession(id) }
    history.flush()
  }

  private func registerCapture(for session: TerminalSession, archiveLocally: Bool) {
    sessionCommands[session.id] = []
    // With History off nothing is captured for the archive.
    if archiveLocally, features.isEnabled(.history) {
      localHistoryDrafts[session.id] = LocalHistoryDraft(capture: TerminalHistoryCapture(seed: session.snapshot))
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
      self?.localHistoryDrafts[session.id]?.capture.capture(snapshot)
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
          !draft.commands.isEmpty,
          // Turned off while the session ran: drop what was captured.
          features.isEnabled(.history)
    else { return }
    history.archive(HistorySession(
      id: id,
      commands: draft.commands,
      output: draft.capture.output,
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
      #if os(macOS) || os(Windows)
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
      #if os(macOS) || os(Windows)
      // -lic (login + interactive + command) sources ~/.zshrc so the
      // user's environment (e.g. bun's PATH in ~/.zshrc) is present when
      // the action runs. Plain -lc is non-interactive and skips .zshrc.
      transport = LocalPTYTransport.command(spec.action.commands)
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
      let resolved = SmartAddress.resolve(spec.action.webAddress)
      // Persist the session so it appears in the sidebar (the sidebar renders
      // only *saved* web pages). Reuse an existing page for the same address +
      // SSH host so re-running the action focuses the same sidebar row instead
      // of stacking duplicate bookmarks; a new matched page (a brand-new
      // action) is saved once and opened.
      let web: WebSession
      if let existing = webSessions.all.first(where: { $0.url == resolved && $0.sshConfigID == environment.sshConfig?.id }) {
        web = existing
      } else {
        web = WebSession(
          name: spec.action.name,
          url: resolved,
          sshConfigID: environment.sshConfig?.id
        )
        webSessions.save(web)
      }
      openOrFocusWebSession(web)
      showingActions = false
    } else if focus {
      selection = .session(newSession.id)
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
      case .starting, .connecting, .reconnecting, .connected: return true
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

  #if os(macOS) || os(Windows)
  /// Recomputes the smart actions for the active local directory. Returns
  /// immediately; the blocking scan (directory listing + CodeActions scan +
  /// cache save) runs off the main thread so a large directory never stalls
  /// the UI. The cache short-circuits unchanged directories. Passing nil
  /// clears them.
  ///
  /// A directory visited before publishes its memoized schemes SYNCHRONOUSLY
  /// (the memo is keyed by canonical path and survives session switches), so
  /// switching sessions shows the toolbar controls instantly instead of
  /// waiting on the encrypted cache read. The background refresh still runs
  /// to revalidate the memo.
  func refreshSmartActions(for directory: URL?) {
    smartActionsGeneration += 1
    smartActionDirectory = directory
    guard let directory else {
      smartActionSchemes = []
      openWithKinds = []
      return
    }
    // Smart Actions disabled → the directory listing + scan is background
    // work that must not run; publish nothing.
    guard features.isEnabled(.smartActions) else {
      smartActionSchemes = []
      openWithKinds = []
      return
    }
    let canonical = directory.standardizedFileURL
    // First visit: publish nothing yet so the toolbar never shows the
    // previous directory's actions under this one. Revisit: publish the
    // memoized result immediately, then revalidate in the background.
    if let memo = smartActionResultMemo[canonical.path] {
      smartActionSchemes = memo.schemes
      openWithKinds = memo.openKinds
    } else {
      smartActionSchemes = []
      openWithKinds = []
    }
    let generation = smartActionsGeneration
    let coordinator = smartActions
    Task { @MainActor [weak self] in
      // The coordinator (and the "Open With" resolution) are pure,
      // non-MainActor-bound logic — run them off the main actor, then hop
      // back to publish.
      let result = await Task.detached(priority: .userInitiated) {
        let schemes = coordinator.refresh(directory: canonical)
        let entries = IntegrationFileLister.list(directory: canonical)
        // The lister skips dotfiles, so whether it's a repository is checked here.
        let isRepository = FileManager.default.fileExists(atPath: canonical.appendingPathComponent(".git").path)
        let openKinds = OpenWithResolver.kinds(for: entries, isRepository: isRepository)
        return (schemes: schemes, openKinds: openKinds)
      }.value
      guard let self, self.smartActionsGeneration == generation else { return }
      let memo = SmartActionResult(schemes: result.schemes, openKinds: result.openKinds)
      self.smartActionResultMemo[canonical.path] = memo
      self.smartActionSchemes = memo.schemes
      self.openWithKinds = memo.openKinds
    }
  }

  /// The currently running smart-action session for a directory, if any.
  func currentSmartAction(in directory: URL) -> TerminalSession? {
    currentSmartActionByDirectory[directory.standardizedFileURL.path]?.session
  }

  /// Whether `kind` of `scheme` is the smart action running in `directory`
  /// (gates the toolbar control's stop.fill state).
  func isSmartActionRunning(_ kind: ActionKind, scheme: ActionScheme, in directory: URL) -> Bool {
    guard let running = currentSmartActionByDirectory[directory.standardizedFileURL.path] else { return false }
    return running.schemeID == scheme.id && running.kind == kind
  }

  /// Runs `kind` of `scheme` (CodeActions' command for a terminal) as a
  /// Running-section session in `directory` with no focus. Replaces any
  /// current run for that directory (stops it first); archives to history on
  /// completion via `actionSessionCompleted`.
  func runSmartAction(_ kind: ActionKind, scheme: ActionScheme, in directory: URL) {
    guard let schemeCommand = scheme.terminalCommand(for: kind) else { return }
    // An Export needs notarization set up first: the sheet checks it and
    // runs the action again once a profile is saved.
    var environment = ""
    if kind.needsNotarization {
      guard let notaryProfile else {
        notarizationSetup = NotarizationSetupRequest(scheme: scheme, directory: directory)
        return
      }
      environment = "export NOTARY_PROFILE=\(shellQuote(notaryProfile)) && "
    }

    // Replace semantics: stop the current run for this dir before starting.
    stopSmartAction(in: directory)

    // LocalPTYTransport has no working-dir parameter, so cd into the project.
    let command = "\(environment)cd \(shellQuote(scheme.directory.path)) && \(schemeCommand)"
    let spec = ActionSpec(
      action: Action(
        id: UUID(),
        name: "\(kind.title) · \(scheme.name)",
        appliesToLocal: true,
        commands: command,
        focusWindow: false,
        keepAfterCompletion: false
      ),
      config: nil
    )
    // -lic sources ~/.zshrc (same reasoning as runAction): a bun or other
    // tool added to PATH in .zshrc must be visible for the smart action.
    let transport = LocalPTYTransport.command(command)
    let newSession = TerminalSession(transport: transport)
    sessionKinds[newSession.id] = .action(spec)
    registerActionCapture(for: newSession, seedCommand: command)
    let key = directory.standardizedFileURL.path
    currentSmartActionByDirectory[key] = RunningSmartAction(session: newSession, schemeID: scheme.id, kind: kind)
    newSession.actionCompletionHandler = { [weak self, weak newSession] in
      guard let self, let newSession else { return }
      if self.currentSmartActionByDirectory[key]?.session === newSession {
        self.currentSmartActionByDirectory[key] = nil
      }
      self.actionSessionCompleted(newSession)
    }
    sessions.append(newSession)
    // No focus: the run stays in Running, the user's selection is unchanged.
  }

  /// Terminates the running smart-action session for a directory and takes
  /// it out of Running (no-op when none is running). Closing stops watching
  /// the process, so its exit never completes the run on its own.
  func stopSmartAction(in directory: URL) {
    guard let running = currentSmartActionByDirectory.removeValue(
      forKey: directory.standardizedFileURL.path
    ) else { return }
    removeSession(running.session.id)
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
    guard features.isEnabled(.authorizedKeys) else { return }
    authorizedKeysTarget = target
    showingAuthorizedKeys = true
  }

  /// The Local section's key-ring button: this Mac's authorized_keys.
  func openLocalAuthorizedKeys() {
    showAuthorizedKeys(for: .local)
  }

  /// Re-reads the shared stores and the notes folders when the scene becomes
  /// active (they also follow changes live; this catches anything missed while
  /// the app was in the background). The launch-time activation is skipped in
  /// ContentView.
  func refreshOnActivation() {
    // Notes are gated behind their feature. SSH configs and device keys always
    // refresh.
    if features.isEnabled(.notes) { notes.refreshOnActivation() }
    connectionStore.refreshOnActivation()
    if features.isEnabled(.authorizedKeys) { deviceKeys.refreshOnActivation() }
    databaseStore.refreshOnActivation()
  }
}
