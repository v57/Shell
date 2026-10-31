import ComponentKit
import ShellKit
import SwiftUI

extension View {
  /// The questions an SSH session asks while it connects, as the kit's overlays over the window (never a system sheet
  /// or alert on the Mac and iPad): an unknown or changed host key (`kitDialog`, the fingerprints in it) and the
  /// password (`kitSheet`).
  func terminalPrompts(_ session: TerminalSession) -> some View {
    modifier(TerminalPrompts(session: session))
  }
}

private struct TerminalPrompts: ViewModifier {
  @Bindable var session: TerminalSession

  func body(content: Content) -> some View {
    let prompt = session.hostKeyPrompt
    let changed = prompt?.previousFingerprint != nil
    content
      .kitDialog(
        changed ? "Host key changed" : "Untrusted host key",
        isPresented: Binding(
          get: { session.hostKeyPrompt != nil },
          // Cancel (Reject, or Disconnect for a changed key) and a click on the dim reject; Accept clears the prompt
          // before the dialog closes.
          set: { if !$0, let prompt = session.hostKeyPrompt { session.rejectHostKey(prompt) } }),
        message: prompt.map { prompt in
          changed
            ? "The key for \(prompt.host):\(prompt.port) isn't the one Shell remembers. Someone could be intercepting this connection, or the server was reinstalled."
            : "The authenticity of \(prompt.host):\(prompt.port) can't be established. Connect only if this is the host's key."
        },
        systemImage: changed ? "exclamationmark.shield" : "key.horizontal",
        confirm: changed ? "Trust New Key" : "Accept",
        role: changed ? .destructive : nil
      ) {
        if let prompt {
          VStack(alignment: .leading, spacing: 6) {
            if let previous = prompt.previousFingerprint {
              FingerprintLine(label: "Remembered", fingerprint: previous)
            }
            FingerprintLine(label: changed ? "Presented" : "Fingerprint", fingerprint: prompt.fingerprint)
          }
        }
      } action: {
        if let prompt = session.hostKeyPrompt { session.acceptHostKey(prompt) }
      }
      .kitSheet(item: $session.passwordPrompt) { prompt in
        PasswordPromptSheet(prompt: prompt)
      }
  }
}

/// A host key's fingerprint under its label, in the kit's code block (monospaced, selectable).
private struct FingerprintLine: View {
  let label: String
  let fingerprint: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).kitFont(.caption)
      KitCodeBlock(fingerprint, font: .monoSmall)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The password an SSH login asks for, and whether to keep it in the Keychain. Closed any other way than Connect
/// (Cancel, Escape, a click on the dim), it answers with no password, once, so the login never waits.
private struct PasswordPromptSheet: View {
  let prompt: TerminalPasswordPrompt
  @Environment(\.kitDismiss) private var dismiss
  @State private var password = ""
  @State private var save = true
  @State private var answered = false

  var body: some View {
    KitSheet(
      title: "Password required", meta: "\(prompt.username)@\(prompt.host)", systemImage: "lock", hue: .blue,
      width: 380
    ) {
      FormCard {
        FormRow(
          "Password", systemImage: "ellipsis.rectangle", hue: .blue,
          field: SecureField("Password", text: $password).textContentType(.password).onSubmit(submit))
        FormRow("Save in Keychain", systemImage: "key", hue: .blue) {
          Toggle("Save in Keychain", isOn: $save).toggleStyle(.kitSwitch).kitLabelsHidden()
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Connect") { submit() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(password.isEmpty)
    }
    .onDisappear {
      if !answered { prompt.respond(nil, false) }
    }
  }

  private func submit() {
    guard !password.isEmpty, !answered else { return }
    answered = true
    prompt.respond(password, save)
    dismiss()
  }
}
