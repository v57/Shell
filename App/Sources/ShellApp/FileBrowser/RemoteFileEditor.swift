#if os(iOS)
  import CodeEditor
  import CodeHighlighting
  import ComponentKit
  import MarkdownKit
  import SwiftUI

  /// The iPhone and iPad's editor for a file in the Files panel (`RemoteFileDocument`): Code's editor with its syntax
  /// colors, or Markdown's for a Markdown file. Save (⌘S) writes it back to the host; closing with unsaved edits asks
  /// first.
  struct RemoteFileEditor: View {
    let document: RemoteFileDocument
    let onClose: () -> Void
    @State private var confirmsDiscard = false
    @State private var markdownCommands = MarkdownEditorCommands()
    @ScaledMetric(relativeTo: .footnote) private var fontSize: CGFloat = 13

    var body: some View {
      NavigationStack {
        VStack(spacing: 0) {
          if let notice = document.notice {
            Label(notice, systemImage: "info.circle")
              .kitFont(.caption)
              .foregroundStyle(.kitSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, KitMetrics.gutter)
              .padding(.vertical, 8)
          }
          editor
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
      }
      .interactiveDismissDisabled(document.isEdited)
      .confirmationDialog(
        "Save your changes to “\(document.name)”?", isPresented: $confirmsDiscard, titleVisibility: .visible
      ) {
        Button("Save") {
          Task { if await document.save() { onClose() } }
        }
        Button("Discard Changes", role: .destructive) { onClose() }
        Button("Cancel", role: .cancel) {}
      }
      .alert(
        problemTitle, isPresented: problemShown, presenting: document.saveProblem
      ) { problem in
        if problem == .changedOnHost || problem == .removedFromHost {
          Button("Save Anyway", role: .destructive) {
            Task { await document.save(overwriting: true) }
          }
          Button("Cancel", role: .cancel) {}
        } else {
          Button("OK", role: .cancel) {}
        }
      } message: { problem in
        Text(problemMessage(problem))
      }
      .onDisappear { document.close() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
      ToolbarItem(placement: .cancellationAction) {
        Button("Close") {
          if document.isEdited { confirmsDiscard = true } else { onClose() }
        }
      }
      ToolbarItem(placement: .principal) {
        VStack(spacing: 0) {
          Text(document.name).kitFont(.headline).lineLimit(1)
          Text(document.language.map { "\(document.path) · \($0.name)" } ?? document.path)
            .kitFont(.caption)
            .foregroundStyle(.kitSecondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      if document.isEditable {
        ToolbarItem(placement: .confirmationAction) {
          if document.isSaving {
            ProgressView()
          } else {
            Button("Save") { Task { await document.save() } }
              .keyboardShortcut("s", modifiers: .command)
              .disabled(!document.isEdited)
          }
        }
      }
    }

    @ViewBuilder private var editor: some View {
      if !document.isText {
        Spacer()
      } else if document.isMarkdown {
        GuardedMarkdownEditor(
          editor: MarkdownEditorView(
            text: document.loadedText, isReadOnly: !document.isEditable, onChange: { document.edit($0) },
            commands: markdownCommands))
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if document.isEditable { MarkdownQuickActionsBar(commands: markdownCommands) }
        }
      } else {
        CodeTextEditor(
          text: Binding(get: { document.text }, set: { document.edit($0) }), language: document.language,
          configuration: EditorConfiguration(themeID: "github", fontSize: fontSize, isEditable: document.isEditable))
        .ignoresSafeArea(.container, edges: .bottom)
      }
    }

    private var problemShown: Binding<Bool> {
      Binding(get: { document.saveProblem != nil }, set: { if !$0 { document.saveProblem = nil } })
    }

    private var problemTitle: String {
      switch document.saveProblem {
      case .changedOnHost: String(localized: "“\(document.name)” changed on the host")
      case .removedFromHost: String(localized: "“\(document.name)” was removed from the host")
      default: String(localized: "Couldn’t save “\(document.name)”")
      }
    }

    private func problemMessage(_ problem: RemoteFileDocument.SaveProblem) -> String {
      switch problem {
      case .changedOnHost:
        String(localized: "It was changed after you opened it. Save Anyway replaces those changes with yours.")
      case .removedFromHost:
        String(localized: "It was deleted after you opened it. Save Anyway writes it again with your text.")
      case .failed(let message): message
      }
    }
  }
#endif
