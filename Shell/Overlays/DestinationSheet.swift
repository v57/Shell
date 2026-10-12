import SwiftUI
import ShellIntegrations

/// The move/copy destination prompt: a text field pre-filled with the current
/// directory, a Move/Copy mode selector, and a confirm/cancel pair. `onConfirm`
/// receives the typed destination and the chosen mode.
struct DestinationSheet: View {
  let defaultPath: String
  @Binding var text: String
  let initialMode: FileCommandBuilder.MoveCopyMode
  let onConfirm: (String, FileCommandBuilder.MoveCopyMode) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var mode: FileCommandBuilder.MoveCopyMode

  init(
    defaultPath: String, text: Binding<String>, initialMode: FileCommandBuilder.MoveCopyMode,
    onConfirm: @escaping (String, FileCommandBuilder.MoveCopyMode) -> Void
  ) {
    self.defaultPath = defaultPath
    self._text = text
    self.initialMode = initialMode
    self.onConfirm = onConfirm
    self._mode = State(initialValue: initialMode)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(mode == .move ? "Move to…" : "Copy to…").font(.headline)
      TextField("Destination path", text: $text).textFieldStyle(.roundedBorder).font(
        .body.monospaced()
      ).onAppear { text = defaultPath }
      Picker("", selection: $mode) {
        Text("Move").tag(FileCommandBuilder.MoveCopyMode.move)
        Text("Copy").tag(FileCommandBuilder.MoveCopyMode.copy)
      }.pickerStyle(.segmented).labelsHidden()
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button(mode == .move ? "Move" : "Copy") {
          onConfirm(text, mode)
          dismiss()
        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding().frame(minWidth: 340).background(.regularMaterial)
  }
}
