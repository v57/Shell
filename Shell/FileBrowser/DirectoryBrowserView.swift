import Foundation
import SwiftUI
import TerminalIntegrations
import UniformTypeIdentifiers

#if os(macOS)
/// A row dragged out of the browser. Carries the absolute file URL so a LOCAL
/// file can be dropped into Finder (which copies/moves the actual file); for a
/// remote listing the URL is best-effort and simply won't resolve there. Also
/// carries the names of the dragged rows, so a drop onto a directory row in the
/// SAME table can move/copy them into that directory — the drag-OUT URL and the
/// drag-IN names travel together as two representations of one payload.
private struct RowDragPayload: Transferable, Codable {
  /// The dragged row names. Dragging a selected row carries the whole
  /// selection; dragging an unselected row carries just that one name.
  let names: [String]
  /// The absolute file URL for drag-OUT to Finder (single-file export).
  let url: URL

  // The app target compiles MainActor-default; the transfer representation is
  // read by the framework on a background thread, so it must be nonisolated.
  nonisolated static var transferRepresentation: some TransferRepresentation {
    // Internal drag: JSON payload, so a directory row's
    // `.dropDestination(for: RowDragPayload.self)` reconstructs the names and
    // can move/copy them into the target directory.
    CodableRepresentation(for: RowDragPayload.self, contentType: .json)
    // Drag-OUT to Finder: export the file URL as a file.
    FileRepresentation(exportedContentType: .fileURL) { item in
      SentTransferredFile(item.url)
    }
  }
}
#endif

/// The directory browser's main content area: a breadcrumb path bar plus the
/// listing of the current directory's entries.
///
/// The view is deliberately a dumb, testable component. It takes the rows to
/// render, the current absolute path (for the breadcrumb), a *selection* binding
/// (a set of entry names, so callers can drive toolbar operations such as
/// delete/move), and a *sortOrder* binding, plus a handful of callbacks that the
/// owning model wires up. It owns no state and spawns no work — the owner decides
/// when to list, navigate, open, or run file operations.
///
/// Rendered states, in priority order:
/// - **Error** — `errorMessage` is non-nil (`ContentUnavailableView` + Retry).
/// - **Loading** — `isLoading` is true and there are no rows yet (`ProgressView`).
/// - **Empty** — no rows and no error (`ContentUnavailableView`).
/// - **Success** — the `Table` (macOS) or `List` (iOS) of rows.
///
/// On macOS the listing is sortable `Table` with Name / Type / Size / Modified
/// columns. On iOS it falls back to a `List` layout rendering the same row model.
struct DirectoryBrowserView: View {
  /// The parsed entries of the current directory, in the order the listing
  /// returned them. Sorting is applied by the view from `sortOrder`.
  let rows: [FileRow]
  /// The absolute directory being shown. Used for the breadcrumb path bar.
  let path: String
  /// Selected entry names (the `.id` of a `FileRow` is its name).
  @Binding var selection: Set<String>
  /// The active column sort order, driven by the sortable `Table` columns.
  @Binding var sortOrder: [KeyPathComparator<FileRow>]
  /// Whether a refresh is in flight. Shown as a `ProgressView` only while the
  /// initial listing is still pending (rows empty), so a refresh that already
  /// has a table on screen doesn't flash it away.
  let isLoading: Bool
  /// A non-nil value replaces the table with an error state + Retry.
  let errorMessage: String?

  /// The name of the row currently being renamed, or nil when not editing.
  /// A row is in rename mode when `renamingName == row.name`.
  @State private var renamingName: String?
  /// The in-progress text of the rename field, seeded from the row name when
  /// rename mode begins. Only one row is ever in rename mode.
  @State private var renameText = ""
  /// Focus for the rename `TextField`, keyed by the row name so the field is
  /// focused the moment rename mode begins.
  @FocusState private var renameFieldFocused: String?
  /// A short suppression window so a Return that just committed a rename
  /// (the focused TextField's `.onSubmit`) cannot be re-interpreted by the
  /// table's `.onKeyPress(.return)` in the same event pass and immediately
  /// re-open the editor. Cleared on commit/cancel; a human Return press
  /// never lands inside this window except the commit itself.
  @State private var suppressRenameUntil = Date.distantPast

