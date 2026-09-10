import Foundation
import SwiftUI
import Terminal

/// Sheet for creating a NEW SSH connection, or EDITING a saved one (when
/// initialized with a `config`): fields prefill and the toolbar button
/// saves in place (same id) instead of connecting.
struct NewConnectionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  
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
    NavigationStack {
      VStack(spacing: 0) {
        Form {
          Section {
            TextField("Host", text: $host).textContentType(.URL)
            TextField("User", text: $user).textContentType(.username)
            TextField("Name \(host)", text: $name)
            TextField("Port", value: $port, format: .number)
          }
          
          Section("Authentication") {
            Picker("Method", selection: $authMethod) {
              ForEach(SSHConfig.AuthMethod.allCases) { method in
                Text(method.label).tag(method)
              }
            }
            if authMethod == .password {
              SecureField("Password", text: $password)
                .textContentType(.password)
              Toggle("Save in Keychain", isOn: $savePassword)
            }
          }
          
          if authMethod == .keychainKey {
            Section {
              KeyRow(
                label: "Default key",
                fingerprint: model.publicKeyFingerprint(),
                onCopy: {
                  model.copyPublicKey()
                  keyError = model.publicKeyError
                }
              )
            } header: {
              Text("SSH key")
            } footer: {
              Text("Add this key to the server's ~/.ssh/authorized_keys to use key authentication.")
            }
          }
        }.formStyle(.grouped)
      }.toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(editing == nil ? "Connect" : "Save", systemImage: "checkmark") {
            submit()
          }.keyboardShortcut(.defaultAction).disabled(!canConnect)
        }
      }.alert("Could not copy public key", isPresented: Binding(
        get: { keyError != nil },
        set: { if !$0 { keyError = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(keyError ?? "")
      }.navigationTitle(editing == nil ? "New Connection" : "Edit Connection")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
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

/// One row in the SSH key section: label + fingerprint + copy button.
private struct KeyRow: View {
  let label: String
  let fingerprint: String?
  let onCopy: () -> Void
  
  var body: some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      if let fingerprint {
        Text(fingerprint)
          .font(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Button {
        onCopy()
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .help("Copy \(label.lowercased()) public key")
    }
  }
}
