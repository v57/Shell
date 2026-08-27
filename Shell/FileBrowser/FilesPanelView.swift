import SwiftUI

/// The Files panel: binds a `DirectoryBrowserModel` into the dumb
/// `DirectoryBrowserView`. Owns no state and spawns no work — it forwards the
/// model's properties and routes every visual action back to model methods.
struct FilesPanelView: View {
  @Bindable var model: DirectoryBrowserModel

  var body: some View {
    DirectoryBrowserView(
      rows: model.rows, path: model.path, selection: $model.selection, sortOrder: $model.sortOrder,
      isLoading: model.busy, errorMessage: model.lastError,
      onNavigate: { model.navigate(into: $0) }, onOpen: { model.open($0) },
      onNavigateUp: { model.navigateUp() }, onRetry: { Task { await model.refresh() } },
      onDelete: { _ in }, onMove: { _, _ in })
  }
}
