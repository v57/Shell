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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The window root's AppKit view: which window this is, and where a screen point falls in it.
  @State private var anchor = WindowAnchor()

  /// The pending drop, when it was dropped on this window (or on no known window, and this one is key).
  private var request: FileDropRequest? {
    guard let request = model.fileDropRequest, let window = anchor.view?.window else { return nil }
    if let number = request.windowNumber { return number == window.windowNumber ? request : nil }
    return window.isKeyWindow ? request : nil
  }

  private var animates: Bool { FeatureFlagsStore.shared.isEnabled(.animations) && !reduceMotion }
  #endif

  func body(content: Content) -> some View {
    #if os(macOS)
    content
      .overlay {
        ZStack(alignment: .topLeading) {
          WindowAnchorView(anchor: anchor)
            .allowsHitTesting(false)
          if let request, let point = anchor.point(fromScreen: request.location) {
            // A click anywhere outside the menu cancels it, as outside a menu.
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture { model.fileDropRequest = nil }
            FileDropMenuPlacement(pointer: point) {
              FileDropMenu(request: request)
            }
            .transition(.opacity.combined(with: .offset(y: 6)))
          }
        }
        .animation(animates ? .smooth(duration: 0.25) : nil, value: request?.id)
      }
      .alert(
        "Couldn't Drop Files",
        isPresented: Binding(
          get: { showsErrors && model.fileDropError != nil },
          set: { if !$0 { model.fileDropError = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(model.fileDropError ?? "")
      }
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

/// Places the menu centered under the pointer, its actions just below the arrow, kept inside the window: above
/// the pointer when there is no room below it.
private struct FileDropMenuPlacement<Content: View>: View {
  let pointer: CGPoint
  @ViewBuilder let content: Content

  /// The menu's height, once laid out (the flip needs it).
  @State private var height: CGFloat = 0

  /// The pointer arrow's height: the menu starts below it, so the arrow never covers the first action.
  private static var arrowHeight: CGFloat { 22 }
  private static var margin: CGFloat { 8 }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let x = min(max(pointer.x - FileDropMenu.width / 2, Self.margin), size.width - FileDropMenu.width - Self.margin)
      let below = pointer.y + Self.arrowHeight
      let y = below + height + Self.margin <= size.height ? below : max(pointer.y - height - Self.margin, Self.margin)
      content
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .offset(x: x, y: y)
    }
  }
}

/// The drop menu (designed on the "Shell Drop Menu" canvas): the choices first, nearest the pointer, then what was
/// dropped where. Hover or ↑/↓ picks a row, Return or a click runs it, 1–9 run a row directly, and Esc or a click
/// outside cancels.
private struct FileDropMenu: View {
  static let width: CGFloat = 244

  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme
  let request: FileDropRequest

  @State private var selected = 0
  /// The key monitor while the menu is open (see `handle`).
  @State private var keyMonitor: Any?

  private var actions: [FileDropAction] { model.fileDropActions(for: request) }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(Array(actions.enumerated()), id: \.element) { index, action in
        FileDropMenuRow(
          title: model.fileDropTitle(of: action, for: request),
          systemImage: action.systemImage,
          hint: index == selected ? "↩" : (index < 9 ? "\(index + 1)" : nil),
          isSelected: index == selected
        ) {
          perform(action)
        }
        .onHover { if $0 { selected = index } }
      }
      Divider()
        .padding(.horizontal, 6)
        .padding(.top, 4)
      header
    }
    .padding(5)
    .frame(width: Self.width, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(colorScheme == .dark ? Color(white: 0.165) : Color.white)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: 14, y: 10)
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 3, y: 2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.fileDropTitle(for: request))
    .onAppear {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        handle(event) ? nil : event
      }
    }
    .onDisappear {
      if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
      keyMonitor = nil
    }
  }

  /// The menu's keys. Like a menu it never takes keyboard focus, so the terminal keeps it once the menu closes;
  /// while it is open it takes every key but ⌘ shortcuts.
  private func handle(_ event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command) { return false }
    switch event.keyCode {
    case 126:  // ↑
      selected = max(selected - 1, 0)
    case 125:  // ↓
      selected = min(selected + 1, actions.count - 1)
    case 36, 76:  // Return, Enter
      if actions.indices.contains(selected) { perform(actions[selected]) }
    case 53:  // Esc
      model.fileDropRequest = nil
    default:
      if let number = event.charactersIgnoringModifiers.flatMap(Int.init), actions.indices.contains(number - 1) {
        perform(actions[number - 1])
      }
    }
    return true
  }

  /// What was dropped where, under the choices.
  private var header: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: headerSymbol)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(width: 26, height: 26)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(model.fileDropSubject(for: request))
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        Text("Dropped on \(model.fileDropTargetName(for: request))")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if let message = model.fileDropMessage(for: request) {
          Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.top, 8)
    .padding(.bottom, 6)
  }

  private var headerSymbol: String {
    guard request.files.count == 1 else { return "doc.on.doc" }
    return request.files[0].isDirectory ? "folder" : "doc"
  }

  private func perform(_ action: FileDropAction) {
    model.performFileDrop(action, for: request)
  }
}

private struct FileDropMenuRow: View {
  let title: String
  let systemImage: String
  /// ↩ on the selected row, the row's number key on the others.
  let hint: String?
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .frame(width: 16)
          .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        Text(title)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        if let hint {
          Text(hint)
            .font(.system(size: 12))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
        }
      }
      .font(.system(size: 13))
      .padding(.horizontal, 8)
      .frame(height: 26)
      .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isSelected ? Color.accentColor : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
