import ComponentKit
import SwiftUI
import ShellDatabaseEngines
import ShellKit
#if os(macOS)
import AppKit
#endif

/// The content of a detached session/note in its own window (macOS) or scene
/// (iPad). Resolves the live item by id from AppModel and presents the same
/// detail content the main window would — `TerminalView` for a session
/// (local, SSH, action, screen), the WebView for a `.web` session, the
/// database browser for a `.database` session, or `NoteEditorView` for a note.
///
/// Presented via `openWindow(id: "detach", value: id)` (see `ShellApp`), and
/// returned to the main window by re-attaching (remove from `detachedIDs`) and
/// dismissing the window (`dismissWindow(id: "detach", value: id)`).
/// Scoped to macOS + iPad; the iPhone app stays single-scene (out of scope).
struct DetachDetailView: View {
  @Environment(AppModel.self) private var model
  let itemID: UUID
  /// Whether this detached window stays above other apps. Kept per window, so
  /// one detached session's always-on-top flag never leaks to another.
  @State private var isAlwaysOnTop = false
  /// Whether a detached action run shows its terminal instead of its output.
  @State private var actionShowsTerminal = false
  /// The hosting NSWindow, resolved from the SwiftUI view (via a pass-through
  /// background accessor) so the toolbar button can toggle its window level
  /// and collection behavior. macOS only.
  #if os(macOS)
  @State private var detachWindow: NSWindow?
  #endif

  var body: some View {
    content
      .fileDropMenu()
      .background {
        #if os(macOS)
        DetachWindowAccessor { window in
          detachWindow = window
        }
        #endif
      }
      // The kit's toolbar, as in the main window: the item's title and tools,
      // and Always on Top on the Mac. Database's pages have their own.
      .modifier(DetachToolbar(isOn: !isDatabase, title: title, tools: tools))
      .onDisappear {
        // Closing the detached window/scene returns the item to the main
        // window (and deletes it if it was an empty note). Only runs on a
        // real close — the item is otherwise re-selected in the main window.
        model.handleDetachedWindowClosed(itemID)
      }
  }

  @ViewBuilder
  private var content: some View {
    if let session = model.sessions.first(where: { $0.id == itemID }) {
      // Branch on the session kind exactly like ContentView does, so a
      // detached `.web`/`.database` session renders its real content instead
      // of falling through to an empty terminal.
      let kind = model.kind(of: session)
      Group {
        if case .web(let web) = kind {
          // A web session renders its URL in the system SwiftUI WebView (no
          // terminal). For an ssh-owned session the tunnel runtime supplies the
          // reachable local URL (or a connecting/error state).
          WebSessionDetailView(web: web, tunnel: model.webSessionRuntime(for: web))
            .id(session.id)
        } else if case .database(let connection) = kind {
          // A database session shows its connection in Database's interface,
          // with its tree in the window's own sidebar.
          DetachedDatabaseView(connection: connection)
            .id(session.id)
        } else if case .action = kind {
          ActionRunsView(session: session, showsAll: false, showsTerminal: $actionShowsTerminal)
            .id(session.id)
        } else {
          TerminalView(session: session)
            .terminalPrompts(session)
            .id(session.id)
            .terminalFileDrop(session)
        }
      }
    } else if let note = model.notes.notes.first(where: { $0.id == itemID }) {
      NoteEditorView(noteID: note.id)
        .id(note.id)
    } else {
      EmptyState(
        systemImage: "rectangle.dashed", title: "Item Closed",
        message: "This session or note is no longer available.")
    }
  }

  /// Whether the window shows a database (its pages bring their own toolbar).
  private var isDatabase: Bool {
    guard let session = model.sessions.first(where: { $0.id == itemID }) else { return false }
    if case .database = model.kind(of: session) { return true }
    return false
  }

  /// The item's title in the kit's toolbar.
  private var title: PageTitle {
    if let session = model.sessions.first(where: { $0.id == itemID }) {
      let kind = model.kind(of: session)
      let status: WorkStatus =
        switch kind {
        case .action: session.actionRunStatus
        case .web(let web): model.webSessionRuntime(for: web)?.status ?? .idle
        default: session.linkStatus
        }
      return PageTitle(
        model.displayName(for: session), meta: kind.titleMeta, systemImage: kind.titleSymbol, hue: kind.titleHue,
        status: status)
    } else if let note = model.notes.notes.first(where: { $0.id == itemID }) {
      return PageTitle(model.notes.title(for: note.id), meta: ["Note"], systemImage: "doc.text", hue: .orange)
    }
    return PageTitle("Item Closed", systemImage: "rectangle.dashed", hue: .gray)
  }

