import SwiftUI
import UniformTypeIdentifiers

// TerminalView (host-key/password prompts) + PasswordEntryView.
// Extracted from the Shell app (TerminalView.swift / SidebarView.swift) into the Terminal library.

public struct TerminalView: View {
  @Bindable public var session: TerminalSession

  public init(session: TerminalSession) {
    self.session = session
  }
  
  public var body: some View {
    TerminalScreenView(session: session)
      .padding(4)
      .alert(item: $session.hostKeyPrompt) { prompt in
        Alert(
          title: Text("Untrusted host key"),
          message: Text("The authenticity of host '\(prompt.host):\(prompt.port)' can't be established.\n\(prompt.fingerprint)\n\nAre you sure you want to continue connecting?"),
          primaryButton: .default(Text("Accept")) {
            session.acceptHostKey(prompt)
          },
          secondaryButton: .cancel(Text("Reject")) {
            session.rejectHostKey(prompt)
          }
        )
      }
      .sheet(item: $session.passwordPrompt) { prompt in
        PasswordEntryView(prompt: prompt)
      }
  }
}


// MARK: - Password prompt sheet

struct PasswordEntryView: View {
  @Environment(\.dismiss) private var dismiss
  let prompt: TerminalPasswordPrompt
  
  @State private var password = ""
  @State private var save = true
  
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Password required")
        .font(.headline)
      Text("\(prompt.username)@\(prompt.host)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      SecureField("Password", text: $password)
        .textContentType(.password)
        .onSubmit(submit)
      Toggle("Save in Keychain", isOn: $save)
      HStack {
        Spacer()
        Button("Cancel") {
          prompt.respond(nil, false)
          dismiss()
        }
        Button("Connect") {
          submit()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(password.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 340)
  }
  
  private func submit() {
    prompt.respond(password, save)
    dismiss()
  }
}

