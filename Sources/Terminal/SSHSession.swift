import Crypto
import Foundation
import NIOSSH

/// Main-actor SSH transport over `SSHConnectionEngine`. Exposes the
/// connection lifecycle and UI-facing prompts (host-key verification,
/// password entry) to the terminal session.
@MainActor
public final class SSHSession: TerminalTransport {
  public let config: SSHConfig
  /// When non-nil the connection runs this command via PTY + exec
  /// instead of an interactive shell (action sessions).
  private let execCommand: String?

  /// All callbacks are delivered on the main thread.
  public var onOutput: ((Data) -> Void)?
  public var onConnected: (() -> Void)?
  public var onTerminated: ((String) -> Void)?
  /// The exec command's remote exit status (action sessions only).
  public var onExit: ((Int32) -> Void)?
  public var onHostKeyPrompt: ((TerminalHostKeyPrompt) -> Void)?
  public var onPasswordPrompt: ((TerminalPasswordPrompt) -> Void)?

  private var engine: SSHConnectionEngine?
  private var started = false

  public init(config: SSHConfig, execCommand: String? = nil) {
    self.config = config
    self.execCommand = execCommand
  }

  public func start() {
    guard !started else { return }
    started = true

    // The identity key lives in the Secure Enclave; it never touches disk.
    let key = try? SSHKeychain.loadOrCreateDefaultKey()
    let engine = SSHConnectionEngine(config: config, privateKey: key, execCommand: execCommand)

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
}
