import SwiftUI
import Terminal
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
  /// The hosting NSWindow, resolved from the SwiftUI view (via a pass-through
  /// background accessor) so the toolbar button can toggle its window level
  /// and collection behavior. macOS only.
  #if os(macOS)
  @State private var detachWindow: NSWindow?
  #endif

  var body: some View {
    content
      .background {
        #if os(macOS)
        DetachWindowAccessor { window in
          detachWindow = window
        }
        #endif
      }
      .toolbar {
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
          alwaysOnTopButton
        }
        #endif
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
          // A database session renders the per-engine documents/tables browser.
          // The live engine lifecycle is owned by AppModel.
          if let dbSession = model.databaseSession(for: connection) {
            DatabaseBrowserView(session: dbSession)
              .id(session.id)
          } else {
            ContentUnavailableView(
              "Database Not Open",
              systemImage: "server.rack",
              description: Text("The database connection is not open.")
            )
            .id(session.id)
          }
        } else {
          TerminalView(session: session)
            .id(session.id)
        }
      }
      .navigationTitle(model.displayName(for: session))
    } else if let note = model.notes.notes.first(where: { $0.id == itemID }) {
      NoteEditorView(noteID: note.id)
        .id(note.id)
        .navigationTitle(model.notes.title(for: note.id))
    } else {
      ContentUnavailableView(
        "Item Closed",
        systemImage: "rectangle.dashed",
        description: Text("This session or note is no longer available.")
      )
    }
  }

  #if os(macOS)
  /// The toolbar button that toggles this detached window's always-on-top
  /// behavior. Reflects the on-state with an accent foreground.
  private var alwaysOnTopButton: some View {
    Button {
      toggleAlwaysOnTop()
    } label: {
      Label("Always on Top", systemImage: "interface.window.on.rectangle.dashed")
        .foregroundStyle(isAlwaysOnTop ? Color.accentColor : Color.primary)
    }
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
  private final class PassThroughView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindow?(window)
    }
  }
}
#endif
