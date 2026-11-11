import Foundation
import ShellKit
import ShellIntegrations

/// Runs ONE command over the active SSH session's transport without a
/// visible terminal, returning its output and exit status as a
/// `CommandResult`. The SSH counterpart to the local `Process` runner, used
/// by the directory browser for file operations on remote connections.
///
/// Authentication mirrors interactive sessions: the Secure Enclave key first
/// (via `SSHSession`), saved password as fallback. A host key not seen before
/// is refused without sending anything: the terminal asks about it. A
/// timeout guard aborts a hung connection so the browser cannot be blocked
/// forever.
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
  /// The address the last connection reached: a host whose own address doesn't answer is dialed at the fallback that
  /// did first, instead of waiting for the dead one on every command (S-011).
  private var answeringAddress: String?

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

  /// The config to dial: the address that answered last time first, then the host and its other fallbacks. The host
  /// key check knows the machine's keys at all of them (`KnownHostsStore.fingerprints`).
  private var dialConfig: SSHConfig {
    guard let address = answeringAddress, address.lowercased() != config.host.lowercased() else { return config }
    var dial = config
    dial.host = address
    dial.fallbacks = [config.host] + config.fallbacks.filter { $0.lowercased() != address.lowercased() }
    return dial
  }

  // MARK: - Execution

  /// One command's connection and what it captured. Each run has its own, so a `pwd` from the panel's tick and a
  /// listing at the same moment can't take each other's state: one of them then never finished, and Files stayed on
  /// "Loading…" (S-011).
  private final class Run {
    var session: SSHSession?
    var output = ""
    var exitCode: Int32 = -1
    var terminationMessage: String?
    var finished = false
    /// The server's key was unknown and refused (see `onHostKeyPrompt`).
    var refusedHostKey = false
    var timeoutTask: Task<Void, Never>?
  }

  private func execute(_ execCommand: String) async throws -> CommandResult {
    let run = Run()
    return try await withCheckedThrowingContinuation { continuation in
      let session = SSHSession(config: dialConfig, execCommand: execCommand)
      run.session = session

      // Timeout guard: a hung connection must not block the file browser; it ends in an error the panel shows with
      // Retry.
      let timeout = timeout
      run.timeoutTask = Task {
        try? await Task.sleep(for: .seconds(timeout))
        guard !run.finished, !Task.isCancelled else { return }
        run.session?.close()
        Self.complete(
          run, continuation, forceError: SSHCommandRunnerError.connectionFailed("no answer after \(Int(timeout)) s"))
      }

      session.onAddress = { [weak self] address in self?.answeringAddress = address }
      session.onOutput = { data in
        run.output += String(data: data, encoding: .utf8) ?? ""
      }
      session.onExit = { code in
        run.timeoutTask?.cancel()
        run.exitCode = code
        Self.complete(run, continuation)
      }
      session.onTerminated = { message in
        run.timeoutTask?.cancel()
        run.terminationMessage = message
        Self.complete(run, continuation)
      }
      // A key Shell doesn't know yet is the terminal's question: the Files
      // panel lists the host of a terminal that is connecting at the same
      // moment and asks itself, with the fingerprints. Asking here too made a
      // first connection ask about one key three times (S-001). The listing
      // fails instead and comes back once the terminal's answer is remembered
      // (the engine accepts known hosts itself).
      session.onHostKeyPrompt = { prompt in
        prompt.respond(false)
        run.refusedHostKey = true
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

  private static func complete(
    _ run: Run, _ continuation: CheckedContinuation<CommandResult, Error>, forceError: Error? = nil
  ) {
    guard !run.finished else { return }
    run.finished = true
    run.session = nil
    if let forceError {
      continuation.resume(throwing: forceError)
    } else if run.refusedHostKey {
      continuation.resume(throwing: SSHCommandRunnerError.untrustedHostKey)
    } else if let message = run.terminationMessage {
      continuation.resume(throwing: SSHCommandRunnerError.connectionFailed(message))
    } else {
      continuation.resume(returning: CommandResult(output: run.output, exitCode: run.exitCode))
    }
  }
}

/// Errors thrown when a remote command could not be executed at all
/// (as opposed to running and returning a non-zero exit code).
enum SSHCommandRunnerError: LocalizedError {
  case connectionFailed(String)

  /// The server's key isn't known yet; the terminal asks about it.
  case untrustedHostKey

  var errorDescription: String? {
    switch self {
    case .connectionFailed(let message):
      return "Could not connect: \(message)"
    case .untrustedHostKey:
      return String(localized: "This server's key isn't trusted yet. Accept it in the terminal.")
    }
  }
}
