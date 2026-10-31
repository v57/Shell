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
    KitSheet(
      title: "Insert into Terminal", meta: "→ \(sessionName)", systemImage: "text.insert", hue: .green, width: 480
    ) {
      TextEditor(text: $text)
        .kitFont(.mono)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 180)
        .padding(6)
        .kitSurface(.field)
        .focused($editorFocused)
        .padding(.horizontal, KitMetrics.gutter)
      FormCard(
        footer: isMultiline && !sendAsSeparateCommands
          ? "Newlines are sent as-is, so multi-line text is pasted verbatim."
          : "Each line is sent as Enter, so multi-line text runs line-by-line in the shell."
      ) {
        if isMultiline {
          FormRow("Send as separate commands", systemImage: "return", hue: .green) {
            Toggle("Send as separate commands", isOn: $sendAsSeparateCommands)
              .toggleStyle(.kitSwitch)
              .kitLabelsHidden()
          }
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Apply") { apply() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!canApply)
    }
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
