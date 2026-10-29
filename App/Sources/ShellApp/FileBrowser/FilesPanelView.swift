import ComponentKit
import SwiftUI
import ShellIntegrations

/// The Files panel: binds a `DirectoryBrowserModel` into the dumb
/// `DirectoryBrowserView`, and owns the file-operation UI — a selection-aware
/// toolbar (Open/Delete/Move/Copy), the delete confirmation dialog, and the
/// move/copy destination prompt. It owns no state of its own beyond what those
/// transient sheets need; every action routes back to a model method.
struct FilesPanelView: View {
  @Environment(AppModel.self) private var app
  @Bindable var model: DirectoryBrowserModel

  /// Whether the delete confirmation dialog is showing.
  @State private var showsDeleteConfirm = false
  /// The names the delete confirmation dialog is showing for. Snapshotted when
  /// the context-menu Delete is tapped so the dialog acts on exactly those rows
  /// rather than re-reading the (possibly changed) selection.
  @State private var deleteCandidates: Set<String> = []
  /// Whether the move/copy destination sheet is showing.
  @State private var showsDestinationSheet = false
  /// The names being moved/copied (snapshotted when the sheet is opened).
  @State private var mutatingNames: Set<String> = []
  /// The mode (move or copy) for a pending operation.
  @State private var mutatingMode: FileCommandBuilder.MoveCopyMode = .move
  /// The destination the user is typing in the sheet.
  @State private var destinationText = ""

  var body: some View {
    DirectoryBrowserView(
      rows: model.rows, path: model.path, selection: $model.selection,
      sortOrder: $model.sortOrder, isLoading: model.busy, errorMessage: model.lastError,
      sshConfig: model.context?.kind.sshConfig, onNavigate: { model.navigate(into: $0) }, onOpen: { model.open($0) },
      onNavigateUp: { model.navigateUp() }, onRetry: { Task { await model.refresh() } },
      onDelete: { names in
        deleteCandidates = names
        showsDeleteConfirm = true
      }, onMove: { names, _ in beginMutate(names: names, mode: .move) },
      onCopy: { names in beginMutate(names: names, mode: .copy) },
      onDrop: { files in
        #if os(macOS)
        app.dropFiles(files, into: model)
        #else
        model.copyIn(urls: files)
        #endif
      },
      onRename: { from, to in model.rename(from: from, to: to) },
      onMoveCopyIntoDirectory: { names, targetPath, mode in
        model.moveCopy(names, to: targetPath, mode: mode)
      })
      .kitConfirmation(
        "Delete \(deleteCandidates.count) item\(deleteCandidates.count == 1 ? "" : "s")?",
        isPresented: $showsDeleteConfirm, message: "This cannot be undone.", systemImage: "trash", confirm: "Delete"
      ) { model.delete(deleteCandidates) }
      .kitSheet(isPresented: $showsDestinationSheet) {
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
