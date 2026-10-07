import Combine
import SwiftUI
import Terminal
import TerminalIntegrations
#if os(macOS)
import AppKit
#endif

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
  /// A `.web` session's address bar: the text of the toolbar search field
  /// (`.searchable` is applied to the web session's detail pane).
  @State private var webAddressText = ""
  /// Whether the address search field currently holds focus, so an in-flight
  /// tunnel update never clobbers the user's typing.
  @FocusState private var webAddressFocused: Bool
  /// Presents the first-launch "choose your features" welcome sheet on a fresh
  /// install, when the feature-flags store has never been configured.
  @State private var showFirstLaunchWelcome = false
  private let directoryTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  /// The feature-flag source of truth. Reads `.isEnabled(_:)` here so a
  /// disabled feature's controls vanish from the UI. Accessing it through
  /// `@Observable` re-renders the toolbar when a flag flips.
  private var flags: FeatureFlagsStore { .shared }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The Animations feature, unless the system asks for reduced motion.
  private var animates: Bool {
    flags.isEnabled(.animations) && !reduceMotion
  }

  /// How a detail page enters and leaves when the selection changes: the new
  /// page fades in from slightly smaller, the old one fades out. Inert while
  /// Animations is off (nothing animates the swap).
  private var detailTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.combined(with: .scale(scale: 0.98)),
      removal: .opacity
    )
  }

  var body: some View {
    @Bindable var model = model
    ZStack {
      NavigationSplitView {
        HStack(spacing: 0) {
          if animates {
            SidebarView2()
          } else {
            SidebarView()
          }
        }
      } detail: {
        detailPane
          // Switching pages cross-fades the outgoing page into the incoming
          // one (each page carries `detailTransition`).
          .animation(animates ? .smooth(duration: 0.25) : nil, value: model.selection)
      }
      .sheet(isPresented: $model.showingNewConnection) {
        NewConnectionView()
      }
      .sheet(isPresented: $model.showingNewDatabaseConnection) {
        if let editing = model.editingDatabaseConnection {
          NewDatabaseConnectionView(connection: editing,
                                   savedPassword: model.passwordForDatabase(editing))
        } else {
          NewDatabaseConnectionView(connection: nil,
                                   presetSSHConfigID: model.databasePresetSSHConfigID)
        }
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
      // First-launch "choose your features" welcome (FeatureSelectionView as a
      // sheet). Present once, when the feature-flags store has never been
      // configured; Continue records the selection via markConfigured().
      .sheet(isPresented: $showFirstLaunchWelcome) {
        FeatureWelcomeView()
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
          #if os(macOS)
          model.flushOpenedFiles()
          #endif
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

      // Settings as an in-window overlay (same instant appear/close pattern as
      // the Actions overlay above). Backdrop click, Esc, and ⌘, close it.
      if model.showingSettings {
        Color.black.opacity(0.001)
          .ignoresSafeArea()
          .onTapGesture { model.showingSettings = false }
        SettingsView()
          .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }
    }
    .animation(.easeOut(duration: 0.15), value: model.showingActions)
    .animation(.easeOut(duration: 0.15), value: model.showingSettings)
    .preferredColorScheme(model.appearanceMode.colorScheme)
    .environment(\.terminalBackgroundsDisabled, model.disableTerminalBackgrounds)
    .environment(\.terminalAnimationsEnabled, animates)
    .onAppear {
      // Set the browser up for the initially-selected session (onChange does
      // not fire for the initial value).
      syncFileBrowser()
      // First-launch welcome: show the "choose your features" sheet once, when
      // the feature-flags store has never been configured.
      if FeatureFlagsStore.shared.needsFirstLaunchSelection {
        showFirstLaunchWelcome = true
      }
      #if os(macOS)
      // Record the primary window so the ⌘W key monitor can route Window-close
      // to session-close here while detached-item windows still close normally.
      if AppModel.shared.mainWindow == nil { AppModel.shared.mainWindow = NSApp.keyWindow }
      #endif
    }
    .onReceive(directoryTimer) { _ in
      refreshLocalDirectory()
      // Keep the Files panel's directory in sync with the live session.
      model.directoryBrowser.syncTick()
    }
    // Kick the directory refresh the moment the selected session changes
    // (the timer alone adds up to a second of lag before the toolbar
    // actions refresh when switching sessions in the sidebar).
    .onChange(of: model.selection) { _, _ in
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
    .onChange(of: model.showingActions) { _, _ in
      // The Esc monitor closes whichever overlay is up (actions or settings).
      // It is armed while EITHER overlay is showing. Both on/off transitions
      // re-evaluate the need for the monitor.
      #if os(macOS)
      updateEscMonitor()
      #endif
    }
    .onChange(of: model.showingSettings) { _, _ in
      #if os(macOS)
      updateEscMonitor()
      #endif
    }
  }
  

  /// The main window's detail pane for the current selection. The KIND comes
  /// from the selection itself — one switch, each branch a single targeted
  /// lookup — instead of a chain of per-collection getters that had to be
  /// probed in turn to find out what was selected. A selection whose item
  /// lives in its OWN detached window presents nothing here: that window owns
  /// it, and re-attaching (`markAttached`) restores it.
  @ViewBuilder
  private var detailPane: some View {
    switch model.selection {
    case .session(let id):
      if let session = model.session(id), !model.isDetached(id) {
        sessionDetail(session)
      } else {
        noSelection
      }
    case .note(let id):
      if let note = model.note(id), !model.isDetached(id) {
        NoteEditorView(noteID: note.id)
          .id(note.id)
          .transition(detailTransition)
          .navigationTitle(model.notes.title(for: note.id))
      } else {
        noSelection
      }
    case .history(let id):
      if let record = model.historySession(id), !model.isDetached(id) {
        historyDetail(record)
      } else {
        noSelection
      }
    #if os(macOS)
    case .openedFile(let id):
      if let file = model.openedFile(id), !model.isDetached(id) {
        OpenFilePane(file: file)
          .id(file.id)
          .transition(detailTransition)
          .navigationTitle(file.displayName)
      } else {
        noSelection
      }
    #endif
    default:
      // Nothing selected, or a saved row (`ssh` / `screen` / `web` /
      // `database`) that is still being opened — those become a session
      // selection once the item they name is open.
      noSelection
    }
  }

  /// The detail pane for a live session: a `.web` session renders its page,
  /// a `.database` session its browser, everything else (local, SSH, action,
  /// persistent attachment) its terminal. The pane is picked from the
  /// session's KIND — the same branching the detached window does.
  @ViewBuilder
  private func sessionDetail(_ session: TerminalSession) -> some View {
    let kind = model.kind(of: session)
    Group {
      if case .web(let web) = kind {
        // A web session renders its URL in the system SwiftUI WebView
        // (no terminal, no Files panel, no terminal toolbar). For an
        // ssh-owned session the tunnel runtime supplies the reachable
        // local URL (or a connecting/error state) instead of the raw URL.
        let tunnel = model.webSessionRuntime(for: web)
        // The address bar value: the tunneled local URL for an ssh-owned
        // session once the tunnel is up, otherwise the stored web URL —
        // so the displayed value matches what the WebView actually loads.
        let effectiveURLText: String = tunnel?.tunnelURL?.absoluteString ?? web.url
        WebSessionDetailView(web: web, tunnel: tunnel)
          .id(session.id)
          .transition(detailTransition)
          // The address bar is the window toolbar's search field: the
          // `searchable` modifier hands the field to the toolbar (a
          // plain TextField stacked above the WebView cannot sit there),
          // and Return — via `.onSubmit(of: .search)` — commits the
          // edited text to navigate the WebView.
          .searchable(text: $webAddressText, prompt: "URL")
          .searchFocused($webAddressFocused)
          // By default the search field hides the rest of the toolbar
          // while it is active (on iOS the navigation bar's back button
          // disappears until the field is cleared). Keep the toolbar's
          // other controls visible so the user can always navigate away
          // without cancelling the search first. Must come AFTER
          // `.searchable` to apply to the toolbar search field.
          .searchPresentationToolbarBehavior(.avoidHidingContent)
          .onSubmit(of: .search) {
            // Only navigate when the edited text actually differs from
            // what's displayed — submitting an unchanged address is a
            // no-op (avoids an unnecessary reconnect/reload).
            guard webAddressText != effectiveURLText else { return }
            model.updateWebSessionURL(web, to: webAddressText)
          }
          .onChange(of: effectiveURLText) { _, newText in
            // Keep the field in sync with the effective URL — an
            // ssh-owned page's bar follows the tunnel's local URL as it
            // comes up. While the user is editing, never overwrite
            // their keystrokes.
            if !webAddressFocused { webAddressText = newText }
          }
          // `webAddressText` is ContentView state (not the pane's), so
          // re-seed it when a different web session is selected.
          .onChange(of: session.id) { _, _ in
            webAddressText = effectiveURLText
          }
          .onAppear {
            // Seed the field with the effective URL. The field is NOT
            // focused on appear — a toolbar search field that grabs
            // focus on open would immediately engage search (and, on
            // iOS, raise the keyboard over the page), which is not what
            // opening a saved page should do. The user taps the field
            // when they want to type an address.
            webAddressText = effectiveURLText
          }
          .onDisappear { webAddressFocused = false }
          .toolbar {
            // The SSH-tunnel picker is a web-session-only control: it
            // lets the user switch which host the open page is tunnelled
            // through (or clear the tunnel). See webSSHTunnelPicker.
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
              webSSHTunnelPicker(web: web)
            }
            #endif
          }
      } else if case .database(let connection) = kind {
        // A database session renders the per-engine documents/tables
        // browser (no terminal, no Files panel). The live engine
        // lifecycle is owned by AppModel.
        if let dbSession = model.databaseSession(for: connection) {
          DatabaseBrowserView(session: dbSession)
            .id(session.id)
            .transition(detailTransition)
        } else {
          ContentUnavailableView(
            "Database Not Open",
            systemImage: "server.rack",
            description: Text("The database connection is not open.")
          )
          .id(session.id)
          .transition(detailTransition)
        }
      } else {
        ZStack {
          // The terminal stays mounted so its scrollback/focus state is
          // preserved while the Files panel is shown on top of it. The
          // panel only covers it (and blocks its hit-testing) when the
          // Files feature is enabled AND the panel is open.
          TerminalView(session: session)
            .id(session.id)
            .transition(detailTransition)
            .allowsHitTesting(!(model.directoryBrowser.visible && flags.isEnabled(.files)))

          if model.directoryBrowser.visible, flags.isEnabled(.files) {
            FilesPanelView(model: model.directoryBrowser)
              .transition(.opacity)
              .background(.background)
          }
        }
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
                  if group.kind == .distribute {
                    DistributeMenu(actions: group.actions, directory: directory)
                  } else {
                    SmartActionMenu(actions: group.actions, directory: directory)
                  }
                }
              }
            }

            if #available(macOS 26.0, *) {
              ToolbarSpacer()
            }
            files

            // Open With for the active local directory — trailing secondary
            // action, showing the available apps' real icons.
            if let directory = model.smartActionDirectory, !model.openWithKinds.isEmpty {
              ToolbarItemGroup(placement: .primaryAction) {
                OpenWithMenu(directory: directory, kinds: model.openWithKinds)
              }
            }
#else
            files
#endif
          }
      }
    }
    .navigationTitle(model.displayName(for: session))
    .navigationDirectorySubtitle(localDirectoryText)
  }

  /// The detail pane for an archived history session, with its delete /
  /// replay / create-action toolbar.
  @ViewBuilder
  private func historyDetail(_ historySession: HistorySession) -> some View {
    HistorySessionView(session: historySession)
      .id(historySession.id)
      .transition(detailTransition)
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
  }

  /// Shown when nothing presentable is selected: nothing at all, a saved row
  /// still being opened, or an item living in its own detached window (which
  /// owns it — re-attaching restores it here).
  private var noSelection: some View {
    ContentUnavailableView(
      "No Terminal Selected",
      systemImage: "terminal",
      description: Text("Choose a terminal in the sidebar or create a new one.")
    )
    .transition(detailTransition)
    .navigationTitle("Terminals")
  }

  @ContentBuilder
  var files: some ToolbarContent {
    // Terminal | Files view toggle: a single button whose icon flips
    // between the two. Shows `folder.fill` (open Files) while in the
    // terminal and `terminal.fill` (back to the terminal) while Files
    // is shown.
    // The Files panel is part of the Files feature; hide the
    // toggle button entirely when the feature is disabled.
    if flags.isEnabled(.files) {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.directoryBrowser.visible.toggle()
        } label: {
          Label(
            "Files & Terminal",
            systemImage: model.directoryBrowser.visible ? "terminal.fill" : "folder.fill")
        }
        .help(model.directoryBrowser.visible ? "Show Terminal" : "Show Files")
      }
    }
  }

  #if os(macOS)
  /// Arms/re-arms the local Esc key monitor while either overlay (Actions or
  /// Settings) is showing, and removes it once both are closed. Esc closes
  /// whichever overlay is up first.
  private func updateEscMonitor() {
    let anyOverlay = model.showingActions || model.showingSettings
    if anyOverlay {
      if escMonitor == nil {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          if event.keyCode == 53 {   // Esc
            if AppModel.shared.showingActions {
              AppModel.shared.showingActions = false
            } else if AppModel.shared.showingSettings {
              AppModel.shared.showingSettings = false
            }
            return nil
          }
          return event
        }
      }
    } else if let escMonitor {
      NSEvent.removeMonitor(escMonitor)
      self.escMonitor = nil
    }
  }
  #endif

  /// The live session the main window presents, if the selection names one —
  /// nil while a saved row (`ssh` / `screen` / `web` / `database`) is still
  /// being opened, and for an item living in its own detached window. Drives
  /// the cwd subtitle, the smart actions and the Files panel; the detail pane
  /// itself switches on `model.selection`.
  private var presentedSession: TerminalSession? {
    guard case .session(let id) = model.selection, !model.isDetached(id) else { return nil }
    return model.session(id)
  }

  /// Re-queries the selected session's cwd so the window subtitle follows
  /// the shell's `cd`. Local sessions read the child's live cwd via libproc;
  /// ssh-backed sessions run a throttled `pwd` over the live transport and
  /// read the published cwd. Non-selected/cleared sessions hide the subtitle.
  /// The home-directory prefix is shortened to `~` for display — LOCAL only
  /// (the remote home is on another host, so remote paths are shown in full).
  private func refreshLocalDirectory() {
    let session = presentedSession
    let kind = session.map { model.kind(of: $0) }
    let path: String?
    switch kind {
    case .local?:
      path = session?.currentDirectory?.path
    case .ssh?, .action?:
      // ssh-backed: refresh the live remote cwd from the transport
      // (throttled), then read it. A local action session (no sshTransport)
      // clears it — no remote cwd to show.
      session?.refreshRemoteDirectory()
      path = session?.remoteCurrentDirectory?.path
    default:
      path = nil
    }
    guard let path, !path.isEmpty else {
      localDirectoryText = ""
      if activeDirectoryURL != nil {
        activeDirectoryURL = nil
        #if os(macOS)
          model.refreshSmartActions(for: nil)
        #endif
      }
      return
    }
    // Only a LOCAL session drives the smart-action directory. Remote sessions
    // get the subtitle but never refresh smart actions (no local directory).
    if case .local? = kind {
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
        #if os(macOS)
          model.refreshSmartActions(for: url)
        #endif
      }
    } else {
      localDirectoryText = path
    }
  }

  /// Points the shared File browser model at the currently-selected session
  /// (or clears it when nothing terminal-ish is selected), so the Files panel
  /// rebuilds its context and lists the right directory for the right runner.
  private func syncFileBrowser() {
    if let session = presentedSession {
      model.directoryBrowser.setSession(session, kind: model.kind(of: session))
    } else {
      model.directoryBrowser.setSession(nil, kind: .local)
    }
  }

  #if os(macOS)
  /// Non-nil smart-action targets (schemes/executables) sorted for the picker.
  private var smartActionsTargets: [String] {
    Array(Set(model.smartActionActions.compactMap(\.target))).sorted()
  }

  /// The SSH-tunnel picker shown in a `.web` session's toolbar. Lists every
  /// saved SSH connection from `model.connections` plus a "None (open
  /// directly)" option (mapped to nil). The current value reflects the web
  /// session's `sshConfigID`; changing it persists via `webSessions.save` and
  /// reconnects the open page (see AppModel.updateWebSessionSSH).
  @ViewBuilder
  private func webSSHTunnelPicker(web: WebSession) -> some View {
    Menu {
      Button {
        model.updateWebSessionSSH(web, to: nil)
      } label: {
        if web.sshConfigID == nil {
          Label("None (open directly)", systemImage: "checkmark")
        } else {
          Text("None (open directly)")
        }
      }
      if !model.connections.isEmpty {
        Divider()
        ForEach(model.connections) { config in
          Button {
            model.updateWebSessionSSH(web, to: config.id)
          } label: {
            if web.sshConfigID == config.id {
              Label(config.displayName, systemImage: "checkmark")
            } else {
              Text(config.displayName)
            }
          }
        }
      }
    } label: {
      Label(currentWebSSHTunnelLabel(for: web), systemImage: "network")
    }
    .help("SSH tunnel")
  }

  /// The picker's current value label: the bound SSH host's display name, or
  /// "None" when the web session is a plain (no-ssh) page.
  private func currentWebSSHTunnelLabel(for web: WebSession) -> String {
    if let id = web.sshConfigID,
       let config = model.connections.first(where: { $0.id == id }) {
      return config.displayName
    }
    return "None (open directly)"
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
#endif
}

#if os(macOS)
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
    case .distribute: return "square.and.arrow.up"
    case .lint: return "checkmark.seal"
    }
  }
}

/// A smart-action control for the `.distribute` kind: a plain Menu labeled
/// "Distribute" whose items each run their action immediately on click.
/// Distribute actions (Install / Upload) are one-shot — unlike
/// build/run/test they never toggle to a stop state.
private struct DistributeMenu: View {
  let actions: [IntegrationAction]
  let directory: URL
  @Environment(AppModel.self) private var model

  var body: some View {
    Menu {
      ForEach(actions) { action in
        Button {
          model.runSmartAction(action, in: directory)
        } label: {
          Label(action.title, systemImage: "square.and.arrow.up")
        }
      }
    } label: {
      Label("Distribute", systemImage: "square.and.arrow.up")
    }
    .menuIndicator(.hidden)
  }
}
#endif

/// Shows a navigation subtitle only when `text` is non-empty (empty text
/// would otherwise render an empty subtitle slot).
private extension View {
  @ViewBuilder
  func navigationDirectorySubtitle(_ text: String) -> some View {
    if text.isEmpty {
      self
    } else if #available(iOS 26.0, macOS 26.0, *) {
      self.navigationSubtitle(Text(text))
    } else {
      self
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