  /// Double-clicking a directory emits `navigate(into:)`.
  var onNavigate: (FileRow) -> Void
  /// Double-clicking a file emits `open(file:)`.
  var onOpen: (FileRow) -> Void
  /// The breadcrumb "up" button.
  var onNavigateUp: () -> Void
  /// The error state's Retry button.
  var onRetry: () -> Void
  /// Delete the selected entries (context-menu op).
  var onDelete: (Set<String>) -> Void
  /// Move the selected entries to a destination (context-menu op).
  var onMove: (Set<String>, String) -> Void
  /// Copy the selected entries to a destination (context-menu op).
  var onCopy: (Set<String>) -> Void
  /// Copy files dropped onto the table (from Finder) into the current directory.
  var onDrop: ([URL]) -> Void
  /// Rename a single entry from `from` to `to`. The view enters rename mode on
  /// Return and commits via this callback; the model reuses its move/copy path
  /// (rename is a move within the current directory).
  var onRename: (String, String) -> Void
  /// Move or copy the named entries into a target directory row. Fired by an
  /// internal drag dropped onto a directory row, and by the directory row's
  /// "Move Here" / "Copy Here" context-menu items. `targetPath` is the absolute
  /// directory path; the model routes through `FileBrowserActions.moveCopy` so
  /// the canonical-path / directory-into-itself guards still apply.
  var onMoveCopyIntoDirectory: (Set<String>, String, FileCommandBuilder.MoveCopyMode) -> Void

  init(
    rows: [FileRow], path: String, selection: Binding<Set<String>>,
    sortOrder: Binding<[KeyPathComparator<FileRow>]>, isLoading: Bool = false,
    errorMessage: String? = nil, onNavigate: @escaping (FileRow) -> Void = { _ in },
    onOpen: @escaping (FileRow) -> Void = { _ in }, onNavigateUp: @escaping () -> Void = {},
    onRetry: @escaping () -> Void = {}, onDelete: @escaping (Set<String>) -> Void = { _ in },
    onMove: @escaping (Set<String>, String) -> Void = { _, _ in },
    onCopy: @escaping (Set<String>) -> Void = { _ in },
    onDrop: @escaping ([URL]) -> Void = { _ in },
    onRename: @escaping (String, String) -> Void = { _, _ in },
    onMoveCopyIntoDirectory: @escaping (Set<String>, String, FileCommandBuilder.MoveCopyMode) -> Void
      = { _, _, _ in }
  ) {
    self.rows = rows
    self.path = path
    self._selection = selection
    self._sortOrder = sortOrder
    self.isLoading = isLoading
    self.errorMessage = errorMessage
    self.onNavigate = onNavigate
    self.onOpen = onOpen
    self.onNavigateUp = onNavigateUp
    self.onRetry = onRetry
    self.onDelete = onDelete
    self.onMove = onMove
    self.onCopy = onCopy
    self.onDrop = onDrop
    self.onRename = onRename
    self.onMoveCopyIntoDirectory = onMoveCopyIntoDirectory
  }

  var body: some View {
    VStack(spacing: 0) {
      BreadcrumbBar(path: path, canNavigateUp: canNavigateUp, onNavigateUp: onNavigateUp)
      Divider()
      content
    }.frame(minWidth: 480)
      // Blur cancels rename mode: when the focused field loses focus for any
      // reason other than the field's own Return/Esc (whose handlers clear
      // focus first), exit rename mode without issuing a rename.
      .onChange(of: renameFieldFocused) { _, newValue in
        if let renaming = renamingName, newValue != renaming {
          cancelRenameLocal()
        }
      }
  }

  // MARK: - Content states

