import SwiftUI
import Terminal

/// The content of a detached session/note in its own window (macOS) or scene
/// (iPad). Resolves the live item by id from AppModel and presents the same
/// detail content the main window would — `TerminalView` for a session
/// (local, SSH, action, screen) or `NoteEditorView` for a note.
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
      TerminalView(session: session)
        .id(session.id)
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
