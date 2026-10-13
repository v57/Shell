import SwiftUI
import ShellKit
import ShellIntegrations
#if os(macOS)
import UpdateKit
#endif

@main
struct ShellApp: App {
  #if os(macOS)
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// Updates for the Mac app from GitHub Releases (Shell.zip, built by
  /// Scripts/release.sh): checked daily once the user turns on
  /// automatic checks (never before), installed in place with a relaunch.
  /// The iOS app updates through the App Store.
  private let updater = AppUpdater(github: "v57/Shell", assetName: "Shell.zip")

  init() { updater.start() }
  #endif

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(AppModel.shared)
    }
    #if os(macOS)
    .commands {
      ShellCommands()
      UpdaterCommands(updater: updater)
    }
    #endif

    // Settings is an in-window overlay (not a separate window/scene), so it
    // opens over the main window like the Actions overlay. On macOS it is
    // reached from the Shell menu's Settings… item (⌘,) which sets
    // AppModel.showingSettings; on iOS from the sidebar gear button.

    // A detached session/note lives in its own value-keyed window (macOS) or
    // scene (iPad), created by `openWindow(id: "detach", value: id)`; it is
    // returned to the main window by re-attaching (removing the id from
    // AppModel.detachedIDs) and dismissing (`dismissWindow(id: "detach")`).
    // The UUID resolves to the same detail content (TerminalView/NoteEditorView
    // via DetachDetailView). Present on macOS + iPad; iPhone stays single-scene.
    WindowGroup("Detach", id: "detach", for: UUID.self) { itemID in
      DetachDetailView(itemID: itemID.wrappedValue ?? UUID())
        .environment(AppModel.shared)
    }
  }
}

#if os(macOS)
/// Removes the system File > Close (⌘W) so the shortcut closes the
/// selected terminal (Shell > Close Terminal) instead of the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Retains the ⌘W local key monitor token (nil = not armed).
  private var cmdWMonitor: Any?

  /// Flushes pending note autosaves on quit (the last <5s of typing).
  func applicationWillTerminate(_ notification: Notification) {
    AppModel.shared.flushForTermination()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      self?.removeSystemCloseItems()
    }
    installCmdWMonitor()
  }

  /// Routes files/directories opened into Shell — from Finder "Open With > Shell"
  /// or a drop on the Dock icon — to the right pane:
  /// - a folder opens a new local terminal session running in it,
  /// - a recognized text file opens the file-content pane (`OpenFilePane`),
  /// - anything else is dropped silently (`.ignored`).
  ///
  /// AppKit delivers this open event both when the app is cold-launched by the
  /// open and when it is already running, so one handler covers both. The work
  /// is dispatched to the main actor because `AppModel.shared` is a `@MainActor`
  /// singleton; `addLocalTerminal(in:)` already selects the new session and
  /// `openFile(_:)` already selects the opened-file pane.
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    Task { @MainActor in
      for filename in filenames {
        let url = URL(fileURLWithPath: filename)
        switch OpenPathResolver.target(for: url) {
        case .terminal(folder: let folder):
          AppModel.shared.addLocalTerminal(in: folder.path)
        case .textFile(url: let fileURL):
          AppModel.shared.openFile(fileURL)
        case .ignored:
          break
        }
      }
    }
    sender.reply(toOpenOrPrint: .success)
  }

  /// The system File menu provides a ⌘W "Close" that closes the whole window,
  /// and SwiftUI re-generates it every time a window/scene appears — so the
  /// one-time removal below cannot reliably win against it. The authoritative
  /// fix is the ⌘W key monitor (`installCmdWMonitor`), which swallows the key
  /// before menu dispatch. This removal is kept only so the misleading "Close"
  /// item isn't shown when it happens not to be regenerated.
  private func removeSystemCloseItems() {
    guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
    for title in ["New Window", "Close"] {
      if let index = fileMenu.items.firstIndex(where: { $0.title == title }) {
        fileMenu.removeItem(at: index)
      }
    }
  }

  /// ⌘W must close the selected session (or note/opened file) and NEVER the
  /// whole main window — regardless of which subview has focus and regardless
  /// of how many times SwiftUI regenerates the File menu. A local key monitor
  /// runs before menu-key-equivalent dispatch, so the system "Close" can never
  /// win. Modal sheets keep their own ⌘W (they dismiss), and detached-item
  /// windows still close normally (their ⌘W is passed through).
  private func installCmdWMonitor() {
    cmdWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let mods = event.modifierFlags
      // Only plain ⌘W (no shift/option/control).
      guard mods.contains(.command),
            !mods.contains(.shift),
            !mods.contains(.option),
            !mods.contains(.control),
            event.charactersIgnoringModifiers?.lowercased() == "w" else {
        return event
      }
      // A modal sheet owns its ⌘W (dismiss it); don't close a session under it.
      guard let window = NSApp.keyWindow, window.attachedSheet == nil else {
        return event
      }
      // Route ⌘W to session-close only on the main window; detached-item
      // windows close normally. Local monitors always fire on the main thread,
      // so this is safe to assume as the MainActor.
      let handled = MainActor.assumeIsolated {
        // In-window overlays (Actions/Settings) are non-modal; don't close a
        // session beneath one. Swallow the key as a no-op (Esc dismisses them).
        if AppModel.shared.showingActions || AppModel.shared.showingSettings { return true }
        if let main = AppModel.shared.mainWindow, window !== main { return false }
        AppModel.shared.closeSelectedSessionAndSelectNeighbor()
        return true
      }
      return handled ? nil : event
    }
  }
}

