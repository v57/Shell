import ComponentKit
import SwiftUI
import ShellKit

/// A saved web session row in the sidebar's Local or SSH section. Mirrors the
/// screen/remote rows: an icon, the page name, an open/closed dot, and a
/// second line (the URL for a plain page, or the SSH host for an ssh-owned
/// page). The context menu offers Open / Reconnect / Edit / Delete.
struct WebSessionRow: View {
  @Environment(AppModel.self) private var model
  let web: WebSession
  /// The SSH host name shown as the row's environment subtitle (ssh-owned
  /// rows), like remote screen rows carry their origin. nil for plain pages.
  var environmentName: String? = nil

  private var liveSession: TerminalSession? { model.liveWebSession(for: web) }

  var body: some View {
    let isOpen = liveSession != nil
    // The row carries the open page's session when it is up (so the row shows
    // selected while its WebView is visible), else the page's own id —
    // activating that opens it.
    SidebarRow(value: model.rowSelection(for: web), web.sidebarTitle, subtitle: subtitle, systemImage: "globe") {
      StatusDot(hue: isOpen ? .green : .gray, isHollow: !isOpen)
        .accessibilityLabel(isOpen ? "Open" : "Closed")
        .help(isOpen ? "Web session open" : "Web session closed")
    }
    .contextMenu {
      Button("Open") { model.openOrFocusWebSession(web) }
      Button("Reconnect") { model.reconnectWebSession(web) }
      Divider()
      Button("Edit…") { model.editingWebSession = web }
      Divider()
      Button("Delete", role: .destructive) { model.deleteWebSession(web) }
    }
  }

  /// The row's second line: the SSH host for ssh-owned pages, else the URL.
  private var subtitle: String? {
    if let environmentName, !environmentName.isEmpty { return environmentName }
    return web.url.isEmpty ? nil : web.url
  }
}

extension WebSession {
  /// The page's name in the sidebar: its name, else its URL.
  var sidebarTitle: String {
    name.isEmpty ? (url.isEmpty ? "Web Session" : url) : name
  }
}
