import Combine
import ComponentKit
import SwiftUI
import ShellDatabaseEngines
import ShellKit
import ShellIntegrations
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  /// Local Esc monitor while the actions overlay is open (the overlay is
  /// non-modal and never gets keyboard focus, so onExitCommand won't fire).
  /// macOS only — iOS dismisses the overlay by tapping the backdrop.
  #if os(macOS) || os(Windows) || os(Linux)
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
  /// The picker's selected smart-action scheme (nil = the first one).
  @State private var smartActionsSchemeID: String?
  /// A `.web` session's address bar: the text of the toolbar's URL field.
  @State private var webAddressText = ""
  /// Whether an action run's page shows its terminal instead of its output.
  @State private var actionShowsTerminal = false
  /// Presents the first-launch "choose your features" welcome sheet on a fresh
  /// install, when the feature-flags store has never been configured.
  @State private var showFirstLaunchWelcome = false
  private let directoryTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  /// The feature-flag source of truth. Reads `.isEnabled(_:)` here so a
  /// disabled feature's controls vanish from the UI. Accessing it through
  /// `@Observable` re-renders the toolbar when a flag flips.
  private var flags: FeatureFlagsStore { .shared }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Whether the window appears active (key window). Animations freeze while
  /// the window is unfocused.
  @WindowAppearsActive private var appearsActive
  /// The split view's columns, for the sidebar's own toggle on iPad.
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

  /// Whether anything animates right now: the Animations feature, motion, AND
  /// the window appearing active. Feeds the terminal and the detail transition
  /// (the sidebar's motion is the kit's own).
  private var animates: Bool {
    flags.isEnabled(.animations) && !reduceMotion && appearsActive
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
      NavigationSplitView(columnVisibility: $columnVisibility) {
        SidebarView(columnVisibility: $columnVisibility)
          .navigationSplitViewColumnWidth(ideal: KitMetrics.sidebarWidth, max: 360)
      } detail: {
        // A STABLE root for the detail column: `NavigationSplitView` swaps a
        // new root view in without animation, so switching between kinds of
        // page (a terminal → a note) changes branches INSIDE this container,
        // where the pages' `detailTransition` cross-fades them.
        ZStack {
          detailPane
        }
        // The kit's window ground under every page (and its empty state): the
        // split view's own is black on iPhone and iPad in dark mode.
        .background { Rectangle().fill(.kitWindow).ignoresSafeArea() }
        // Switching pages cross-fades the outgoing page into the incoming
        // one (each page carries `detailTransition`).
        .animation(animates ? .smooth(duration: 0.25) : nil, value: model.selection)
        // The kit's toolbar, on the column rather than on each page, so it
        // stays put while the pages cross-fade under it: the page's title and
        // its tools, compacting to icons and then into "…" as room runs out.
        // Database's pages bring their own (the table's title, its filters,
        // modes and inspector), so the column's steps aside for them.
        .modifier(PageToolbar(isOn: !showsDatabase, title: pageTitle, tools: pageTools))
        // The Data menu acts on the database the detail pane shows.
        .focusedSceneValue(\.databaseWindow, showsDatabase ? model.databaseWindow : nil)
        .kitSidebarToggle(columnVisibility: $columnVisibility)
      }
      .kitSheet(isPresented: $model.showingNewConnection) {
        NewConnectionView()
      }
      // Database's New and Edit Connection sheets.
      .databaseSheets(model.databaseWindow)
      .kitSheet(isPresented: $model.showingNewAction) {
        NewActionView(
          action: model.editingAction,
          draft: model.newActionDraft,
          commands: model.newActionCommands,
          targetSSHConnectionID: model.newActionTargetSSHConnectionID
        )
      }
      .kitSheet(isPresented: $model.showingCommandInsert) {
        CommandInsertView()
      }
      .kitSheet(isPresented: $model.showingThemes) {
        ThemesView()
      }
#if os(macOS) || os(Windows) || os(Linux)
      .kitSheet(item: $model.notarizationSetup) { request in
        NotarizationSheet(request: request)
      }
#endif
      // First-launch "choose your features" welcome (FeatureSelectionView as a
      // sheet). Present once, when the feature-flags store has never been
      // configured; Continue records the selection via markConfigured().
      .kitSheet(isPresented: $showFirstLaunchWelcome) {
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
      .fileDropMenu(showsErrors: true)
      .noticeSheet(
        "Encrypted Storage Error",
        isPresented: Binding(
          get: { model.notes.storageError != nil || model.history.storageError != nil },
          set: { if !$0 { model.notes.storageError = nil; model.history.storageError = nil } }
        ),
        message: model.notes.storageError ?? model.history.storageError ?? "Unknown encrypted storage error.")
      // Settings, as the kit's sheet over the window (Escape, a click on the
      // dim, its close button and ⌘, close it).
      .kitSheet(isPresented: $model.showingSettings) {
        SettingsView()
      }

      // The actions list as an in-window overlay (not a sheet) so it
      // appears/closes instantly, over the kit's scrim, which dims the window
      // as the board does. Backdrop click, Esc, and ⌘R close it.
      if model.showingActions {
        Rectangle()
          .fill(.kitScrim)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { model.showingActions = false }
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel("Close")
          .transition(.opacity)
        ActionsOverlayView()
          .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }
    }
    .animation(.easeOut(duration: 0.15), value: model.showingActions)
    .kitColorScheme(model.appearanceMode.colorScheme)
    // Database's interface: the tree rows in the sidebar, the detail pages and
    // the connection sheets read the model.
    .environment(model.databases)
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
      if flags.isEnabled(.files) { model.directoryBrowser.syncTick() }
    }
    // Kick the directory refresh the moment the selected session changes
    // (the timer alone adds up to a second of lag before the toolbar
    // actions refresh when switching sessions in the sidebar).
    .onChange(of: model.selection) { _, _ in
      refreshLocalDirectory()
      syncFileBrowser()
      actionShowsTerminal = false
    }
    .onChange(of: flags.isEnabled(.files)) { _, _ in
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
      // The Esc monitor closes the actions overlay; it is armed while it shows.
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
      } else {
        noSelection
      }
    #endif
    case .databaseItem(let item):
      if !model.isDatabaseDetached(item.connectionID), model.databaseConnection(item.connectionID) != nil {
        databaseDetail
      } else {
        noSelection
      }
    default:
      // Nothing selected, or a saved row (`ssh` / `screen` / `web` /
      // `database`) that is still being opened — those become a session
      // selection once the item they name is open.
      noSelection
    }
  }

  /// Whether the detail pane shows Database's interface: an open database's
  /// overview, or one of its tables or queries.
  private var showsDatabase: Bool {
    switch model.selection {
    case .session(let id):
      guard let session = model.session(id), !model.isDetached(id) else { return false }
      if case .database = model.kind(of: session) { return true }
      return false
    case .databaseItem(let item):
      return !model.isDatabaseDetached(item.connectionID)
    default:
      return false
    }
  }

  /// Database's page for what the main window's database navigation shows: a
  /// connection's overview, a table or collection, a Redis key space or a
  /// query tab.
  private var databaseDetail: some View {
    DetailView(window: model.databaseWindow)
      .transition(detailTransition)
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
        // (no terminal, no Files panel). For an ssh-owned session the tunnel
        // runtime supplies the reachable local URL (or a connecting/error
        // state) instead of the raw URL; the toolbar holds its address.
        let tunnel = model.webSessionRuntime(for: web)
        let effectiveURLText = webURLText(web)
        WebSessionDetailView(web: web, tunnel: tunnel)
          .id(session.id)
          .transition(detailTransition)
          .onChange(of: effectiveURLText) { oldText, newText in
            // Keep the field on the effective URL (an ssh-owned page's bar
            // follows the tunnel's local URL as it comes up), unless the user
            // has typed something else into it.
            if webAddressText == oldText { webAddressText = newText }
          }
          // `webAddressText` is ContentView state (not the pane's), so
          // re-seed it when a different web session is selected.
          .onChange(of: session.id) { _, _ in
            webAddressText = effectiveURLText
          }
          .onAppear {
            // Seed the field with the effective URL, without focusing it: the
            // user clicks the field when they want to type an address.
            webAddressText = effectiveURLText
          }
      } else if case .database = kind {
        // A database session shows its connection in Database's interface
        // (no terminal, no Files panel): its overview, until a table or a
        // query is picked in its tree.
        databaseDetail
      } else if case .action = kind {
        // An action run nobody types into: run blocks (ActionRunsView.swift).
        ActionRunsView(session: session, showsTerminal: $actionShowsTerminal)
          .id(session.id)
          .transition(detailTransition)
      } else {
        VStack(spacing: 0) {
          #if os(macOS)
          if case .screen(let info) = kind, info.kind == .session, !info.isRemote {
            sessionAgentBanner
          }
          #endif
          ZStack {
            // The terminal stays mounted so its scrollback/focus state is
            // preserved while the Files panel is shown on top of it. The
            // panel only covers it (and blocks its hit-testing) when the
            // Files feature is enabled AND the panel is open.
            TerminalView(session: session)
              .terminalPrompts(session)
              .id(session.id)
              .transition(detailTransition)
              .terminalFileDrop(session)
              .allowsHitTesting(!(model.directoryBrowser.visible && flags.isEnabled(.files)))

            if model.directoryBrowser.visible, flags.isEnabled(.files) {
              FilesPanelView(model: model.directoryBrowser)
                .transition(.opacity)
                .background(.kitWindow)
            }
          }
        }
      }
    }
  }

  #if os(macOS)
  /// Over a `session` session's terminal while it would end when Shell quits:
  /// the daemon's LaunchAgent (`SessionAgentModel`) isn't running.
  @ViewBuilder
  private var sessionAgentBanner: some View {
    let agent = model.sessionAgent
    if agent.sessionsEndWithShell, !agent.tipDismissed, let status = agent.status {
      Banner(
        "This session ends when Shell quits",
        message: Self.sessionAgentMessage(status),
        systemImage: "power", hue: .orange, onDismiss: { agent.tipDismissed = true }
      ) {
        switch status {
        case .needsApproval: Button("Open Login Items") { agent.openLoginItems() }
        case .stopped: Button("Start") { agent.start() }
        case .waiting, .running: EmptyView()
        case .notInstalled, .outdated: Button("Keep Running") { agent.install() }
        }
      }
      .disabled(agent.isWorking)
      .padding(KitMetrics.gutter)
      .transition(.opacity)
    }
  }

  private static func sessionAgentMessage(_ status: SessionAgent.Status) -> String {
    switch status {
    case .needsApproval: "Its login item is off in Login Items & Extensions."
    case .waiting: "The login item takes over when Shell quits; sessions started after that keep running."
    default: "A login item for the session daemon keeps sessions running."
    }
  }
  #endif

  // MARK: - Toolbar

  /// The selected page's title in the kit's toolbar, matching `detailPane`.
  private var pageTitle: PageTitle {
    switch model.selection {
    case .session(let id):
      if let session = model.session(id), !model.isDetached(id) {
        let kind = model.kind(of: session)
        return PageTitle(
          model.displayName(for: session), meta: sessionMeta(session, kind: kind), systemImage: kind.titleSymbol,
          hue: kind.titleHue, status: titleStatus(session, kind: kind))
      }
    case .note(let id):
      if let note = model.note(id), !model.isDetached(id) {
        return PageTitle(
          model.notes.title(for: note.id),
          meta: [
            "Note", "edited " + note.lastUpdate.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
          ],
          systemImage: "doc.text", hue: .orange)
      }
    case .history(let id):
      if let record = model.historySession(id), !model.isDetached(id) {
        return PageTitle(
          record.title,
          meta: ["History", record.activityDate.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))],
          systemImage: "clock", hue: .orange)
      }
    #if os(macOS)
    case .openedFile(let id):
      if let file = model.openedFile(id), !model.isDetached(id) {
        return PageTitle(
          file.displayName, meta: [file.isDirty ? "Edited" : "Text file", file.url.deletingLastPathComponent().path],
          systemImage: "doc.text", hue: .gray)
      }
    #endif
    default:
      break
    }
    return PageTitle("Terminals", meta: ["No terminal selected"], systemImage: "terminal", hue: .green)
  }

  /// The selected page's tools in the kit's toolbar, matching `detailPane`.
  @ToolbarSlotBuilder
  private var pageTools: [ToolbarSlot] {
    if let session = presentedSession {
      sessionTools(session)
    } else if case .note(let id) = model.selection, model.note(id) != nil, !model.isDetached(id) {
      ToolGroup(iconOnly: true) { NoteEncryptButton(noteID: id) }
    } else if case .history(let id) = model.selection, let record = model.historySession(id), !model.isDetached(id) {
      historyTools(record)
    }
  }

  /// A live session's tools: a web page's address (and tunnel), an action
  /// run's terminal switch, a terminal's Reconnect, smart actions, Files and
  /// Open With. Open With folds first as the window narrows, then the smart
  /// actions.
  @ToolbarSlotBuilder
  private func sessionTools(_ session: TerminalSession) -> [ToolbarSlot] {
    let kind = model.kind(of: session)
    if case .web(let web) = kind {
      #if os(macOS) || os(Windows) || os(Linux)
      ToolbarSlot(priority: 1) {
        ToolGroup { webSSHTunnelPicker(web: web) }
      } menu: {
        KitSubmenu("SSH Tunnel", systemImage: "network") { webSSHTunnelOptions(web) }
      }
      #endif
      ToolbarSlot { webAddressField(web) }
    } else if case .action = kind {
      ToolGroup(iconOnly: true) { ActionTerminalToggle(showsTerminal: $actionShowsTerminal) }
    } else if case .database = kind {
      []
    } else {
      // Dial again now: skips a scheduled reconnect's wait, retries a final
      // failure after the user fixed it (password, host key), or reopens a
      // shell that ended. Only on sessions that can reconnect (SSH
      // terminals), only while they are not live.
      if session.canReconnect, !isLive(session) {
        ToolGroup {
          Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnectNow() }
            .help("Reconnect now")
        }
      }
      #if os(macOS) || os(Windows) || os(Linux)
      if model.smartActionDirectory != nil, selectedSmartActionScheme != nil {
        ToolbarSlot(priority: 1) { smartActionTools } menu: { smartActionMenu }
      }
      #endif
      if flags.isEnabled(.files) || hasOpenWith {
        // Files, then the apps that open the directory, in one card.
        ToolbarSlot(priority: 0) {
          ToolGroup(iconOnly: true) {
            filesButton
            #if os(macOS)
            if let directory = model.smartActionDirectory {
              OpenWithMenu(directory: directory, kinds: model.openWithKinds)
            }
            #endif
          }
        } menu: {
          filesButton
          #if os(macOS)
          if let directory = model.smartActionDirectory {
            KitSubmenu("Open With", systemImage: "arrow.up.forward.app") {
              OpenWithMenu(directory: directory, kinds: model.openWithKinds)
            }
          }
          #endif
        }
      }
    }
  }

  /// A history session's tools: delete it, replay its commands, or make them
  /// an action.
  private func historyTools(_ historySession: HistorySession) -> some View {
    ToolGroup(iconOnly: true) {
      Button("Delete History", systemImage: "trash", role: .destructive) {
        model.deleteHistorySession(historySession.id)
      }
      .help("Delete History")
      Button("Replay Commands", systemImage: "play") {
        model.replayHistorySession(historySession)
      }
      .help("Replay Commands")
      Button("Create Action", systemImage: "command") {
        model.createAction(from: historySession)
      }
      .help("Create Action")
    }
  }

  /// A web page's address: what the WebView loads (the tunnel's local URL for
  /// an ssh-owned page once it is up, else the stored URL), or what the user
  /// typed; Return opens it.
  private func webAddressField(_ web: WebSession) -> some View {
    KitSearchField(text: $webAddressText, prompt: "URL")
      .frame(width: 320)
      .onSubmit {
        // Submitting the address already shown is a no-op (no reconnect or
        // reload).
        guard webAddressText != webURLText(web) else { return }
        model.updateWebSessionURL(web, to: webAddressText)
      }
  }

  /// The address the web page shows: the tunneled local URL for an ssh-owned
  /// session once the tunnel is up, otherwise the stored web URL, so the bar
  /// matches what the WebView actually loads.
  private func webURLText(_ web: WebSession) -> String {
    model.webSessionRuntime(for: web)?.tunnelURL?.absoluteString ?? web.url
  }

  /// The title's live icon: an action's run, a web page's tunnel, else the
  /// session's link.
  private func titleStatus(_ session: TerminalSession, kind: ConnectionKind) -> WorkStatus {
    switch kind {
    case .action: session.actionRunStatus
    case .web(let web): model.webSessionRuntime(for: web)?.status ?? .idle
    default: session.linkStatus
    }
  }

  /// The title's status line: the directory the shell is in, else where the
  /// session lives.
  private func sessionMeta(_ session: TerminalSession, kind: ConnectionKind) -> [String] {
    localDirectoryText.isEmpty ? kind.titleMeta : [localDirectoryText]
  }

  /// Whether the Open With apps show for the active local directory.
  private var hasOpenWith: Bool {
    #if os(macOS) || os(Windows) || os(Linux)
    model.smartActionDirectory != nil && !model.openWithKinds.isEmpty
    #else
    false
    #endif
  }

  #if os(macOS) || os(Windows) || os(Linux)
  /// Smart actions for the active local directory (Code's CodeActions
  /// schemes), in one card: a scheme picker when the directory has several, a
  /// Run/Stop button per action of the selected scheme, and its distribute
  /// actions in a menu.
  @ViewBuilder
  private var smartActionTools: some View {
    if let directory = model.smartActionDirectory, let scheme = selectedSmartActionScheme {
      ToolGroup(iconOnly: true) {
        if model.smartActionSchemes.count > 1 {
          KitMenuButton(scheme.name, systemImage: "scope", style: .button) {
            schemeOptions(scheme)
          }
          .help("Select scheme")
        }
        ForEach(SmartActionButton.kinds.filter { scheme.terminalCommand(for: $0) != nil }, id: \.self) { kind in
          SmartActionButton(kind: kind, scheme: scheme, directory: directory)
        }
        let distribution = ActionKind.allCases.filter { $0.isDistribution && $0.isOfferedHere && scheme.supports($0) }
        if !distribution.isEmpty {
          DistributeMenu(kinds: distribution, scheme: scheme, directory: directory)
        }
      }
    }
  }

  /// The directory's schemes as menu options, the picked one checked.
  private func schemeOptions(_ scheme: ActionScheme) -> some View {
    KitMenuOptions(
      selection: Binding(get: { scheme.id }, set: { smartActionsSchemeID = $0 }),
      segments: model.smartActionSchemes.map {
        KitSegment($0.name, value: $0.id, systemImage: $0.toolchain.symbolName)
      })
  }

  /// The smart actions as rows of the toolbar's "…" menu once they fold.
  @ViewBuilder
  private var smartActionMenu: some View {
    if let directory = model.smartActionDirectory, let scheme = selectedSmartActionScheme {
      if model.smartActionSchemes.count > 1 {
        KitSubmenu("Scheme", systemImage: "scope") { schemeOptions(scheme) }
      }
      ForEach(SmartActionButton.kinds.filter { scheme.terminalCommand(for: $0) != nil }, id: \.self) { kind in
        SmartActionButton(kind: kind, scheme: scheme, directory: directory)
      }
      let distribution = ActionKind.allCases.filter { $0.isDistribution && $0.isOfferedHere && scheme.supports($0) }
      if !distribution.isEmpty {
        KitSubmenu("Distribute", systemImage: "square.and.arrow.up") {
          ForEach(distribution, id: \.self) { kind in
            Button(kind.title, systemImage: "square.and.arrow.up") {
              model.runSmartAction(kind, scheme: scheme, in: directory)
            }
          }
        }
      }
    }
  }
  #endif

  /// Whether the session's link is up or being set up for the first time
  /// (no Reconnect button then).
  private func isLive(_ session: TerminalSession) -> Bool {
    switch session.connectionState {
    case .starting, .connecting, .connected: true
    case .reconnecting, .failed, .closed: false
    }
  }

  /// The detail pane for an archived history session (its delete / replay /
  /// create-action tools are `historyTools`).
  private func historyDetail(_ historySession: HistorySession) -> some View {
    HistorySessionView(session: historySession)
      .id(historySession.id)
      .transition(detailTransition)
  }

  /// Shown when nothing presentable is selected: nothing at all, a saved row
  /// still being opened, or an item living in its own detached window (which
  /// owns it — re-attaching restores it here).
  private var noSelection: some View {
    EmptyState(
      systemImage: "terminal", title: "No Terminal Selected",
      message: "Choose a terminal in the sidebar or create a new one.")
    .transition(detailTransition)
  }

  /// Terminal | Files view toggle: a single button whose icon flips between
  /// the two. Shows `folder.fill` (open Files) while in the terminal and
  /// `terminal.fill` (back to the terminal) while Files is shown. The Files
  /// panel is part of the Files feature; the button hides while it is off.
  @ViewBuilder
  private var filesButton: some View {
    if flags.isEnabled(.files) {
      Button(
        "Files & Terminal", systemImage: model.directoryBrowser.visible ? "terminal.fill" : "folder.fill"
      ) {
        model.directoryBrowser.visible.toggle()
      }
      .help(model.directoryBrowser.visible ? "Show Terminal" : "Show Files")
    }
  }

  #if os(macOS)
  /// Arms the local Esc key monitor while the Actions overlay shows, and
  /// removes it once it closes (Settings is a kit sheet, which handles Esc).
  private func updateEscMonitor() {
    if model.showingActions {
      if escMonitor == nil {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          if event.keyCode == 53 {   // Esc
            AppModel.shared.showingActions = false
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
        #if os(macOS) || os(Windows) || os(Linux)
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
        smartActionsSchemeID = nil   // don't carry a stale scheme across projects
        #if os(macOS) || os(Windows) || os(Linux)
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
    // With Files off the browser holds no session, so nothing lists a
    // directory (remotely that's an SSH connection per command).
    if flags.isEnabled(.files), let session = presentedSession {
      model.directoryBrowser.setSession(session, kind: model.kind(of: session))
    } else {
      model.directoryBrowser.setSession(nil, kind: .local)
    }
  }

  #if os(macOS) || os(Windows) || os(Linux)
  /// The scheme whose smart actions the toolbar shows: the picked one, else
  /// the directory's first.
  private var selectedSmartActionScheme: ActionScheme? {
    model.smartActionSchemes.first { $0.id == smartActionsSchemeID } ?? model.smartActionSchemes.first
  }

  /// The SSH-tunnel picker shown in a `.web` session's toolbar. Lists every
  /// saved SSH connection from `model.connections` plus a "None (open
  /// directly)" option (mapped to nil). The current value reflects the web
  /// session's `sshConfigID`; changing it persists via `webSessions.save` and
  /// reconnects the open page (see AppModel.updateWebSessionSSH).
  @ViewBuilder
  private func webSSHTunnelPicker(web: WebSession) -> some View {
    KitMenuButton(currentWebSSHTunnelLabel(for: web), systemImage: "network", style: .button) {
      webSSHTunnelOptions(web)
    }
    .help("SSH tunnel")
  }

  /// The saved SSH hosts a web page can tunnel through, and none, as menu
  /// options.
  private func webSSHTunnelOptions(_ web: WebSession) -> some View {
    KitMenuOptions(
      selection: Binding(get: { web.sshConfigID }, set: { model.updateWebSessionSSH(web, to: $0) }),
      segments: [KitSegment<UUID?>("None (open directly)", value: nil)]
        + model.connections.map { KitSegment($0.displayName, value: Optional($0.id)) })
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
#endif
}

#if os(macOS) || os(Windows) || os(Linux)
/// A smart action of a scheme: Build = hammer, Run = play, Test =
/// play.diamond, Lint = checkmark.seal. While it runs the icon flips to
/// `stop.fill` and the button stops it instead, so there's no separate Stop.
private struct SmartActionButton: View {
  /// The actions shown as buttons, in toolbar order.
  static let kinds: [ActionKind] = [.run, .build, .test, .lint]

  let kind: ActionKind
  let scheme: ActionScheme
  let directory: URL
  @Environment(AppModel.self) private var model

  var body: some View {
    let running = model.isSmartActionRunning(kind, scheme: scheme, in: directory)
    Button(kind.title, systemImage: running ? "stop.fill" : icon) {
      if running {
        model.stopSmartAction(in: directory)
      } else {
        model.runSmartAction(kind, scheme: scheme, in: directory)
      }
    }
    .help(running ? "Stop" : "\(kind.title) \(scheme.name)")
  }

  private var icon: String {
    switch kind {
    case .run: return "play.fill"
    case .build: return "hammer.fill"
    case .test: return "play.diamond"
    default: return "checkmark.seal"
    }
  }
}

/// The scheme's distribute actions (Install / Export / Upload to App Store)
/// in a "Distribute" menu whose items run immediately. They are one-shot —
/// unlike build/run/test they never toggle to a stop state.
private struct DistributeMenu: View {
  let kinds: [ActionKind]
  let scheme: ActionScheme
  let directory: URL
  @Environment(AppModel.self) private var model

  var body: some View {
    KitMenuButton("Distribute", systemImage: "square.and.arrow.up", style: .button) {
      ForEach(kinds, id: \.self) { kind in
        Button(kind.title, systemImage: "square.and.arrow.up") {
          model.runSmartAction(kind, scheme: scheme, in: directory)
        }
      }
      if kinds.contains(where: \.needsNotarization) {
        Divider()
        Button("Notarization Settings…", systemImage: "checkmark.seal") {
          model.notarizationSetup = NotarizationSetupRequest()
        }
      }
    }
  }
}
#endif

extension ConnectionKind {
  /// The detail title's glyph for a session of this kind.
  var titleSymbol: String {
    switch self {
    case .local: "terminal"
    case .screen(let info): info.isProtected ? "lock.fill" : "shield.fill"
    case .ssh: "network"
    case .action: "play.fill"
    case .web: "globe"
    case .database(let connection): connection.engine.systemImage
    }
  }

  /// The detail title's status line: where a session of this kind lives.
  var titleMeta: [String] {
    switch self {
    case .local: [thisComputerName]
    case .screen(let info): [info.kind == .tmux ? "tmux" : info.kind == .session ? "session" : "screen"]
    case .ssh(let config): ["\(config.user)@\(config.host)"]
    case .action(let spec): [spec.config?.displayName ?? "Local"]
    case .web(let web): [web.url]
    case .database(let connection): [connection.subtitle]
    }
  }

  /// The detail title's tile hue: green on this Mac, blue remote.
  var titleHue: Hue {
    switch self {
    case .local, .screen: .green
    case .ssh, .web: .blue
    case .action: .purple
    case .database: .indigo
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

/// A page's title in the kit's toolbar: the window's title and the kit's rich
/// title (tile, name, status line, live icon).
struct PageTitle {
  var title: String
  var meta: [String]
  var systemImage: String
  var hue: Hue
  var status: WorkStatus

  init(_ title: String, meta: [String] = [], systemImage: String, hue: Hue, status: WorkStatus = .idle) {
    self.title = title
    self.meta = meta
    self.systemImage = systemImage
    self.hue = hue
    self.status = status
  }

  var view: KitTitle { KitTitle(title, meta: meta, systemImage: systemImage, hue: hue, status: status) }
}

/// The column's kit toolbar while `isOn` (pages without a toolbar of their own).
private struct PageToolbar: ViewModifier {
  let isOn: Bool
  let title: PageTitle
  let tools: [ToolbarSlot]

  func body(content: Content) -> some View {
    if isOn {
      content.kitToolbar(title.title, title: { title.view }, tools: { tools })
    } else {
      content
    }
  }
}
