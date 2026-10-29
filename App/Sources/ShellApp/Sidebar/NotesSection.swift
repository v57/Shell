import ComponentKit
import SwiftUI

/// The Notes section: the notes Shell shares with the Markdown app, read per visible row. Hidden
/// entirely while the notes feature is off (this section's own gate), and its
/// collapse state is local to this section.
struct NotesSectionView: View {
  @Environment(AppModel.self) private var model
  /// The sidebar's shared state (SidebarChrome.swift): the filter.
  let state: SidebarState

  /// Collapse state for this section, persisted across launches.
  @AppStorage("sidebar.notes.collapsed") private var notesCollapsed = false

  private var flags: FeatureFlagsStore { .shared }

  private var notes: [NotesStore.NoteSummary] {
    model.notes.notes.filter { state.matches(model.notes.title(for: $0.id)) }
  }

  var body: some View {
    if flags.isEnabled(.notes) {
      let count = model.notes.notes.count
      KitSection("Notes", systemImage: "doc.text", hue: .orange, isExpanded: .expanded(collapsed: $notesCollapsed)) {
        ForEach(notes) { note in
          NoteRow(note: note)
            .kitContextMenu {
              Button(note.isEncrypted ? "Decrypt Note" : "Encrypt Note") {
                model.notes.setEncrypted(!note.isEncrypted, for: note.id)
              }
              Divider()
              Button("Delete Note", role: .destructive) {
                model.deleteNote(note.id)
              }
            }
        }
      } meta: {
        if let edited = model.notes.notes.map(\.lastUpdate).max() {
          // "2 notes · edited 2 min. ago", dropping words rather than truncating in a narrow sidebar.
          let notes = count == 1 ? "1 note" : "\(count) notes"
          let ago = edited.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
          ViewThatFits(in: .horizontal) {
            MetaLine(notes, "edited \(ago)")
            MetaLine(notes, ago)
            MetaLine(notes)
          }
        } else {
          MetaLine("No notes")
        }
      } accessory: {
        Button("New Note", systemImage: "plus") {
          model.newNote()
        }
        .help("New note")
      }
      // Text files dropped on the section: copied into encrypted notes, or linked.
      .notesFileDrop()
    } // end if (notes section gate)
  }
}

/// A note row in the sidebar. The title is the first non-empty line of the
/// note (editing it renames it); the preview is the next non-empty line.
/// Both are DECRYPTED IN THE VIEW via `decryptedNote(id:)` — `KitSection`'s
/// rows are a `KitLazyStack`, which builds the rows near the screen only, so
/// only those decrypt (results cached by the store).
private struct NoteRow: View {
  @Environment(AppModel.self) private var model
  let note: NotesStore.NoteSummary

  var body: some View {
    SidebarRow(
      value: AppModel.Selection.note(note.id), model.notes.title(for: note.id),
      subtitle: model.notes.subtitle(for: note.id), systemImage: "note.text"
    ) {
      DetachReturnBadge(selection: .note(note.id))
      if note.isEncrypted {
        Image(systemName: "lock.fill")
          .foregroundStyle(.kitSecondary)
          .help("Markdown keeps this note's file encrypted (it syncs encrypted either way)")
          .transition(.scale.combined(with: .opacity))
      }
    }
    .animation(.kit, value: note.isEncrypted)
  }
}

private extension View {
  /// Text files dropped on Notes: copied into encrypted notes, or linked (FileDropActions.swift).
  func notesFileDrop() -> some View {
    modifier(NotesFileDrop())
  }
}

private struct NotesFileDrop: ViewModifier {
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View {
    #if os(macOS)
    content.fileDrop { files in model.requestFileDrop(files, on: .notes) }
    #else
    content
    #endif
  }
}
