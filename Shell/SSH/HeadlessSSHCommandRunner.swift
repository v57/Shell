import Foundation
import Terminal

/// Runs ONE command over SSH without a visible terminal session, returning
/// its output and exit status. Used by `AuthorizedKeysManager` to read and
/// modify a remote `~/.ssh/authorized_keys`.
///
/// Authentication mirrors interactive sessions: the Secure Enclave key
/// first (via `SSHSession`), saved password as fallback. Host keys are
/// trusted on first use — opening the authorized-keys panel for a host IS
/// the intent to connect to it. A changed host key fails the command.
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

  func run(config: SSHConfig, command: String, timeout: TimeInterval = 30) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
      let session = SSHSession(config: config, execCommand: command)
      self.session = session

      // Timeout guard: a hung connection must not block the panel forever.
      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        guard let self, !self.finished else { return }
        self.session?.close()
        self.complete(continuation, forceError: AuthorizedKeysError.connectionFailed("timed out after \(Int(timeout))s"))
      }

      session.onOutput = { [weak self] data in
        self?.outputBuffer += String(data: data, encoding: .utf8) ?? ""
      }
      session.onExit = { [weak self, timeoutTask] code in
        timeoutTask.cancel()
        self?.exitCode = code
        self?.complete(continuation)
      }
      session.onTerminated = { [weak self, timeoutTask] message in
        timeoutTask.cancel()
        self?.terminationMessage = message
        self?.complete(continuation)
      }
      // Trust on first use, never a changed key — the user explicitly opened
      // the keys panel for this host (the engine also auto-accepts known
      // hosts).
      session.onHostKeyPrompt = { prompt in
        prompt.respondTrustingFirstUse()
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
