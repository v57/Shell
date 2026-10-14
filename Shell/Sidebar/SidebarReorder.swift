import Foundation
#if os(macOS)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's drag-to-reorder machinery for the `LazyVStack` container.
///
/// A `List` reorders rows with `.onMove` — one call per list, in the section
/// views — but a `LazyVStack` has no reordering of its own, so there the ROWS do
/// it: a reorderable row is a drag source (publishing which list it is in and
/// where) and a drop target, and the target MOVES the dragged row to its own
/// index as the drag passes over it, which is the live reordering a `List` shows.
///
/// Both containers end up calling the SAME model `move*` function for the list
/// (`SidebarReorderGroup.move`), so a row kind reorders identically either way.

/// One drag-reorderable list of the sidebar. WHICH list a row belongs to is what
/// stops a drop between lists: a local session dragged over an SSH host's row is
/// refused, exactly as `.onMove` refuses it in the `List` sidebar.
enum SidebarReorderList: Hashable {
  /// The Local section's shell rows (`AppModel.moveLocalSession`).
  case localSessions
  /// The Local section's saved web pages (`AppModel.moveLocalWebSession`).
  case localWebSessions
  /// The Local section's untunneled database connections
  /// (`AppModel.moveLocalDatabaseConnection`).
  case localDatabaseConnections
  /// The saved SSH hosts (`AppModel.moveConnection`).
  case sshConnections
  /// The running sessions under one SSH host (`AppModel.moveSSHSession(for:)`).
  case sshSessions(UUID)
}

/// One reorderable list of a section: its identity plus its move, in ONE place,
/// so the section's `ForEach` (the `List`'s `.onMove`) and its rows (the
/// `LazyVStack`'s drags) reorder through the same call.
struct SidebarReorderGroup {
  /// Which list this is — the drop check: drops only land inside the same list.
  let list: SidebarReorderList
  /// The model-side move, on the list's OWN slice indices: the `IndexSet`/`Int`
  /// contract `.onMove` reports and the model's `move*` functions take.
  let move: (IndexSet, Int) -> Void

  init(_ list: SidebarReorderList, move: @escaping (IndexSet, Int) -> Void) {
    self.list = list
    self.move = move
  }

  /// The row descriptor for the row at `index` in this list.
  func row(at index: Int) -> SidebarReorder {
    SidebarReorder(list: list, index: index, move: move)
  }
}

/// One drag-reorderable row: the list it belongs to, its index in that list, and
/// the move to apply when it is dragged over a sibling.
struct SidebarReorder {
  let list: SidebarReorderList
  let index: Int
  let move: (IndexSet, Int) -> Void
}

/// The in-flight row drag of the `LazyVStack` sidebar, shared by every draggable
/// row so a drop target can find out WHICH row is being dragged (and in which
/// list). Owned by `SidebarView2` and published through the environment; absent
/// in the `List` sidebar, where `List` owns drag-reordering and a row must not
/// claim the drag gesture for itself.
@Observable
final class SidebarDragState {
  /// The type a sidebar row drag declares and accepts (declared in Shell-Info.plist). The provider's payload is
  /// never read — the drag is described by this object — but a drag and its targets have to agree on a type to be
  /// matched at all. Its own type, not plain text, so a row never takes a file drop meant for the session
  /// (`fileDrop`) and a file never reorders a row.
  static let contentType = UTType(exportedAs: "dev.v57.shell.sidebar-row")

  /// The list the dragged row was in, and its index in that list (kept up to
  /// date as the row is moved under the cursor).
  private(set) var list: SidebarReorderList?
  private(set) var index: Int?

  /// Starts a drag of the row at `index`.
  func begin(_ list: SidebarReorderList, at index: Int) {
    self.list = list
    self.index = index
  }

  /// Records that the dragged row now sits at `index` (after a live move).
  func update(index: Int) {
    self.index = index
  }

  /// Whether `reorder` is the row being dragged. That row is drawn only as the
  /// drag image, so in the sidebar it stays as an empty gap where it would drop.
  func isDragging(_ reorder: SidebarReorder) -> Bool {
    list == reorder.list && index == reorder.index
  }

  /// Ends the drag.
  func end() {
    list = nil
    index = nil
  }
}

private struct SidebarDragStateKey: EnvironmentKey {
  static let defaultValue: SidebarDragState? = nil
}

extension EnvironmentValues {
  /// The in-flight row drag — set by `SidebarView2` (see `.sidebarDragState`).
  var sidebarDragState: SidebarDragState? {
    get { self[SidebarDragStateKey.self] }
    set { self[SidebarDragStateKey.self] = newValue }
  }
}

extension View {
  /// Publishes the drag state to every row below. Applied once, by the
  /// `LazyVStack` container.
  func sidebarDragState(_ state: SidebarDragState) -> some View {
    environment(\.sidebarDragState, state)
  }
}

