import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The main-view editor for a single note. The note's ciphertext is
/// decrypted HERE when the note opens (`decryptedNote`), never eagerly at
/// load; edits are pushed into the store, which autosaves 5s after the last
/// keystroke. The window title and the sidebar row follow the first
/// non-empty line (Notes.app style), so editing it renames the note.
struct NoteEditorView: View {
  @Environment(AppModel.self) private var model
  let noteID: UUID

  @State private var text = ""
  @FocusState private var editorFocused: Bool

  var body: some View {
    TextEditor(text: $text)
      .font(.system(size: 13).monospaced())
      .scrollContentBackground(.hidden)
      .padding(8)
      .focused($editorFocused)
      .onAppear {
        text = model.notes.decryptedNote(id: noteID)?.text ?? ""
        editorFocused = true
        disableQuoteSubstitution()
      }
      .onChange(of: editorFocused) { _, focused in
        if focused { disableQuoteSubstitution() }
      }
      .onChange(of: text) { _, newValue in
        model.notes.updateText(newValue, for: noteID)
      }
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

  /// SwiftUI's TextEditor doesn't expose smart-quote control, but it's backed
  /// by an NSTextView, so walk the key window and disable automatic quote and
  /// dash substitution while the note is focused. Notes should store exactly
  /// what you type — no `"`→“ ” munging. Runs on appear and again whenever the
  /// editor regains focus (the backing view can be recreated between notes).
  private func disableQuoteSubstitution() {
    #if os(macOS)
    guard let window = NSApp.keyWindow,
          let textView = Self.findTextView(in: window.contentView) else { return }
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    #endif
  }

  #if os(macOS)
  private static func findTextView(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
      if let found = findTextView(in: subview) { return found }
    }
    return nil
  }
  #endif
}