/// Application menu commands for creating terminals and managing the SSH key.
struct ShellCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  /// Feature-flag source of truth; a disabled feature's commands are dropped
  /// from the Shell menu so they aren't reachable by key equivalent either.
  private var flags: FeatureFlagsStore { .shared }

  var body: some Commands {
    CommandMenu("Shell") {
      Button(newTerminalLabel) {
        // ⌘N with a note focused creates a new note (same-section logic).
        if AppModel.shared.selectedNote != nil {
          AppModel.shared.newNote()
        } else {
          AppModel.shared.newSessionInSameSection()
        }
      }
      .keyboardShortcut("n", modifiers: .command)

      // ⌘T opens a new terminal tab whose shell starts in the same
      // directory as the current session's cwd (falls back to a plain new
      // local terminal when there's no local cwd). Menu key equivalents
      // are processed before terminal keyDown, so it works while a
      // terminal has focus.
      if flags.isEnabled(.sessions) {
      Button("New Terminal in Same Directory") {
        AppModel.shared.openTerminalInSameDirectoryAsSelected()
      }
      .keyboardShortcut("t", modifiers: .command)
      }
      
      // ⌘⇧N opens a new persistent session and auto-attaches a terminal
      // (screen/tmux). Menu key equivalents are processed before terminal
      // keyDown, so it works while a terminal has focus.
      if flags.isEnabled(.screen) {
      Button("New Persistent Session") {
        AppModel.shared.createScreenSession()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      }

      // ⌘R toggles the actions overlay. Menu key equivalents are
      // processed before terminal keyDown, so it works while a terminal
      // has focus (same precedent as the ⌘W/⌘N rebind).
      if flags.isEnabled(.actions) {
      Button("Actions…") {
        AppModel.shared.showingActions.toggle()
      }
      .keyboardShortcut("r", modifiers: .command)

      Button("Create Action from Session") {
        AppModel.shared.createActionFromCurrentSession()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(!AppModel.shared.canCreateActionFromCurrentSession)
      }

      Divider()

      // ⌘E opens the "insert into terminal" overlay. Menu key equivalents
      // are processed before terminal keyDown, so it works while a terminal
      // has focus (same precedent as the ⌘W/⌘N rebind).
      Button("Insert into Terminal…") {
        AppModel.shared.showingCommandInsert = true
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(AppModel.shared.selectedSession == nil)

      Divider()

      // ⌘⇧D detaches the selected session/note into its own window/scene
      // (macOS window, iPad scene) when attached, or returns it to the main
      // window when pressed again while detached (its window/scene is
      // dismissed and the item is selected in the main window). Disabled
      // when nothing detachable is selected. Menu key equivalents dispatch
      // before terminal keyDown, so it works while a terminal has focus.
      Button("Detach Session/Note") {
        guard let target = AppModel.shared.selectedDetachable else { return }
        let id = target.itemID
        if AppModel.shared.isDetached(id) {
          AppModel.shared.markAttached(id)
          AppModel.shared.selection = target
          dismissWindow(id: "detach", value: id)
        } else {
          openWindow(id: "detach", value: id)
          AppModel.shared.markDetached(id)
        }
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(AppModel.shared.selectedDetachable == nil)

      Divider()

      // ⌘⇧H opens the Themes sheet. Menu key equivalents dispatch before
      // terminal keyDown, so it works while a terminal has focus (and ⌘⇧H
      // doesn't collide with Hide/Hide Others, which are ⌘H/⌥⌘H). Themes
      // is always enabled (no feature toggle) — the menu item is unconditional.
      Button("Themes…") {
        AppModel.shared.showingThemes = true
      }
      .keyboardShortcut("h", modifiers: [.command, .shift])

      // ⌘⇧F toggles the Files panel. Disabled without a selected terminal
      // session (the Files panel only shows alongside a live session). Menu
      // key equivalents dispatch before terminal keyDown, so it works while a
      // terminal has focus.
      if flags.isEnabled(.files) {
      Button("Toggle Files Panel") {
        AppModel.shared.directoryBrowser.visible.toggle()
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .disabled(AppModel.shared.selectedSession == nil)

      // ⌘⇧U navigates the Files panel up one directory. Disabled without a
      // selected session or once the browser is already at the directory root.
      Button("Navigate Up") {
        AppModel.shared.directoryBrowser.navigateUp()
      }
      .keyboardShortcut("u", modifiers: [.command, .shift])
      .disabled(
        AppModel.shared.selectedSession == nil
          || !AppModel.shared.directoryBrowser.canNavigateUp)
      }

      Divider()
      
      // ⌘W closes the selected terminal and focuses its section neighbor
      // (the system File > Close was removed in AppDelegate, so this is
      // the only ⌘W binding).
      Button(closeTerminalLabel) {
        AppModel.shared.closeSelectedSessionAndSelectNeighbor()
      }
      .keyboardShortcut("w", modifiers: .command)
      
      if flags.isEnabled(.ssh) {
      Divider()
      
      Button("Copy SSH Public Key") {
        AppModel.shared.copyPublicKey()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      }

      Divider()

      // Settings… is an overlay (not a separate window) — open it like the
      // Actions overlay. Replaces the system Settings scene's ⌘, binding.
      Button("Settings…") {
        AppModel.shared.showingSettings = true
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }
  
  /// ⌘N creates a new session in the same section as the selected one:
  /// a local terminal, a duplicate connection, or a new persistent
  /// session; a plain local terminal when nothing is selected.
  private var newTerminalLabel: String {
    if AppModel.shared.selectedNote != nil { return "New Note" }
    guard let session = AppModel.shared.selectedSession else {
      return "New Local Terminal"
    }
    switch AppModel.shared.kind(of: session) {
    case .local, .action:
      return "New Local Terminal"
    case .screen:
      return "New Persistent Session"
    case .ssh(let config):
      return "New Connection to \(config.displayName)"
    case .web:
      return "New Web Page"
    case .database(let connection):
      return "Open \(connection.displayName)"
    }
  }
  
  private var closeTerminalLabel: String {
    if AppModel.shared.selectedNote != nil { return "Close Note" }
    guard let session = AppModel.shared.selectedSession else {
      return "Close Terminal"
    }
    switch AppModel.shared.kind(of: session) {
    case .local:
      return "Close Terminal"
    case .action:
      return "Close Action"
    case .screen:
      return "Close Session"
    case .ssh:
      return "Close Connection"
    case .web:
      return "Close Web Page"
    case .database:
      return "Close Database"
    }
  }
}
#endif // os(macOS)
