import ComponentKit
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

  @Environment(\.kitDismiss) private var dismiss
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
    KitSheet(
      title: mode == .move ? "Move to…" : "Copy to…", systemImage: mode == .move ? "folder" : "doc.on.doc",
      hue: .blue, width: 420
    ) {
      FormCard {
        FormRow("Mode", systemImage: "arrow.left.arrow.right", hue: .blue) {
          KitSegmented(selection: $mode, options: [("Move", .move), ("Copy", .copy)])
        }
        FormRow(
          "Destination", systemImage: "folder", hue: .blue,
          field: TextField("Destination path", text: $text).kitFont(.mono))
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(mode == .move ? "Move" : "Copy") {
        onConfirm(text, mode)
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .onAppear { text = defaultPath }
  }
}
