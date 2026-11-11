import ComponentKit
import SwiftUI
import ShellIntegrations
import ShellKit

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
  /// The pending move or copy the destination sheet shows: the names and mode snapshotted when it opened. One value
  /// the sheet is presented for, so its content never reads names or a mode from before (S-010: Copy… opened as
  /// Move with no names, and its Copy did nothing).
  @State private var mutating: MutateRequest?
  /// The destination the user is typing in the sheet.
  @State private var destinationText = ""

  var body: some View {
    DirectoryBrowserView(
      rows: model.rows, path: model.path, selection: $model.selection,
      sortOrder: $model.sortOrder, isLoading: model.busy, errorMessage: model.lastError,
      sshConfig: model.context?.kind.sshConfig, onNavigate: { model.navigate(into: $0) }, onOpen: { model.open($0) },
      onNavigateUp: { model.navigateUp() }, onRetry: { Task { await model.refresh() } },
      onNavigateTo: { model.navigate(toPath: $0) }, onRefresh: { await model.refresh() },
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
      // The terminal's keyboard can be up under the panel: its last rows stay above it (S-008).
      .keepsAboveKeyboard()
      .kitConfirmation(
        "Delete \(deleteCandidates.count) item\(deleteCandidates.count == 1 ? "" : "s")?",
        isPresented: $showsDeleteConfirm, message: "This cannot be undone.", systemImage: "trash", confirm: "Delete"
      ) { model.delete(deleteCandidates) }
      .kitSheet(item: $mutating) { request in
        DestinationSheet(defaultPath: request.defaultPath, text: $destinationText, initialMode: request.mode) {
          destination, mode in model.moveCopy(request.names, to: destination, mode: mode)
        }
      }
  }

  /// Snapshot the selection + mode and open the destination sheet, pre-filling
  /// the current path as the destination default.
  private func beginMutate(names: Set<String>, mode: FileCommandBuilder.MoveCopyMode) {
    guard !names.isEmpty else { return }
    let path = model.path.isEmpty ? "/" : model.path
    destinationText = path
    mutating = MutateRequest(names: names, mode: mode, defaultPath: path)
  }
}

/// A move or copy waiting for its destination.
private struct MutateRequest: Identifiable {
  let id = UUID()
  let names: Set<String>
  let mode: FileCommandBuilder.MoveCopyMode
  let defaultPath: String
}
