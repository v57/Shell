import SwiftUI
import Md

/// The main-view editor for a single note, rendered with the `Md` markdown
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
    .toolbar {
      ToolbarItem {
        Button {
          model.notes.setICloudStorage(!inICloud, for: noteID)
        } label: {
          Image(systemName: inICloud ? "icloud.fill" : "icloud")
        }
        .help(inICloud ? "Store this note on this device only (encrypted)" : "Store this note in iCloud (encrypted)")
      }
    }
  }

  /// The current note's storage location (false until the note loads).
  private var inICloud: Bool {
    model.notes.notes.first { $0.id == noteID }?.storedInICloud ?? false
  }
}
