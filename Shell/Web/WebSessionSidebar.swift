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
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: "globe")
          .foregroundStyle(.secondary)
        Text(web.name.isEmpty ? (web.url.isEmpty ? "Web Session" : web.url) : web.name)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Circle()
          .fill(liveSession != nil ? Color.green : Color.gray)
          .frame(width: 7, height: 7)
          .accessibilityLabel(liveSession != nil ? "Open" : "Closed")
          .help(liveSession != nil ? "Web session open" : "Web session closed")
      }
      if let subtitle {
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .contentShape(Rectangle())
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
