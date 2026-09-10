import SwiftUI
import Terminal

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

/// Sheet for EDITING a saved web session: fields prefill and the toolbar button
/// saves in place (same id) — mirrors NewConnectionView. Creating a page has no
/// sheet: the SSH host menu items open one immediately (openNewWebSession), and
/// the page names itself from its HTML title.
struct NewWebSessionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  /// The saved web session being edited.
  private let editing: WebSession

  @State private var name: String
  @State private var url: String
  @State private var sshConfigID: UUID?

  init(web: WebSession) {
    editing = web
    _name = State(initialValue: web.name)
    _url = State(initialValue: web.url)
    _sshConfigID = State(initialValue: web.sshConfigID)
  }

  private var canSave: Bool {
    !url.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
          TextField("URL", text: $url)
            .textContentType(.URL)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
        }
        Section("SSH Host") {
          Picker("SSH host", selection: $sshConfigID) {
            Text("None (open directly)").tag(nil as UUID?)
            ForEach(model.connections) { config in
              Text(config.displayName).tag(config.id as UUID?)
            }
          }
          if sshConfigID != nil {
            Text("The host's localhost will be tunnelled to the WebView.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", systemImage: "checkmark") {
            submit()
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
        }
      }
      .navigationTitle("Edit Web Session")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
    }
  }

  private func submit() {
    let web = WebSession(
      id: editing.id,
      name: name.trimmingCharacters(in: .whitespaces),
      url: url.trimmingCharacters(in: .whitespaces),
      sshConfigID: sshConfigID
    )
    model.webSessions.save(web)
    dismiss()
  }
}
