import ComponentKit
import ShellKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
  /// Files dropped on a terminal: the same choices as a drop on its sidebar row (FileDropActions.swift).
  func terminalFileDrop(_ session: TerminalSession) -> some View {
    modifier(TerminalFileDrop(session: session))
  }

  /// Shows the drop menu (`AppModel.fileDropRequest`) at the pointer when the files were dropped on THIS window.
  /// Applied once per window root: the main window and every detached one. `showsErrors` reports a drop that
  /// failed; only the main window does, as the other alerts do.
  func fileDropMenu(showsErrors: Bool = false) -> some View {
    modifier(FileDropMenuPresenter(showsErrors: showsErrors))
  }
}

private struct TerminalFileDrop: ViewModifier {
  @Environment(AppModel.self) private var model
  let session: TerminalSession

  func body(content: Content) -> some View {
    #if os(macOS)
    content.fileDrop { files in model.requestFileDrop(files, on: .session(session.id)) }
    #else
    content
    #endif
  }
}

private struct FileDropMenuPresenter: ViewModifier {
  @Environment(AppModel.self) private var model
  let showsErrors: Bool

  #if os(macOS)
  /// The window root's AppKit view: which window this is, and where a screen point falls in it.
  @State private var anchor = WindowAnchor()

  /// The pending drop, when it was dropped on this window (or on no known window, and this one is key).
  private var request: FileDropRequest? {
    guard let request = model.fileDropRequest, let window = anchor.view?.window else { return nil }
    if let number = request.windowNumber { return number == window.windowNumber ? request : nil }
    return window.isKeyWindow ? request : nil
  }
  #endif

  func body(content: Content) -> some View {
    #if os(macOS)
    content
      .background {
        WindowAnchorView(anchor: anchor)
          .allowsHitTesting(false)
      }
      // The drop's choices as the kit's menu at the pointer: the first is highlighted (Return runs it), 1–9 run a
      // row, Escape or a click outside cancels.
      .kitMenu(
        isPresented: Binding(get: { request != nil }, set: { if !$0 { model.fileDropRequest = nil } }),
        at: request.flatMap { anchor.point(fromScreen: $0.location) } ?? .zero
      ) {
        if let request { FileDropMenu(request: request) }
      }
      .kitNotice(
        "Couldn't Drop Files",
        isPresented: Binding(
          get: { showsErrors && model.fileDropError != nil },
          set: { if !$0 { model.fileDropError = nil } }
        ),
        message: model.fileDropError, systemImage: "doc.badge.ellipsis")
    #else
    content
    #endif
  }
}

#if os(macOS)
/// Holds the AppKit view behind a window root (not observed: it is set once, before any drop).
private final class WindowAnchor {
  weak var view: NSView?

  /// `screenPoint` in the view's top-left coordinates, as SwiftUI lays out the overlay.
  func point(fromScreen screenPoint: CGPoint) -> CGPoint? {
    guard let view, let window = view.window else { return nil }
    let local = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    return CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
  }
}

private struct WindowAnchorView: NSViewRepresentable {
  let anchor: WindowAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    anchor.view = nsView
  }
}

/// The drop menu's rows (designed on the "Shell Drop Menu" canvas): the choices first, nearest the pointer, each
/// with its number key, then what was dropped where.
private struct FileDropMenu: View {
  @Environment(AppModel.self) private var model
  let request: FileDropRequest

  var body: some View {
    let actions = model.fileDropActions(for: request)
    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
      Button(model.fileDropTitle(of: action, for: request), systemImage: action.systemImage) {
        model.performFileDrop(action, for: request)
      }
      .kitMenuHint(index < 9 ? "\(index + 1)" : nil)
    }
    Divider()
    KitMenuFooter(
      model.fileDropSubject(for: request), subtitle: "Dropped on \(model.fileDropTargetName(for: request))",
      message: model.fileDropMessage(for: request), systemImage: headerSymbol)
  }

  private var headerSymbol: String {
    guard request.files.count == 1 else { return "doc.on.doc" }
    return request.files[0].isDirectory ? "folder" : "doc"
  }
}

private extension FileDropAction {
  var systemImage: String {
    switch self {
    case .copy: "doc.on.doc"
    case .upload: "arrow.up.doc"
    case .insertPath: "character.cursor.ibeam"
    case .goToFolder: "folder"
    case .copyToNote: "lock.doc"
    case .linkFile: "link"
    }
  }
}
#endif
