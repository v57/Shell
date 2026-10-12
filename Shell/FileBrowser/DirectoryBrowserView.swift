import Foundation
import SwiftUI
import ShellKit
import ShellIntegrations
import UniformTypeIdentifiers

#if os(macOS)
/// A row dragged out of the browser. Internally it carries the file URL (+
/// optional remote config id) as a custom-UTType Codable payload — this is what
/// makes it importable by the app's own `.dropDestination(for: ShellFile.self)`
/// targets (a sidebar session cell, a directory row) via `visibility(.ownProcess)`.
/// It also exports as a real file (FileRepresentation) so a local row can be
/// dropped into Finder. When a selection is dragged, `Table` emits one
/// `ShellFile` per selected row, so the payloads arrive as an array — no need to
/// bundle the whole selection's names inside one item.
/// (Internal — referenced by the sidebar session-cell drop, hence not `private`.)
struct ShellFile: Transferable, Codable {
  let url: URL
  let isDirectory: Bool
  /// Non-nil for a REMOTE (SSH) row: the host to fetch the file from so it can
  /// be materialized (downloaded) before drag-out. Nil for local rows.
  var remote: SSHConfig?
  init(url: URL, isDirectory: Bool, remote: SSHConfig? = nil) {
    self.url = url
    self.isDirectory = isDirectory
    self.remote = remote
  }
  /// Returns a REAL local file URL for the transfer: a local row's own `url`,
  /// or a freshly SFTP-downloaded temp copy of a remote row's file (so Finder /
  /// a session-cell drop get actual bytes, not a remote path that doesn't exist
  /// on this Mac).
  func download() async throws -> URL {
    guard let config = remote else { return url }
    let data = try await SSHSession.downloadFile(config: config, remotePath: url.path)
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("shell-drag", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(url.lastPathComponent)
    try data.write(to: dest)
    return dest
  }
  nonisolated static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .shellFile).visibility(.ownProcess)
    FileRepresentation(contentType: .data) { file in
      // allowAccessingOriginalFile:true gives the destination the ORIGINAL URL
      // instead of a sandbox-hidden temp copy. A staged copy (false) forces
      // SwiftUI to hand off a `public.file-url` sandbox extension on drop, which
      // fails with -20 ("does client lack read access") for an in-app file → the
      // drop silently does nothing. Local files are already readable by this
      // (non-sandboxed) process, so pass the original through.
      return try await SentTransferredFile(file.download(), allowAccessingOriginalFile: true)
    } importing: { file in
      ShellFile(url: file.file, isDirectory: file.file.hasDirectoryPath)
    }.suggestedFileName { $0.url.lastPathComponent }
  }
}
extension UTType {
  nonisolated static var shellFile: UTType { UTType(exportedAs: "dev.v57.url") }
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
  /// The SSH config of the directory being browsed, when its runner is remote
  /// (`.ssh`). Drives the drag payload's `remote` so a dragged row can be
  /// materialized (downloaded) before drag-out. Nil for local listings.
  let sshConfig: SSHConfig?

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
    errorMessage: String? = nil, sshConfig: SSHConfig? = nil, onNavigate: @escaping (FileRow) -> Void = { _ in },
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
    self.sshConfig = sshConfig
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
    #if os(macOS)
      // Blur cancels rename mode: when the focused field loses focus for any
      // reason other than the field's own Return/Esc (whose handlers clear
      // focus first), exit rename mode without issuing a rename.
      .onChange(of: renameFieldFocused) {
        if let renaming = renamingName, renameFieldFocused != renaming {
          cancelRenameLocal()
        }
      }
    #endif
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
            iconAndName(row)
              .accessibilityIdentifier("file-row-\(row.name)")
              .frame(maxWidth: .infinity, alignment: .leading)
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
            tableRow.dropDestination(for: ShellFile.self) { payloads in
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
      // Accept files dropped onto the browser (from Finder, or a dragged row)
      // and copy them into the current dir. Finder drops decode as a `ShellFile`
      // via the FileRepresentation importing closure; internal row drags decode
      // via the custom-UTType Codable payload. Both carry `.url`.
      .dropDestination(for: ShellFile.self) { files, _ in
        onDrop(files.map(\.url))
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

    /// The drag payload for a row. A local row carries its own file URL; a row
    /// in an SSH listing also carries the connection config so `download()` can
    /// fetch the file before it's delivered to Finder or a session cell. When a
    /// selection is dragged, `Table` emits one `ShellFile` per selected row.
    private func dragPayload(for row: FileRow) -> ShellFile {
      return ShellFile(
        url: URL(fileURLWithPath: absolutePath(for: row)),
        isDirectory: row.isDirectory,
        remote: sshConfig)
    }

    /// Handles an internal drop of one or more rows onto a directory row: moves
    /// them into that directory via the shared move/copy path. The model routes
    /// through `FileBrowserActions.moveCopy`, so the canonical-path guard (a
    /// directory moved into itself) and the source==destination guard still
    /// apply. The target directory is excluded up front so a selection that
    /// already contains it (or the target dragged onto itself) never attempts a
    /// self-move. `Table` delivers one `ShellFile` per dragged (selected) row,
    /// so the names come from each payload's file URL, not a bundle. Finder (URL)
    /// drops never reach here — they use the table-level dropDestination.
    private func handleRowDrop(_ payloads: [ShellFile], onto target: FileRow) {
      guard target.isDirectory else { return }
      let names = Set(payloads.map { $0.url.lastPathComponent }).subtracting([target.name])
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
