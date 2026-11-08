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
  @State private var commands = MarkdownEditorCommands()

  var body: some View {
    GuardedMarkdownEditor(
      editor: MarkdownEditorView(
        text: model.notes.decryptedNote(id: noteID)?.text ?? "",
        onChange: { model.notes.updateText($0, for: noteID) },
        commands: commands
      ))
    .safeAreaInset(edge: .bottom, spacing: 0) { MarkdownQuickActionsBar(commands: commands) }
    // The editor is deallocated with this view, but its text edits stay on the
    // window's undo stack — a later ⌘Z would message the freed editor.
    // (ContentView keys this view by note id, so a note switch lands here too.)
    .onDisappear { UndoHygiene.discardStaleTextUndo() }
  }
}

/// A Markdown editor whose web images wait for "Load Images" and whose links that don't open at once ask first, as
/// in the Markdown app (security audit M1, H4): a note or a file is anyone's text, and its image is a read receipt.
struct GuardedMarkdownEditor: View {
  let editor: MarkdownEditorView
  @State private var loadsImages = false
  @State private var hasBlockedImages = false
  @State private var linkRequest: MarkdownLinkRequest?

  var body: some View {
    VStack(spacing: 0) {
      if hasBlockedImages, !loadsImages {
        Banner(
          "This note's images from the web aren't loaded.",
          message: "Loading them tells their servers that the note was opened.", systemImage: "photo", hue: .blue
        ) {
          Button("Load Images") { loadsImages = true }
        }
        .padding(KitMetrics.gutter)
      }
      editor
        .remoteImages(loads: loadsImages) { hasBlockedImages = $0 }
        .onConfirmLink { linkRequest = $0 }
    }
    .kitConfirmation(
      linkTitle, isPresented: Binding(get: { linkRequest != nil }, set: { if !$0 { linkRequest = nil } }),
      message: linkMessage, systemImage: "link", confirm: "Open", role: nil
    ) { [linkRequest] in linkRequest?.open() }
  }

  private var linkTitle: LocalizedStringKey {
    guard let linkRequest, linkRequest.url.isFileURL else { return "Open this link?" }
    return "Open “\(linkRequest.target)”?"
  }

  /// Where the link leads in full (a file's path, else the whole URL) and the app that would open it.
  private var linkMessage: LocalizedStringKey {
    guard let url = linkRequest?.url else { return "" }
    let place = url.isFileURL ? url.path : url.absoluteString
    guard let opener = linkRequest?.opener else { return "\(place) opens in another app." }
    return "\(place) opens in \(opener)."
  }
}

/// The toggles for the selected text and lines (lists, checkboxes, code, notes) under a Markdown editor.
struct MarkdownQuickActionsBar: View {
  let commands: MarkdownEditorCommands

  var body: some View {
    HStack(spacing: 0) {
      ForEach(MarkdownQuickAction.allCases) { action in
        Button(action.title, systemImage: action.systemImage) { commands.apply(action.format) }
          .kitHelp(action.title)
      }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.kitToolIcon)
    .padding(.horizontal, KitMetrics.gutter)
    .frame(height: 40)
    .kitSurface(.floating, cornerRadius: KitMetrics.radiusCapsule)
    .padding(.bottom, KitMetrics.gutter)
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
    .kitHelp(
      isEncrypted
        ? "Keep this note as a plain Markdown file in Markdown's notes folder"
        : "Keep this note's file encrypted, readable only by the v57 apps")
  }
}