  @ViewBuilder private var content: some View {
    if let errorMessage {
      ErrorStateView(message: errorMessage, onRetry: onRetry)
    } else if isLoading && rows.isEmpty {
      ProgressView("Loading…").controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if rows.isEmpty {
      EmptyStateView()
    } else {
      fileTable
    }
  }

  /// Whether the "up" button should be enabled: not already at the root and a
  /// path has been established (an unseeded remote path can't go up).
  private var canNavigateUp: Bool { !path.isEmpty && path != "/" }

  /// The rows sorted according to the current `sortOrder`. An empty sort order
  /// means "keep the listing's natural order".
  private var sortedRows: [FileRow] {
    guard !sortOrder.isEmpty else { return rows }
    return rows.sorted(using: sortOrder)
  }

  // MARK: - macOS Table

  #if os(macOS)
    private var fileTable: some View {
      Table(of: FileRow.self, selection: $selection, sortOrder: $sortOrder) {
        TableColumn("Name", sortUsing: KeyPathComparator(\FileRow.name)) { row in
          if renamingName == row.name {
            TextField("", text: $renameText)
              .textFieldStyle(.roundedBorder)
              .font(.body)
              .focused($renameFieldFocused, equals: row.name)
              .onSubmit { commitRename() }
              .onExitCommand { cancelRename() }
          } else {
            iconAndName(row).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        TableColumn("Type", sortUsing: KeyPathComparator(\FileRow.sortableType)) { row in
          Text(row.sortableType)
        }
        TableColumn("Size", sortUsing: KeyPathComparator(\FileRow.sortableSize)) { row in
          Text(Self.formattedSize(row.size)).monospacedDigit()
        }
        TableColumn("Modified", sortUsing: KeyPathComparator(\FileRow.sortableModified)) { row in
          Text(Self.formattedDate(row.modified))
        }
      } rows: {
        ForEach(sortedRows) { row in
          let tableRow = TableRow(row)
            .draggable(dragPayload(for: row))
          if row.isDirectory {
            // A directory row is a drop target for an INTERNAL drag: dropping
            // one or more (selected) rows here moves/copies them into it. This
            // uses the dedicated internal payload type so it never captures the
            // Finder (URL) drops handled by the table-level dropDestination.
            tableRow.dropDestination(for: RowDragPayload.self) { payloads in
              handleRowDrop(payloads, onto: row)
            }
          } else {
            tableRow
          }
        }
      }
      // Right-click → context-menu actions; double-click (or Return) → primary
      // action. Both are driven by the row selection, so a right-click on an
      // unselected row selects it first (matching the toolbar semantics that
      // used to live above the table).
      .contextMenu(forSelectionType: String.self) { names in
        rowContextMenu(names: names)
      } primaryAction: { names in
        for name in names {
          guard let row = rows.first(where: { $0.name == name }) else { continue }
          activate(row)
        }
      }
      // Accept files dragged in from Finder and copy them into the current dir.
      .dropDestination(for: URL.self) { urls, _ in
        onDrop(urls)
        return true
      }
      // Return on a single selected row enters rename mode. When already in
      // rename mode, the TextField's own `.onSubmit` (Return) commits — so this
      // key handler is only active in the non-editing state.
      .onKeyPress(.return, phases: .down) { _ in
        beginRenameIfSingleSelection()
        return .handled
      }
    }

    /// The rename field's OnSubmit was already handled by the contained
    /// `TextField`, so this covers the path where Return reaches the table.
    private func beginRenameIfSingleSelection() {
      guard renamingName == nil, renameFieldFocused == nil, selection.count == 1,
        let name = selection.first
      else { return }
      guard Date() >= suppressRenameUntil else { return }
      guard rows.contains(where: { $0.name == name }) else { return }
      renamingName = name
      renameText = name
      renameFieldFocused = name
    }

    /// The drag payload for a row. Dragging a selected row carries the whole
    /// selection (so a drop onto a directory moves all of them); dragging an
    /// unselected row carries just that one. The exported URL is always the
    /// single row's own absolute file URL, so drag-OUT to Finder is unchanged.
    private func dragPayload(for row: FileRow) -> RowDragPayload {
      let names = selection.contains(row.name) ? selection.sorted() : [row.name]
      return RowDragPayload(names: names, url: URL(fileURLWithPath: absolutePath(for: row)))
    }

    /// Handles an internal drop of one or more rows onto a directory row: moves
    /// them into that directory via the shared move/copy path. The model routes
    /// through `FileBrowserActions.moveCopy`, so the canonical-path guard (a
    /// directory moved into itself) and the source==destination guard still
    /// apply. The target directory is excluded up front so a selection that
    /// already contains it (or the target dragged onto itself) never attempts a
    /// self-move. Finder (URL) drops never reach here — they use the table-level
    /// `.dropDestination(for: URL.self)` and route to `copyIn`.
    private func handleRowDrop(_ payloads: [RowDragPayload], onto target: FileRow) {
      guard target.isDirectory else { return }
      let names = Set(payloads.flatMap(\.names)).subtracting([target.name])
      guard !names.isEmpty else { return }
      onMoveCopyIntoDirectory(names, absolutePath(for: target), .move)
    }

    /// Commits the rename: fires `onRename(from:to:)` when the text changed,
    /// then always exits rename mode (the model re-lists on success).
    private func commitRename() {
      guard let name = renamingName else { return }
      let to = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !to.isEmpty && to != name { onRename(name, to) }
      suppressRenameUntil = Date().addingTimeInterval(0.25)
      cancelRenameLocal()
    }

    /// Cancels rename mode without issuing any rename.
    private func cancelRename() {
      suppressRenameUntil = Date().addingTimeInterval(0.25)
      cancelRenameLocal()
    }

    private func cancelRenameLocal() {
      renamingName = nil
      renameText = ""
      renameFieldFocused = nil
    }

    private func iconAndName(_ row: FileRow) -> some View {
      HStack(spacing: 8) {
        Image(systemName: iconName(for: row)).foregroundStyle(iconColor(for: row)).frame(width: 16)
        Text(row.name).lineLimit(1).truncationMode(.middle)
      }
    }

  #else

    // MARK: - iOS list

    private var fileTable: some View {
      List(selection: $selection) {
        ForEach(sortedRows) { row in
          HStack(spacing: 12) {
            Image(systemName: iconName(for: row)).foregroundStyle(iconColor(for: row)).frame(
              width: 22)
            Text(row.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Self.formattedSize(row.size)).foregroundStyle(.secondary).font(.callout)
            Text(Self.formattedDate(row.modified)).foregroundStyle(.secondary).font(.callout)
          }.contentShape(Rectangle()).onTapGesture(count: 2) { activate(row) }.tag(row.name)
            .contextMenu {
              rowContextMenu(names: [row.name])
            }
        }
      }
    }

  #endif

  // MARK: - Row activation & icons

  /// Double-click behavior: a directory navigates into it, anything else opens.
  private func activate(_ row: FileRow) {
    if row.isDirectory { onNavigate(row) } else { onOpen(row) }
  }

  /// The file-operation context menu, replacing the old selection toolbar.
  /// Shared by the macOS table (`.contextMenu(forSelectionType:)`) and the iOS
  /// list (per-row `.contextMenu`).
  @ViewBuilder private func rowContextMenu(names: Set<String>) -> some View {
    if names.count == 1, let name = names.first,
      let row = rows.first(where: { $0.name == name })
    {
      Button(row.isDirectory ? "Open Folder" : "Open in Default App", systemImage: "arrow.up.forward.app") {
        activate(row)
      }
      // For a directory row, offer to move/copy the OTHER selected entries into
      // it — the menu-side counterpart of dropping rows onto the directory. The
      // target directory itself is excluded (a directory cannot be moved into
      // itself), so these appear only when other rows are selected.
      if row.isDirectory {
        let others = names.subtracting([row.name])
        if !others.isEmpty {
          Divider()
          Button("Move Here", systemImage: "folder") {
            onMoveCopyIntoDirectory(others, absolutePath(for: row), .move)
          }
          Button("Copy Here", systemImage: "doc.on.doc") {
            onMoveCopyIntoDirectory(others, absolutePath(for: row), .copy)
          }
        }
      }
    }
    Divider()
    Button("Move…", systemImage: "folder") { onMove(names, "") }
    Button("Copy…", systemImage: "doc.on.doc") { onCopy(names) }
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) { onDelete(names) }
  }

  /// The absolute path for a row, joined onto the current directory.
  private func absolutePath(for row: FileRow) -> String {
    if path.isEmpty { return row.name }
    if path == "/" { return "/" + row.name }
    return path + "/" + row.name
  }

  /// The SF Symbol for a row: folders, symlinks, then plain files.
  private func iconName(for row: FileRow) -> String {
    if row.symlinkTarget != nil {
      // Symlinks (aliases) get Finder's curved-arrow symbol.
      return "arrow.triangle.turn.up.right.circle"
    }
    if row.isDirectory { return "folder.fill" }
    return "doc"
  }

  /// Tint per row kind: folders blue, symlinks purple, files secondary.
  private func iconColor(for row: FileRow) -> Color {
    if row.symlinkTarget != nil { return .purple }
    if row.isDirectory { return .blue }
    return .secondary
  }

  // MARK: - Formatting helpers

  /// Human-readable byte count (`ByteCountFormatter`), or an em dash when the
  /// listing didn't report a size.
  private static func formattedSize(_ size: Int64?) -> String {
    guard let size else { return "—" }
    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
  }

  /// Locale-stable date, or an em dash when no date was parsed.
  private static func formattedDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .numeric, time: .shortened)
  }
}

