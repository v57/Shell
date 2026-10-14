import ShellKit
import SwiftUI

extension View {
  /// Files dropped on a terminal: the same choices as a drop on its sidebar row (FileDropActions.swift).
  func terminalFileDrop(_ session: TerminalSession) -> some View {
    modifier(TerminalFileDrop(session: session))
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

/// Asks what to do with dropped files (`AppModel.fileDropRequest`), and reports a drop that failed.
struct FileDropDialog: ViewModifier {
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View {
    #if os(macOS)
    content
      .confirmationDialog(
        model.fileDropRequest.map { model.fileDropTitle(for: $0) } ?? "",
        isPresented: Binding(
          get: { model.fileDropRequest != nil },
          set: { if !$0 { model.fileDropRequest = nil } }
        ),
        titleVisibility: .visible,
        presenting: model.fileDropRequest
      ) { request in
        ForEach(model.fileDropActions(for: request), id: \.self) { action in
          Button(model.fileDropTitle(of: action, for: request)) {
            model.performFileDrop(action, for: request)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: { request in
        if let message = model.fileDropMessage(for: request) { Text(message) }
      }
      .alert(
        "Couldn't Drop Files",
        isPresented: Binding(
          get: { model.fileDropError != nil },
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
