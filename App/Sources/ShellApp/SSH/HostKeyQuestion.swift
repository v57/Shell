import ShellKit
import VaultUI

extension TerminalHostKeyPrompt {
  /// Answers for a connection with no terminal of its own (the file browser, a tunnel, the authorized-keys panel): the
  /// user is asked in the window before anything is sent to the server, and with no window nobody says yes. A changed
  /// key is refused without asking: only the terminal, which shows both keys, can replace a remembered one.
  /// `answered` runs once the question is over.
  func askInWindow(_ request: VaultHostKeyRequest = .shared, answered: @escaping @MainActor () -> Void = {}) {
    guard previousFingerprint == nil else {
      respond(false)
      answered()
      return
    }
    Task { @MainActor in
      respond(await request.ask(name: host, address: host, port: port, fingerprint: fingerprint))
      answered()
    }
  }
}
