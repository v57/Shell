import SwiftUI
import Terminal

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
        } else {
          ToolbarItem {
            Button {
              if let session = model.selectedSession {
                // Persistent sessions: quit the session itself
                // (screen -S <name> -X quit / tmux kill-session -t <name>),
                // which also kills every attached client.
                if case .screen(let info) = model.kind(of: session) {
                  #if os(macOS)
                  model.closeScreenSession(info)
                  #else
                  model.removeSession(session.id)
                  #endif
                } else {
                  model.removeSession(session.id)
                }
              }
            } label: {
              Label("Close Terminal", systemImage: "xmark")
            }
            .help("Close Terminal")
            .disabled(model.selectedSession == nil)
          }
        }
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
}