  /// The item's tools: a note's encryption, an action run's terminal switch,
  /// and Always on Top on the Mac.
  @ToolbarSlotBuilder
  private var tools: [ToolbarSlot] {
    if model.notes.notes.contains(where: { $0.id == itemID }) {
      ToolGroup(iconOnly: true) { NoteEncryptButton(noteID: itemID) }
    } else if let session = model.sessions.first(where: { $0.id == itemID }), case .action = model.kind(of: session) {
      ToolGroup(iconOnly: true) { ActionTerminalToggle(showsTerminal: $actionShowsTerminal) }
    }
    #if os(macOS)
    ToolGroup(iconOnly: true) { alwaysOnTopButton }
    #endif
  }

  #if os(macOS)
  /// The toolbar button that toggles this detached window's always-on-top
  /// behavior, drawn on while it is.
  private var alwaysOnTopButton: some View {
    Button("Always on Top", systemImage: "interface.window.on.rectangle.dashed") {
      toggleAlwaysOnTop()
    }
    .kitToolOn(isAlwaysOnTop)
    .help(isAlwaysOnTop ? "Keep window above other apps (on)" : "Keep window above other apps")
  }

  private func toggleAlwaysOnTop() {
    guard let window = resolveDetachWindow() else { return }
    isAlwaysOnTop.toggle()
    if isAlwaysOnTop {
      window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
      window.level = .floating
    } else {
      window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
      window.level = .normal
    }
  }

  /// The hosting detached NSWindow: the one captured from the SwiftUI view,
  /// falling back to scanning `NSApp.windows` for the "detach" identifier.
  private func resolveDetachWindow() -> NSWindow? {
    if let detachWindow { return detachWindow }
    return NSApp.windows.first { $0.identifier?.rawValue.contains("detach") == true }
  }
  #endif
}

#if os(macOS)
/// A pass-through background view that reports the NSWindow it lands in, so a
/// detached window's toolbar button can reach the hosting window through the
/// SwiftUI view (same approach as `WindowStatsObserver`).
private struct DetachWindowAccessor: NSViewRepresentable {
  var onWindow: (NSWindow?) -> Void

  func makeNSView(context: Context) -> PassThroughView {
    let view = PassThroughView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ nsView: PassThroughView, context: Context) {
    nsView.onWindow = onWindow
  }

  /// Never intercepts mouse events; reports when it moves into/out of a window.
  final class PassThroughView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindow?(window)
    }
  }
}
#endif

/// The window's kit toolbar while `isOn`.
private struct DetachToolbar: ViewModifier {
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

/// A detached database: its tree in the window's own sidebar, beside Database's page for the row picked in it, with
/// a navigation of its own.
private struct DetachedDatabaseView: View {
  @Environment(AppModel.self) private var model
  let connection: DatabaseConnection
  @State private var window: WindowModel?

  var body: some View {
    Group {
      if let window {
        DetachedDatabaseSplit(connection: connection, window: window)
      } else {
        Color.clear
      }
    }
    .onAppear {
      guard window == nil else { return }
      let navigation = WindowModel(app: model.databases)
      navigation.selection = .connection(connection.id)
      window = navigation
    }
  }
}

private struct DetachedDatabaseSplit: View {
  @Environment(AppModel.self) private var model
  let connection: DatabaseConnection
  @Bindable var window: WindowModel
  @State private var columnVisibility = NavigationSplitViewVisibility.all

  var body: some View {
    let live = model.databases.connection(for: connection.id)
    NavigationSplitView(columnVisibility: $columnVisibility) {
      KitSidebar(selection: $window.selection) {
        KitSection(connection.displayName, meta: [connection.subtitle], systemImage: connection.engine.systemImage) {
          SidebarRow(value: SidebarItem.connection(connection.id), "Overview", systemImage: "info.circle")
            .disclosureSlot()
          ConnectionContents(connection: live, window: window, level: 0)
        } accessory: {
          EmptyView()
        }
      }
      .toolbar(removing: .sidebarToggle)
      .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
    } detail: {
      DetailView(window: window)
        .kitSidebarToggle(columnVisibility: $columnVisibility)
    }
    .focusedSceneValue(\.databaseWindow, window)
    .databaseSheets(window)
    .environment(model.databases)
  }
}
