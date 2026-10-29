import SwiftUI

/// A small rename prompt presented as a sheet from the database connection
/// context menu. The TextField is pre-filled with the connection's current
/// name (or its display name fallback); committing an empty value resets the
/// name to the engine display name, matching the displayName fallback.
struct DatabaseRenameSheet: View {
  let connection: DatabaseConnection
  @Binding var text: String
  let onCommit: () -> Void
  let onCancel: () -> Void

  @FocusState private var fieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Database Connection")
        .font(.headline)
      TextField(connection.displayName, text: $text)
        .textFieldStyle(.roundedBorder)
        .focused($fieldFocused)
        .onSubmit { onCommit() }
      Label(connection.displayName, systemImage: connection.engine.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
        Button("Rename") { onCommit() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear { fieldFocused = true }
  }
}
