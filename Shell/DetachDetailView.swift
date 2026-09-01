import SwiftUI
import Terminal

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

  var body: some View {
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
}
