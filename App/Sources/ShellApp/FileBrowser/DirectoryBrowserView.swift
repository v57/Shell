import ComponentKit
import Foundation
import SwiftUI
import ShellKit
import ShellIntegrations
import UniformTypeIdentifiers

#if os(macOS)
/// What the Files panel receives from a drop: Shell's own rows keep their host (see `FileDrop`).
typealias DroppedFiles = [ShellFile]
#else
typealias DroppedFiles = [URL]
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
/// - **Error** — `errorMessage` is non-nil (an `EmptyState` with Retry).
/// - **Loading** — `isLoading` is true and there are no rows yet (a working `EmptyState`).
/// - **Empty** — no rows and no error (an `EmptyState`).
/// - **Success** — the `KitGrid` (macOS) or `KitList` (iOS) of rows.
///
/// On macOS the listing is the kit's `KitGrid` as a list of files
/// (`.interaction(.rows)`) with sortable Name / Type / Size / Modified columns:
/// a double click opens, Return renames in place, a row (or the selection)
/// drags out as `ShellFile`s and a directory row takes Shell's own rows. On
/// iOS it is a `KitList` of the same row model.
struct DirectoryBrowserView: View {
  /// The parsed entries of the current directory, in the order the listing
  /// returned them. Sorting is applied by the view from `sortOrder`.
  let rows: [FileRow]
  /// The absolute directory being shown. Used for the breadcrumb path bar.
  let path: String
  /// Selected entry names (the `.id` of a `FileRow` is its name).
  @Binding var selection: Set<String>
  /// The active column sort order, driven by the grid's sortable columns.
  @Binding var sortOrder: [KeyPathComparator<FileRow>]
  /// Whether a refresh is in flight. Shown as a working `EmptyState` only while the
  /// initial listing is still pending (rows empty), so a refresh that already
  /// has a grid on screen doesn't flash it away.
  let isLoading: Bool
  /// A non-nil value replaces the grid with an error state + Retry.
  let errorMessage: String?
  /// The SSH config of the directory being browsed, when its runner is remote
  /// (`.ssh`). Drives the drag payload's `remote` so a dragged row can be
  /// materialized (downloaded) before drag-out. Nil for local listings.
  let sshConfig: SSHConfig?

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
  /// Copy files dropped onto the browser (from Finder, or another Files listing) into the current directory.
  var onDrop: (DroppedFiles) -> Void
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
    onDrop: @escaping (DroppedFiles) -> Void = { _ in },
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
  }

  // MARK: - Content states

  @ViewBuilder private var content: some View {
    if let errorMessage {
      EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn't Load Folder", message: errorMessage) {
        Button("Retry", action: onRetry).buttonStyle(.kit)
      }
    } else if isLoading && rows.isEmpty {
      EmptyState(systemImage: "folder", title: "Loading…", status: .working)
    } else if rows.isEmpty {
      EmptyState(systemImage: "folder", title: "Empty Folder", message: "This folder contains no files.")
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

  // MARK: - macOS grid

  #if os(macOS)
    private var fileTable: some View {
      KitGrid(
        sortedRows,
        columns: [
          KitGridColumn<FileRow>(
            "Name", width: 280, value: { $0.name },
            edit: { row, name in
              let to = name.trimmingCharacters(in: .whitespacesAndNewlines)
              if !to.isEmpty && to != row.name { onRename(row.name, to) }
            }
          ) { row in
            iconAndName(row).accessibilityIdentifier("file-row-\(row.name)")
          },
          KitGridColumn<FileRow>("Type", width: 120) { $0.sortableType },
          KitGridColumn<FileRow>("Size", width: 90, alignment: .trailing) { row in
            Text(Self.formattedSize(row.size)).monospacedDigit()
          },
          KitGridColumn<FileRow>("Modified", width: 160) { Self.formattedDate($0.modified) },
        ],
        selection: $selection, sort: gridSort,
        // A double click or ⌘↓ opens the selection: a folder navigates into it, a file opens.
        primaryAction: { names in
          for name in names {
            guard let row = rows.first(where: { $0.name == name }) else { continue }
            activate(row)
          }
        }
      )
      // A list of files: a click selects the row, Return renames it (the Name column's edit).
      .interaction(.rows)
      // A row drags out as a `ShellFile` (to Finder, a terminal or a session); a selected row drags the selection.
      .rowDrag { name in rows.first { $0.name == name }.map(dragPayload) }
      // A directory row takes an INTERNAL drag (Shell's own rows) and moves them into it. Finder (URL) drops don't
      // reach it: the rows pass them on to the drop around the grid.
      .rowDropDestination(for: ShellFile.self, isEnabled: \.isDirectory) { files, row in
        handleRowDrop(files, onto: row)
      }
      // Right-click → the file operations, on the selection when the clicked row is in it.
      .rowContextMenu { names in rowContextMenu(names: names) }
      // Files dropped on the browser (from Finder, or a dragged row) are copied into the current dir. `FileDrop`
      // reads the drag pasteboard: a Finder file's original path, or a row's own description (with its host, when
      // it comes from a remote listing).
      .kitDropDestination(of: FileDrop.contentTypes) { _ in FileDrop.perform(onDrop) }
    }

    /// The grid's sort, read from and written to `sortOrder` (the model keeps the comparators).
    private var gridSort: Binding<KitGridSort?> {
      Binding(
        get: {
          guard let first = sortOrder.first,
            let column = Self.sortColumns.first(where: { $0.keyPath == first.keyPath })
          else { return nil }
          return KitGridSort(column.id, ascending: first.order == .forward)
        },
        set: { sort in
          guard let sort, let column = Self.sortColumns.first(where: { $0.id == sort.column }) else {
            sortOrder = []
            return
          }
          sortOrder = [column.comparator(sort.ascending ? .forward : .reverse)]
        })
    }

    /// Each column's id, the key path it sorts by, and the comparator for an order.
    private static var sortColumns:
      [(id: String, keyPath: PartialKeyPath<FileRow>, comparator: (SortOrder) -> KeyPathComparator<FileRow>)]
    {
      [
        ("Name", \FileRow.name, { KeyPathComparator(\FileRow.name, order: $0) }),
        ("Type", \FileRow.sortableType, { KeyPathComparator(\FileRow.sortableType, order: $0) }),
        ("Size", \FileRow.sortableSize, { KeyPathComparator(\FileRow.sortableSize, order: $0) }),
        ("Modified", \FileRow.sortableModified, { KeyPathComparator(\FileRow.sortableModified, order: $0) }),
      ]
    }

    /// The drag payload for a row. A local row carries its own file URL; a row
    /// in an SSH listing also carries the connection config so `download()` can
    /// fetch the file before it's delivered to Finder or a session cell. When a
    /// selection is dragged, the grid emits one `ShellFile` per selected row.
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
    /// self-move. The grid delivers one `ShellFile` per dragged (selected) row,
    /// so the names come from each payload's file URL, not a bundle. Finder (URL)
    /// drops never reach here — they use the drop around the grid.
    private func handleRowDrop(_ payloads: [ShellFile], onto target: FileRow) {
      guard target.isDirectory else { return }
      // Only rows of THIS listing move by name: a row of another folder or host would move its namesake here.
      let here = payloads.filter {
        $0.remote?.id == sshConfig?.id && $0.url.deletingLastPathComponent().path == URL(fileURLWithPath: path).path
      }
      let names = Set(here.map { $0.url.lastPathComponent }).subtracting([target.name])
      guard !names.isEmpty else { return }
      onMoveCopyIntoDirectory(names, absolutePath(for: target), .move)
    }

    private func iconAndName(_ row: FileRow) -> some View {
      HStack(spacing: 8) {
        Image(systemName: iconName(for: row))
          .foregroundStyle(iconHue(for: row).map { AnyShapeStyle($0.fill) } ?? AnyShapeStyle(.kitSecondary))
          .frame(width: 16)
        Text(row.name).lineLimit(1).truncationMode(.middle)
      }
    }

  #else

    // MARK: - iOS list

    private var fileTable: some View {
      KitList(
        selection: Binding<String?>(
          get: { selection.first }, set: { selection = $0.map { [$0] } ?? [] })
      ) {
        ForEach(sortedRows) { row in
          SidebarRow(
            value: row.name, row.name, subtitle: Self.formattedDate(row.modified), systemImage: iconName(for: row),
            hue: iconHue(for: row)
          ) {
            Text(Self.formattedSize(row.size))
          }
          .kitContextMenu { rowContextMenu(names: [row.name]) }
        }
      }
      .primaryAction { (name: String) in
        if let row = rows.first(where: { $0.name == name }) { activate(row) }
      }
    }

  #endif

  // MARK: - Row activation & icons

  /// Double-click behavior: a directory navigates into it, anything else opens.
  private func activate(_ row: FileRow) {
    if row.isDirectory { onNavigate(row) } else { onOpen(row) }
  }

  /// The file-operation context menu, replacing the old selection toolbar.
  /// Shared by the macOS grid (`rowContextMenu`) and the iOS list (per-row
  /// `kitContextMenu`).
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

  /// Tint per row kind: folders blue, symlinks purple, files the quiet colour.
  private func iconHue(for row: FileRow) -> Hue? {
    if row.symlinkTarget != nil { return .purple }
    if row.isDirectory { return .blue }
    return nil
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

/// Comparable derived sort keys for the grid's columns. `FileRow` stores size
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

/// The top bar: an "up" button plus the path as the kit's path bar. The home directory is shortened to `~` (the same
/// rule `ContentView.refreshLocalDirectory` applies to the window subtitle).
private struct BreadcrumbBar: View {
  let path: String
  let canNavigateUp: Bool
  let onNavigateUp: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button("Up", systemImage: "chevron.up", action: onNavigateUp)
        .buttonStyle(.kitIcon)
        .labelStyle(.iconOnly)
        .disabled(!canNavigateUp)
        .kitHelp("Up", shortcut: "⇧⌘U")

      let segments = pathSegments
      if segments.isEmpty {
        Text("Path not set").kitFont(.callout).foregroundStyle(.kitSecondary)
      } else {
        KitPathBar(
          components: segments.enumerated().map { index, segment in
            KitPathItem(segment, systemImage: index == 0 ? (segment == "~" ? "house" : "internaldrive") : nil)
          })
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
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
