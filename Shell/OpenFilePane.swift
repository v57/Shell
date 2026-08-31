#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Md

/// A transient, scratch document for a local text file opened into Shell.
///
/// Lives in the sidebar's "Text Files" section (mirroring the Notes section)
/// and is edited in the existing content area. It is NOT persisted — it is
/// cleared on app restart and when the file is closed via ⌘W — and it is kept
/// completely separate from `NotesStore` (an opened file is a scratch view,
/// not a Notes item). Read-write: content is loaded off the main thread,
/// edited, and written back to the same path on Save.
struct OpenedFile: Identifiable, Equatable {
  let id = UUID()
  /// The on-disk path the file was opened from (the save/write-back target).
  let url: URL
  /// The current in-memory text (the edit buffer; the source of truth for save).
  /// The setter is `internal` (default) so `AppModel` (same module) can apply
  /// loads/edits; the view only reads.
  var text: String
  /// True once `text` differs from the content last written to disk.
  var isDirty = false
  /// True once the initial load has completed (successfully or with a notice).
  var isLoaded = false
  /// A visible notice for a non-UTF8 or oversized file; nil == editable.
  /// When set, the pane is read-only and Save is disabled.
  var loadNotice: String?
  /// The monotonic generation this file's content was loaded under; a stale
  /// off-main load is discarded when it no longer matches the current value.
  let loadGeneration: Int

  init(url: URL, text: String = "", loadGeneration: Int = 0) {
    self.url = url
    self.text = text
    self.loadGeneration = loadGeneration
  }

  var displayName: String { url.lastPathComponent }

  /// Whether the file may be edited and saved. Non-UTF8 and oversized files
  /// are shown with a notice and kept read-only so a Save can never truncate
  /// or corrupt the on-disk file.
  var canEdit: Bool { loadNotice == nil }
}

/// Read-write editor pane for an opened local text file.
///
/// - `.md`/`.markdown` renders with `Md.MarkdownEditorView` (live preview,
///   same editor as Notes) and writes back through `onChange`.
/// - Other text extensions render in a monospaced `TextEditor` with smart
///   quotes/dashes disabled (plain-text files must be stored verbatim).
/// - A non-UTF8 or oversized file shows a notice and is read-only.
/// - Dirty files surface a Save confirmation on close (⌘W); Save (⌘S) writes
///   the buffer back to `url`.
struct OpenFilePane: View {
  @Environment(AppModel.self) private var model
  let file: OpenedFile

  /// Recognized markdown extensions (live-preview editor).
  private var isMarkdown: Bool {
    ["md", "markdown"].contains(file.url.pathExtension.lowercased())
  }

  var body: some View {
    Group {
      if !file.isLoaded {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let notice = file.loadNotice {
        // Non-UTF8 / oversized: visible notice, read-only, no save.
        readOnlyNotice(notice)
      } else if isMarkdown {
        MarkdownEditorView(text: file.text, onChange: { newText in
          model.updateOpenedFileText(newText, for: file.id)
        })
      } else {
        monospacedEditor
      }
    }
    .toolbar {
      if file.isLoaded && file.canEdit && file.isDirty {
        ToolbarItem(placement: .primaryAction) {
          Button {
            model.saveOpenedFile(file.id)
          } label: {
            Label("Save", systemImage: "square.and.arrow.down")
          }
          .help("Save (⌘S)")
        }
      }
    }
    // ⌘S while the pane is shown: a hidden button in the view tree registers
    // the key equivalent without adding a menu command (toolbar buttons don't
    // take key equivalents here). Menu key equivalents dispatch before the
    // terminal's onKeyPress, and this only fires while the file pane is up.
    .overlay {
      if file.isLoaded && file.canEdit {
        Button("Save") { model.saveOpenedFile(file.id) }
          .keyboardShortcut("s", modifiers: .command)
          .frame(width: 0, height: 0)
          .opacity(0)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }
    }
    .confirmationDialog(
      "Save changes to \(file.displayName)?",
      isPresented: Binding(
        get: { model.pendingCloseOpenedFile == file.id },
        set: { if !$0 { model.clearPendingClose() } }
      ),
      titleVisibility: .visible
    ) {
      Button("Save & Close") { model.commitCloseOpenedFile(file.id) }
      Button("Close Without Saving", role: .destructive) {
        model.discardCloseOpenedFile(file.id)
      }
      Button("Cancel", role: .cancel) { model.clearPendingClose() }
    }
  }

  /// Store-backed binding: reads the current buffer from the model and pushes
  /// every edit back through `updateOpenedFileText` (which no-ops on an
  /// unchanged value, so the initial hydrate doesn't phantom-mark dirty).
  private var textBinding: Binding<String> {
    Binding(
      get: { file.text },
      set: { model.updateOpenedFileText($0, for: file.id) }
    )
  }

  /// Monospaced text editor for .txt/.conf/.yml/.yaml, with smart quotes and
  /// dashes disabled so plain-text files are stored byte-for-byte verbatim.
  private var monospacedEditor: some View {
    TextEditor(text: textBinding)
      .font(.system(size: 13, design: .monospaced))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear { disableSmartQuotes() }
      .onChange(of: file.text) { _, _ in disableSmartQuotes() }
  }

  /// A visible error/notice for non-UTF8 or oversized files, with the
  /// (possibly truncated) content shown below as read-only text.
  private func readOnlyNotice(_ notice: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(notice, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
        .padding()
      ScrollView {
        Text(file.text.isEmpty ? "No preview available." : file.text)
          .font(.system(size: 13, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
    }
  }

  /// Disables automatic quote/dash substitution on the backing `NSTextView` so
  /// a plain-text file is stored verbatim (SwiftUI exposes no public knob).
  /// The text view can be recreated, so it is re-applied on every keystroke.
  private func disableSmartQuotes() {
    guard let window = NSApp.keyWindow,
          let textView = Self.findTextView(in: window.contentView) else { return }
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
  }

  private static func findTextView(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
      if let found = findTextView(in: subview) { return found }
    }
    return nil
  }
}
#endif // os(macOS)
