import Foundation
import Terminal
import TerminalIntegrations

/// Runs ONE command over the active SSH session's transport without a
/// visible terminal, returning its output and exit status as a
/// `CommandResult`. The SSH counterpart to the local `Process` runner, used
/// by the directory browser for file operations on remote connections.
///
/// Authentication mirrors interactive sessions: the Secure Enclave key first
/// (via `SSHSession`), saved password as fallback. Host keys are trusted on
/// first use — opening the file browser for a host IS the intent to connect
/// to it. A timeout guard aborts a hung connection so the browser cannot be
/// blocked forever.
///
/// The connection config is supplied by the caller (e.g. extracted from
/// `model.kind(of:)`'s `.ssh(config)`); this runner never resolves config
/// on its own.
@MainActor
final class SSHCommandRunner: FileCommandExecutor {
  /// The SSH connection to use.
  private let config: SSHConfig
  /// Max time a single command may run before the session is aborted.
  private let timeout: TimeInterval

  // Per-run capture state. The runner is used serially by the directory
  // browser (operations are gated by the model's busy flag), so instance
  // state mirrors `HeadlessSSHCommandRunner` without needing a fresh object
  // per command.
  private var session: SSHSession?
  private var outputBuffer = ""
  private var exitCode: Int32 = -1
  private var terminationMessage: String?
  private var finished = false

  init(config: SSHConfig, timeout: TimeInterval = 30) {
    self.config = config
    self.timeout = timeout
  }

  /// Runs `command` in directory `dir`, prefixed with a shell `cd` so the
  /// remote command executes in the requested directory — the same shape
  /// used by interactive smart-action sessions.
  func run(inDirectory dir: String, _ command: String) async throws -> CommandResult {
    let execCommand = "cd " + FileCommandBuilder.shellQuote(dir) + " && " + command
    return try await execute(execCommand)
  }

  // MARK: - Execution

  private func execute(_ execCommand: String) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
      resetCapture()

      let session = SSHSession(config: config, execCommand: execCommand)
      self.session = session

      // Timeout guard: a hung connection must not block the file browser.
      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(self?.timeout ?? 30))
        guard let self, !self.finished else { return }
        self.session?.close()
        self.complete(
          continuation,
          forceError: SSHCommandRunnerError.connectionFailed(
            "timed out after \(Int(self.timeout))s"))
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
      // Trust on first use — the user explicitly opened the file browser for
      // this host (the engine also auto-accepts known hosts).
      session.onHostKeyPrompt = { prompt in
        prompt.respond(true)
      }
      // Saved passwords answer silently; without one, auth fails and the
      // caller surfaces the termination error.
      session.onPasswordPrompt = { [config] prompt in
        let saved = (try? SSHKeychain.loadPassword(account: config.passwordAccount)) ?? nil
        prompt.respond(saved, false)
      }
      session.start()
    }
  }

  private func resetCapture() {
    outputBuffer = ""
    exitCode = -1
    terminationMessage = nil
    finished = false
  }

  private func complete(
    _ continuation: CheckedContinuation<CommandResult, Error>,
    forceError: Error? = nil
  ) {
    guard !finished else { return }
    finished = true
    session = nil
    if let forceError {
      continuation.resume(throwing: forceError)
    } else if let terminationMessage {
      continuation.resume(throwing: SSHCommandRunnerError.connectionFailed(terminationMessage))
    } else {
      continuation.resume(returning: CommandResult(output: outputBuffer, exitCode: exitCode))
    }
  }
}

/// Errors thrown when a remote command could not be executed at all
/// (as opposed to running and returning a non-zero exit code).
enum SSHCommandRunnerError: LocalizedError {
  case connectionFailed(String)

  var errorDescription: String? {
    switch self {
    case .connectionFailed(let message):
      return "Could not connect: \(message)"
    }
  }
}