/// What a row does with OTHER drops than its siblings (files, on a session row), published by the row
/// (`sidebarFileDrop`, FileDrag.swift) to its drag-reorder target. SwiftUI hands a drop to the innermost target
/// under the pointer only, so in the `LazyVStack` sidebar the row's reorder target has to take those too.
struct SidebarRowDropHandler {
  /// The types the row accepts besides its siblings.
  let contentTypes: [UTType]
  /// Reads the drop and handles it; false when there was nothing to take.
  let perform: @MainActor () -> Bool
}

private struct SidebarRowDropHandlerKey: EnvironmentKey {
  static let defaultValue: SidebarRowDropHandler? = nil
}

extension EnvironmentValues {
  /// The row's handler for drops other than a sibling's (see `SidebarRowDropHandler`).
  var sidebarRowDropHandler: SidebarRowDropHandler? {
    get { self[SidebarRowDropHandlerKey.self] }
    set { self[SidebarRowDropHandlerKey.self] = newValue }
  }
}

/// The drop half of a row's drag-reorder: while the drag passes over a sibling
/// row, that sibling moves the dragged row to its own index — the live
/// reordering `.onMove` gives the `List` sidebar. Any other drop goes to the
/// row's `SidebarRowDropHandler`, when it has one.
struct SidebarRowDropDelegate: DropDelegate {
  let reorder: SidebarReorder
  let drag: SidebarDragState
  let other: SidebarRowDropHandler?

  /// Whether the drop is a sidebar row (a reorder) rather than something else. Read from the drag pasteboard on
  /// macOS: `DropInfo` describes a drag that SwiftUI started in this process (a Files-panel row) with no types.
  private func isRow(_ info: DropInfo) -> Bool {
    #if os(macOS)
    NSPasteboard(name: .drag).types?.contains(NSPasteboard.PasteboardType(SidebarDragState.contentType.identifier))
      ?? false
    #else
    info.hasItemsConforming(to: [SidebarDragState.contentType])
    #endif
  }

  /// Only a row of the SAME list (and never the dragged row itself) is a target,
  /// so a drag across lists is refused rather than mis-moving a row. Anything
  /// else matched one of the handler's types (`onDrop` checked them).
  func validateDrop(info: DropInfo) -> Bool {
    guard isRow(info) else { return other != nil }
    return drag.list == reorder.list && drag.index != reorder.index
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: isRow(info) ? .move : .copy)
  }

  func dropEntered(info: DropInfo) {
    guard isRow(info), drag.list == reorder.list, let from = drag.index, from != reorder.index else { return }
    // `.onMove`'s contract, reproduced: a row dragged DOWN lands after the row
    // it was dropped on, one dragged UP lands before it. Either way it ends up
    // AT the drop target's index, which is what the drag state must remember so
    // the next hover moves the same row (and not the one it displaced).
    let destination = from < reorder.index ? reorder.index + 1 : reorder.index
    reorder.move(IndexSet(integer: from), destination)
    drag.update(index: reorder.index)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard isRow(info) else { return other?.perform() ?? false }
    drag.end()
    return true
  }
}

/// Makes a sidebar row a drag source and a drop target (`LazyVStack` only — in
/// the `List` sidebar `drag` is nil, so the row keeps its hands off the drag
/// gesture, which `.onMove` owns there).
struct SidebarRowDrag: ViewModifier {
  @Environment(\.sidebarRowDropHandler) private var other
  let reorder: SidebarReorder?
  let drag: SidebarDragState?

  func body(content: Content) -> some View {
    if let reorder, let drag {
      content
        .onDrag {
          // A drag always starts on the main thread, but `onDrag`'s closure is
          // not MainActor-isolated (the same assumption the ⌘W monitor makes).
          MainActor.assumeIsolated { drag.begin(reorder.list, at: reorder.index) }
          let provider = NSItemProvider()
          provider.registerDataRepresentation(
            forTypeIdentifier: SidebarDragState.contentType.identifier, visibility: .ownProcess
          ) { completion in
            completion(Data(), nil)
            return nil
          }
          return provider
        }
        .modifier(SidebarDraggedRowGap(reorder: reorder, drag: drag))
        .onDrop(
          of: [SidebarDragState.contentType] + (other?.contentTypes ?? []),
          delegate: SidebarRowDropDelegate(reorder: reorder, drag: drag, other: other))
    } else {
      content
    }
  }
}

/// The drag image IS the row while it is dragged, so the row itself only keeps
/// its space. A drag can end without a drop on a row (outside the sidebar, or
/// back on itself), so the session's end clears the drag state too. Before
/// macOS 26 / iOS 27 nothing reports that end, and a hidden row could stay
/// hidden, so there the row stays drawn.
private struct SidebarDraggedRowGap: ViewModifier {
  let reorder: SidebarReorder
  let drag: SidebarDragState

  func body(content: Content) -> some View {
    if #available(macOS 26.0, iOS 27.0, *) {
      content
        .opacity(drag.isDragging(reorder) ? 0 : 1)
        .onDragSessionUpdated { session in
          if case .ended = session.phase { drag.end() }
        }
    } else {
      content
    }
  }
}
