import ComponentKit
import SwiftUI
import ShellKit

/// A saved web session row in the sidebar's Web section: one line with an
/// icon, the page name and an open/closed dot; the URL and the SSH host it
/// tunnels through are in its tooltip. The context menu offers Open /
/// Reconnect / Edit / Delete.
struct WebSessionRow: View {
  @Environment(AppModel.self) private var model
  let web: WebSession
  private var liveSession: TerminalSession? { model.liveWebSession(for: web) }

  var body: some View {
    let isOpen = liveSession != nil
    // The row carries the open page's session when it is up (so the row shows
    // selected while its WebView is visible), else the page's own id —
    // activating that opens it.
    SidebarRow(
      value: model.rowSelection(for: web), web.sidebarTitle, systemImage: "globe",
      status: model.webSessionRuntime(for: web)?.status ?? .idle
    ) {
      StatusDot(hue: isOpen ? .green : .gray, isHollow: !isOpen)
        .accessibilityLabel(isOpen ? "Open" : "Closed")
        .help(isOpen ? "Web session open" : "Web session closed")
    }
    .kitHelp(web.sidebarTitle, meta: address, systemImage: "globe", hue: .teal)
    .kitContextMenu {
      Button("Open") { model.openOrFocusWebSession(web) }
      Button("Reconnect") { model.reconnectWebSession(web) }
      Divider()
      Button("Edit…") { model.editingWebSession = web }
      Divider()
      Button("Delete", role: .destructive) { model.deleteWebSession(web) }
    }
  }

  /// The URL, and the SSH host an ssh-owned page tunnels through.
  private var address: String? {
    let host = web.sshConfigID.flatMap { id in model.connections.first { $0.id == id } }?.displayName
    let parts = [web.url, host.map { "via \($0)" } ?? ""].filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }
}

extension WebSession {
  /// The page's name in the sidebar: its name, else its URL.
  var sidebarTitle: String {
    name.isEmpty ? (url.isEmpty ? "Web Session" : url) : name
  }
}
