import ComponentKit
import SwiftUI
import ShellKit

/// The ⌘E "insert into terminal" overlay: a multiline text area plus Apply.
///
/// Applying sends the typed text into the focused terminal's output stream.
/// With "Send as separate commands" on (default), newlines are translated to
/// carriage returns so each line runs as its own Enter in the shell (a small
/// script or a sequence of commands, one per line). With it off, newlines go
/// through as literal `\n` — the text is pasted verbatim into the line
/// editor (e.g. a multi-line paste inside a heredoc or a quoted string).
struct CommandInsertView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.kitDismiss) private var dismiss
  @State private var text = ""
  @FocusState private var editorFocused: Bool

  /// Persisted choice: send each line as a separate Enter (true) vs. send
  /// the newlines verbatim (false). Defaults to separate commands.
  @AppStorage("sendAsSeparateCommands") private var sendAsSeparateCommands = true

  /// The toggle is only meaningful for multi-line input: a single line has
  /// no newlines to translate either way.
  private var isMultiline: Bool {
    text.contains("\n")
  }

  private var sessionName: String {
    guard let session = model.selectedSession else { return "no terminal selected" }
    return model.displayName(for: session)
  }

  private var canApply: Bool {
    model.selectedSession != nil && !text.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Insert into Terminal")
          .font(.headline)
        Spacer()
        Text("→ \(sessionName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .frame(minWidth: 420, minHeight: 180)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.25))
        )
        .focused($editorFocused)

      if isMultiline {
        Toggle("Send as separate commands", isOn: $sendAsSeparateCommands)
#if os(macOS) || os(Windows)
          .toggleStyle(.checkbox)
#else
          .toggleStyle(.switch)
#endif
          .font(.caption)
        Text(sendAsSeparateCommands
          ? "Each line is sent as Enter, so multi-line text runs line-by-line in the shell."
          : "Newlines are sent as-is, so multi-line text is pasted verbatim.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Each line is sent as Enter, so multi-line text runs line-by-line in the shell.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Apply") { apply() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canApply)
      }
    }
    .padding(16)
    .onAppear {
      DispatchQueue.main.async { editorFocused = true }
    }
    // The TextEditor dies with this overlay; drop the edits it left on the
    // window's undo stack so a later ⌘Z cannot message the freed editor.
    .onDisappear { UndoHygiene.discardStaleTextUndo() }
  }

  private func apply() {
    guard let session = model.selectedSession else { return }
    model.insertCommandText(text, into: session, sendAsSeparateCommands: sendAsSeparateCommands)
    dismiss()
  }
}
