import SwiftUI
import Terminal

/// The ⌘E "insert into terminal" overlay: a multiline text area plus Apply.
///
/// Applying sends the typed text into the focused terminal's output stream
/// with newlines translated to carriage returns, so multi-line input each
/// becomes an Enter in the shell (e.g. a small script or a sequence of
/// commands, one per line).
struct CommandInsertView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @FocusState private var editorFocused: Bool

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

      Text("Each line is sent as Enter, so multi-line text runs line-by-line in the shell.")
        .font(.caption)
        .foregroundStyle(.secondary)

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
  }

  private func apply() {
    guard let session = model.selectedSession else { return }
    model.insertCommandText(text, into: session)
    dismiss()
  }
}
