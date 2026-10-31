import ComponentKit
import Foundation
import SwiftUI
import ShellKit

/// The kit sheet for EDITING a saved web session: fields prefill and the footer's button
/// saves in place (same id) — mirrors NewConnectionView. Creating a page has no
/// sheet: the SSH host menu items open one immediately (openNewWebSession), and
/// the page names itself from its HTML title.
struct NewWebSessionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.kitDismiss) private var dismiss

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
    KitSheet(
      title: "Edit Web Session", meta: editing.sidebarTitle, systemImage: "globe", hue: .teal
    ) {
      FormCard {
        FormRow("Name", help: "Empty takes the page's title", systemImage: "character.cursor.ibeam", hue: .teal,
                field: TextField("Name", text: $name))
        FormRow("URL", systemImage: "link", hue: .teal, field: urlField)
      }
      FormCard(footer: sshConfigID == nil ? nil : "The host's localhost is tunnelled to the page.") {
        FormRow("SSH Host", systemImage: "network", hue: .blue) {
          KitPicker(
            "SSH host", selection: $sshConfigID,
            options: [("None (open directly)", nil as UUID?)] + model.connections.map { ($0.displayName, $0.id as UUID?) })
            .fixedSize()
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save") { submit() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
    }
  }

  private var urlField: some View {
    #if os(iOS)
    TextField("https://", text: $url).textContentType(.URL).textInputAutocapitalization(.never)
      .autocorrectionDisabled()
    #else
    TextField("https://", text: $url).textContentType(.URL).autocorrectionDisabled()
    #endif
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
