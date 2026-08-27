import Foundation
import SwiftUI
import TerminalIntegrations

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

  /// Double-clicking a directory emits `navigate(into:)`.
  var onNavigate: (FileRow) -> Void
  /// Double-clicking a file emits `open(file:)`.
  var onOpen: (FileRow) -> Void
  /// The breadcrumb "up" button.
  var onNavigateUp: () -> Void
  /// The error state's Retry button.
  var onRetry: () -> Void
  /// Delete the selected entries (toolbar op).
  var onDelete: (Set<String>) -> Void
  /// Move the selected entries to a destination (toolbar op).
  var onMove: (Set<String>, String) -> Void

  init(
    rows: [FileRow], path: String, selection: Binding<Set<String>>,
    sortOrder: Binding<[KeyPathComparator<FileRow>]>, isLoading: Bool = false,
    errorMessage: String? = nil, onNavigate: @escaping (FileRow) -> Void = { _ in },
    onOpen: @escaping (FileRow) -> Void = { _ in }, onNavigateUp: @escaping () -> Void = {},
    onRetry: @escaping () -> Void = {}, onDelete: @escaping (Set<String>) -> Void = { _ in },
    onMove: @escaping (Set<String>, String) -> Void = { _, _ in }
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
      Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
        TableColumn("Name", sortUsing: KeyPathComparator(\FileRow.name)) { row in
          interactiveCell(for: row) { iconAndName(row) }.frame(
            maxWidth: .infinity, alignment: .leading)
        }
        TableColumn("Type", sortUsing: KeyPathComparator(\FileRow.sortableType)) { row in
          interactiveCell(for: row) { Text(row.sortableType) }
        }
        TableColumn("Size", sortUsing: KeyPathComparator(\FileRow.sortableSize)) { row in
          interactiveCell(for: row) { Text(Self.formattedSize(row.size)).monospacedDigit() }
        }
        TableColumn("Modified", sortUsing: KeyPathComparator(\FileRow.sortableModified)) { row in
          interactiveCell(for: row) { Text(Self.formattedDate(row.modified)) }
        }
      }
    }

    /// A cell that surfaces the whole cell as the double-click target, so a
    /// double-click anywhere on the row activates it (a count-2 tap gesture does
    /// not consume the single-click that drives `Table` selection).
    @ViewBuilder private func interactiveCell<Content: View>(
      for row: FileRow, @ViewBuilder content: () -> Content
    ) -> some View { content().contentShape(Rectangle()).onTapGesture(count: 2) { activate(row) } }

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
        }
      }
    }

  #endif

  // MARK: - Row activation & icons

  /// Double-click behavior: a directory navigates into it, anything else opens.
  private func activate(_ row: FileRow) {
    if row.isDirectory { onNavigate(row) } else { onOpen(row) }
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