/// Comparable derived sort keys for the `Table` columns. `FileRow` stores size
/// and modified as optional, which are not `Comparable`; these computed values
/// give the sortable columns a stable, comparable key for each entry.
extension FileRow {
  /// A short, localizable kind label: folders, symlinks, then the file
  /// extension (or "File" when the name has no extension).
  fileprivate var sortableType: String {
    if symlinkTarget != nil { return "Symlink" }
    if isDirectory { return "Folder" }
    let ext = (name as NSString).pathExtension
    return ext.isEmpty ? "File" : ext.uppercased() + " File"
  }

  /// Size in bytes, `0` for entries without a reported size.
  fileprivate var sortableSize: Int64 { size ?? 0 }

  /// Modification date, the distant past when unknown.
  fileprivate var sortableModified: Date { modified ?? .distantPast }
}

/// The top bar: an "up" button plus the path rendered as a breadcrumb. The home
/// directory is shortened to `~` (the same rule `ContentView.refreshLocalDirectory`
/// applies to the window subtitle).
private struct BreadcrumbBar: View {
  let path: String
  let canNavigateUp: Bool
  let onNavigateUp: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onNavigateUp) { Image(systemName: "chevron.up").frame(width: 16) }.buttonStyle(
        .borderless
      ).disabled(!canNavigateUp).help("Up")

      let segments = pathSegments
      if segments.isEmpty {
        Text("Path not set").foregroundStyle(.secondary)
      } else {
        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
          if index > 0 {
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
          }
          Text(segment).lineLimit(1).truncationMode(.middle)
        }
      }

      Spacer(minLength: 0)
    }.padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
  }

  /// The breadcrumb components, with the home-directory prefix collapsed to `~`.
  private var pathSegments: [String] {
    let home = NSHomeDirectory()
    var display: String
    if path == home {
      display = "~"
    } else if path.hasPrefix(home + "/") {
      display = "~" + path.dropFirst(home.count)
    } else {
      display = path
    }

    if display == "/" || display == "~" { return [display] }
    let parts = display.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if display.hasPrefix("/") { return ["/"] + parts }
    return parts
  }
}

/// Shown when the current directory has no entries.
private struct EmptyStateView: View {
  var body: some View {
    ContentUnavailableView(
      "Empty Folder", systemImage: "folder", description: Text("This folder contains no files."))
  }
}

/// Shown when the listing for the current directory failed.
private struct ErrorStateView: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Couldn't Load Folder", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Retry", action: onRetry)
    }
  }
}
