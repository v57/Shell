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
          VStack(spacing: 0) {
            // Terminal | Files selector, sitting directly above the content.
            // We are inside the `if let session` branch, so this is only shown
            // while a terminal session is selected — the Files panel never
            // appears for a note/history/none selection.
            HStack {
              Picker("View", selection: Binding(
                get: { model.directoryBrowser.visible },
                set: { model.directoryBrowser.visible = $0 }
              )) {
                Text("Terminal").tag(false)
                Text("Files").tag(true)
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .frame(width: 220)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            ZStack {
              // The terminal stays mounted so its scrollback/focus state is
              // preserved while the Files panel is shown on top of it.
              TerminalView(session: session)
                .id(session.id)
                .allowsHitTesting(!model.directoryBrowser.visible)

              if model.directoryBrowser.visible {
                FilesPanelView(model: model.directoryBrowser)
                  .transition(.opacity)
                  .background(.background)
              }
            }
          }
          .navigationTitle(model.displayName(for: session))
          .navigationDirectorySubtitle(localDirectoryText)
          .toolbar {
#if os(macOS)
              // Smart actions for the active local directory: a Run button per
              // action, a Stop button (disabled unless something is running), and a
              // target picker when the project has multiple targets/schemes.
              if let directory = model.smartActionDirectory, !model.smartActionActions.isEmpty {
                ToolbarItemGroup(placement: .primaryAction) {
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
                  ForEach(smartActionGroups) { group in
                    SmartActionMenu(actions: group.actions, directory: directory)
                  }
                }
              }
              
              if #available(macOS 26.0, *) {
                ToolbarSpacer()
              }
              
              // Open With for the active local directory — trailing secondary
              // action, showing the available apps' real icons.
              if let directory = model.smartActionDirectory, !model.openWithKinds.isEmpty {
                ToolbarItemGroup(placement: .primaryAction) {
                  OpenWithMenu(directory: directory, kinds: model.openWithKinds)
                }
              }
#endif
            }
        } else if let historySession = model.selectedHistorySession {
          HistorySessionView(session: historySession)
            .id(historySession.id)
            .navigationTitle(historySession.title)
            .toolbar {
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
      .sheet(isPresented: $model.showingCommandInsert) {
        CommandInsertView()
      }
      .sheet(isPresented: $model.showingThemes) {
        ThemesView()
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
    .preferredColorScheme(model.appearanceMode.colorScheme)
    .environment(\.terminalBackgroundsDisabled, model.disableTerminalBackgrounds)
    .onAppear {
      // Set the browser up for the initially-selected session (onChange does
      // not fire for the initial value).
      syncFileBrowser()
    }
    .onReceive(directoryTimer) { _ in
      refreshLocalDirectory()
      // Keep the Files panel's directory in sync with the live session.
      model.directoryBrowser.syncTick()
    }
    // Kick the directory refresh the moment the selected session changes
    // (the timer alone adds up to a second of lag before the toolbar
    // actions refresh when switching sessions in the sidebar).
    .onChange(of: model.selectedSession?.id) { _, _ in
      refreshLocalDirectory()
      syncFileBrowser()
    }
    .onChange(of: model.directoryBrowser.visible) { _, nowVisible in
      if nowVisible {
        // Opening the panel fetches a fresh listing. SSH pwd polling is gated
        // on visibility, so a remote panel is stale until it appears.
        Task { await model.directoryBrowser.refresh() }
      }
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

  /// Points the shared File browser model at the currently-selected session
  /// (or clears it when nothing terminal-ish is selected), so the Files panel
  /// rebuilds its context and lists the right directory for the right runner.
  private func syncFileBrowser() {
    if let session = model.selectedSession {
      model.directoryBrowser.setSession(session, kind: model.kind(of: session))
    } else {
      model.directoryBrowser.setSession(nil, kind: .local)
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

  /// Displayed actions grouped by kind (icon), preserving first-appearance
  /// order. Groups with a single action render as a plain button; groups with
  /// several render as a menu whose primary action runs the selected one.
  private var smartActionGroups: [SmartActionGroup] {
    var order: [IntegrationActionKind] = []
    var map: [IntegrationActionKind: [IntegrationAction]] = [:]
    for action in smartActionsForDisplay {
      if map[action.kind] == nil { order.append(action.kind) }
      map[action.kind, default: []].append(action)
    }
    return order.map { SmartActionGroup(kind: $0, actions: map[$0] ?? []) }
  }
}

/// A group of smart actions sharing the same kind (icon). Used by the toolbar
/// to render several same-icon actions as a menu instead of many buttons.
private struct SmartActionGroup: Identifiable {
  let kind: IntegrationActionKind
  let actions: [IntegrationAction]
  var id: IntegrationActionKind { kind }
}

/// A smart-action control for one kind: renders a single button when there's
/// one action, or a menu whose primary action runs the currently selected
/// action (the dropdown switches the selection). Normal icon per kind
/// (Build = hammer, Run = play, Test = play.diamond); when the selected action
/// is running the icon flips to `stop.fill` and the primary action stops it
/// instead — so there's no separate Stop button.
private struct SmartActionMenu: View {
  let actions: [IntegrationAction]
  let directory: URL
  @Environment(AppModel.self) private var model
  @State private var selectedAction: IntegrationAction?

  private var selected: IntegrationAction { selectedAction ?? actions[0] }

  var body: some View {
    if actions.count > 1 {
      Menu {
        ForEach(actions) { action in
          Button(action.title, systemImage: smartActionIcon(for: action)) {
            selectedAction = action
          }
        }
      } label: {
        Label(selected.title, systemImage: smartActionIcon(for: selected))
      } primaryAction: {
        toggle(selected)
      }.menuIndicator(.hidden)
    } else if let action = actions.first {
      Button(action.title, systemImage: smartActionIcon(for: action)) {
        toggle(action)
      }
    }
  }

  /// Run the action, or stop it when it's already the running one.
  private func toggle(_ action: IntegrationAction) {
    if model.isSmartActionRunning(action.id, in: directory) {
      model.stopSmartAction(in: directory)
    } else {
      model.runSmartAction(action, in: directory)
    }
  }

  private func smartActionIcon(for action: IntegrationAction) -> String {
    if model.isSmartActionRunning(action.id, in: directory) {
      return "stop.fill"
    }
    switch action.kind {
    case .build: return "hammer.fill"
    case .run: return "play.fill"
    case .test: return "play.diamond"
    }
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

#if os(macOS)
/// The toolbar "Open With" control for the active local directory. The label
/// shows the primary app's real icon; the menu lists every installed app with
/// its own icon. Using the primary icon keeps the toolbar compact while still
/// surfacing the apps. Apps that aren't installed are omitted entirely.
private struct OpenWithMenu: View {
  let directory: URL
  let kinds: [OpenWithKind]

  /// Only the kinds whose app is actually installed on this machine.
  private var installedKinds: [OpenWithKind] {
    kinds.filter { ProjectOpener.isInstalled($0) }
  }

  var body: some View {
    ForEach(installedKinds, id: \.self) { kind in
      Button {
        ProjectOpener.open(kind, in: directory)
      } label: {
        Label {
          Text(ProjectOpener.displayName(for: kind))
        } icon: {
          Image(nsImage: ProjectOpener.icon(for: kind))
            .resizable()
            .frame(width: 24, height: 24)
        }
      }.help("Open in \(ProjectOpener.displayName(for: kind))")
    }
  }
}
#endif // os(macOS)
