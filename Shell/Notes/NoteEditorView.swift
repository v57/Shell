import ComponentKit
import SwiftUI
import MarkdownKit

/// The main-view editor for a single note, rendered with the `MarkdownKit` markdown
/// editor (Obsidian-style live preview: syntax symbols hide on inactive lines
/// and appear while editing them). The note's ciphertext is decrypted HERE when
/// the note opens — the decrypted text is passed to the editor as its
/// initial content; edits are pushed into the store via `onChange`, which
/// autosaves 5s after the last keystroke. The window title and the sidebar row
/// follow the first non-empty line (Notes.app style), so editing it renames the
/// note. The markdown editor disables smart quotes/dashes and auto-focuses on
/// appear, so neither needs to be handled here.
struct NoteEditorView: View {
  @Environment(AppModel.self) private var model
  let noteID: UUID

  var body: some View {
    MarkdownEditorView(
      text: model.notes.decryptedNote(id: noteID)?.text ?? "",
      onChange: { model.notes.updateText($0, for: noteID) }
    )
    // The editor is deallocated with this view, but its text edits stay on the
    // window's undo stack — a later ⌘Z would message the freed editor.
    // (ContentView keys this view by note id, so a note switch lands here too.)
    .onDisappear { UndoHygiene.discardStaleTextUndo() }
  }
}

/// The toolbar's switch between a note kept as a plain Markdown file and an
/// encrypted one.
struct NoteEncryptButton: View {
  @Environment(AppModel.self) private var model
  let noteID: UUID

  private var isEncrypted: Bool {
    model.notes.notes.first { $0.id == noteID }?.isEncrypted ?? false
  }

  var body: some View {
    Button(isEncrypted ? "Decrypt Note" : "Encrypt Note", systemImage: isEncrypted ? "lock.fill" : "lock.open") {
      model.notes.setEncrypted(!isEncrypted, for: noteID)
    }
    .help(
      isEncrypted
        ? "Keep this note as a plain Markdown file in Markdown's notes folder"
        : "Keep this note's file encrypted, readable only by the v57 apps")
  }
}
