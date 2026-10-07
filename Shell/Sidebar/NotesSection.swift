import SwiftUI

/// The Notes section: the saved notes, decrypted per visible row. Hidden
/// entirely while the notes feature is off (this section's own gate), and its
/// collapse state is local to this section.
struct NotesSectionView: View {
  @Environment(AppModel.self) private var model

  /// Collapse state for this section, persisted across launches.
  @AppStorage("sidebar.notes.collapsed") private var notesCollapsed = false

  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    if flags.isEnabled(.notes) {
      SidebarSection {
        ForEach(notesCollapsed || !flags.isEnabled(.notes) ? [] : model.notes.notes) { note in
          NoteRow(note: note)
            .sidebarRow(.note(note.id))
            .contextMenu {
              Button("Delete Note", role: .destructive) {
                model.deleteNote(note.id)
              }
            }
        }
      } header: {
        SidebarSectionHeader(collapsed: $notesCollapsed) {
          Text("Notes")
        } trailing: {
          if flags.isEnabled(.notes) {
            Button {
              model.newNote()
            } label: {
              Image(systemName: "plus")
            }.buttonStyle(.borderless).help("New note")
          }
        }
      }
    } // end if (notes section gate)
  }
}

/// A note row in the sidebar. The title is the first non-empty line of the
/// note (editing it renames it); the preview is the next non-empty line.
/// Both are DECRYPTED IN THE VIEW via `decryptedNote(id:)` — SwiftUI's List
/// materializes visible rows only, so only visible cells decrypt (results
/// cached by the store).
private struct NoteRow: View {
  @Environment(AppModel.self) private var model
  let note: NotesStore.NoteSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: "note.text")
          .foregroundStyle(.secondary)
        Text(model.notes.title(for: note.id))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        DetachReturnBadge(selection: .note(note.id))
        if note.storedInICloud {
          Image(systemName: "icloud.fill")
            .font(.caption2)
            .foregroundStyle(Color.blue)
            .help("Stored in iCloud (encrypted)")
            .transition(SidebarMotion.iconTransition)
        }
      }
      .sidebarAnimation(value: note.storedInICloud)
      if let subtitle = model.notes.subtitle(for: note.id) {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .contentShape(Rectangle())
  }
}
