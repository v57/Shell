import Foundation
import ShellKit

/// Runs ONE command over SSH without a visible terminal session, returning
/// its output and exit status. Used by `AuthorizedKeysManager` to read and
/// modify a remote `~/.ssh/authorized_keys`.
///
/// Authentication mirrors interactive sessions: the Secure Enclave key
/// first (via `SSHSession`), saved password as fallback. A host key not seen
/// before is the user's to accept, asked over the window before anything is
/// sent. A changed host key fails the command.
@MainActor
final class HeadlessSSHCommandRunner {
  struct Result {
    var output: String
    var exitCode: Int32
  }

  private var session: SSHSession?
  private var outputBuffer = ""
  private var exitCode: Int32 = -1
  private var terminationMessage: String?
  private var finished = false
  private var timeoutTask: Task<Void, Never>?

  func run(config: SSHConfig, command: String, timeout: TimeInterval = 30) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
      let session = SSHSession(config: config, execCommand: command)
      self.session = session

      // Timeout guard: a hung connection must not block the panel forever.
      @MainActor func startTimeout() {
        timeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(timeout))
          guard let self, !self.finished, !Task.isCancelled else { return }
          self.session?.close()
          self.complete(continuation, forceError: AuthorizedKeysError.connectionFailed("timed out after \(Int(timeout))s"))
        }
      }
      startTimeout()

      session.onOutput = { [weak self] data in
        self?.outputBuffer += String(data: data, encoding: .utf8) ?? ""
      }
      session.onExit = { [weak self] code in
        self?.timeoutTask?.cancel()
        self?.exitCode = code
        self?.complete(continuation)
      }
      session.onTerminated = { [weak self] message in
        self?.timeoutTask?.cancel()
        self?.terminationMessage = message
        self?.complete(continuation)
      }
      // The user decides about a first contact, and the clock waits for them.
      // A changed key is refused (the engine accepts known hosts itself).
      session.onHostKeyPrompt = { [weak self] prompt in
        self?.timeoutTask?.cancel()
        prompt.askInWindow { startTimeout() }
      }
      // Saved passwords answer silently; without one, auth fails and the
      // panel surfaces the termination message.
      session.onPasswordPrompt = { [config] prompt in
        let saved = (try? SSHKeychain.loadPassword(account: config.passwordAccount)) ?? nil
        prompt.respond(saved, false)
      }
      session.start()
    }
  }

  private func complete(
    _ continuation: CheckedContinuation<Result, Error>,
    forceError: Error? = nil
  ) {
    guard !finished else { return }
    finished = true
    session = nil
    if let forceError {
      continuation.resume(throwing: forceError)
    } else if let terminationMessage {
      continuation.resume(throwing: AuthorizedKeysError.connectionFailed(terminationMessage))
    } else {
      continuation.resume(returning: Result(output: outputBuffer, exitCode: exitCode))
    }
  }
}
