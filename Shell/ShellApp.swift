import SwiftUI
import Terminal

@main
struct ShellApp: App {
  #if os(macOS)
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  #endif

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(AppModel.shared)
    }
    #if os(macOS)
    .commands {
      ShellCommands()
    }
    #endif
  }
}

#if os(macOS)
/// Removes the system File > Close (⌘W) so the shortcut closes the
/// selected terminal (Shell > Close Terminal) instead of the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Flushes pending note autosaves on quit (the last <5s of typing).
  func applicationWillTerminate(_ notification: Notification) {
    AppModel.shared.flushForTermination()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.async {
      // ⌘W/⌘N close/open terminals, not windows: drop the system
      // File > New Window (⌘N) and File > Close (⌘W) items so the
      // Shell menu's bindings are the only ones for those keys.
      if let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu {
        for title in ["New Window", "Close"] {
          if let index = fileMenu.items.firstIndex(where: { $0.title == title }) {
            fileMenu.removeItem(at: index)
          }
        }
      }
    }
  }
}

/// Application menu commands for creating terminals and managing the SSH key.
struct ShellCommands: Commands {
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
      
      Button("New SSH Connection…") {
        AppModel.shared.showingNewConnection = true
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      // ⌘R toggles the actions overlay. Menu key equivalents are
      // processed before terminal keyDown, so it works while a terminal
      // has focus (same precedent as the ⌘W/⌘N rebind).
      Button("Actions…") {
        AppModel.shared.showingActions.toggle()
      }
      .keyboardShortcut("r", modifiers: .command)

      Button("Create Action from Session") {
        AppModel.shared.createActionFromCurrentSession()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(!AppModel.shared.canCreateActionFromCurrentSession)

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
      
      // ⌘W closes the selected terminal and focuses its section neighbor
      // (the system File > Close was removed in AppDelegate, so this is
      // the only ⌘W binding).
      Button(closeTerminalLabel) {
        AppModel.shared.closeSelectedSessionAndSelectNeighbor()
      }
      .keyboardShortcut("w", modifiers: .command)
      
      Divider()
      
      Button("Copy SSH Public Key") {
        AppModel.shared.copyPublicKey()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
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
    }
  }
}
#endif // os(macOS)
