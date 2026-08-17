import Combine
import SwiftUI
import Terminal
import TerminalIntegrations

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  /// Local Esc monitor while the actions overlay is open (the overlay is
  /// non-modal and never gets keyboard focus, so onExitCommand won't fire).
  /// macOS only — iOS dismisses the overlay by tapping the backdrop.
  #if os(macOS)
  @State private var escMonitor: Any?
  #endif
  /// The launch-time `.active` scene change fires while the SwiftData store
  /// is still bootstrapping; a fetch in that window can trap inside
  /// SwiftData (observed as a launch crash in reload()). Init already
  /// loaded everything, so the first activation is skipped.
  @State private var hasActivatedOnce = false
  /// Live cwd of the selected local session, polled every second (follows
  /// the shell's `cd`). Empty for non-local sessions — no subtitle shown.
  @State private var localDirectoryText = ""
  /// The last directory `refreshSmartActions` was computed for; smart actions
  /// are refreshed only when this changes (the coordinator's cache makes
  /// repeat refreshes of the same directory cheap anyway).
  @State private var activeDirectoryURL: URL?
  /// The picker's currently selected smart-action target (nil = all/project).
  @State private var smartActionsTarget: String?
  private let directoryTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    @Bindable var model = model
    ZStack {
      NavigationSplitView {
        SidebarView()
          .navigationSplitViewColumnWidth(min: 190, ideal: 230)
      } detail: {
        if let session = model.selectedSession {
          TerminalView(session: session)
            .id(session.id)
            .navigationTitle(model.displayName(for: session))
            .navigationDirectorySubtitle(localDirectoryText)
        } else if let historySession = model.selectedHistorySession {
          HistorySessionView(session: historySession)
            .id(historySession.id)
            .navigationTitle(historySession.title)
        } else if let note = model.selectedNote {
          NoteEditorView(noteID: note.id)
            .id(note.id)
            .navigationTitle(model.notes.title(for: note.id))
        } else {
          ContentUnavailableView(
            "No Terminal Selected",
            systemImage: "terminal",
            description: Text("Choose a terminal in the sidebar or create a new one.")
          )
          .navigationTitle("Terminals")
        }
      }
      .toolbar {
        if let historySession = model.selectedHistorySession {
          ToolbarItemGroup {
            Button(role: .destructive) {
              model.deleteHistorySession(historySession.id)
            } label: {
              Label("Delete History", systemImage: "trash")
            }
            .help("Delete History")

            Button {
              model.replayHistorySession(historySession)
            } label: {
              Label("Replay Commands", systemImage: "play")
            }
            .help("Replay Commands")

            Button {
              model.createAction(from: historySession)
            } label: {
              Label("Create Action", systemImage: "command")
            }
            .help("Create Action")
          }
        }
        #if os(macOS)
        // Smart actions for the active local directory: a Run button per
        // action, a Stop button (disabled unless something is running), and a
        // target picker when the project has multiple targets/schemes.
        if let directory = model.smartActionDirectory, !model.smartActionActions.isEmpty {
          ToolbarItemGroup {
            if smartActionsTargets.count > 1 {
              Menu {
                Button("Project") { smartActionsTarget = nil }
                Divider()
                ForEach(smartActionsTargets, id: \.self) { target in
                  Button(target) { smartActionsTarget = target }
                }
              } label: {
                Label(smartActionsTarget ?? "Project", systemImage: "scope")
              }
              .help("Select target")
            }
            ForEach(smartActionsForDisplay) { action in
              Button {
                model.runSmartAction(action, in: directory)
              } label: {
                Label(action.title, systemImage: "play")
              }
              .help(action.command)
            }
            Button {
              model.stopSmartAction(in: directory)
            } label: {
              Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!model.isSmartActionRunning(in: directory))
            .help("Stop the running action")
          }
        }
        #endif
      }
      .sheet(isPresented: $model.showingNewConnection) {
        NewConnectionView()
      }
      .sheet(isPresented: $model.showingNewAction) {
        NewActionView(
          action: model.editingAction,
          commands: model.newActionCommands,
          targetSSHConnectionID: model.newActionTargetSSHConnectionID
        )
      }
      // Notes: refresh on activation (no-push sync trigger — re-fetch shows
      // changes the CloudKit store pulled while the app ran) and flush
      // pending edits when leaving the active scene (also flushed on quit
      // in AppDelegate).
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          // Skip the first activation: init already loaded the stores, and
          // fetching during launch can race SwiftData's store bootstrap.
          if hasActivatedOnce {
            model.refreshOnActivation()
          } else {
            // But CloudKit's initial sync lands AFTER bootstrap, so on
            // first launch the stores are still empty once launch settles.
            // Schedule one delayed refresh (the CloudKit remote-change
            // observer in AppModel covers the same gap live) so iCloud
            // data appears without a restart.
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(4))
              model.refreshOnActivation()
            }
          }
          hasActivatedOnce = true
        } else {
          model.notes.flush()
        }
      }
      .alert("Encrypted Storage Error", isPresented: Binding(
        get: { model.notes.storageError != nil || model.history.storageError != nil },
        set: { if !$0 { model.notes.storageError = nil; model.history.storageError = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(model.notes.storageError ?? model.history.storageError ?? "Unknown encrypted storage error.")
      }

      // The actions list as an in-window overlay (not a sheet) so it
      // appears/closes instantly. Backdrop click, Esc, and ⌘R close it.
      if model.showingActions {
        Color.black.opacity(0.001)
          .ignoresSafeArea()
          .onTapGesture { model.showingActions = false }
        ActionsOverlayView()
          .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }
    }
    .animation(.easeOut(duration: 0.15), value: model.showingActions)
    .onReceive(directoryTimer) { _ in
      refreshLocalDirectory()
    }
    .onChange(of: model.showingActions) { _, showing in
      #if os(macOS)
      if showing {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          if event.keyCode == 53 {   // Esc
            AppModel.shared.showingActions = false
            return nil
          }
          return event
        }
      } else if let escMonitor {
        NSEvent.removeMonitor(escMonitor)
        self.escMonitor = nil
      }
      #endif
    }
  }

  /// Re-queries the selected local session's cwd so the window subtitle
  /// follows the shell's `cd`. Non-local sessions clear the subtitle.
  /// The home-directory prefix is shortened to `~` for display.
  private func refreshLocalDirectory() {
    guard let session = model.selectedSession,
          case .local = model.kind(of: session),
          let path = session.currentDirectory?.path else {
      localDirectoryText = ""
      if activeDirectoryURL != nil {
        activeDirectoryURL = nil
        model.refreshSmartActions(for: nil)
      }
      return
    }
    let home = NSHomeDirectory()
    if path == home {
      localDirectoryText = "~"
    } else if path.hasPrefix(home + "/") {
      localDirectoryText = "~" + path.dropFirst(home.count)
    } else {
      localDirectoryText = path
    }
    let url = URL(fileURLWithPath: path)
    if activeDirectoryURL != url {
      activeDirectoryURL = url
      smartActionsTarget = nil   // don't carry a stale target across projects
      model.refreshSmartActions(for: url)
    }
  }

  /// Non-nil smart-action targets (schemes/executables) sorted for the picker.
  private var smartActionsTargets: [String] {
    Array(Set(model.smartActionActions.compactMap(\.target))).sorted()
  }

  /// Smart actions to show in the toolbar: everything when no target is
  /// selected, otherwise the selected target's actions plus project-wide ones.
  private var smartActionsForDisplay: [IntegrationAction] {
    guard let target = smartActionsTarget else { return model.smartActionActions }
    return model.smartActionActions.filter { $0.target == nil || $0.target == target }
  }
}

/// Shows a navigation subtitle only when `text` is non-empty (empty text
/// would otherwise render an empty subtitle slot).
private extension View {
  @ViewBuilder
  func navigationDirectorySubtitle(_ text: String) -> some View {
    if text.isEmpty {
      self
    } else {
      self.navigationSubtitle(Text(text))
    }
  }
}
