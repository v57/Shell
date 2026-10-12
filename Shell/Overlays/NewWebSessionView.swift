import Foundation
import SwiftUI
import ShellKit

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
