import SwiftUI
import TerminalIntegrations

/// The Files panel: binds a `DirectoryBrowserModel` into the dumb
/// `DirectoryBrowserView`, and owns the file-operation UI — a selection-aware
/// toolbar (Open/Delete/Move/Copy), the delete confirmation dialog, and the
/// move/copy destination prompt. It owns no state of its own beyond what those
/// transient sheets need; every action routes back to a model method.
struct FilesPanelView: View {
  @Bindable var model: DirectoryBrowserModel

  /// Whether the delete confirmation dialog is showing.
  @State private var showsDeleteConfirm = false
  /// Whether the move/copy destination sheet is showing.
  @State private var showsDestinationSheet = false
  /// The names being moved/copied (snapshotted when the sheet is opened).
  @State private var mutatingNames: Set<String> = []
  /// The mode (move or copy) for a pending operation.
  @State private var mutatingMode: FileCommandBuilder.MoveCopyMode = .move
  /// The destination the user is typing in the sheet.
  @State private var destinationText = ""

  var body: some View {
    VStack(spacing: 0) {
      SelectionToolbar(
        hasSelection: !model.selection.isEmpty,
        onOpen: {
          for name in model.selection {
            if let row = model.rows.first(where: { $0.name == name }) { model.open(row) }
          }
        }, onDelete: { showsDeleteConfirm = true },
        onMove: { beginMutate(names: model.selection, mode: .move) },
        onCopy: { beginMutate(names: model.selection, mode: .copy) })
      Divider()
      DirectoryBrowserView(
        rows: model.rows, path: model.path, selection: $model.selection,
        sortOrder: $model.sortOrder, isLoading: model.busy, errorMessage: model.lastError,
        onNavigate: { model.navigate(into: $0) }, onOpen: { model.open($0) },
        onNavigateUp: { model.navigateUp() }, onRetry: { Task { await model.refresh() } },
        onDelete: { names in model.delete(names) },
        onMove: { names, _ in beginMutate(names: names, mode: .move) })
    }.confirmationDialog(
      "Delete \(model.selection.count) item\(model.selection.count == 1 ? "" : "s")?",
      isPresented: $showsDeleteConfirm, titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { model.delete(model.selection) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This cannot be undone.")
    }.sheet(isPresented: $showsDestinationSheet) {
      DestinationSheet(
        defaultPath: model.path.isEmpty ? "/" : model.path, text: $destinationText,
        initialMode: mutatingMode
      ) { destination, mode in model.moveCopy(mutatingNames, to: destination, mode: mode) }
    }
  }

  /// Snapshot the selection + mode and open the destination sheet, pre-filling
  /// the current path as the destination default.
  private func beginMutate(names: Set<String>, mode: FileCommandBuilder.MoveCopyMode) {
    guard !names.isEmpty else { return }
    mutatingNames = names
    mutatingMode = mode
    destinationText = model.path.isEmpty ? "/" : model.path
    showsDestinationSheet = true
  }
}

/// A small selection-aware toolbar: the file-operation entry points surfaced on
/// top of the browser. Buttons are disabled until there is a selection.
private struct SelectionToolbar: View {
  let hasSelection: Bool
  let onOpen: () -> Void
  let onDelete: () -> Void
  let onMove: () -> Void
  let onCopy: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onOpen) { Label("Open", systemImage: "arrow.up.forward.app") }.disabled(
        !hasSelection)
      Spacer(minLength: 10)
      Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }.disabled(!hasSelection)
      Button(action: onMove) { Label("Move", systemImage: "folder") }.disabled(!hasSelection)
      Button(action: onDelete) { Label("Delete", systemImage: "trash") }.disabled(!hasSelection)
    }.labelStyle(.titleAndIcon).padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
  }
}

/// The move/copy destination prompt: a text field pre-filled with the current
/// directory, a Move/Copy mode selector, and a confirm/cancel pair. `onConfirm`
/// receives the typed destination and the chosen mode.
private struct DestinationSheet: View {
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
