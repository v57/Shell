import ComponentKit
import Foundation
import SwiftUI
import ShellKit

/// The kit sheet for creating a NEW SSH connection, or EDITING a saved one
/// (when initialized with a `config`): fields prefill and the footer's button
/// saves in place (same id) instead of connecting.
struct NewConnectionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.kitDismiss) private var dismiss
  
  /// Non-nil when editing a saved connection.
  private let editing: SSHConfig?
  
  @State private var name: String
  @State private var host: String
  @State private var user: String
  @State private var port: Int
  @State private var authMethod: SSHConfig.AuthMethod
  @State private var password: String
  @State private var savePassword: Bool
  @State private var keyError: String?
  
  init(config: SSHConfig? = nil) {
    editing = config
    _name = State(initialValue: config?.name ?? "")
    _host = State(initialValue: config?.host ?? "")
    _user = State(initialValue: config?.user ?? NSUserName())
    _port = State(initialValue: config?.port ?? 22)
    _authMethod = State(initialValue: config?.authMethod ?? .keychainKey)
    _password = State(initialValue: "")
    _savePassword = State(initialValue: config?.savePassword ?? true)
    _keyError = State(initialValue: nil)
  }
  
  private var canConnect: Bool {
    !host.trimmingCharacters(in: .whitespaces).isEmpty
    && !user.trimmingCharacters(in: .whitespaces).isEmpty
    && port > 0 && port < 65536
    && (authMethod == .keychainKey
        || !password.isEmpty
        || editing?.authMethod == .password)  // stored password still applies
  }
  
  var body: some View {
    KitSheet(
      title: editing == nil ? "New Connection" : "Edit Connection",
      meta: editing == nil ? "An SSH host to open terminals on" : editing?.displayName,
      systemImage: "network", hue: .blue
    ) {
      FormCard {
        FormRow("Host", systemImage: "server.rack", hue: .blue, field: hostField)
        FormRow("User", systemImage: "person", hue: .blue, field: userField)
        FormRow("Name", help: "Shown in the sidebar", systemImage: "character.cursor.ibeam", hue: .blue,
                field: TextField(host.isEmpty ? "Optional" : host, text: $name))
        FormRow("Port", systemImage: "number", hue: .blue, field: TextField("22", value: $port, format: .number))
      }
      FormCard("Authentication") {
        FormRow("Method", systemImage: "key", hue: .indigo) {
          KitPicker("Method", selection: $authMethod, options: SSHConfig.AuthMethod.allCases.map { ($0.label, $0) })
            .fixedSize()
        }
        if authMethod == .password {
          FormRow("Password", systemImage: "ellipsis.rectangle", hue: .indigo,
                  field: SecureField(editing?.authMethod == .password ? "Unchanged" : "Password", text: $password)
                    .textContentType(.password))
          FormRow("Save in Keychain", systemImage: "lock", hue: .indigo) {
            Toggle("Save in Keychain", isOn: $savePassword).toggleStyle(.kitSwitch).kitLabelsHidden()
          }
        }
      }
      if authMethod == .keychainKey {
        FormCard("SSH key", footer: "Add this key to the server's ~/.ssh/authorized_keys to use key authentication.") {
          FormRow("Default key", help: model.publicKeyFingerprint(), systemImage: "key.horizontal", hue: .gray) {
            Button("Copy", systemImage: "doc.on.doc") {
              model.copyPublicKey()
              keyError = model.publicKeyError
            }
            .buttonStyle(.kit)
            .help("Copy the default key's public key")
          }
        }
      }
    } footer: {
      if let keyError {
        SheetStatus(keyError, systemImage: "exclamationmark.triangle", hue: .red)
      }
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(editing == nil ? "Connect" : "Save") { submit() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!canConnect)
    }
  }

  private var hostField: some View {
    #if os(iOS)
    TextField("example.com", text: $host).textContentType(.URL).textInputAutocapitalization(.never)
      .autocorrectionDisabled()
    #else
    TextField("example.com", text: $host).textContentType(.URL).autocorrectionDisabled()
    #endif
  }

  private var userField: some View {
    #if os(iOS)
    TextField("User", text: $user).textContentType(.username).textInputAutocapitalization(.never)
      .autocorrectionDisabled()
    #else
    TextField("User", text: $user).textContentType(.username).autocorrectionDisabled()
    #endif
  }

  private func submit() {
    let config = SSHConfig(
      id: editing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      host: host.trimmingCharacters(in: .whitespaces),
      user: user.trimmingCharacters(in: .whitespaces),
      port: port,
      authMethod: authMethod,
      savePassword: savePassword
    )
    // Password lifecycle: a typed password saves or clears per the toggle;
    // editing without retyping leaves the stored password untouched; the
    // toggle turned off without a new password deletes it.
    if authMethod == .password {
      if !password.isEmpty {
        if savePassword {
          try? SSHKeychain.savePassword(password, account: config.passwordAccount)
        } else {
          SSHKeychain.deletePassword(account: config.passwordAccount)
        }
      } else if !savePassword {
        SSHKeychain.deletePassword(account: config.passwordAccount)
      }
    }
    if editing != nil {
      model.updateConnection(config)
    } else {
      model.connect(to: config)
    }
    dismiss()
  }
}
