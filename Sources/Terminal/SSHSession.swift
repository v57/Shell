import Crypto
import Foundation

/// Main-actor SSH transport over `Libssh2Connection`. Exposes the
/// connection lifecycle and UI-facing prompts (host-key verification,
/// password entry) to the terminal session.
@MainActor
public final class SSHSession: TerminalTransport {
  public let config: SSHConfig
  /// When non-nil the connection runs this command via PTY + exec
  /// instead of an interactive shell (action sessions).
  private let execCommand: String?
  /// When true the connection carries no shell/exec session channel and exists
  /// purely to multiplex `direct-tcpip` port-forward channels.
  private let forwardingOnly: Bool

  /// All callbacks are delivered on the main thread.
  public var onOutput: ((Data) -> Void)?
  public var onConnected: (() -> Void)?
  public var onTerminated: ((String) -> Void)?
  /// The exec command's remote exit status (action sessions only).
  public var onExit: ((Int32) -> Void)?
  public var onHostKeyPrompt: ((TerminalHostKeyPrompt) -> Void)?
  public var onPasswordPrompt: ((TerminalPasswordPrompt) -> Void)?

  private var engine: Libssh2Connection?
  private var started = false

  public init(config: SSHConfig, execCommand: String? = nil, forwardingOnly: Bool = false) {
    self.config = config
    self.execCommand = execCommand
    self.forwardingOnly = forwardingOnly
  }

  public func start() {
    guard !started else { return }
    started = true

    // The identity key lives in the Secure Enclave; it never touches disk.
    let key = try? SSHKeychain.loadOrCreateDefaultKey()
    let engine = Libssh2Connection(
      config: config,
      privateKey: key,
      execCommand: execCommand,
      forwardingOnly: forwardingOnly
    )

    engine.onOutput = { [weak self] data in
      self?.onOutput?(data)
    }
    engine.onConnected = { [weak self] in
      self?.onConnected?()
    }
    engine.onTerminated = { [weak self] message in
      self?.onTerminated?(message)
    }
    engine.onExit = { [weak self] status in
      self?.onExit?(status)
    }
    engine.onHostKeyChallenge = { [weak self] challenge in
      guard let self else { return }
      self.onHostKeyPrompt?(TerminalHostKeyPrompt(
        host: self.config.host,
        port: self.config.port,
        fingerprint: challenge.fingerprint,
        respond: challenge.respond
      ))
    }
    engine.onPasswordChallenge = { [weak self] challenge in
      guard let self else { return }
      self.onPasswordPrompt?(TerminalPasswordPrompt(
        host: self.config.host,
        username: challenge.username,
        respond: { password, save in
          if save, let password {
            try? SSHKeychain.savePassword(password, account: self.config.passwordAccount)
          }
          challenge.respond(password)
        }
      ))
    }

    self.engine = engine
    engine.start()
  }

  public func write(_ data: Data) {
    engine?.write(data)
  }

  public func resize(columns: Int, rows: Int) {
    engine?.resize(columns: columns, rows: rows)
  }

  public func close() {
    engine?.close()
    engine = nil
  }

  /// Runs a one-shot `command` on the ALREADY-CONNECTED connection — no new
  /// SSH dial is made (the remote persistent-session scanner's whole point).
  /// The captured stdout is delivered to `completion` on the main thread; a
  /// non-zero remote exec status is carried back as the stdout the command
  /// produced (list commands like `tmux ls` exit non-zero on the normal "no
  /// server" case), so callers interpret the text rather than treat non-zero
  /// as a failure. Only meaningful after `start()` has connected — the
  /// scanner gates on `connectionState == .connected` before calling.
  public func runCommand(_ command: String, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
    guard let engine else {
      completion(.failure(Libssh2Connection.EngineError.notConnected))
      return
    }
    engine.runRemoteCommand(command, completion: completion)
  }

  // MARK: - Local port-forward (web / remote tunnel)

  /// Starts a local port-forward over this ALREADY-CONNECTED connection — no
  /// new SSH dial/auth. Resolves to the bound local port once the listener is
  /// up. Only meaningful after `start()` has authenticated (the web session
  /// calls this from `onConnected`).
  public func startLocalPortForward(
    bindHost: String = "127.0.0.1",
    bindPort: Int = 0,
    targetHost: String,
    targetPort: Int,
    completion: @escaping @Sendable (Result<Int, Error>) -> Void
  ) {
    guard let engine else {
      completion(.failure(Libssh2Connection.EngineError.notConnected))
      return
    }
    engine.startLocalPortForward(
      bindHost: bindHost,
      bindPort: bindPort,
      targetHost: targetHost,
      targetPort: targetPort,
      completion: completion
    )
  }

  /// Closes the local port-forward (if any); the SSH connection itself is left
  /// open.
  public func stopLocalPortForward() {
    engine?.stopLocalPortForward()
  }
}
